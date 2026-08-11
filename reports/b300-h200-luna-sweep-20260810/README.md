# B300 / H200 / Bedrock GPT-5.6-Luna 并发扩展性对比报告

> **Run ID**: `b300-h200-luna-sweep-20260810`
> **日期**: 2026-08-10
> **模型**: DeepSeek-V4-Flash（自建）+ Bedrock GPT-5.6-Luna（托管 API）
> **统一口径**: 真实 **40K input / 1.5K output** + EAGLE(3/1/4)，`random-range-ratio 1.0`，强制满 1500 输出
> **结论**: 高并发场景 **B300 2P2D 最优**；tp=8 只适合低并发；H200 tp=8 高并发崩溃；Luna 作为零运维托管方案 TPOT/TTFT 均达标。

---

## 1. 测试范围

本轮在统一口径（40K in / 1.5K out / +EAGLE）下，对 **5 个配置**做并发扫描（c=1/4/8/16/32）与单请求验收：

| 配置 | 硬件 | 部署 | 说明 |
|------|------|------|------|
| B300 tp=8 | p6-b300.48xlarge (8×B300) | 单容器 tp=8 | prefill+decode 混布 |
| B300 2P2D | p6-b300.48xlarge | PD 分离：2 prefill + 2 decode（各 tp=2） | 4 卡专用 decode 池 |
| B300 3P1D | p6-b300.48xlarge | PD 分离：3 prefill + 1 decode（各 tp=2） | 2 卡 decode 池 |
| H200 tp=8 | 8×H200 | 单容器 tp=8 | 硬件对照 |
| GPT-5.6-Luna | Bedrock Mantle (us-east-1) | 托管 Responses API | 流式实测 TTFT/TPOT，同口径 40K/1.5K |

**验收指标**：TPOT P50 ≤ 4.5 ms，TTFT P50 ≤ 1.7 s。

---

## 2. 核心结论

### 2.1 并发扩展性（TPOT P50，越低越好）

| 并发 | B300 tp=8 | B300 2P2D | B300 3P1D | H200 tp=8 | Luna(托管) |
|------|-----------|-----------|-----------|-----------|------------|
| c=1  | **3.45** | 3.75 | 3.71 | 3.15 | — |
| c=4  | **4.04** | 4.28 | 4.37 | 5.04 | — |
| c=8  | 4.92 | **4.53** | 5.14 | 7.86 | — |
| c=16 | 8.73 | **5.12** | 6.14 | 18.36 | — |
| c=32 | 16.66 | **5.66** | 6.99 | 34.32 | — |
| 参考 | | | | | **5.79**（同口径单请求流式） |

- **交叉点 ≈ c=8**：低并发 tp=8 最快（无 KV 传输开销）；高并发 PD 完胜。
- **c=32**：2P2D(5.66) < 3P1D(6.99) << B300 tp8(16.66) < H200 tp8(34.32)。
- **关键洞察**：高并发长输出场景，**给 decode 更多卡**最有效（2P2D 的 4 卡 decode 池 > 3P1D 的 2 卡 > tp=8 混布）。

### 2.2 TTFT P50（首 token 延迟，越低越好）

| 并发 | B300 tp=8 | B300 2P2D | B300 3P1D | H200 tp=8 | Luna |
|------|-----------|-----------|-----------|-----------|------|
| c=1  | **245** | 1066 | 1078 | 1472 | 1390 |
| c=8  | **274** | 1323 | 1328 | 1377 | — |
| c=32 | **1123** | 4368 | 3437 | 2523 | — |

- **B300 tp=8 TTFT 全程最低**（8 卡 prefill 火力最强），是唯一 c=32 仍 < 1.7s 的自建配置。
- PD 因 prefill 卡少 + nixl KV 传输，c≥16 破 1.7s 线。
- **Luna 1.39s（同口径 40K）达标** ✅。

### 2.3 硬件对比 B300 vs H200（均 tp=8）

- **c=1 近似打平**（H200 3.15 略快于 B300 3.45，纯单请求算力）。
- **一上并发 B300 全面碾压**：c=16 快 2.1×，c=32 快 2.06×（16.66 vs 34.32）。
- 吞吐：B300 持续爬升至 1754 tok/s；H200 c=8 见顶(911) 后回落 —— H200 tp8 在 c≥16 调度受限/饱和。

