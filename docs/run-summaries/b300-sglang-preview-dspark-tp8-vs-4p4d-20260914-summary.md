# B300 SGLang preview DSpark: whole-machine TP8 vs 4P4D PD run summary (2026-09-14)

> Route: SGLang `v0.5.17-cu130` + preview `deepseek-ai/DeepSeek-V4-Flash-DSpark`
> (fp8 / mxfp4 preview), served in **two topologies** on the same 8x B300 and
> the same weight copy:
> - **Whole-machine TP8** (single engine, all 8 cards, direct to engine).
> - **4P4D PD-disaggregation** (prefill TP4 on GPUs 0-3 + decode TP4 on GPUs 4-7,
>   nixl transfer backend, SGLang native PD router, DSpark on the decode side).
>
> Both ran the identical bench 口径 (40k input / 1.5k output, c=1/2/4/8/16) over
> loopback `127.0.0.1:30080`. Goal (user, "整机 + 4p4d"): compare TPOT / ITL
> between the two topologies on this preview stack.

## Environment

| Item | Value |
|---|---|
| Instance | `i-0230a688056b553f5`, p6-b300.48xlarge (8x B300, 275 GB/card) |
| Account / Region / AZ | 077090643075 / us-west-2 / us-west-2a |
| Access | AWS SSM `send-command` only (no interactive session; loopback bench) |
| Serving endpoint | `127.0.0.1:30080` (loopback; SG has no ingress) |
| SGLang image | `lmsysorg/sglang:v0.5.17-cu130` (v0.5.12 has a flash-mla kernel crash >=16K) |
| Model | preview `deepseek-ai/DeepSeek-V4-Flash-DSpark` (fp8 / mxfp4), 156 GB on disk, 48 shards, at `/opt/dlami/nvme/models/deepseek-ai__DeepSeek-V4-Flash-DSpark` |
| MoE runner | `--moe-runner-backend flashinfer_mxfp4` (NOT megamoe; megamoe+EP8+DSPARK+cuda-graph crashes on B300) |
| DSpark | `--speculative-algorithm DSPARK` (draft arch `DeepseekV4ForCausalLMDSpark`) |
| Topology A (TP8) | one engine, `--tp 8`, all 8 GPUs, bench direct to engine on `127.0.0.1:30080` |
| Topology B (4P4D) | prefill engine GPUs 0-3 (`--tp 4`, `--disaggregation-mode prefill`, bootstrap port 9000, port 30000) + decode engine GPUs 4-7 (`--tp 4`, `--disaggregation-mode decode`, bootstrap port 9300, port 30300, DSpark), `--disaggregation-transfer-backend nixl`, `sglang_router --pd-disaggregation` on `127.0.0.1:30080` |
| mem-fraction-static | `0.90` on both topologies (no OOM at either TP8 or TP4) |
| TP8 result files | `/opt/dlami/nvme/bench-out/c{1,2,4,8,16}.jsonl` + `.log` |
| 4P4D result files | `/opt/dlami/nvme/bench-out-pd/c{1,2,4,8,16}.jsonl` + `.log` |

## Did it come up?

Yes, both topologies came up cleanly and ran the full sweep with 0 failed requests.

### Weight download (once, reused by both)

**Succeeded.** The historical `exit(1)` from platform auto-deploy did **NOT**
reproduce when downloading manually. The preview repo
`deepseek-ai/DeepSeek-V4-Flash-DSpark` is **public**: it downloaded unauthenticated
(no `HF_TOKEN` needed; HF only warned about lower anonymous rate limits).
`dl_preview.log` ended with `Fetching 74 files: 100%`, `156G`, `DOWNLOAD_DONE`:
48 safetensors shards + `config.json` + tokenizer/encoding/inference files.
The single copy was reused in place by both topologies (never re-downloaded).

### Whole-machine TP8 bring-up

- `/health` returns **200**. Cold start ~13 min wall (weight load 48/48 shards
  ~390 s -> FlashInfer `trtllm_fp4_block_scale_moe` autotune ~85 s -> DeepGEMM JIT
  precompile -> cuda-graph capture incl. spec-decode graphs) -> "The server is
  fired up and ready to roll!".
- **DSpark confirmed** on all 8 TP ranks:
  `Draft checkpoint bundles a DSpark head; loading draft arch
  DeepseekV4ForCausalLMDSpark.` Also `Auto-detected DSV4 routed-expert layout:
  is_fp4_experts=True`.
- **No OOM** at `--mem-fraction-static 0.90`: all 8 GPUs ~252.5 GB used (0.90 of
  275 GB). megamoe was correctly avoided; `flashinfer_mxfp4` loaded as
  `Mxfp4FlashinferTrtllmMoEMethod`.
- Smoke `/v1/chat/completions` ("capital of France?") -> "The capital of France is
  Paris." (finish_reason=stop). End-to-end generation confirmed.
