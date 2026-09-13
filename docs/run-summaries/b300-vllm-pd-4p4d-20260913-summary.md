# B300 vLLM PD-disaggregated 4P4D ("第一种": lower TPOT) run summary — 2026-09-13

> Route: vLLM `nightly` + `nvidia/DeepSeek-V4-Flash-nvfp4-DSpark` (NVFP4), split
> into a **prefill instance (GPUs 0-3, TP4, kv_producer)** and a **decode
> instance (GPUs 4-7, TP4, kv_consumer)** connected over **NixlConnector**, with
> the disagg proxy on `127.0.0.1:30080`. `--kv-cache-dtype fp8`, DSpark
> speculative decoding kept on both sides.
>
> Goal (user, "第一种，我主要为了提升 tpot"): **lower TPOT** and stabilize the
> ITL p99 tail that spiked to 224-240 ms at c>=8 on the prior TP8 run.

## Environment

| Item | Value |
|---|---|
| Instance | `i-07a1fb189f180ff3e`, p6-b300.48xlarge (8x B300, 275 GB/card) |
| Account / Region | 077090643075 / us-west-2 |
| Access | AWS SSM `send-command` only (no interactive session) |
| vLLM version | `0.29.1rc1.dev9+g2671fedfc` (image `vllm/vllm-openai:nightly`) |
| Model | `/opt/dlami/nvme/models/nvidia__DeepSeek-V4-Flash-nvfp4-DSpark` (NVFP4 MoE) |
| served-model-name | `dsv4-nvfp4-dspark` |
| Topology | **PD-disaggregated 4P4D** (NixlConnector, V1) |
| Prefill engine | GPUs 0-3, TP4, `kv_role=kv_producer`, port `8100`, side-channel `5600` |
| Decode engine | GPUs 4-7, TP4, `kv_role=kv_consumer`, port `8200`, side-channel `5601` |
| Disagg proxy | `127.0.0.1:30080` (exposes `/v1/completions` + `/v1/chat/completions`; no `/health`) |
| gpu-memory-utilization | `0.90` (fit with headroom at TP4; no OOM, no drop needed) |
| KV transport | NIXL over shared host loopback (`--network host`), `UCX_TLS=cuda_ipc,cuda_copy,tcp` |
| Shared serving flags | `--tensor-parallel-size 4 --enable-expert-parallel --trust-remote-code --kv-cache-dtype fp8 --gpu-memory-utilization 0.90 --max-model-len 133120 --reasoning-parser deepseek_v4 --tool-call-parser deepseek_v4 --enable-auto-tool-choice` |
| DSpark | `--speculative-config '{"method":"dspark","num_speculative_tokens":7,"draft_sample_method":"greedy"}'` on **both** sides |
| Result files | `/opt/dlami/nvme/bench-out-vllm-pd/c{1,2,4,8,16}.json` + `.log`, `bench_runner.log` |

## Did it come up?

Yes. The 4P4D topology stood up cleanly in FEAT-002 and was **re-verified healthy
at the start of this bench run** (no relaunch needed):

- `curl :8100/health` = **200** (prefill), `curl :8200/health` = **200** (decode).
- All 8 GPUs loaded ~245,972 MiB each — prefill on 0-3, decode on 4-7 (no
  collision).
- Disagg proxy process alive on `:30080`; a smoke `/v1/chat/completions` through
  the proxy returned a valid completion (prefill -> NIXL KV transfer -> decode ->
  stream proven end to end).

Key green signals (from FEAT-002 cold start, ~11 min):
- `DSpark draft model loaded` — speculative-config recognized on both engines.
- `Setting kv cache block size to 256 for DEEPSEEK_SPARSE_SWA backend`, `Using
  BLHNC KV cache layout` on both — identical fp8 KV layout across producer/consumer.
- `TRT-LLM fused MoE ... 140 SMs used for MoE` + `UE8M0 for DeepGEMM` — NVFP4 MoE active.
- NixlConnector side-channel bind on `5600`/`5601`, NIXL handshake succeeded, no
  bind conflict; proxy log printed `Prefill node TTFT stats` (~5 ms).

## Troubleshooting narrative

Carried over from FEAT-002 (stand-up), plus this bench run:

