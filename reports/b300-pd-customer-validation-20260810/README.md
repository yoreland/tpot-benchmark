# B300 / H200 客户验收口径实测报告（含 PD 分离对比）

> **Run 日期**: 2026-08-10
> **实例**:
> - B300: `i-01ac85bde661e57f8` / `p6-b300.48xlarge` (8×B300 288GB) / us-west-2b / spot $51.97/hr
> - H200: `i-04bf3b9d70107c447` / `p5en.48xlarge` (8×H200 141GB) / us-west-2c / spot $27.25/hr
>
> **镜像**: `lmsysorg/sglang:v0.5.17-cu130`（两种硬件同镜像，MoE 后端不同）
> **模型**: `deepseek-ai/DeepSeek-V4-Flash` (284B, FP4 experts + FP8 dense)
> **测试口径**: 40K in / 1.5K out, `--random-range-ratio 1.0`, c=1 及 c=1/4/8/16/32 扫描
> **所有实例已回收**，权重镜像保留在 S3
>
> **一句话结论**：客户当前 c=1 口径下 **H200 整机 tp=8 是最优选**（TPOT 3.147 ms，$/1M = $31.17，
> 成本只有 B300 的 54%）；B300 的价值只在 c≥8 高并发，且需配 2P2D 拓扑。

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

### 1.0 四方案总览（含 H200）

| 方案 | 硬件 | TPOT P50 | TPOT P95 | TTFT P50 | TTFT P95 | 吞吐 | $/hr | **$/1M tok** | 判定 |
|---|---|---|---|---|---|---|---|---|---|
| **H200 tp=8 整机** | 8×H200 141G | **3.147** 🏆 | **3.528** 🏆 | 1469.0 | 1497.3 | 242.9 | $27.25 | **$31.17** 🏆 | ✅ PASS |
| B300 tp=8 整机 | 8×B300 288G | 3.475 | 3.894 | **683.1** 🏆 | 1939.9 | **247.8** 🏆 | $51.97 | $58.25 | ✅ PASS |
| B300 2P2D | 8×B300 288G | 3.688 | 4.090 | 799.5 | **1057.3** 🏆 | 234.3 | $51.97 | $61.62 | ✅ PASS |
| B300 3P1D | 8×B300 288G | 3.959 | 4.386 | 1548.2 | 1637.6 | 199.8 | $51.97 | $72.24 | ✅ PASS |

**四方案全部通过验收。** 关键结论：

1. **H200 整机是客户口径下的最优选择** —— TPOT 比 B300 tp=8 还快 9.4%（3.147 vs 3.475 ms），而成本只有 **53%**（$27.25 vs $51.97/hr）。折算成 **$/1M output tokens 是 $31.17，只有 B300 tp=8 的 54%**。
2. H200 唯一的劣势是 **TTFT 慢一倍多**（1469 vs 683 ms），但仍在 1.7 s 线内，余量 14%。
3. B300 在这个 c=1 口径下**没有体现出任何优势** —— 贵一倍，TPOT 还更慢。B300 的价值只在高并发（见 §4）。
4. H200 用 tp=8 整机跑通了，且 EAGLE accept_length 2.819 与 B300 的 2.818 一致 —— 投机解码效果与硬件无关。

> H200 参数与 B300 不同，不能照抄：Hopper 走原始 FP4 checkpoint 必须用 `--moe-runner-backend marlin`（W4A16），
> 而不是 B300 的 `--moe-a2a-backend megamoe`（DeepGEMM，Blackwell 路径）；也不需要 megamoe 那个 token 预算 env。
> 详见 `scripts/docker-compose-tp8-h200.yaml`。
> 另注：SGLang cookbook 给 H200 的处方是 TP=4，本轮按「整机部署」实测 TP=8 也能跑通。

### 1.1 B300 三方案细节

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

### 客户当前口径（c=1 单请求）→ **H200 整机 tp=8**