- **DSpark accept length 5.47-5.76** across all levels (far above 1.0), surfaced
  because the bench ran direct to the engine.

### 4P4D PD bring-up

- Stood up on the **first try** with SGLang native PD + **nixl** transfer backend
  (mooncake not attempted; nixl worked as the reference predicted). Cold start
  ~11-12 min; both engines logged "Disaggregation warmup requests completed" ->
  "End of disaggregation warmup" -> "The server is fired up and ready to roll!",
  i.e. the PD bootstrap handshake succeeded and a warmup request already flowed
  prefill -> nixl KV transfer -> decode.
- **No GPU collision.** Physical cards pinned explicitly with docker
  `--gpus '"device=0,1,2,3"'` (prefill) / `'"device=4,5,6,7"'` (decode); did NOT
  use `--gpus all`. nvidia-smi confirmed the clean split: prefill GPUs 0-3 each
  ~253 GB, decode GPUs 4-7 each ~252 GB. The prior vLLM PD run's `--gpus all`
  collision did not recur.
- **DSpark on decode is compatible with PD.** DSpark stayed on the decode side
  (`--speculative-algorithm DSPARK`); all 4 decode TP ranks logged the
  `Draft checkpoint bundles a DSpark head; loading draft arch
  DeepseekV4ForCausalLMDSpark` line. No KV-shape mismatch, no fallback needed.
  `dp-attention` left OFF (it causes AssertionError + GPU mem drop to 0).
- Router `sglang_router --pd-disaggregation --prefill http://127.0.0.1:30000 9000
  --decode http://127.0.0.1:30300 --host 0.0.0.0 --port 30080` exposed the PD
  endpoint on the same loopback `127.0.0.1:30080` as TP8, so the identical bench
  command was reused. Router `/health` = 200.
- **Benign router warning** (left as-is): `Model ... has conflicting
  load_balance_method: prefill=Some("follow_bootstrap_room"),
  decode=Some("round_robin")`. This is normal for PD (each side uses its own
  policy); both workers still report healthy and route correctly.
- Smoke `/v1/chat/completions` through the router -> "The capital of France is
  Paris." (finish_reason=stop). PD path proven router -> prefill(0-3) -> nixl KV
  transfer -> decode(4-7, DSpark) -> stream, end to end.

## Troubleshooting narrative

1. **The `--flush-cache` race (both topologies).** `bench_serving`'s post-warmup
   `flush_server_cache()` fires a single `POST /flush_cache` with **no retry**;
   SGLang returns **HTTP 400** whenever running/waiting requests still exist, and
   with the large 40k-in / 1.5k-out warmup request still draining, the flush
   deterministically 400s -> `raise_for_status()` aborts the entire run
   (reproduced twice at c=1 on TP8). **Fix:** drop `--flush-cache` from the bench
   command and instead pre-flush **manually** on the idle server/router before
   each level (POST `/flush_cache` retrying until 200, settle 2 s, then run bench
   without `--flush-cache`). Identical goal (measured run starts with an empty
   prefix cache), no race. The router **does** proxy `POST /flush_cache` to the
   engines (returns 200), so the same manual pre-flush works through the PD router.
2. **Range-ratio semantics: do NOT copy vLLM's value.** On SGLang v0.5.17,
   `--random-range-ratio 1.0` yields a **fixed 40k input** (`range_ratio` is the
   MIN fraction; 1.0 => `[40000, 40000]`). Validated at c=1 on both topologies:
   `#Input tokens` = exactly 40000/req, `#Output tokens` = 1500/req. This is the
   **opposite** of the prior vLLM runs, where the `random` dataset's `range_ratio`
   is the *variation* fraction and `1.0` is rejected (0 min tokens), so vLLM needed
   `0.0`. **Do not copy vLLM's `0.0` to SGLang**; `1.0` is correct here.
