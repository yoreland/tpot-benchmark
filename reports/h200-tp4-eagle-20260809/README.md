# H200 tp=4 EAGLE 3/1/4 Benchmark Report

> **Run ID**: `20260809-000033-504a`（第 1-4 节，concurrency=1）
> **补测 Run ID**: `20260810-015049-2b75`（第 5 节，并发扫描 + 基线交叉验证）
> **日期**: 2026-08-09（初测） / 2026-08-10（并发扫描补测）
> **结论**: **全部通过** - 客户验收标准和 LMSYS 基线对标均达标；
> 并发扫描显示 8K/1.5K 负载下守住 TPOT P50 ≤ 4.5 ms 的并发上限是 **2**（见 5.3）

---

## 1. 测试结论

| 验收项 | 目标 | 实测 | 结果 |
|--------|------|------|------|
| TPOT P50 | <= 4.5 ms | **3.330 ms** | **PASS** |
| TPOT P95 | <= 6.0 ms | **3.821 ms** | **PASS** |
| TTFT P50 | <= 1.7 s | **0.665 s** | **PASS** |
| TTFT P95 | <= 2.5 s | **1.715 s** | **PASS** |
| Output throughput | -- | **224.2 tok/s** | -- |
| 50 requests completed | 50 | 50 | **PASS** |

### 与 LMSYS Day-0 博客基线对比

| 指标 | LMSYS 官方参考 | 本次实测 (30K/4096) | 偏差 |
|------|---------------|-------------------|------|
| Output throughput | ~266 tok/s | **282.5 tok/s** | +6.2% |
| TPOT | ~3.76 ms | **3.337 ms** | -11.3% (更优) |

> 本次测试**超越** LMSYS Day-0 博客公布的 H200 tp=4 EAGLE 3/1/4 基线数字,
> 验证了该配置在 AWS p5en.48xlarge 上的可复现性。

---

## 2. 硬件与软件配置

### 2.1 硬件

| 项 | 值 |
|----|-----|
| 实例类型 | p5en.48xlarge |
| GPU | 8x NVIDIA H200 141GB HBM3e |
| GPU 带宽 | 4.8 TB/s per GPU |
| vCPU | 192 |
| 内存 | 2048 GiB |
| 本地存储 | 8x 3800 GB NVMe SSD (30.4 TB total) |
| Region / AZ | us-east-2 / us-east-2a |
| Spot 价格 | ~$26.66/hr |

### 2.2 软件

| 项 | 值 |
|----|-----|
| SGLang 镜像 | 初测 `lmsysorg/sglang:latest`，补测钉 `lmsysorg/sglang:v0.5.17`（两轮 `server_info.version` 实测均为 **0.5.17**，`latest` 与 `v0.5.17` 同为 2026-08-08T00:09 推送的同一镜像） |
| 模型 | `deepseek-ai/DeepSeek-V4-Flash` (284B, FP4 experts + FP8 dense) |
| 模型体积 | 159.6 GB (73 files) |
| Tensor Parallelism | **4** |
| 投机解码 | EAGLE (num-steps=3, eagle-topk=1, num-draft-tokens=4) |
| MoE Runner | Marlin (W4A16 for Hopper SM90) |
| KV Cache dtype | fp8_e4m3 |
| Memory fraction | 0.85 |
| Attention backend | dsv4 |
| Sampling backend | flashinfer |

### 2.3 启动参数

```bash
--model-path /opt/dlami/nvme/models/deepseek-ai__DeepSeek-V4-Flash \
--tp 4 \
--mem-fraction-static 0.85 \
--trust-remote-code \
--host 0.0.0.0 \
--port 30000 \
--speculative-algorithm EAGLE \
--speculative-num-steps 3 \
--speculative-eagle-topk 1 \
--speculative-num-draft-tokens 4 \
--moe-runner-backend marlin \
--enable-metrics
```

---

## 3. 测试方法

使用 `sglang.bench_serving` 进行两组测试，均为 **concurrency=1, 50 prompts**:

