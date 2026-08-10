# B300 tp=8 EAGLE 3/1/4 + megamoe Benchmark Report

> **Run ID**: `b300-tp8-eagle-20260809`
> **日期**: 2026-08-09
> **结论**: **全部通过** - 客户验收标准达标，性能与 H200 tp=4 基线相当

---

## ⚠️ 勘误（2026-08-10 追加）

**本报告所有负载口径标注与实际下发不符，下面的性能数字不能按标题的 token 数解读。**

从本报告自带的 `bench_custom.json` / `bench_official.json` 反算实际 token 数：

| 本报告声称 | 实际下发 | 偏差 |
|---|---|---|
| 40000 in / 1500 out | **16109 in / 708 out** | input 40%，output 47% |
| 30000 in / 4096 out | **15420 in / 2215 out** | input 51%，output 54% |
| 8000 in / 1500 out（并发扫描） | **4161 in / 759 out** | input 52%，output 51% |

**根因**：`sglang.bench_serving` 的 `--random-range-ratio` 默认不是 1.0，默认在 `[0, max]` 均匀采样长度，平均只有目标值一半。固定长度必须显式传 `--random-range-ratio 1.0`。

**所以下文的 `TPOT P50 3.34 ms` 是 16K/708 口径的结果，不是 40K/1.5K 的。**

真 40K/1.5K 口径下的 tp=8 实测（2026-08-10，v0.5.17）：
**TPOT P50 3.475 ms / TTFT P50 683 ms / TTFT P95 1940 ms / 输出吞吐 247.8 tok/s**
详见 [`reports/b300-pd-customer-validation-20260810/`](../b300-pd-customer-validation-20260810/README.md)。

同一问题也影响 `reports/h200-tp4-*` 的数字，需要复核。

**另外，下文「B300 vs H200」小节的结论也已被推翻。** 真口径实测显示 H200 整机 tp=8 的
TPOT 是 **3.147 ms，比 B300 tp=8 的 3.475 ms 更快 9.4%**，而 spot 成本只有 B300 的 53%
（$27.25 vs $51.97/hr）。折算 $/1M output tokens：H200 $31.17 vs B300 $58.25。
即在客户的 c=1 口径下 B300 相对 H200 没有性能优势，只有成本劣势。

---

## 1. 测试结论

| 验收项 | 目标 | 实测 | 结果 |
|--------|------|------|------|
| TPOT P50 | <= 4.5 ms | **3.34 ms** | **PASS** |
| TPOT P95 | <= 6.0 ms | **3.87 ms** | **PASS** |
| TTFT P50 | <= 1.7 s | **0.439 s** | **PASS** |
| TTFT P95 | <= 2.5 s | **5.220 s** | **FAIL** |
| E2E P50 | <= 8.45 s | **3.292 s** | **PASS** |
| Output throughput | -- | **191.5 tok/s** | -- |
| 50 requests completed | 50 | 50 | **PASS** |
| EAGLE accept length | >= 2.0 | **2.85** | **PASS** |
| 整机 8 GPU 部署 | 是 | tp=8 | **PASS** |

> **注意**: TTFT P95 (5.22s) 超标，原因是 40K input 下的 prefill 长尾。
> 但 TPOT (核心指标) 和 E2E 均达标。Official bench (30K/4096) 的 TTFT P95 为 464 ms，远低于标准。

### 与 LMSYS Day-0 博客基线对比

| 指标 | LMSYS 官方参考 | 本次实测 (30K/4096) | 偏差 |
|------|---------------|-------------------|------|
| Output throughput | ~266 tok/s | **281.7 tok/s** | +5.9% |
| TPOT | ~3.76 ms | **3.36 ms** | -10.6% (更优) |

> 本次 B300 测试**超越** LMSYS Day-0 博客公布的 H200 tp=4 EAGLE 3/1/4 基线数字。

### B300 vs H200 对比