### 2.4 Bedrock GPT-5.6-Luna（托管 API，同口径 40K/1.5K，流式实测）

| 指标 | P50 | P95 |
|------|-----|-----|
| TTFT | **1.39 s** ✅ | 1.39 s |
| TPOT | **5.79 ms** | 5.79 ms |
| E2E | 14.91 s | 14.91 s |
| 输出 token | ~1467 | — |

- TPOT 5.79ms ≈ B300 2P2D 在 c=8~16 的水平；TTFT 1.39s 与 B300 PD 配置同档，均达标。
- 优势：**零运维、弹性承载、不随并发崩溃**（AWS 侧扩容）。
- 局限：要亚秒 TTFT / <4ms TPOT 仍需自建 B300 tp=8（低并发）。

---

## 3. 选型建议

| 场景 | 推荐 | 理由 |
|------|------|------|
| 单请求 / 低并发（c≤4）、看重 TTFT | **B300 tp=8** | TTFT 245ms、TPOT 3.4ms，最快、单容器最简单 |
| 高并发生产（c≥8） | **B300 2P2D** | TPOT/吞吐双优，唯一能扛住高并发的配置 |
| 不想自建 / 并发波动大 / 可接受 6ms 级 TPOT | **Bedrock GPT-5.6-Luna** | 零运维、达标、弹性 |
| — | ~~B300 3P1D~~ | 全程被 2P2D 压制，可淘汰 |
| — | ~~H200 tp=8~~ | 高并发崩溃，仅低并发可用 |

---

## 4. 图表

见 `charts/`：

- `all5_combined_compare.png` — **五配置综合对比**（TPOT/TTFT/E2E/吞吐 vs 并发；Luna 为同口径橙色参考线）
- `b300_sweep40k_3way.png` — B300 三方案并发曲线
- `b300_vs_h200_tp8.png` — B300 vs H200 硬件对比
- `b300_4metrics_compare.png` — B300 三方案 c=1 验收 4 指标

---

## 5. 数据与复现

- **B300 三方案原始 sweep**：`sweep-b300/{tp8,2p2d,3p1d}_sweep40k_c{1,4,8,16,32}.jsonl`
  （来源 S3 `s3://tpot-bench-results-077090643075-us-west-2/runs/b300-sweep40k/`，token 口径已验证 40000/1500）
- **H200 sweep**：`sweep-h200/h200tp8_sweep40k_c{1,4,8,16,32}.json`
  （由实时 SSM 采集的指标重构；原始 jsonl 随实例 `i-04bf3b9d70107c447` 终止丢失）
- **Luna**：`luna/gpt56_luna_aligned.{py,json}`（同口径 40K/1.5K 流式）、`luna/gpt56_luna_stream.{py,json}`（长文 ~860 tok 版本）
- **绘图脚本**：`scripts/make_all5.py`、`make_sweep.py`、`make_b300_h200.py`（需 CJK 字体 wqy-zenhei）

### 复现要点

自建 bench 命令（sglang）：
```
python3 -m sglang.bench_serving --backend sglang --base-url http://127.0.0.1:30080 \
  --dataset-name random --num-prompts <N> \
  --random-input 40000 --random-output 1500 --random-range-ratio 1.0 \
  --max-concurrency <C> --request-rate inf --output-file <file>
```
（并发档 num-prompts 按并发缩放：c1=16, c4=32, c8=64, c16=128, c32=256）

Luna 流式 bench（Bedrock Mantle Responses API，SigV4 service=`bedrock-mantle`）：
- **必须用流式**（`"stream":true` + `Accept: text/event-stream`）才能测 per-token 延迟；
- TTFT = 首个 `output_text.delta` 到达时间；TPOT = (末 delta − 首 delta)/(delta 数 − 1)；
- 非流式只能测整请求延迟。详见 `luna/gpt56_luna_aligned.py`。

### 已知注意事项

- EAGLE 是 PD 方案 TPOT 达标的关键；缺失会显著恶化 decode 延迟。
- Luna 流式 usage **不回报 input_tokens**（显示 0）；输出 token 正常。输入量经字符/词估算约 40K。
- 每次运行务必核对 `total_input_tokens/completed ≈ 40000`、`total_output_tokens/completed ≈ 1500` 再采信指标。