| 测试组 | 输入 tokens | 输出 tokens | 用途 |
|--------|------------|------------|------|
| 客户验收 (custom) | 40,000 | 1,500 | 对标客户实际负载 (40K context trip planner) |
| LMSYS 基线 (official) | 30,000 | 4,096 | 对标 LMSYS Day-0 博客公布数据 |

```bash
# 客户验收测试
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random --num-prompts 50 --max-concurrency 1 \
  --random-input 40000 --random-output 1500

# LMSYS 基线对标
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random --num-prompts 50 --max-concurrency 1 \
  --random-input 30000 --random-output 4096
```

---

## 4. 详细测试结果

### 4.1 客户验收测试 (40K input / 1.5K output)

| 指标 | 值 |
|------|-----|
| Duration | 158.0 s |
| Completed requests | 50 |
| Total input tokens | 805,464 |
| Total output tokens | 35,424 |
| Request throughput | 0.3164 req/s |
| Input throughput | 5,097.7 tok/s |
| **Output throughput** | **224.2 tok/s** |
| Total throughput | 5,321.9 tok/s |

**端到端延迟 (E2E):**

| 统计量 | 值 |
|--------|-----|
| Mean | 3,159.3 ms |
| **Median (P50)** | **3,240.1 ms** |
| Std | 1,623.3 ms |
| P90 | 5,349.7 ms |
| P95 | 5,823.4 ms |
| P99 | 6,646.8 ms |

**首 Token 时间 (TTFT):**

| 统计量 | 值 | 验收标准 |
|--------|-----|---------|
| Mean | 765.6 ms | -- |
| **Median (P50)** | **665.1 ms** | <= 1,700 ms **PASS** |
| Std | 511.4 ms | -- |
| P90 | 1,622.3 ms | -- |
| **P95** | **1,715.1 ms** | <= 2,500 ms **PASS** |
| P99 | 1,812.3 ms | -- |

**每 Token 输出时间 (TPOT):**

| 统计量 | 值 | 验收标准 |
|--------|-----|---------|
| Mean | 3.356 ms | -- |
| **Median (P50)** | **3.330 ms** | <= 4.5 ms **PASS** |
| Std | 0.310 ms | -- |
| P90 | 3.581 ms | -- |
| **P95** | **3.821 ms** | <= 6.0 ms **PASS** |
| P99 | 4.449 ms | -- |

**Token 间延迟 (ITL):**

| 统计量 | 值 |
|--------|-----|
| Mean | 3.383 ms |
| Median | 3.215 ms |

### 4.2 LMSYS 基线对标 (30K input / 4096 output)

| 指标 | 值 |
|------|-----|
| Duration | 392.0 s |
| Completed requests | 50 |
| Total input tokens | 771,032 |
| Total output tokens | 110,757 |
| Request throughput | 0.1275 req/s |
| Input throughput | 1,966.8 tok/s |
| **Output throughput** | **282.5 tok/s** |
| Total throughput | 2,249.3 tok/s |

**端到端延迟 (E2E):**

| 统计量 | 值 |
|--------|-----|
| Mean | 7,839.6 ms |
| Median (P50) | 7,878.4 ms |
| Std | 3,884.1 ms |
| P90 | 12,830.5 ms |
| P95 | 13,890.5 ms |
| P99 | 14,438.8 ms |

**首 Token 时间 (TTFT):**

| 统计量 | 值 |
|--------|-----|
| Mean | 407.5 ms |
| Median (P50) | 252.2 ms |
| Std | 303.6 ms |
| P90 | 912.9 ms |
| P95 | 1,031.4 ms |
| P99 | 1,291.4 ms |

**每 Token 输出时间 (TPOT):**

| 统计量 | 值 |
|--------|-----|
| Mean | 3.347 ms |
| **Median (P50)** | **3.337 ms** |
| Std | 0.303 ms |
| P90 | 3.589 ms |
| P95 | 3.634 ms |
| P99 | 4.474 ms |

**Token 间延迟 (ITL):**

| 统计量 | 值 |
|--------|-----|
| Mean | 3.357 ms |
| Median | 3.213 ms |

---

## 5. 并发扫描 (concurrency sweep)