1. **GPU collision (main stand-up blocker).** First launch used
   `docker run --gpus all` + `-e NVIDIA_VISIBLE_DEVICES=0,1,2,3 / 4,5,6,7`.
   `--gpus all` exposes all 8 cards to each container and **overrides**
   `NVIDIA_VISIBLE_DEVICES`, so vLLM TP4 grabbed logical devices 0-3 in *both*
   containers and they collided on physical GPUs 0-3 while 4-7 sat idle.
   **Fix:** pin physical cards with `--gpus '"device=0,1,2,3"'` (prefill) /
   `'"device=4,5,6,7"'` (decode) and drop the ineffective env var. Memory then
   split correctly 0-3 vs 4-7.
2. **DSpark + PD compatibility — CONFIRMED.** DSpark speculative decoding was kept
   enabled on both sides. It is **compatible with the NIXL PD path on this build**:
   no KV-shape mismatch, no error, no need for the "disable spec on both sides"
   fallback. This matters because the decode engine is exactly where DSpark +
   fp8-KV + NVFP4 do their TPOT/ITL work.
3. **fp8 KV cross-instance — matched cleanly.** Both engines use identical
   `--kv-cache-dtype fp8`, so producer and consumer KV layouts (block size 256,
   BLHNC layout, DEEPSEEK_SPARSE_SWA) matched with no producer/consumer mismatch.
4. **NIXL side-channel ports must differ** (`5600` prefill vs `5601` decode);
   rendezvous kv_port 14579 on shared 127.0.0.1 loopback. Handshake succeeded.
5. **SSM JSON quoting.** The `--kv-transfer-config` / `--speculative-config`
   values contain double quotes that are fragile inside `send-command`
   `commands=[...]`. **Fix:** base64-encode driver scripts
   (`launch_pd.sh`, `start_proxy.sh`, `run_bench.sh`, smoke payload) before
   writing them to the instance to preserve quoting exactly.
6. **gpu-mem-util 0.90 fit at TP4** on the 275 GB B300 cards (185.45 GiB KV per
   engine, ~1.9M-token GPU KV cache); no OOM, so no drop to 0.85/0.80.
7. **Bench run (this feature): clean.** All 5 concurrency levels ran through the
   proxy with 0 failed requests and `completed == num_prompts`. No NIXL handshake
   timeouts under concurrency, no OOM, no proxy 500s. `--random-range-ratio 0.0`
   used (this nightly rejects `1.0`), fixed 40k input confirmed
   (`Sampling input_len from [40000, 40000]`).

## Results — PD 4P4D (40k input / 1.5k output, `random`, fixed length)

Latencies in ms. Median + p99 only (bench default). 0 failed requests across all levels.

| conc | reqs | dur (s) | out tok/s | total tok/s | TTFT med | TTFT p99 | TPOT med | TPOT p99 | ITL med | ITL p99 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1  | 8  | 55.11 | 217.74 | 6036.18  | 1652.61 | 5913.00 | 3.09 | 3.67  | 7.50  | 11.28  |
| 2  | 8  | 30.02 | 399.74 | 11081.69 | 390.33  | 4843.08 | 3.41 | 7.84  | 8.20  | 14.88  |
| 4  | 12 | 31.69 | 567.92 | 15744.01 | 4074.17 | 6960.70 | 4.66 | 5.50  | 9.52  | 16.11  |
| 8  | 24 | 40.86 | 881.15 | 24427.22 | 1607.07 | 4447.76 | 6.61 | 13.78 | 11.29 | 153.29 |
| 16 | 48 | 58.22 | 1236.75| 34285.10 | 1652.70 | 5675.70 | 8.99 | 23.22 | 13.15 | 256.82 |

DSpark acceptance rate/length is **not exposed to the bench client through the
disagg proxy** (the proxy forwards the OpenAI response only; server-side
speculative-decode stats stay inside the decode engine and are not surfaced per
request as they were in the TP8 direct-to-engine run). DSpark is confirmed active
from the engine startup logs (`DSpark draft model loaded`).

## Direct comparison vs TP8 baseline

TP8 baseline (same 口径, from the prior `b300-vllm-nvfp4-dspark-20260913` run):