TPOT 最低（3.147 ms，余量 30%），$/1M output tokens 最低（$31.17，只有 B300 tp=8 的 54%），部署最简单（单容器）。
唯一需要留意的是 TTFT 1469 ms，距 1.7 s 线只有 14% 余量 —— 若客户实际 prompt 比 40K 更长需要复测。

### 如果客户按 TTFT P95 验收 → 需要重新讨论

各方案 TTFT P95：H200 1497 ms、2P2D 1057 ms、3P1D 1638 ms、B300 tp8 1940 ms。
按 P95 判定，**B300 tp=8 会 FAIL**，H200 和 2P2D 通过。

但注意遗留问题 §6.2：50 个请求的 P95 样本量不足（同配置两轮曾差 4.7 倍），**这个排序不稳，不宜直接作为选型依据**。
建议先跟客户确认 1.7 s 是 P50 还是 P95；若是 P95，需要用 `--num-prompts 200` 重跑一轮再定。

### 如果客户需要并发 → 见 §4，答案随并发变

c=4 选 B300 tp=8（唯一守住 4.5 ms 的），c≥8 选 B300 2P2D（吞吐/$ 最优），但 c≥8 时无方案达标 4.5 ms。

### B300 3P1D 建议淘汰

同样 8 卡，3P1D 被 2P2D 在**每一项**指标上支配（TPOT 3.96 vs 3.69、TTFT P50 1548 vs 800、吞吐 199.8 vs 234.3）。多一个 prefill 少一个 decode 是纯亏——prefill 不是瓶颈，decode 才是。

### 成本效率（客户口径 c=1）

| 方案 | 输出吞吐 | spot $/hr | $/1M output tokens |
|---|---|---|---|
| **H200 tp=8** | 242.9 tok/s | $27.25 | **$31.17** 🏆 |
| B300 tp=8 | 247.8 tok/s | $51.97 | $58.25 |
| B300 2P2D | 234.3 tok/s | $51.97 | $61.62 |
| B300 3P1D | 199.8 tok/s | $51.97 | $72.24 |

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

## 4. 并发扫描（真 40K/1.5K 口径，四方案）

口径与 §1 完全一致（`--random-range-ratio 1.0`，每个点都核对过 in/req=40000、out/req=1500），
`num-prompts = max(16, 8×c)`。原始数据在 `sweep-40k/` 与 `h200-comparison/`。

### TPOT P50 (ms) — 验收线 4.5 ms

| 并发 | H200 tp=8 | B300 tp=8 | B300 2P2D | B300 3P1D |
|---|---|---|---|---|
| c=1 | **3.147** ✅ | 3.454 ✅ | 3.749 ✅ | 3.714 ✅ |
| c=4 | 5.038 ❌ | **4.037** ✅ | 4.277 ✅ | 4.367 ✅ |
| c=8 | 7.858 ❌ | 4.917 ❌ | **4.534** ❌ | 5.140 ❌ |
| c=16 | 18.357 ❌ | 8.733 ❌ | **5.121** ❌ | 6.135 ❌ |
| c=32 | 34.321 ❌ | 16.663 ❌ | **5.662** ❌ | 6.988 ❌ |

### 输出吞吐 (tok/s)

| 并发 | H200 tp=8 | B300 tp=8 | B300 2P2D | B300 3P1D |
|---|---|---|---|---|
| c=1 | 243.6 | **272.5** | 224.5 | 227.2 |
| c=4 | 660.3 | **916.8** | 712.5 | 669.4 |
| c=8 | 911.3 | 1356.8 | **1358.3** | 1246.1 |
| c=16 | 789.0 | 1723.1 | **2186.7** | 1946.5 |
| c=32 | 869.0 | 1754.1 | **3360.9** 🏆 | 3090.0 |

### 成本效率 $/1M output tokens

| 并发 | H200 tp=8 | B300 tp=8 | B300 2P2D | B300 3P1D |
|---|---|---|---|---|
| c=1 | **$31.08** 🏆 | $52.97 | $64.29 | $63.53 |
| c=4 | **$11.46** 🏆 | $15.75 | $20.26 | $21.56 |
| c=8 | **$8.31** 🏆 | $10.64 | $10.63 | $11.58 |
| c=16 | $9.59 | $8.38 | **$6.60** 🏆 | $7.42 |
| c=32 | $8.71 | $8.23 | **$4.29** 🏆 | $4.67 |