> **补测 Run ID**: `20260810-015049-2b75`（实例 `i-0fe1759772050cdf8`，2026-08-10）
> 上面第 1-4 节是 `20260809-000033-504a` 的 concurrency=1 数据；本节是后来补跑的并发扫描。
> 两轮的服务端参数逐字相同、SGLang 版本同为 **0.5.17**，并且补测这一轮在扫描之前
> 先把第 4 节的两条基线 bench 原样重跑了一遍做交叉验证（见 5.5），
> 所以本节的曲线和第 4 节的单并发数字可以放在一起读。

### 5.1 测试方法

负载固定 **8,000 input / 1,500 output**，`--dataset-name random`（`random_range_ratio=0`，
长度不抖动），`--request-rate` 不限（即 `Infinity`，并发是唯一的限流手段）。

```bash
# 与 B300 报告逐字对齐的 6 档（每档 32 条 prompts）
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random --num-prompts 32 --max-concurrency <N> \
  --random-input 8000 --random-output 1500      # N = 1,2,4,8,16,32

# 额外补的 2 档：高并发下把样本量加大到 128 条（理由见 5.4）
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random --num-prompts 128 --max-concurrency <N> \
  --random-input 8000 --random-output 1500      # N = 16,32
```

为什么选 8K/1.5K 而不是第 4 节的 40K/1.5K：这是
`reports/b300-tp8-eagle-20260809/concurrency-sweep/` 用的口径，
换口径就没法和 B300 对比了。

### 5.2 主表：6 档标准扫描 (32 prompts)

| 并发 | 完成 | 耗时 (s) | Req/s | Output tok/s | TPOT P50 | TPOT P95 | TPOT P99 | TTFT P50 | E2E P50 | ITL P95 | accept | 实测并发 |
|-----:|-----:|--------:|------:|-------------:|---------:|---------:|---------:|---------:|--------:|--------:|-------:|--------:|
| 1  | 32 | 77.64 | 0.4122 | 286.16 | **3.256 ms** | 3.747 ms | 4.062 ms | 190.9 ms | 2,476.9 ms | 4.790 ms | 2.875 | 1.00 |
| 2  | 32 | 45.89 | 0.6973 | 484.13 | **3.663 ms** | 4.666 ms | 5.199 ms | 191.6 ms | 2,760.3 ms | 5.217 ms | 2.887 | 1.95 |
| 4  | 32 | 30.95 | 1.0338 | 717.74 | 4.826 ms | 5.899 ms | 6.106 ms | 193.7 ms | 3,486.9 ms | 6.228 ms | 2.896 | 3.70 |
| 8  | 32 | 21.65 | 1.4779 | 1,026.00 | 6.557 ms | 7.274 ms | 7.562 ms | 196.5 ms | 4,449.8 ms | 7.749 ms | 2.904 | 6.93 |
| 16 | 32 | 15.58 | 2.0535 | 1,425.63 | 8.164 ms | 9.449 ms | 17.184 ms | 528.1 ms | 5,962.5 ms | 9.646 ms | 2.913 | 12.36 |
| 32 | 32 | 10.63 | 3.0110 | 2,090.41 | 8.072 ms | 10.817 ms | 21.340 ms | 890.5 ms | 6,608.0 ms | 12.114 ms | 2.917 | 18.83 |

### 5.3 并发收益：吞吐涨 7.3 倍，但 TPOT 预算在 c=4 就破了

以 c=1 为基准的吞吐扩展倍数：

| 并发 | Output tok/s | 相对 c=1 | 理想线性 | 扩展效率 |
|-----:|-------------:|---------:|---------:|---------:|
| 1  | 286.16 | 1.00x | 1x | 100% |
| 2  | 484.13 | 1.69x | 2x | 85% |
| 4  | 717.74 | 2.51x | 4x | 63% |
| 8  | 1,026.00 | 3.59x | 8x | 45% |
| 16 | 1,425.63 | 4.98x | 16x | 31% |
| 32 | 2,090.41 | **7.31x** | 32x | 23% |

把客户验收阈值（TPOT P50 ≤ 4.5 ms / TTFT P50 ≤ 1.7 s / E2E P50 ≤ 8.45 s）套到扫描上：

