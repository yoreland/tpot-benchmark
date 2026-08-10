# B300 PD 分离 + 客户验收口径实测报告

> **Run 日期**: 2026-08-10
> **实例**: `i-01ac85bde661e57f8` / `p6-b300.48xlarge` / us-west-2b / spot $51.97/hr
> **镜像**: `lmsysorg/sglang:v0.5.17-cu130`
> **模型**: `deepseek-ai/DeepSeek-V4-Flash` (284B, FP4 experts + FP8 dense)
> **S3**: `s3://tpot-bench-results-077090643075-us-west-2/runs/b300-customer-validation/`

---

## 0. 最重要的结论：历史报告的负载口径是错的

**在写任何性能结论之前必须先说这件事。**

`reports/b300-tp8-eagle-20260809/` 那份报告标题写的是 "40K input / 1.5K output"，但从它自己的 `bench_custom.json` 里反算出来的实际负载是：

| 声称口径 | 实际下发 | 偏差 |
|---|---|---|
| 40000 in / 1500 out | **16109 in / 708 out** | input 只有 **40%**，output 只有 **47%** |
| 30000 in / 4096 out | **15420 in / 2215 out** | input 只有 **51%**，output 只有 **54%** |
| 8000 in / 1500 out（并发扫描） | **4161 in / 759 out** | input 只有 **52%**，output 只有 **51%** |

**根因**：`sglang.bench_serving` 的 `--random-range-ratio` 默认值不是 1.0。默认行为是在 `[0, max]` 区间里均匀采样长度，所以平均只有目标值的一半左右。要固定长度必须显式传 `--random-range-ratio 1.0`。

**影响范围**：本仓库此前**所有** B300 / H200 的 benchmark 数字都是在这个缩水口径下测的，包括那个被当作基线引用的 `TPOT 3.34 ms @ 40K/1.5K`。那个 3.34 ms 实际是 **16K/708 口径**下的数字。

**本报告的三轮客户验收测试是本仓库第一次真正在 40K/1.5K 口径下的实测**，token 数已逐条核对：

```
total_input_tokens  = 2000000 / 50 = 40000  ✅
total_output_tokens =   75000 / 50 =  1500  ✅
```

---

## 1. 客户验收结果（真 40K/1.5K，c=1）

客户需求：**input 40K / output 1.5K（带 think）/ TPOT < 4.5 ms / TTFT < 1.7 s**

统一命令（三个方案只有 `--output-file` 不同）：

```bash
python3 -m sglang.bench_serving --backend sglang \
  --base-url http://127.0.0.1:30080 \
  --dataset-name random --num-prompts 50 \
  --random-input 40000 --random-output 1500 \
  --random-range-ratio 1.0 \
  --max-concurrency 1 --request-rate inf \
  --output-file b300_<方案>_req40k_out1500.jsonl
```

| 指标 | 目标 | **方案 A: 2P2D** | **方案 B: 3P1D** | **方案 C: tp=8** |
|---|---|---|---|---|
| input / 请求 | 40000 | 40000 ✅ | 40000 ✅ | 40000 ✅ |
| output / 请求 | 1500 | 1500 ✅ | 1500 ✅ | 1500 ✅ |
| **TPOT P50** | **< 4.5 ms** | 3.688 ✅ | 3.959 ✅ | **3.475** ✅ 🏆 |
| TPOT P95 | — | 4.090 | 4.386 | **3.894** 🏆 |
| TPOT P99 | — | 4.785 | 5.021 | **4.559** 🏆 |
| **TTFT P50** | **< 1.7 s** | 799.5 ms ✅ | 1548.2 ms ✅ | **683.1 ms** ✅ 🏆 |
| TTFT P95 | — | **1057.3 ms** 🏆 | 1637.6 ms | 1939.9 ms |
| TTFT P99 | — | **2245.5 ms** 🏆 | 2808.6 ms | 3274.1 ms |
| E2E P50 | — | 6350 ms | 7450 ms | **5900 ms** 🏆 |
| 输出吞吐 | — | 234.3 tok/s | 199.8 tok/s | **247.8 tok/s** 🏆 |
| 测试时长 | — | 320.1 s | 375.3 s | **302.7 s** 🏆 |
| Accept length | — | n/a¹ | n/a¹ | 2.818 |
| Completed | 50 | 50/50 ✅ | 50/50 ✅ | 50/50 ✅ |

> ¹ PD 分离模式下 `accept_length` 不由 router 回传，EAGLE 实际是在 decode 引擎内生效的（见 §3 反证）。

### 验收判定：**三个方案全部 PASS**

| 方案 | TPOT P50 | TTFT P50 | 判定 | 余量 |
|---|---|---|---|---|
| A: 2P2D | 3.688 ms | 799.5 ms | **PASS** | TPOT 18%，TTFT 53% |
| B: 3P1D | 3.959 ms | 1548.2 ms | **PASS** | TPOT 12%，TTFT **仅 9%** ⚠️ |
| C: tp=8 | **3.475 ms** | **683.1 ms** | **PASS** | TPOT 23%，TTFT 60% |

---

