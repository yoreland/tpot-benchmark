# B300 launch configs — 4 verified rounds (reproducible compose)

Four docker-compose files under `scripts/`, one per B300 serving config that was
**actually brought up and benched** across the last four rounds on
p6-b300.48xlarge (8x B300, 275 GB/card). Every image tag, model path, CLI flag,
port, env var and GPU-pinning below is transcribed verbatim from the run
summaries in `docs/run-summaries/` — nothing is invented. All four serve on the
loopback front door `127.0.0.1:30080`.

| # | Compose file | Round | Image | Model | Topology |
|---|---|---|---|---|---|
| 1 | `docker-compose-vllm-tp8-nvfp4.yaml` | vLLM TP8 NVFP4 | `vllm/vllm-openai:nightly` | `nvidia/DeepSeek-V4-Flash-nvfp4-DSpark` (NVFP4) | whole-machine TP8, expert-parallel, fp8 KV, DSpark |
| 2 | `docker-compose-vllm-pd-4p4d.yaml` | vLLM PD 4P4D | `vllm/vllm-openai:nightly` | `nvidia/DeepSeek-V4-Flash-nvfp4-DSpark` (NVFP4) | prefill GPUs 0-3 TP4 (kv_producer) + decode GPUs 4-7 TP4 (kv_consumer) + disagg proxy, NixlConnector |
| 3 | `docker-compose-sglang-tp8-preview-mxfp4.yaml` | SGLang preview TP8 mxfp4 | `lmsysorg/sglang:v0.5.17-cu130` | `deepseek-ai/DeepSeek-V4-Flash-DSpark` (fp8 / mxfp4 preview) | whole-machine TP8, `flashinfer_mxfp4` MoE, DSpark |
| 4 | `docker-compose-sglang-pd-4p4d.yaml` | SGLang preview PD 4P4D | `lmsysorg/sglang:v0.5.17-cu130` | `deepseek-ai/DeepSeek-V4-Flash-DSpark` (fp8 / mxfp4 preview) | prefill GPUs 0-3 TP4 + decode GPUs 4-7 TP4 (DSpark) + `sglang_router --pd-disaggregation`, nixl backend |

Source summaries:

- Rounds 1 & 2 (vLLM): `docs/run-summaries/b300-vllm-nvfp4-dspark-20260913-summary.md`,
  `docs/run-summaries/b300-vllm-pd-4p4d-20260913-summary.md`
- Rounds 3 & 4 (SGLang): `docs/run-summaries/b300-sglang-preview-dspark-tp8-vs-4p4d-20260914-summary.md`

All configs assume the model weights already live on the instance NVMe at
`/opt/dlami/nvme/models/...` (the paths baked into each compose command). Cold
start is ~11-18 min (weight load -> kernel JIT/autotune -> cuda-graph capture ->
server bind); the healthcheck `start_period` is set to 1800s to cover it.

## Usage

```bash
# pick one config
docker compose -f scripts/docker-compose-vllm-tp8-nvfp4.yaml up -d
# wait for the server(s) to become healthy (see docker compose ps), then bench
# against http://127.0.0.1:30080
```

For the PD configs the front door is a proxy/router; the underlying engines
expose their own `/health` (vLLM PD: `:8100` prefill, `:8200` decode; SGLang PD:
`:30000` prefill, `:30300` decode, router `:30080`). The vLLM disagg proxy itself
has no `/health` — check the two engine ports instead.

## Known gotchas / notes (all from the summaries, no new conclusions)

- **Bench `--random-range-ratio` is stack-specific and semantically opposite.**
  - vLLM nightly: use `--random-range-ratio 0.0` for a fixed 40k input
    (min == max == input_len). The nightly **rejects `1.0`** (it would mean 0 min
    tokens), which aborts every level instantly.
  - SGLang v0.5.17: use `--random-range-ratio 1.0` for a fixed 40k input
    (`range_ratio` is the MIN fraction here, so `1.0` => `[40000, 40000]`).
  - Do **not** copy vLLM's `0.0` into SGLang or vice-versa.
- **PD must pin physical cards explicitly.** Both PD configs pin GPUs per engine
  (`0-3` prefill / `4-7` decode). The original runs used docker
  `--gpus '"device=0,1,2,3"'` / `'"device=4,5,6,7"'`. `--gpus all` exposes all 8
  cards to each container and **overrides** `NVIDIA_VISIBLE_DEVICES`, so both TP4
  engines grab logical devices 0-3 and collide on physical GPUs 0-3 while 4-7 sit
  idle (the vLLM PD stand-up hit exactly this). In these compose files the pin is
  expressed via `deploy.resources.reservations.devices.device_ids`.
- **SGLang preview: disable megamoe on B300.** Use
  `--moe-runner-backend flashinfer_mxfp4`, NOT megamoe — megamoe + EP8 + DSPARK +
  cuda-graph crashes on B300. `dp-attention` is also left OFF on the PD config
  (it causes an AssertionError and GPU memory drops to 0).
- **SSM double-quote JSON needs base64.** The vLLM `--kv-transfer-config` /
  `--speculative-config` values contain double quotes that are fragile inside
  `aws ssm send-command commands=[...]`; the original runs base64-encoded the
  driver scripts before writing them to the instance to preserve quoting exactly.
  (These compose files quote the JSON inline instead, so no base64 is needed when
  using compose directly.)
- **PD-side DSpark acceptance is not observable.** On both PD configs the
  speculative-decode accept-rate/length stats stay inside the decode engine and
  are **not surfaced through the proxy/router** per request (unlike the TP8
  direct-to-engine runs). DSpark is confirmed active from the decode engine
  startup logs (`DSpark draft model loaded` / `Draft checkpoint bundles a DSpark
  head; loading draft arch DeepseekV4ForCausalLMDSpark`).
- **SGLang bench `--flush-cache` race.** `bench_serving`'s post-warmup
  `POST /flush_cache` has no retry and 400s while the large 40k-token warmup is
  still draining, aborting the run. The runs dropped `--flush-cache` and instead
  pre-flushed the prefix cache manually (retry `POST /flush_cache` until 200,
  settle 2s) before each level. The PD router does proxy `/flush_cache` to the
  engines.
- **SGLang v0.5.17-cu130, not v0.5.12.** v0.5.12 has a flash-mla kernel crash at
  >=16K context.