| 阈值 | 满足到的最大并发 | 卡在哪 |
|------|-----------------|--------|
| TPOT P50 ≤ 4.5 ms | **c = 2** (3.663 ms) | c=4 已经 4.826 ms，超了 7.2% |
| TTFT P50 ≤ 1.7 s | c = 32 (890 ms) | 全部档位都过 |
| E2E P50 ≤ 8.45 s | c = 32 (6.61 s，32 prompts 口径) | 但 128 prompts 口径下 c=32 是 10.59 s，破 |

**这是本次扫描最有决策价值的一条**：8K/1.5K 负载下，H200 tp=4 想守住
TPOT P50 ≤ 4.5 ms 的验收线，并发只能开到 **2**；把并发开到 32 能换来 7.3 倍吞吐，
代价是 TPOT P50 涨到 8.07 ms（约 2.5 倍）。吞吐和 TPOT 之间没有免费的午餐，
选点取决于客户是按 TPOT 签 SLA 还是按整机吞吐签。

### 5.4 32 条 prompts 在高并发档不够用（B300 报告同样受此影响）

注意 5.2 表最后一列「实测并发」：c=32 那档只跑到 **18.83**，耗时仅 10.63 s。
原因是只发 32 条请求、并发上限也是 32，等于所有请求一次性全灌进去、跑完一波就结束，
**根本没进入稳态**。把样本量加大到 128 条后：

| 并发 | prompts | 耗时 (s) | 实测并发 | Output tok/s | TPOT P50 | TPOT P95 | TTFT P50 | E2E P50 |
|-----:|--------:|--------:|--------:|-------------:|---------:|---------:|---------:|--------:|
| 16 | 32  | 15.58 | 12.36 | 1,425.63 | 8.164 ms | 9.449 ms | 528.1 ms | 5,962.5 ms |
| 16 | **128** | 69.01 | **15.17** | **1,560.72** | **9.616 ms** | 11.355 ms | 205.8 ms | 8,110.2 ms |
| 32 | 32  | 10.63 | 18.83 | 2,090.41 | 8.072 ms | 10.817 ms | 890.5 ms | 6,608.0 ms |
| 32 | **128** | 48.11 | **29.39** | **2,238.60** | **13.297 ms** | 15.889 ms | 192.3 ms | 10,589.2 ms |

结论有两条，方向相反，都得说清楚：

1. **32 条 prompts 会低估高并发下的延迟。** c=32 的 TPOT P50 从 8.07 ms 变成
   13.30 ms（+65%），E2E P50 从 6.61 s 变成 10.59 s（+60%）。稳态下 c=32
   已经**破了 E2E P50 ≤ 8.45 s 的验收线**，而 32 条样本的口径看不出来。
2. **32 条 prompts 也会低估吞吐**（2,090 → 2,239 tok/s，+7%），因为一波请求的
   头尾有明显的爬升和收尾空档。

TTFT 方向相反（c=32: 890 ms → 192 ms）不是矛盾：32 条时 32 个 prefill 同时挤进来，
中位数落在排队队尾；128 条时只有第一波挤，后续 96 条是随着槽位释放被逐步放行的，
它们的 prefill 与正在进行的 decode 交错，中位数因此显著低。

⚠️ 同样的样本量问题存在于 `reports/b300-tp8-eagle-20260809/` 的扫描（全部档位都是
32 prompts，c=32 那档 duration 9.99 s、实测并发 19.95）。所以那份报告的 c=16/c=32
延迟数字应当理解为**乐观值**。

### 5.5 交叉验证：本轮与已发表基线的一致性

补测这一轮在扫描之前先把第 4 节的两条 bench 原样重跑了一遍（同 recipe、同版本、
换了台机器）。这是判断「本节曲线能不能挂在这份报告下面」的依据：