3. **`mkdir`-before-`nohup` redirect hiccup (4P4D).** The first background `nohup`
   of the c=1 validation died instantly because its stdout was redirected into
   `/opt/dlami/nvme/bench-out-pd/validate_c1.runlog` before that directory existed
   (the redirect target's parent must pre-exist). **Fix:** `mkdir -p
   /opt/dlami/nvme/bench-out-pd` before launching any nohup that logs into it;
   applied to the sweep launch too. Not a model blocker.

No model-level blockers were hit on either topology. None of the PD fallbacks
(switch transfer backend nixl<->mooncake, disable DSpark on decode to validate the
base PD path, adjust mem-fraction) were needed.

## Results

Fixed 40k input / 1.5k output, `--dataset-name random --random-range-ratio 1.0`,
backend `sglang-oai`. Latencies in ms; throughput in tok/s. 0 failed requests
(`completed == num_prompts`) at every level on both topologies. NP map
{1:8, 2:8, 4:12, 8:24, 16:48}.

### (a) Whole-machine TP8 (bench direct to engine on 127.0.0.1:30080)

| conc | reqs | out tok/s | total tok/s | TTFT med | TTFT p90 | TTFT p99 | TPOT med | TPOT p90 | TPOT p99 | ITL med | ITL p90 | ITL p99 | accept len |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1  | 8/8   | 356.5 | 9864  | 1711.26 | 3922    | 3945.79  | 1.20  | 1.37  | 1.43  | 1.19 | 1.42 | 2.36   | 5.74 |
| 2  | 8/8   | 573.3 | 15860 | 1692    | 2022    | 2622     | 2.36  | 3.01  | 4.05  | 1.29 | 1.55 | 2.60   | 5.76 |
| 4  | 12/12 | 511.8 | 14159 | 2932    | 6918    | 8016     | 5.38  | 8.72  | 11.33 | 1.44 | 1.73 | 17.35  | 5.64 |
| 8  | 24/24 | 780.0 | 21581 | 3267    | 9074    | 11381    | 7.17  | 10.51 | 15.72 | 1.67 | 2.02 | 66.02  | 5.63 |
| 16 | 48/48 | 763.3 | 21119 | 4206.86 | 16741   | 23490.85 | 15.02 | 24.54 | 37.13 | 1.96 | 2.93 | 507.52 | 5.47 |

DSpark accept length **5.47-5.76** at every level (draft arch
`DeepseekV4ForCausalLMDSpark` accepting ~5-6 tokens/step), surfaced because the
bench ran direct to the engine.

### (b) 4P4D PD (bench via the SGLang PD router on 127.0.0.1:30080)

| conc | reqs | out tok/s | total tok/s | TTFT med | TTFT p90 | TTFT p99 | TPOT med | TPOT p90 | TPOT p99 | ITL med | ITL p90 | ITL p99 |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1  | 8/8   | 362.8 | 10036 | 1834.43  | 4000  | 4002.77  | 1.22 | 1.40 | 1.47 | 7.07 | 7.12 | 7.20  |
| 2  | 8/8   | 523.9 | 14493 | 2852     | 4923  | 5408     | 1.26 | 1.94 | 2.12 | 7.10 | 7.72 | 7.85  |
| 4  | 12/12 | 814.5 | 22535 | 3780     | 5781  | 6362     | 1.33 | 1.65 | 1.84 | 7.13 | 8.27 | 10.96 |
| 8  | 24/24 | 880.3 | 24355 | 9614     | 11653 | 12395    | 1.32 | 1.42 | 1.52 | 7.12 | 7.76 | 8.67  |
| 16 | 48/48 | 917.7 | 25390 | 21929.31 | 23131 | 24780.18 | 1.32 | 1.45 | 1.56 | 7.12 | 7.75 | 8.48  |

DSpark acceptance rate/length is **not surfaced to the bench client through the PD
router** (the router forwards only the OpenAI response; server-side spec-decode
stats stay inside the decode engine and are not surfaced per request as they were
in the TP8 direct-to-engine run). This is the **same limitation** as the prior
vLLM PD run. DSpark is **confirmed active** from the decode engine startup log
(`Draft checkpoint bundles a DSpark head; loading draft arch
DeepseekV4ForCausalLMDSpark` on all 4 decode ranks), and the very low / flat ITL
(~7.1 ms median at every level) and flat TPOT (~1.3 ms) are consistent with the
strongly-accepting TP8 run.

### (c) TP8 vs 4P4D side-by-side (bold = winning cell)

| conc | out tok/s (TP8 → PD) | TPOT med (TP8 → PD) | TPOT p99 (TP8 → PD) | ITL med (TP8 → PD) | ITL p99 (TP8 → PD) | TTFT med (TP8 → PD) |
|---:|---:|---:|---:|---:|---:|---:|
| 1  | 356.5 → **362.8** | **1.20** → 1.22 | **1.43** → 1.47 | **1.19** → 7.07 | **2.36** → 7.20 | **1711** → 1834 |
| 2  | 573.3 → 523.9     | 2.36 → **1.26** | 4.05 → **2.12** | **1.29** → 7.10 | 2.60 → 7.85 | **1692** → 2852 |
| 4  | 511.8 → **814.5** | 5.38 → **1.33** | 11.33 → **1.84**| **1.44** → 7.13 | 17.35 → **10.96** | **2932** → 3780 |
| 8  | 780.0 → **880.3** | 7.17 → **1.32** | 15.72 → **1.52**| **1.67** → 7.12 | 66.02 → **8.67** | **3267** → 9614 |
| 16 | 763.3 → **917.7** | 15.02 → **1.32**| 37.13 → **1.56**| **1.96** → 7.12 | 507.52 → **8.48** | **4206** → 21929 |

Reading notes for the ITL columns: **ITL median** - TP8 wins at every level
(~1.2-2.0 ms vs PD's ~7.1 ms flat), because on TP8 each DSpark step emits ~5-6
accepted tokens so the *median* inter-token gap is tiny, whereas the PD router
measures a steady ~7.1 ms inter-token cadence. **ITL p99** - PD wins from c4
upward: TP8's p99 tail blows out (c8 66.02 ms, **c16 507.52 ms**) while PD stays
calm (<=10.96 ms at every level). At c1 TP8's ITL p99 (2.36 ms) is still lower than
PD's (7.20 ms), so that cell bolds TP8; the PD ITL p99 win only emerges from c4 up.

### Verdict: which topology is better for TPOT / ITL?

**4P4D wins decisively on TPOT and on the ITL p99 tail; TP8 wins on ITL median and
on TTFT.** This is the opposite outcome from the prior vLLM 4P4D run (where PD did
not lower TPOT), and it is driven by how the two stacks expose latency:

- **TPOT: 4P4D wins clearly.** PD TPOT median is **flat and very low at ~1.3 ms
  across all concurrency** (1.22 → 1.32 ms from c1 to c16), and TPOT p99 stays
  <=2.12 ms everywhere. TP8 TPOT median rises steeply with load (1.20 → **15.02**
  ms at c16) and TPOT p99 hits 37.13 ms at c16. Dedicating 4 cards purely to decode
  keeps per-token decode latency flat and removes prefill interference, so if the
  objective is low/stable TPOT, **4P4D is the better topology**.
- **ITL p99 tail: 4P4D wins.** TP8's tail blows out under load (c8 66.02 ms, c16
  **507.52 ms**) from prefill/decode contention on the shared 8 cards. PD keeps the
  ITL p99 calm at **<=10.96 ms at every level** (c16 8.48 ms). The severe TP8 c16
  tail is essentially gone under PD.
- **ITL median: TP8 wins.** TP8 records ~1.2-2.0 ms median inter-token gaps
  (DSpark emits ~5-6 tokens per verified step, so the typical gap is tiny), vs PD's
  steady ~7.1 ms cadence through the router. So TP8 has the lower *typical*
  inter-token latency even though its *tail* is far worse.
- **TTFT: TP8 wins, and it is the 4P4D cost.** TP8 TTFT median is 1.7-4.2 s and
  grows gently; 4P4D TTFT median grows steeply with concurrency (c8 9.6 s, **c16
  ~21.9 s** vs TP8's ~4.2 s) because prefill has only 4 cards plus the PD handoff.
  If TTFT (prompt responsiveness) matters, TP8 is better.
- **Throughput.** Roughly comparable, with PD ahead at higher concurrency (c16 out
  917.7 vs 763.3 tok/s, c8 880.3 vs 780.0), because PD's dedicated decode cards are
  not stalled by incoming prefills. TP8 leads only at c2.

**Bottom line for "整机 vs 4p4d" on TPOT / ITL:** **4P4D is the better topology for
TPOT and for the ITL p99 tail**: TPOT stays flat at ~1.3 ms and the ITL p99 tail
never exceeds ~11 ms at any concurrency, versus TP8's TPOT climbing to 15 ms and
its ITL p99 exploding to 507 ms at c16. The cost is much higher TTFT (c16 ~22 s vs
~4.2 s, only 4 prefill cards + PD handoff) and a higher *median* ITL. TP8 remains
preferable when TTFT/prompt-responsiveness is the priority or when DSpark
acceptance visibility is required (see caveat).

> **Caveat: DSpark acceptance is unverified on the PD side.** The TPOT/ITL
> comparison implicitly assumes comparable DSpark speculative-decode acceptance
> across the two runs. TP8 reported accept length **5.47-5.76**, but those stats
> are **not observable through the PD router** (see table (b) note). DSpark is
> confirmed configured and loaded identically on the decode side, and the flat
> ~7.1 ms ITL / ~1.3 ms TPOT are consistent with strong acceptance, yet realized
> acceptance could still differ. A slice of any TPOT/ITL delta could therefore
> reflect a spec-decode-acceptance difference rather than the topology alone.

## Not done (by design)

The instance `i-0230a688056b553f5`, **both topologies' servers** (currently the
4P4D PD prefill + decode engines + the router, left running from FEAT-003), and
booking `5bd1f130-904a-45f9-86f7-ffc1cd580682` were **left running**. No
stop/terminate, no booking deletion. Irreversible teardown is the orchestrator's
call after results are reported to the user. The TP8 artifacts in
`/opt/dlami/nvme/bench-out/` and the 4P4D artifacts in
`/opt/dlami/nvme/bench-out-pd/` are preserved on the instance NVMe.