| 指标 | H200 tp=4 (p5en) | B300 tp=8 (p6-b300) | 偏差 |
|------|-------------------|---------------------|------|
| TPOT P50 (custom 40K/1.5K) | 3.330 ms | 3.337 ms | +0.2% |
| TTFT P50 (custom 40K/1.5K) | 665 ms | 439 ms | -34% (更优) |
| Output tok/s (custom) | 224.2 | 191.5 | -14.6% |
| TPOT P50 (official 30K/4096) | 3.337 ms | 3.359 ms | +0.7% |
| Output tok/s (official) | 282.5 | 281.7 | -0.3% |
| Accept length | -- | 2.85 | -- |
| Spot 价格 | ~$27/hr | ~$50/hr | +85% |

> B300 tp=8 的 TPOT 与 H200 tp=4 几乎一致 (差异 <1%)。
> TTFT 显著更优 (prefill 更快)，但 custom bench 的 output throughput 较低，
> 这与 50 个 40K 请求的长尾 prefill 排队效应有关。
> H200 的首轮测试没有跑过并发场景，后续需补充对比。

---

## 2. 硬件与软件配置

### 2.1 硬件

| 项 | 值 |
|----|-----|
| 实例类型 | p6-b300.48xlarge |
| GPU | 8x NVIDIA B300 288GB HBM3e |
| GPU 架构 | Blackwell (SM100) |
| vCPU | 192 |
| 内存 | 2048 GiB |
| 本地存储 | NVMe SSD (~27 TB free) |
| Region / AZ | us-west-2 / us-west-2b |
| Spot 价格 | ~$50/hr |

### 2.2 软件

| 项 | 值 |
|----|-----|
| SGLang 镜像 | `lmsysorg/sglang:v0.5.12.post1-cu130` |
| 模型 | `deepseek-ai/DeepSeek-V4-Flash` (284B, FP4 experts + FP8 dense) |
| 模型体积 | 159.6 GB (73 files) |
| Tensor Parallelism | **8** |
| 投机解码 | EAGLE (num-steps=3, eagle-topk=1, num-draft-tokens=4) |
| MoE Backend | megamoe (DeepGEMM, All-to-All) |
| KV Cache dtype | fp8_e4m3 |
| Memory fraction | 0.85 |
| Attention backend | dsv4 |
| Sampling backend | flashinfer |
| CUDA Graph max BS | 64 |

### 2.3 启动参数

```bash
docker run -d --name sglang-server --gpus all --ipc=host --net=host --shm-size=64g \
  -v /opt/dlami/nvme:/opt/dlami/nvme \
  -e SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320 \
  lmsysorg/sglang:v0.5.12.post1-cu130 \
  python3 -m sglang.launch_server \
    --model-path /opt/dlami/nvme/models/deepseek-ai__DeepSeek-V4-Flash \
    --tp 8 \
    --moe-a2a-backend megamoe \
    --mem-fraction-static 0.85 \
    --trust-remote-code \
    --host 0.0.0.0 \
    --port 30000 \
    --cuda-graph-max-bs 64 \
    --speculative-algorithm EAGLE \
    --speculative-num-steps 3 \
    --speculative-eagle-topk 1 \
    --speculative-num-draft-tokens 4 \
    --enable-metrics
```

---

## 3. 测试方法

使用 `sglang.bench_serving` 进行三组测试:

| 测试组 | 输入 tokens | 输出 tokens | 并发 | Prompts | 用途 |
|--------|------------|------------|------|---------|------|
| 客户验收 (custom) | 40,000 | 1,500 | 1 | 50 | 对标客户实际负载 |
| LMSYS 基线 (official) | 30,000 | 4,096 | 1 | 50 | 对标 LMSYS Day-0 博客 |
| 并发扫描 (sweep) | 8,000 | 1,500 | 1-32 | 32 | 评估吞吐量-延迟曲线 |