| conc | out tok/s (TP8 → PD) | TPOT med (TP8 → PD) | TPOT p99 (TP8 → PD) | ITL p99 (TP8 → PD) |
|---:|---:|---:|---:|---:|
| 1  | 218.24 → 217.74 | 3.17 → **3.09** | 6.89 → **3.67**  | 13.98 → **11.28** |
| 2  | 509.66 → 399.74 | 3.39 → 3.41     | 3.72 → 7.84      | 14.08 → 14.88 |
| 4  | 812.19 → 567.92 | 4.27 → 4.66     | 6.08 → **5.50**  | 17.40 → **16.11** |
| 8  | 1064.67 → 881.15| 6.00 → 6.61     | 8.74 → 13.78     | 224.70 → **153.29** |
| 16 | 1458.79 → 1236.75| 8.71 → 8.99    | 19.85 → 23.22    | 240.12 → 256.82 |

(Bold = PD improved on TP8. The c1 out tok/s cell 218.24 → 217.74 is a negligible
PD *regression* within run-to-run noise, so it is intentionally not bolded.)

> **Caveat — DSpark acceptance is unverified on the PD side.** This TPOT comparison
> implicitly assumes comparable DSpark speculative-decode acceptance across the two
> runs. The TP8 baseline reported accept rates of 11-21% (accept-length ~1.78-2.48),
> but those stats are **not observable through the disagg proxy** on the PD side
> (see the note above). DSpark is confirmed configured identically on both sides,
> yet realized acceptance could still differ. A slice of any TPOT delta below could
> therefore reflect a spec-decode-acceptance difference rather than the topology
> alone.

### Verdict

**Mixed / did NOT achieve the primary goal of lowering TPOT.**

- **TPOT median:** essentially unchanged, and slightly *worse* at higher
  concurrency. c1 improved marginally (3.17 → 3.09 ms), but c2/c4/c8/c16 all
  ticked up (e.g. c8 6.00 → 6.61, c16 8.71 → 8.99). PD disaggregation did **not**
  lower TPOT median — with only 4 decode cards vs 8, per-token decode compute has
  less parallelism, which offsets any benefit from removing prefill interference.
- **TPOT p99:** improved only at c1 (6.89 → 3.67) and c4 (6.08 → 5.50); *worse*
  at c2 (3.72 → 7.84), c8 (8.74 → 13.78), and c16 (19.85 → 23.22).
- **ITL p99 tail:** *partially* stabilized. The TP8 pain point at c8 dropped
  meaningfully (**224.70 → 153.29 ms**, a ~32% reduction), which is the one clear
  PD win — dedicating decode GPUs did smooth the mid-concurrency tail. But at c16
  the tail was **not** stabilized (240.12 → 256.82 ms, slightly worse), and low
  concurrency (c1/c2/c4) was already fine on both.
- **Throughput trade-off (reported honestly):** PD splits the 8 cards into 4+4, so
  peak output throughput dropped materially vs TP8 — c16 1458.79 → 1236.75 tok/s
  (~15% lower), c8 1064.67 → 881.15 (~17% lower), c4 812.19 → 567.92 (~30% lower).
  This is expected: the decode engine only has 4 GPUs, and prefill capacity is
  physically separated so it cannot absorb decode load.
- **TTFT:** noisier and generally higher under PD (extra prefill→NIXL→decode
  handoff), e.g. c4 median 394 → 4074 ms; not the target metric here but noted.

**Bottom line for "第一种 / lower TPOT":** on this hardware and 口径, PD 4P4D did
**not** deliver lower TPOT. TPOT median/p99 are flat-to-slightly-worse because
halving the decode GPU count (TP4 vs TP8) costs more than prefill-isolation saves.
The only durable benefit is a calmer ITL p99 tail at c8 (224.70 → 153.29 ms), and
that comes at a 15-30% peak-throughput cost. If the sole objective is lower TPOT,
**TP8 (the prior run) remains the better configuration**; PD 4P4D is preferable
only if smoothing the c8 ITL tail is worth the throughput sacrifice.

## Not done (by design)

Instance, prefill + decode engines, and the disagg proxy were **left running**.
No stop/terminate, no booking/spot deletion — irreversible teardown is handled by
the orchestrator after results are reported to the user.