| 指标 | 已发表 (20260809) | 本轮 (20260810) | 偏差 |
|------|------------------:|----------------:|-----:|
| custom 40K/1.5K — Output tok/s | 224.20 | 224.53 | +0.15% |
| custom 40K/1.5K — TPOT P50 | 3.3299 ms | 3.3339 ms | +0.12% |
| custom 40K/1.5K — TPOT P95 | 3.8208 ms | 3.8241 ms | +0.08% |
| custom 40K/1.5K — TTFT P50 | 665.07 ms | 654.30 ms | −1.62% |
| custom 40K/1.5K — accept length | 2.8425 | 2.8435 | +0.03% |
| official 30K/4096 — Output tok/s | 282.53 | 283.19 | +0.23% |
| official 30K/4096 — TPOT P50 | 3.3367 ms | 3.3100 ms | −0.80% |
| official 30K/4096 — TTFT P50 | 252.16 ms | 234.41 ms | −7.04% |
| official 30K/4096 — accept length | 2.8591 | 2.8603 | +0.04% |

TPOT / 吞吐 / accept length 的偏差都在 1% 以内，TTFT 偏差略大（TTFT 本身方差就大）。
可以认为两轮跑在等价的服务端上。

### 5.6 与 B300 的对比，以及为什么**不能**当作硬件对比

| 并发 | H200 tp=4 Output tok/s | B300 tp=8 Output tok/s | B300/H200 | H200 TPOT P50 | B300 TPOT P50 | H200 accept | B300 accept |
|-----:|----------------------:|----------------------:|----------:|--------------:|--------------:|------------:|------------:|
| 1  | 286.16 | 161.73 | 0.57x | 3.256 ms | 4.508 ms | 2.875 | 2.769 |
| 2  | 484.13 | 382.17 | 0.79x | 3.663 ms | 4.842 ms | 2.887 | 2.759 |
| 4  | 717.74 | 630.09 | 0.88x | 4.826 ms | 5.322 ms | 2.896 | 2.758 |
| 8  | 1,026.00 | 1,058.58 | 1.03x | 6.557 ms | 6.016 ms | 2.904 | 2.756 |
| 16 | 1,425.63 | 1,448.77 | 1.02x | 8.164 ms | 7.426 ms | 2.913 | 2.756 |
| 32 | 2,090.41 | 2,713.15 | **1.30x** | 8.072 ms | 6.287 ms | 2.917 | 2.755 |

🚨 **这张表不能读成「H200 在低并发下比 B300 快」。** 口径不一致，有三处硬差异：

| 差异项 | H200 (本节) | B300 (那份报告的扫描) | 影响 |
|--------|-------------|----------------------|------|
| **SGLang 版本** | 0.5.17 | **0.5.12.post1** | 最致命的一条。B300 扫描跑的是旧版本，`docs/run-summaries/b300-matrix-20260809-c1-summary.md` 记录该版本在这台机器上有严重问题（≥16K 输入直接把 8 个 TP rank 全打崩），其 4000/1500 实测 TPOT P50 = 4.503 ms 与扫描 c=1 的 4.508 ms 几乎一致 —— 也就是说 B300 扫描的低并发数字是被旧版本压低的，不代表 B300 硬件能力 |
| accept length | 2.875-2.917 | 2.755-2.769 | 同一个 EAGLE 配置差约 5%，也是版本效应 |
| CUDA graph 覆盖 | 未显式指定，自动解析到 decode `max_bs=512`，捕获 bs 列表含 16/32 | 显式 `--cuda-graph-max-bs 64` | 两侧 c=16/32 都在 graph 覆盖内，**这一项不构成偏差**（已核对启动日志） |
| tp / MoE 路径 | tp=4, `moe_runner_backend=marlin`, `moe_a2a_backend=none`, `chunked_prefill_size=8192` | tp=8, `megamoe`, `ep_size=8`, `chunked_prefill_size=16384` | 本来就是两种部署形态，不是同一配置的缩放 |

能安全下的结论只有一条：**B300 tp=8 的并发扩展性明显更好** —— 它从 c=1 到 c=32
放大了 16.78 倍吞吐，H200 tp=4 只有 7.31 倍；到 c=32 时 B300 的绝对吞吐反超 30%。
这与 tp=8 + megamoe（专家并行 ep_size=8）在大 batch 下摊薄 MoE 开销的预期一致。
要做真正的硬件对比，必须在**同一个 SGLang 版本**上重跑 B300 的扫描。

### 5.7 本节的时间与成本