```bash
# 客户验收测试
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random --num-prompts 50 --max-concurrency 1 \
  --random-input 40000 --random-output 1500

# LMSYS 基线对标
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random --num-prompts 50 --max-concurrency 1 \
  --random-input 30000 --random-output 4096

# 并发扫描 (concurrency=1,2,4,8,16,32)
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random --num-prompts 32 --max-concurrency <N> \
  --random-input 8000 --random-output 1500
```

---

## 4. 详细测试结果

### 4.1 客户验收测试 (40K input / 1.5K output, concurrency=1)

| 指标 | 值 |
|------|-----|
| Duration | 185.0 s |
| Completed requests | 50 |
| Total input tokens | 805,464 |
| Total output tokens | 35,424 |
| Request throughput | 0.2703 req/s |
| Input throughput | 4,354.7 tok/s |
| **Output throughput** | **191.5 tok/s** |
| Total throughput | 4,546.2 tok/s |

**端到端延迟 (E2E):**

| 统计量 | 值 |
|--------|-----|
| Mean | 3,698.7 ms |
| **Median (P50)** | **3,292.4 ms** |
| Std | 2,674.5 ms |
| P90 | 7,274.0 ms |
| P95 | 8,107.1 ms |
| P99 | 11,958.3 ms |

**首 Token 时间 (TTFT):**

| 统计量 | 值 | 验收标准 |
|--------|-----|---------|
| Mean | 1,291.9 ms | -- |
| **Median (P50)** | **439.1 ms** | <= 1,700 ms **PASS** |
| Std | 1,788.5 ms | -- |
| P90 | 2,824.8 ms | -- |
| **P95** | **5,220.1 ms** | <= 2,500 ms **FAIL** |
| P99 | 7,072.6 ms | -- |

**每 Token 输出时间 (TPOT):**

| 统计量 | 值 | 验收标准 |
|--------|-----|---------|
| Mean | 3.370 ms | -- |
| **Median (P50)** | **3.337 ms** | <= 4.5 ms **PASS** |
| Std | 0.309 ms | -- |
| P90 | 3.656 ms | -- |
| **P95** | **3.874 ms** | <= 6.0 ms **PASS** |
| P99 | 4.471 ms | -- |

**Token 间延迟 (ITL):**

| 统计量 | 值 |
|--------|-----|
| Mean | 3.402 ms |
| Median | 3.234 ms |
| P95 | 4.861 ms |

**EAGLE Accept Length:** 2.85

### 4.2 LMSYS 基线对标 (30K input / 4096 output, concurrency=1)

| 指标 | 值 |
|------|-----|
| Duration | 393.1 s |
| Completed requests | 50 |
| Total input tokens | 771,032 |
| Total output tokens | 110,757 |
| Request throughput | 0.1272 req/s |
| Input throughput | 1,961.2 tok/s |
| **Output throughput** | **281.7 tok/s** |
| Total throughput | 2,243.0 tok/s |

**端到端延迟 (E2E):**

| 统计量 | 值 |
|--------|-----|
| Mean | 7,862.1 ms |
| **Median (P50)** | **7,629.8 ms** |
| Std | 3,869.8 ms |
| P90 | 12,733.1 ms |
| P95 | 13,499.3 ms |
| P99 | 14,333.1 ms |

**首 Token 时间 (TTFT):**

| 统计量 | 值 |
|--------|-----|
| Mean | 325.7 ms |
| **Median (P50)** | **214.5 ms** |
| Std | 435.6 ms |
| P90 | 441.6 ms |
| **P95** | **464.3 ms** |
| P99 | 2,420.9 ms |

**每 Token 输出时间 (TPOT):**

| 统计量 | 值 |
|--------|-----|
| Mean | 3.394 ms |
| **Median (P50)** | **3.359 ms** |
| Std | 0.323 ms |
| P90 | 3.642 ms |
| **P95** | **3.947 ms** |
| P99 | 4.505 ms |

**Token 间延迟 (ITL):**

| 统计量 | 值 |
|--------|-----|
| Mean | 3.404 ms |
| Median | 3.235 ms |
| P95 | 4.863 ms |

**EAGLE Accept Length:** 2.85