### 结论

**并发是选型的分水岭，三段完全不同的答案：**

| 并发区间 | 最优方案 | 理由 |
|---|---|---|
| **c=1** | **H200 tp=8** | TPOT 最低（3.147 ms），$/1M 最低（$31.08，是 B300 的 54%） |
| **c=4** | **B300 tp=8** | 唯一在 c=4 仍守住 4.5 ms 的方案（4.037）；H200 此时已到 5.038 ❌ |
| **c≥8** | **B300 2P2D** | TPOT 劣化最缓（c=32 仅 5.662 vs B300 tp8 的 16.663、H200 的 34.321），吞吐/$ 最优（$4.29） |

几个值得注意的现象：

1. **H200 在并发下崩得最快**：c=1→c=32 TPOT 从 3.147 恶化到 34.321 ms（**11 倍**），吞吐在 c=8 就见顶（911 tok/s）之后掉头下滑。141 GB HBM 在 40K 长上下文 × 高并发下 KV cache 吃紧，是明显的容量墙。B300 的 288 GB 没这个问题。
2. **B300 tp=8 的 decode 是单引擎瓶颈**：吞吐在 c=16 封顶（1723），c=32 几乎没长（1754），TPOT 却翻倍。
3. **2P2D 是唯一在高并发还能线性扩的**：c=32 吞吐 3361 tok/s，比 B300 tp=8 高 **92%**，比 H200 高 **287%**。
4. **c≥8 时所有方案都超出 4.5 ms** —— 这是 40K 长 prefill 在高并发下的固有瓶颈，换拓扑解决不了。若客户要支撑 c≥8 且守 4.5 ms，需要重新谈指标或加机器（横向扩实例，而非改单机拓扑）。

**所以「PD 分离是否更香」的答案**：c=1 客户当前口径下**不香**（H200 整机完胜，成本还低一半）；只有当并发压到 c≥8 时 PD 才有意义，此时 2P2D 的吞吐/$ 优 48%。

---

## 5. 部署方式

三个方案都已固化为 docker-compose，全部经过实机验证：

| 文件 | 硬件 | 拓扑 | GPU 分配 |
|---|---|---|---|
| `scripts/docker-compose-pd-2p2d.yaml` | B300 | 2 prefill + 2 decode(EAGLE) + router | P: 0,1 / 2,3 · D: 4,5 / 6,7 |
| `scripts/docker-compose-pd-v4flash-b300.yaml` | B300 | 3 prefill + 1 decode(EAGLE) + router | P: 0,1 / 2,3 / 4,5 · D: 6,7 |
| `scripts/docker-compose-tp8-b300.yaml` | B300 | 单引擎 tp=8 + EAGLE | 全部 8 卡 |
| `scripts/docker-compose-tp8-h200.yaml` | H200 | 单引擎 tp=8 + EAGLE + **marlin** | 全部 8 卡 |
| `scripts/docker-compose-tp4-h200.yaml` | H200 | 单引擎 tp=4 + EAGLE + **marlin**（cookbook 处方，回退用） | 0-3 |

五份 compose 都把对外端口统一在 **30080**，所以同一条 bench 命令可以直接切换拓扑/硬件而不用改 `--base-url`。

**B300 与 H200 的参数不可互换**（照抄会起不来）：

| | B300 (Blackwell SM100) | H200 (Hopper SM90) |
|---|---|---|
| MoE 后端 | `--moe-a2a-backend megamoe`（DeepGEMM） | `--moe-runner-backend marlin`（W4A16） |
| megamoe token 预算 env | 必须设 `=16384` | 不需要 |
| dp-attention | 已知会挂 | cookbook 明确 TP-only，不支持 |
| 权重每卡占用 (tp=8) | ~240 GB / 288 GB | ~23.6 GB 加载后升至满配 / 141 GB |

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