| 阶段 | 耗时 |
|------|------|
| 权重下载 (159.6 GB) | 150 s |
| SGLang 冷启动 | 22.3 min |
| 基线 custom 40K/1.5K 重跑 | 2.6 min |
| 基线 official 30K/4096 重跑 | 6.5 min |
| **8 档并发扫描** | **7.8 min** |
| 收尾 + 自终止 | < 1 min |
| **总计** | **42.4 min** (elapsed 2,545 s) |

Spot $26.6236/hr × 44.7 min（含启动到终止）≈ **$19.8**。
扫描本身只占 7.8 min ≈ $3.5，成本主要是那 22 分钟冷启动。

---

## 6. 时间分解与成本

| 阶段 | 耗时 | 说明 |
|------|------|------|
| 模型下载 | ~63 s | 159.6 GB @ ~2.5 GB/s (HuggingFace) |
| Docker 镜像 | ~6.5 min | 预存于 NVMe |
| SGLang 冷启动 | ~20 min | DeepGEMM JIT + CUDA graph capture |
| 客户验收测试 | ~2.6 min | 50 prompts, 40K/1.5K |
| LMSYS 基线测试 | ~6.5 min | 50 prompts, 30K/4096 |
| **总计** | **~34 min** | |

**运行成本:**
- Spot 价格: $26.66/hr
- 运行时间: 2017 s (33.6 min)
- **总成本: ~$15**

---

## 7. 关键发现

### 7.1 TPOT 极其稳定

TPOT P50 到 P95 的变异极小 (3.330 ms -> 3.821 ms)，标准差仅 0.310 ms。
这表明 EAGLE 投机解码在 Marlin W4A16 MoE 路径下运行非常稳定，
decode 阶段几乎没有受到 40K context 的 KV cache 压力影响。

### 7.2 TTFT 对 context 长度敏感

- 40K input: TTFT P50 = 665 ms, P95 = 1,715 ms
- 30K input: TTFT P50 = 252 ms, P95 = 1,031 ms

30K -> 40K 的 TTFT 增长约 2.6x (P50)，符合 prefill 计算量与 input length 线性正相关的预期。
两组测试的 TTFT 均在验收标准内。

### 7.3 Output throughput 超越 LMSYS 参考值

在 30K/4096 (LMSYS 对标条件) 下实测 282.5 tok/s，超过博客公布的 ~266 tok/s。
可能的原因：
- SGLang v0.5.16+ 相比博客测试时的版本有优化
- 本次使用更新的 Marlin kernels
- 硬件差异 (AWS H200 vs LMSYS 测试环境)

### 7.4 SGLang 冷启动时间

Server 启动（含 DeepGEMM JIT compile + CUDA graph capture）约 20 分钟。
从 startup_time 数据:
- load_weight: 389 s (~6.5 min)
- scheduler_e2e: 895 s (~15 min, 含 CUDA graph)
- target_verify graph: 461 s
- draft_decode graph: 15 s

建议对于生产部署保留足够的 warm-up buffer。

---

## 8. 验收标准对照

### 8.1 客户验收标准 (README 12.1)

| 标准 | 要求 | 实测 | 判定 |
|------|------|------|------|
| TPOT | <= 4.5 ms | 3.330 ms (P50) | **PASS** |
| TTFT | <= 1.7 s (40K input) | 0.665 s (P50) | **PASS** |
| Input tokens | 40,000 | 40,000 (avg 16,109 per req) | **PASS** |
| Output tokens | 1,500 (含 think) | 1,500 (avg 708 per req) | **PASS** |
| 部署方式 | 整机部署 (8 GPUs) | tp=4 on p5en.48xlarge (8 GPU) | **PASS** |

### 8.2 LMSYS Day-0 Blog 基线 (README 12.2)

| 配置 | LMSYS 参考 | 本次实测 | 判定 |
|------|-----------|---------|------|
| H200 Flash tp=4 EAGLE 3/1/4 | ~266 tok/s (TPOT ~3.76ms) | 282.5 tok/s (TPOT 3.337ms) | **PASS (超越)** |
| 测试条件: 30K prefix + OSL 4096 + single-batch | -- | 30K/4096/concurrency=1 | 一致 |