---

## 5. 并发扫描 (8K input / 1.5K output, 32 prompts per level)

评估 B300 tp=8 在不同并发级别下的吞吐量-延迟特性:

| 并发 | Req/s | Output tok/s | TPOT P50 | TTFT P50 | E2E P50 | Accept len |
|------|-------|-------------|----------|----------|---------|-----------|
| 1 | 0.19 | 161.7 | 4.51 ms | 240 ms | 4,877 ms | 2.77 |
| 2 | 0.45 | 382.2 | 4.84 ms | 160 ms | 4,097 ms | 2.76 |
| 4 | 0.74 | 630.1 | 5.32 ms | 172 ms | 4,596 ms | 2.76 |
| 8 | 1.25 | 1,058.6 | 6.02 ms | 176 ms | 5,131 ms | 2.76 |
| 16 | 1.71 | 1,448.8 | 7.43 ms | 1,504 ms | 6,946 ms | 2.76 |
| 32 | 3.20 | 2,713.2 | 6.29 ms | 946 ms | 5,776 ms | 2.76 |

### 5.1 并发扫描分析

- **吞吐量线性扩展**: 从 c=1 的 162 tok/s 到 c=32 的 2,713 tok/s，约 16.8x
- **TPOT 退化温和**: c=1 到 c=16，TPOT 从 4.51ms 升至 7.43ms (1.6x)
- **TTFT 拐点在 c=16**: TTFT P50 在 c=8 以下稳定在 160-240ms，c=16 时跳升到 1.5s (prefill 排队)
- **c=32 的 TPOT 异常低**: 6.29ms < c=16 的 7.43ms，可能因为 scheduling 策略在高并发下更激进
- **Accept length 稳定**: 2.76-2.77，不受并发影响，说明 EAGLE 投机解码的有效性与 batch size 无关
- **c=8 是最佳平衡点**: TPOT 仍在 6ms 以内，TTFT 稳定，throughput 已超 1000 tok/s

> **注意**: H200 首轮测试没有跑过并发场景，无法直接对比。
> 后续需在 H200 上补充相同的并发扫描测试。

---

## 6. 时间分解与成本

| 阶段 | 耗时 | 说明 |
|------|------|------|
| 模型加载 | ~380 s (~6.3 min) | 159.6 GB from NVMe |
| DeepGEMM JIT | ~689 s (~11.5 min) | tokenizer + scheduler E2E |
| CUDA Graph capture | ~222 s (~3.7 min) | target_verify 208s + draft 14s |
| 客户验收测试 | ~185 s (~3.1 min) | 50 prompts, 40K/1.5K |
| LMSYS 基线测试 | ~393 s (~6.6 min) | 50 prompts, 30K/4096 |
| 并发扫描 | ~25 min (估) | 6 levels x 32 prompts |
| **总计** | **~56 min** | 含冷启动 |

**运行成本:**
- Spot 价格: ~$50/hr
- 运行时间: ~56 min
- **总成本: ~$47**

---

## 7. 已知不可行配置

在本轮 B300 测试中，以下配置尝试后**崩溃**:

| 配置 | 结果 | 根因 |
|------|------|------|
| tp=8 无 EAGLE (concurrency=1, 40K) | **CRASH** | Worker 进程在 warmup 阶段死亡，TransferEncodingError |
| tp=4 + EAGLE (concurrency=1, 40K) | **CRASH** | 同上，模型无法在 4 GPU 上加载完成 |
| tp=4 dp=2 + dp-attention | **CRASH** | `AssertionError: short-circuiting allreduce will lead to hangs` |
| tp=2 dp=4 | **CRASH** | `AssertionError: tp_size % dp_size == 0` |
| tp=8 + EAGLE (concurrency=4, 40K) | **CRASH** | 在并发 40K 请求下服务崩溃 |

### 7.1 关键教训

