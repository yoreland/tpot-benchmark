# B300 vLLM + NVFP4 DSpark ("选 B") run summary — 2026-09-13

> Route: vLLM `nightly` + `nvidia/DeepSeek-V4-Flash-nvfp4-DSpark` (NVFP4), TP8,
> expert-parallel, `--kv-cache-dtype fp8`, DSpark speculative decoding.
> This route had never succeeded before. **It succeeded this time.**

## Environment

| Item | Value |
|---|---|
| Instance | `i-07a1fb189f180ff3e`, p6-b300.48xlarge (8x B300, 275 GB/card) |
| Account / Region / AZ | 077090643075 / us-west-2 / us-west-2a |
| Access | AWS SSM `send-command` only (no interactive session) |
| Serving endpoint | `127.0.0.1:30080` (loopback; SG has no ingress) |
| Model | `/opt/dlami/nvme/models/nvidia__DeepSeek-V4-Flash-nvfp4-DSpark` (165 GB, 46 shards, `model_type=deepseek_v4`, NVFP4 MoE) |
| vLLM version | `0.29.1rc1.dev9+g2671fedfc` (image `vllm/vllm-openai:nightly`) |
| served-model-name | `dsv4-nvfp4-dspark` |
| Result files | `/opt/dlami/nvme/bench-out-vllm/c{1,2,4,8,16}.json` + `.log`, `runner.log` |

## Did it come up?

Yes. `/health` returns 200. Startup took ~18 min (one-time): weight load (~53 s)
-> CUDA/DeepGEMM kernel compile (`cicc`) -> JIT kernel warmup -> FlashInfer
autotune (22 token buckets x8 workers) -> API server bind ("Application startup
complete"). A smoke `/v1/chat/completions` returned a valid completion and the
DSpark speculative-decode path was confirmed active.

Key green signals from startup log:
- `dspark.py:510] DSpark draft model loaded: 109 params` — speculative-config
  `{"method":"dspark","num_speculative_tokens":7,...}` recognized by vLLM.
- `Setting kv cache block size to 256 for DEEPSEEK_SPARSE_SWA backend` — fp8 KV
  layout honored (`--kv-cache-dtype fp8` required for DeepSeek-V4 fp8_ds_mla).
- `TRT-LLM fused MoE ... 140 SMs used for MoE` + `UE8M0 for DeepGEMM` — NVFP4
  MoE path active. No OOM, no TP/EP init errors.

## The blocker this time (and the fix)

The vLLM **server** came up clean — the historical failure did NOT reproduce at
launch. The one snag was in the **benchmark client**, not the server:

- `vllm bench serve` in this nightly build **rejects `--random-range-ratio 1.0`**
  (the exact value in the Runbook). It raises
  `ValueError: --random-input-len is too small ... input range ratio 1.0 ...
  minimum possible total input tokens is 0`. All 5 concurrency runs failed
  instantly on the first sample() call, producing no results.
- Root cause: the `random` dataset changed semantics. `range_ratio` is now the
  *variation fraction*: min sampled len = `floor(input_len * (1 - range_ratio))`.
  At `1.0` that is 0 (rejected). The Runbook's intent ("exactly 40k, no variance")
  is now expressed as **`--random-range-ratio 0.0`** (min == max == input_len).
- Fix applied: changed `--random-range-ratio 1.0` -> `0.0`. Everything else kept
  identical. Re-ran; all 5 levels passed with total_input_tokens ~40083/req.

## Results (40k input / 1.5k output, `random`, fixed length)

p90 was not captured (bench default saved median + p99 only). Latencies in ms.

| conc | reqs | dur (s) | out tok/s | total tok/s | TTFT med | TTFT p99 | TPOT med | TPOT p99 | ITL med | ITL p99 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1  | 8  | 54.99 | 218.24 | 6049.97  | 747.70 | 2259.72 | 3.17 | 6.89  | 7.04  | 13.98  |
| 2  | 8  | 23.54 | 509.66 | 14128.86 | 191.89 | 2398.15 | 3.39 | 3.72  | 7.52  | 14.08  |
| 4  | 12 | 22.16 | 812.19 | 22515.60 | 394.16 | 812.32  | 4.27 | 6.08  | 8.64  | 17.40  |
| 8  | 24 | 33.81 | 1064.67| 29514.91 | 786.90 | 3203.82 | 6.00 | 8.74  | 9.99  | 224.70 |
| 16 | 48 | 49.36 | 1458.79| 40440.61 | 769.22 | 3937.24 | 8.71 | 19.85 | 11.24 | 240.12 |

Speculative decoding (DSpark) acceptance:

| conc | accept rate % | accept length |
|---:|---:|---:|
| 1  | 11.09 | 1.78 |
| 2  | 18.50 | 2.30 |
| 4  | 17.89 | 2.25 |
| 8  | 21.08 | 2.48 |
| 16 | 14.46 | 2.01 |

Notes:
- 0 failed requests across all 5 levels.
- No 0731 same-口径 baseline file exists on the instance, so this is reported
  standalone. The repo's `b300-matrix-20260809-c1-summary.md` is a different
  serving stack (SGLang EAGLE) and is not directly comparable.
- Throughput scales cleanly with concurrency (6.0k -> 40.4k total tok/s from c1
  to c16). ITL p99 jumps at c>=8 (batching/queueing), TPOT median stays single/low
  double-digit ms.

## Not done (by design)

Runbook Step 5 (DELETE booking / stop instance for cost) was intentionally NOT
executed. Instance left running with the vLLM server healthy for the orchestrator
to confirm results with the user before any irreversible teardown.