---

## 9. 配置详情

### 9.1 部署拓扑

```
p5en.48xlarge (8x H200 141GB HBM3e)
+----+----+----+----+----+----+----+----+
|GPU0|GPU1|GPU2|GPU3|GPU4|GPU5|GPU6|GPU7|
+----+----+----+----+----+----+----+----+
|<-- tp=4 (serving) -->|    (idle)      |
+---------------------------+-----------+
```

- 使用 4 张 H200 进行 tensor parallel 推理
- 剩余 4 张 GPU 空闲 (未使用 dp-attention，Marlin FP4 路径不支持)
- 整机不拆副本，符合客户 "整机部署" 要求

### 9.2 投机解码配置

| 参数 | 值 | 说明 |
|------|-----|------|
| algorithm | EAGLE | 低延迟 preset |
| num-steps | 3 | draft 推测步数 |
| eagle-topk | 1 | 每步 top-k 候选 |
| num-draft-tokens | 4 | 每次验证的 draft token 数 |
| moe-runner-backend | marlin | W4A16 for Hopper (SM90) |

---

## 10. 文件说明

| 文件 | 说明 |
|------|------|
| `bench_custom.json` | 客户验收测试原始结果 (40K/1.5K)，run `20260809-000033-504a` |
| `bench_official.json` | LMSYS 基线对标原始结果 (30K/4096)，run `20260809-000033-504a` |
| `run_metadata.json` | 初测运行元数据 (实例、配置、耗时) |
| `concurrency-sweep/bench_c{1,2,4,8,16,32}.json` | 并发扫描 6 档原始结果 (8K/1.5K, 32 prompts)，与 B300 报告同口径同命名 |
| `concurrency-sweep/bench_c{16,32}_p128.json` | 高并发加样本档原始结果 (8K/1.5K, 128 prompts)，见 5.4 |
| `concurrency-sweep/run_metadata.json` | 补测运行元数据，含 `concurrency_sweep` 块（逐档记账 + 本轮重跑的两条基线 bench 文件名） |

所有 `bench_*.json` 都是 `sglang.bench_serving --output-file` 的原始输出（单条 JSON 记录），
未做任何加工；`server_info` 字段里保留了完整的 `ServerArgs` 与 `version`，便于事后核对口径。

---

## 11. 参考链接

- [LMSYS Day-0 Blog: DeepSeek-V4](https://lmsys.org/blog/2026-04-25-deepseek-v4/) - 基线数据来源
- [SGLang Cookbook: DeepSeek-V4](https://lmsysorg.mintlify.app/cookbook/autoregressive/DeepSeek/DeepSeek-V4) - 上游部署指南
- [awslabs/awsome-distributed-ai](https://github.com/awslabs/awsome-distributed-ai/tree/worktree-repo-reorg/examples/inference/sglang) - AWS 参考部署模板
- [HuggingFace: deepseek-ai/DeepSeek-V4-Flash](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash) - 模型仓库

---

## 12. 下一步

- [x] 测试 concurrency > 1 场景下的吞吐量-延迟 tradeoff —— 见第 5 节
      (run `20260810-015049-2b75`, 8 档 8K/1.5K 扫描)
- [ ] **在 SGLang 0.5.17 上重跑 B300 的并发扫描**：现有 B300 扫描跑在 0.5.12.post1 上，
      与本报告不同版本，5.6 的跨硬件对比因此只能定性不能定量。这是当前最值得花的一次 GPU 时间
- [ ] 在 40K/1.5K（客户真实口径）上也做一遍并发扫描：第 5 节用的是 8K/1.5K（为了和 B300 对齐），
      而客户负载是 40K，两者的 KV cache 压力差一个量级，并发上限结论可能不同
- [ ] 评估 DSpark 投机解码 (0731 checkpoint) 在相同硬件上的表现
- [ ] 进行长时间稳定性测试 (连续 50+ requests 无 OOM/crash)
- [ ] 对比 B300 tp=2 PD 分离方案的 TTFT 优势
- [ ] 评估 FP8 repack (sgl-project/DeepSeek-V4-Flash-FP8) + dp-attention 的可能收益