## 2. 推荐方案

### 只看 P50 → **tp=8**

TPOT / TTFT / E2E / 吞吐四项 P50 全部最优，而且部署最简单（单容器，无 router、无 KV 传输）。

### 要看 P95 尾延迟 → **2P2D**

TTFT P95 **1057 ms vs tp8 的 1940 ms**，优势接近 2 倍；P99 也是 2246 vs 3274 ms。
原因：tp=8 是单引擎，40K 的长 prefill 会互相排队形成长尾；2P2D 有两个独立 prefill 引擎分流。

**如果客户把 TTFT 的 1.7 s 理解为 P95 而不是 P50，那 tp=8 就 FAIL（1.94 s），2P2D 是唯一达标的方案。** 这一点建议向客户确认口径。

### 3P1D 建议淘汰

同样 8 卡，3P1D 被 2P2D 在**每一项**指标上支配（TPOT 3.96 vs 3.69、TTFT P50 1548 vs 800、吞吐 199.8 vs 234.3）。多一个 prefill 少一个 decode 是纯亏——prefill 不是瓶颈，decode 才是。

### 成本效率（客户口径 c=1，spot $51.97/hr）

| 方案 | 输出吞吐 | $/1M output tokens |
|---|---|---|
| tp=8 | 247.8 tok/s | **$58.25** |
| 2P2D | 234.3 tok/s | $61.62 |
| 3P1D | 199.8 tok/s | $72.24 |

---

## 3. EAGLE 是 PD 分离能否达标的决定性变量

PD 分离的 decode 引擎只有 tp=2（2 张卡），带宽约为 tp=8 的 1/4。第一轮没开 EAGLE 时 TPOT 直接翻倍到 7.9 ms，**远超 4.5 ms 验收线**。给 decode 引擎加上 EAGLE（3/1/4）后 TPOT 回到 3.6 ms 级别。

> ⚠️ 下表是**旧口径（16K/708）**的数据，仅用于说明 EAGLE 的相对效果，**不可与 §1 的验收数字混用**。

| 配置 | TPOT P50 | 吞吐 | 说明 |
|---|---|---|---|
| 3P1D 无 EAGLE | 7.929 ms | 103.0 tok/s | ❌ 顶穿 4.5 ms 线 |
| 3P1D + EAGLE | 3.604 ms | 221.2 tok/s | ✅ EAGLE 把 TPOT 拉回 2.2× |
| 2P2D + EAGLE | 3.595 ms | 224.2 tok/s | ✅ |

**结论：PD 分离方案必须开 EAGLE，否则不可能通过 TPOT 验收。**

同时这也验证了一件事：**EAGLE 在 tp=2 + PD decode 模式下可以正常工作**（此前仓库记录里 tp=8 无 EAGLE 会在 warmup 崩溃，tp=4 + EAGLE 也崩过，所以这个组合能跑通不是理所当然的）。

---

## 4. 高并发场景（附录，旧口径）

> ⚠️ 以下并发扫描的实际口径是 **~4.2K in / ~759 out**，不是标称的 8K/1.5K。
> 同一张表内四个配置口径一致，所以**横向相对比较有效**；但绝对值不能拿去对客户。
> tp=8 那一列还是 **v0.5.12.post1** 镜像跑的（其余三列是 v0.5.17），存在版本混淆。

TPOT P50 (ms) / 输出吞吐 (tok/s)：

| 并发 | tp=8 (v0.5.12) | 3P1D 无EAGLE | 3P1D+EAGLE | **2P2D+EAGLE** |
|---|---|---|---|---|
| c=1 | 4.51 / 161.7 | 7.91 / 121.5 | 3.67 / 256.8 | **3.65 / 257.2** |
| c=2 | 4.84 / 382.2 | 8.24 / 220.4 | 3.82 / 448.1 | 3.83 / 445.6 |
| c=4 | 5.32 / 630.1 | 8.77 / 372.9 | **4.28 / 723.8** | 4.29 / 699.0 |
| c=8 | 6.02 / 1058.6 | 9.57 / 548.9 | **5.05 / 1330.5** | 5.05 / 1240.2 |
| c=16 | 7.43 / 1448.8 | 10.77 / 1103.7 | 6.00 / 2094.3 | **5.17 / 2250.3** 🏆 |
| c=32 | 6.29 / 2713.2 | 12.59 / 2019.4 | 7.10 / 3396.7 | **6.09 / 3986.8** 🏆 |

**高并发下结论反转：2P2D 明显最优。** c=32 时 2P2D 吞吐 3987 tok/s，比 tp=8 高 47%，比 3P1D+EAGLE 高 17%，而且 TPOT 反而更低（6.09 vs 7.10 ms）。原因是 decode 是瓶颈，2 个 decode 引擎可以并行消化请求队列。

成本效率（c=32）：

| 方案 | 输出吞吐 | $/1M output tokens |
|---|---|---|
| tp=8 | 2713 tok/s | $5.32 |
| 3P1D+EAGLE | 3397 tok/s | $4.25 |
| **2P2D+EAGLE** | **3987 tok/s** | **$3.62** |