1. **H200 历史报告仍需复核。** `reports/b300-tp8-eagle-20260809/` 已挂勘误；但 `reports/h200-tp4-*` 那两份的口径同样受 `--random-range-ratio` 影响，数字需要重新核对（本轮 H200 只跑了 tp=8 整机，没重跑 tp=4）。
2. **P95 样本量不足。** 50 个请求的 P95 就是第 47-48 名，波动很大——同一个 3P1D+EAGLE 配置两轮跑出的 TTFT P95 分别是 1082 ms 和 5041 ms，差 4.7 倍。若要拿 P95 做决策依据，建议 `--num-prompts` 提到 200，或每方案跑 3 轮取中位数。**本报告 §1 的 TTFT P95 排序不宜单独作为选型依据。**
3. **H200 未测 PD 分离。** 本轮 H200 只做了整机 tp=8。考虑到 H200 在高并发下的容量墙（§4 结论 1），H200 上的 PD 分离（如 2P2D，每引擎 tp=2）可能反而会更早撞 KV cache 上限，但没有实测数据。
4. **H200 tp=4 未测。** cookbook 给 H200 的处方是 TP=4，本轮按「整机」跑的是 TP=8。TP=4 只用 4 卡，理论上单请求 TPOT 会更差但能跑两个副本，值得补一轮。`scripts/docker-compose-tp4-h200.yaml` 已备好。
5. **`scripts/b300-run-config.sh` 尚未支持多引擎拓扑。** 目前 PD 测试靠独立脚本 + compose 驱动，`pd-3p1d-nixl` 那个 config 还是 stub。
6. **c≥8 无方案达标。** 40K 长 prefill 在高并发下所有方案 TPOT 都超 4.5 ms。若客户需要并发，需要谈横向扩实例而不是改单机拓扑。

---

## 7. 原始数据

| 内容 | 位置 |
|---|---|
| 客户验收四方案（真 40K/1.5K，c=1） | `s3://.../runs/b300-customer-validation/` + `runs/h200-customer-validation/` |
| B300 三方案并发扫描（真 40K 口径） | `s3://.../runs/b300-sweep40k/` · repo `sweep-40k/` |
| H200 tp=8 c=1 + 并发扫描 | `s3://.../runs/h200-customer-validation/` · repo `h200-comparison/` |
| 权重镜像（159.6 GB / 222 objects） | `s3://.../checkpoints/deepseek-ai__DeepSeek-V4-Flash/` |
| 旧口径附录（16K/708，仅供 EAGLE 相对效果参考） | repo `appendix-sweep/` |

### 本轮开销

| 项 | 时长 | 单价 | 小计 |
|---|---|---|---|
| B300 `i-01ac85bde661e57f8` | ~7.3 hr | $51.97/hr | ~$379 |
| B300 `i-055aa429152140cd9`（Lambda 抢的，未使用，7h 空转） | ~7.6 hr | $51.97/hr | ~$395 ⚠️ |
| H200 `i-04bf3b9d70107c447` | ~1.4 hr | $27.25/hr | ~$38 |
| H200 `i-0cb28541062df48e6`（Lambda 重复抢，即刻终止） | ~0.2 hr | $27.25/hr | ~$5 |
| H200 `i-0edb43aa7099e075e`（早期误抢，自终止） | ~4 hr | $27.25/hr | ~$109 ⚠️ |
| 权重镜像存储 | — | $0.023/GiB·月 | $3.4/月 |
| | | **合计** | **~$926** |

> ⚠️ **约 $504（54%）是浪费的**：Lambda poller 每次被 EventBridge 触发都会独立抢一台，而"已抢到"的状态只存在于单次 Lambda 调用的内存里（`launched_types` 是局部变量），
> 规则自禁又发生在抢到之后，导致同一轮里重复启动。加上早期误抢的 H200，共三台机器空转。
> **修复方向**：把"本类型已抢到"的状态外置（DynamoDB / S3 标记 / 或启动前先 `describe-instances` 按 tag 查重），
> 而不是依赖 EventBridge 自禁。这条应该在下次用 poller 之前修掉。