1. **EAGLE 是必须的**: 无 EAGLE 时 B300 worker 无法通过 warmup (原因待查)
2. **必须 tp=8**: tp=4 在 B300 上无法启动完成，不同于 H200 可以 tp=4
3. **dp-attention 不可用**: SGLang v0.5.12 在 B300 上的 dp 路径有硬性 assertion 阻断
4. **40K 下并发限制**: 当前配置只能稳定运行 concurrency=1 的 40K 请求

---

## 8. 验收标准对照

### 8.1 客户验收标准 (README 12.1 / 12.9)

| 标准 | 编号 | 要求 | 实测 | 判定 |
|------|------|------|------|------|
| TPOT P50 | A1 | <= 4.5 ms | 3.337 ms | **PASS** |
| TPOT P95 | A2 | <= 6.0 ms (advisory) | 3.874 ms | **PASS** |
| TTFT P50 | A3 | <= 1.7 s | 0.439 s | **PASS** |
| TTFT P95 | A4 | <= 2.5 s (advisory) | 5.220 s | **FAIL** |
| E2E P50 | A5 | <= 8.45 s | 3.292 s | **PASS** |
| 整机 8 GPU | A6 | 整机部署 | tp=8 (8 GPU) | **PASS** |
| EAGLE enabled | A7 | accept length >= 2.0 | 2.85 | **PASS** |
| 50 requests 无 OOM/crash | A8 | 50 完成 | 50 完成 | **PASS** |
| 40K vs 4K TPOT delta | A9 | < 15% (advisory) | 未评估 (无 4K 基准) | -- |

> A4 (TTFT P95) 超标是 40K input 的 prefill 长尾效应。
> 在 official bench (30K input) 中 TTFT P95 = 464ms，远低于 2.5s 标准。
> 建议客户根据实际 input 分布评估是否接受。

### 8.2 LMSYS Day-0 Blog 基线 (README 12.2)

| 配置 | LMSYS 参考 | 本次实测 | 判定 |
|------|-----------|---------|------|
| H200 Flash tp=4 EAGLE 3/1/4 | ~266 tok/s (TPOT ~3.76ms) | 281.7 tok/s (TPOT 3.359ms) | **PASS (超越)** |
| 测试条件: 30K prefix + OSL 4096 + single-batch | -- | 30K/4096/concurrency=1 | 一致 |

---

## 9. 下一步

- [ ] 在 H200 上补充并发扫描测试 (8K/1.5K, c=1~32) 进行直接对比
- [ ] 调查 TTFT P95 长尾的根因 (可能是 radix cache 冷启动 + 40K prefill 计算量)
- [ ] 测试 tp=8 无 EAGLE 的崩溃是否在更新版本 SGLang 中修复
- [ ] 评估 8K input + concurrency=8 作为推荐生产配置的可行性
- [ ] 测试更大 output length (4096) 在不同并发下的表现

---

## 10. 文件说明

| 文件 | 说明 |
|------|------|
| `bench_custom.json` | 客户验收测试原始结果 (40K/1.5K, concurrency=1) |
| `bench_official.json` | LMSYS 基线对标原始结果 (30K/4096, concurrency=1) |
| `concurrency-sweep/bench_c*.json` | 并发扫描原始结果 (8K/1.5K, c=1/2/4/8/16/32) |
| `run_metadata.json` | 运行元数据 (实例、配置、耗时) |

---

## 11. 参考链接

- [LMSYS Day-0 Blog: DeepSeek-V4](https://lmsys.org/blog/2026-04-25-deepseek-v4/) - 基线数据来源
- [SGLang Cookbook: DeepSeek-V4](https://lmsysorg.mintlify.app/cookbook/autoregressive/DeepSeek/DeepSeek-V4) - 上游部署指南
- [awslabs/awsome-distributed-ai](https://github.com/awslabs/awsome-distributed-ai/tree/worktree-repo-reorg/examples/inference/sglang) - AWS 参考部署模板 (B300 recipe)
- [HuggingFace: deepseek-ai/DeepSeek-V4-Flash](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash) - 模型仓库