**所以"PD 分离是否更香"这个问题的答案取决于并发**：
- **c=1（客户当前口径）** → tp=8 更好
- **高并发** → 2P2D 更好，吞吐/$ 优 32%

---

## 5. 部署方式

三个方案都已固化为 docker-compose，全部经过实机验证：

| 文件 | 拓扑 | GPU 分配 |
|---|---|---|
| `scripts/docker-compose-pd-2p2d.yaml` | 2 prefill + 2 decode(EAGLE) + router | P: 0,1 / 2,3 · D: 4,5 / 6,7 |
| `scripts/docker-compose-pd-v4flash-b300.yaml` | 3 prefill + 1 decode(EAGLE) + router | P: 0,1 / 2,3 / 4,5 · D: 6,7 |
| `scripts/docker-compose-tp8-b300.yaml` | 单引擎 tp=8 + EAGLE | 全部 8 卡 |

三份 compose 都把对外端口统一在 **30080**，所以同一条 bench 命令可以直接切换拓扑而不用改 `--base-url`。

```bash
docker compose -f <文件> up -d     # 冷启动约 20-25 min（4 引擎并行读 149GB 权重 + JIT + CUDA graph）
```

### 踩过的坑（都已修进 compose）

| 问题 | 现象 | 解法 |
|---|---|---|
| **compose 里 GPU 挂不进去** | `RuntimeError: No accelerator (CUDA...) is available`，容器 exit 1 | 每个 service 必须加 **`runtime: nvidia`**。只写 `NVIDIA_VISIBLE_DEVICES` 环境变量无效——那个变量要靠 nvidia runtime 才生效 |
| **env 值不对启动即崩** | `ValueError: DeepSeekV4 with MegaMoE requires ...TOKENS_PER_RANK ... Set to at least 16384` | `SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=16384`（不是 8320）。v0.5.17 新增了这条校验 |
| **router 认不到 prefill** | PD 握手失败 | `--prefill URL BOOTSTRAP_PORT` 必须带 bootstrap 端口，`--prefill http://...:30000 9000` |
| **同机 KV 传输** | mooncake V0 不支持同节点 | `--disaggregation-transfer-backend nixl`（v0.5.17 镜像已预装 nixl，实测可用） |
| **引擎启动错位互相判死** | decode 等不到 prefill / 反之 | `SGLANG_DISAGGREGATION_{WAITING,BOOTSTRAP}_TIMEOUT=1800`（默认只有 300s，而冷启动要 ~700s） |
| **router 过早判 worker 死亡** | worker startup timeout | `--worker-startup-timeout-secs`，并用 compose 的 `depends_on: condition: service_healthy` |

### nixl 同机 PD 通路验证（Phase 2 门禁）

上大模型之前先用 Qwen2.5-0.5B 起 1P1D（各 tp=1，GPU 0/1）验证 KV 通路，10 分钟、约 $9，挡掉了一次 $40 级的无效 4 引擎冷启动：

```
PASS: nixl KV transfer works!
```

这个门禁值得保留成标准流程。

---

## 6. 遗留问题

1. **历史报告需要挂勘误。** `reports/b300-tp8-eagle-20260809/` 的口径标注与实际不符，建议加一段勘误说明，或用真口径重跑后替换。H200 那两份报告（`h200-tp4-*`）同样受影响，需要复核。
2. **并发扫描要用真口径重跑。** §4 的相对结论应该成立，但绝对值不可用；而且 tp=8 那一列还是旧镜像，需要在 v0.5.17 + `--random-range-ratio 1.0` 下补齐。
3. **P95 样本量不足。** 50 个请求的 P95 就是第 47-48 名，波动很大——同一个 3P1D+EAGLE 配置两轮跑出的 TTFT P95 分别是 1082 ms 和 5041 ms，差 4.7 倍。若要拿 P95 做决策依据，建议 `--num-prompts` 提到 200，或每方案跑 3 轮取中位数。
4. **权重镜像仍未做。** `s3://.../checkpoints/` 还是空的，下次冷启动仍要从 HF 拉 149 GB。建议在实例还活着的时候 `aws s3 sync` 上去（$3.4/月，省下次约 $43 的下载时间）。
5. **`scripts/b300-run-config.sh` 尚未支持多引擎拓扑。** 目前 PD 测试靠独立脚本 + compose 驱动，`pd-3p1d-nixl` 那个 config 还是 stub。

---

## 7. 原始数据

| 内容 | 位置 |
|---|---|
| 客户验收三轮（真 40K/1.5K） | `s3://.../runs/b300-customer-validation/` |
| 2P2D 全套（含 sweep） | `s3://.../runs/b300-pd-2p2d/` |
| 3P1D + EAGLE | `s3://.../runs/b300-pd-3p1d-eagle/` |
| 3P1D 无 EAGLE | `s3://.../runs/b300-pd-3p1d/` |
| 3P1D compose 复现轮 | `s3://.../runs/b300-pd-3p1d-compose/` |

本轮实例开销：04:27 UTC 启动，约 6 小时 × $51.97 ≈ **$312**。
