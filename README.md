# DeepSeek-V4-Flash 推理选型测试方案

> 场景：to-C Trip Planner ｜ 目标：时延敏感、低并发 ｜ 平台：AWS EKS + SGLang

## 0. 怎么真的跑起来（先看这里）

本仓库现在有**两条**执行路径，互不替代：

| 路径 | 入口 | 适用 |
|---|---|---|
| **EKS 路径**（原有） | `scripts/run-benchmark.sh` | 已有 EKS 集群、走 kubectl 部署 |
| **裸 EC2 路径**（新增） | `scripts/run-staged.sh` | 没有集群、想按台阶渐进验证、不希望流水线依赖某个会话 |

裸 EC2 路径按四级台阶推进，前一级没过就不动下一级：
`preflight($0)` → `plumbing(约 $0.01)` → `gpu-smoke(约 $1.2/hr)` → `full(上限约 $106.65)`。
每一级都必须显式 `CONFIRM_SPEND=yes` 才会真的启动实例，默认是拒绝。

```bash
bash scripts/run-staged.sh          # 零花费预检，什么都不启动
bash scripts/run-staged.sh --show-ledger   # 看哪一级已经过了、上次用的哪个 recipe
```

- **操作手册（可直接复制粘贴的命令、每级花费、故障速查表）**：
  [docs/RUNBOOK.md](docs/RUNBOOK.md)
- **上一次失败的完整复盘（13h14m / 约 $353 / 零产出，以及每条失败对应的修复）**：
  [docs/postmortem-2026-08-07-p5en-run.md](docs/postmortem-2026-08-07-p5en-run.md)
- **三个可直接替换的 H200 配置**：`scripts/recipes/`（换配置只改一个
  `--recipe` 参数，不用改脚本）

---

## 0.1 Benchmark Reports

| 日期 | 硬件 | 配置 | TPOT P50 | Output tok/s | 结果 | 报告 |
|------|------|------|----------|-------------|------|------|
| 2026-08-09 | H200 x4 (p5en.48xlarge) | tp=4, EAGLE 3/1/4, Marlin | 3.330 ms | 224.2 (custom) / 282.5 (official) | **PASS** | [reports/h200-tp4-eagle-20260809](reports/h200-tp4-eagle-20260809/) |

---

## 1. 结论摘要（TL;DR）

| 项 | 结论 |
|---|---|
| **核心指标** | **TPOT ≤ 4.5ms** + **TTFT ≤ 1.7s**（两者都重要，TTFT 占 E2E 约 20%） |
| **首选优化** | **EAGLE 3/1/4 投机解码**（accept length ~2.5，非 MTP） |
| **推荐拓扑** | **整机 unified tp=8** + EAGLE（对标 LMSYS 官方配置）；或整机 PD 分离（需验证 TTFT 是否有优势） |
| **不推荐拓扑** | 副本制（客户要求整机部署）；MTP（官方实测效果远不如 EAGLE） |
| **头号待测硬件** | **p6-b300**（288GB/卡，tp=1 理论可行但 TPOT 目标极严格）；**p6-b200**（带宽仅差 4%，便宜 20%） |
| **官方参考基线** | H200 Flash tp=4: ~266 tok/s (TPOT ≈ 3.76ms)；B200 Pro tp=8: ~199 tok/s (TPOT ≈ 5.03ms) |
| **最大风险** | 4.5ms TPOT 要求极严格 —— 需 EAGLE 有效 + 硬件带宽充足 + 40K KV cache 不挤压 decode 带宽 |

---

## 2. 场景与负载特征

### 2.1 客户需求

- **业务**：to-C Trip Planner（行程规划）
- **时延**：要求高（严格）
- **并发**：要求低
- **模型**：DeepSeek-V4-Flash

### 2.2 模型规格

| 项 | 值 | 来源 |
|---|---|---|
| 总参数 | 284 B | [HF 模型卡](https://huggingface.co/deepseek-ai/DeepSeek-V4-Flash) |
| 激活参数 | 13 B（激活率 4.6%，极稀疏 MoE） | 同上 |
| 上下文 | 1 M tokens | 同上 |
| 精度 | FP4（原生 checkpoint） | [NVFP4 版](https://huggingface.co/nvidia/DeepSeek-V4-Flash-NVFP4) |
| **FP4 权重体积** | **≈ 142 GB**（284B × 0.5 byte） | 推算，与第三方量化仓库标注的 149GB FP4+FP8 源一致 |
| 特性 | 混合注意力（CSA + HCA）、**自带 MTP 头** | HF / [LMSYS V4 博客](https://lmsys.org/blog/2026-04-25-deepseek-v4/) |

> ⚠️ **勘误**：AWS 仓库 `dsv4flash-pd-deploy.yaml` 注释中的 "500GB+ weights" **不准确**，该数字应属 V4-**Pro**（1.6T 参数）。Flash 的 FP4 权重约 142GB，**单张 B300/B200 即可装下**，因此 `tp=1` 可行、单机 8 副本成立。

### 2.3 关键洞察：负载分析（已更新）

**客户确认的真实负载参数：**

| 参数 | 值 |
|---|---|
| 模型输入 | **40K tokens** |
| 模型输出（含 think） | **1.5K tokens** |
| 部署方式 | **整机部署**（8 卡一套，不拆副本） |

**端到端延迟拆解（按客户验收标准）：**

| 组成 | 目标值 | 占 E2E |
|---|---|---|
| TTFT（40K prefill） | **≤ 1.7 s** | **~20%** |
| Decode（1500 tokens × 4.5ms TPOT） | **≤ 6.75 s** | **~80%** |
| **E2E 目标** | **≤ 8.45 s** | 100% |

**负载特征修正：**

- ❌ 之前假设"短输入长输出" → ✅ 实际是**长输入（40K）+ 中等输出（1.5K）**
- ❌ 之前假设"TTFT 可忽略" → ✅ TTFT 占 E2E 约 20%，**两个指标都重要**
- ❌ 之前推荐副本制 → ✅ 客户明确要求**整机部署**
- ❌ 之前推荐 MTP → ✅ LMSYS 官方验证 **EAGLE 3/1/4 远优于 MTP**

**新的优化优先级：**

1. **TPOT**（仍是主矛盾）：4.5ms 极严格，需 EAGLE + 高带宽硬件
2. **TTFT**（不再可忽略）：40K prefill 在 tp=8 下约 1-2s，在 tp=4 可能更快但 TPOT 受限
3. **KV cache 压力**：40K input 的 KV 会占用显存，挤压 decode 可用带宽（需评估影响）

---

## 3. 首要优化：MTP 投机解码

既然 TPOT 是唯一重要指标，投机解码是最该做的事。四个因素叠加得非常好：

1. **V4-Flash 权重自带 MTP 头** —— 无需额外训练 draft model。DeepSeek V4 与 GLM-5.1 的发布权重均内置 MTP 预测头，与主干共享残差流，单次前向可产出 2–4 token（[MTP 部署指南](https://www.spheron.network/blog/multi-token-prediction-mtp-gpu-cloud-deployment-guide/)）
2. **SGLang 原生支持** —— EAGLE-2/3、MTP、DFLASH、NGRAM 等多种方案（[SGLang 文档](https://docs.sglang.io/docs/advanced_features/speculative_decoding)）；LMSYS 的 V4 Day-0 博客明确列出 "MTP speculative decoding with in-graph metadata"
3. **低并发是最佳工况** —— 其原理是用空闲算力换延迟。并发低时 GPU 算力大量闲置，正好用于跑 draft；并发高时反而亏
4. **有实测量级参考** —— AMD 在 Kimi-K2.5 上启用 EAGLE3，TPOT 中位数由 42.73 ms 降至 27.41 ms（**−35.9%**），输出吞吐 672 → 895 tok/s，无精度回归（[ROCm blog](https://rocm.blogs.amd.com/artificial-intelligence/kimi-k2.5-speculative/README.html)）。该数据是 concurrency=40 工况，低并发下收益预期更大

> ⚠️ **AWS 仓库中所有 PD / 副本样例均未启用投机解码**，仅 `dsv4pro-b300-single-node` 的 unified manifest 使用了 `--speculative-algo EAGLE`。直接照抄 3P1D recipe 会错过这个最大优化项。

*（以上引用内容均已改写以符合授权要求）*

---

## 4. 拓扑方案对比

AWS 仓库 `examples/inference/sglang/` 下 B300 相关的 4 种拓扑，加 unified 共 5 种形状：

| # | 拓扑 | 引擎 × tp | 单请求可用资源 | KV 余量/引擎 | 低并发 TPOT | 密度 | 长上下文 | 对本场景 |
|---|---|---|---|---|---|---|---|---|
| 1 | **8× 独立副本** | 8 × tp=1 | 1 卡，**零 TP 通信** | ~146 GB | **可能最优** | **最高** | 受限 | ✅ **推荐** |
| 2 | **4× 独立副本** | 4 × tp=2 | 2 卡，少量通信 | ~434 GB | 好 | 高 | 中 | ✅ **推荐** |
| 3 | PD 3P1D | 4 × tp=2 (3P+1D) | decode 仅 2 卡 + KV 传输开销 | ~434 GB | 中 | 高* | 中 | ❌ 不推荐 |
| 4 | PD 6P2D | 8 × tp=1 (6P+2D) | decode 仅 1 卡 | ~146 GB | 中 | 高* | 受限 | ❌ 不推荐 |
| 5 | Unified 单引擎 | 1 × tp=8 | 8 卡，但通信重 | ~2160 GB | 中（通信主导） | 中 | **最优** | 🔶 备选 |

\* 仅在 prefill 密集负载下密度占优
KV 余量按 `288GB × 卡数 − 142GB 权重` 估算（B300）；tp≥2 时权重分片

### 4.1 为什么稀疏 MoE 下 tp=1 可能反而最快

V4-Flash 激活率仅 4.6%（13B / 284B）：

- **tp=1 优势**：零 tensor-parallel 通信。无逐层 all-reduce、无 MoE all-to-all。单卡全部带宽用于读取激活的 ~6.5 GB(FP4) 权重
- **tp=8 代价**：权重分片后每卡只读 1/8（快），但需付 ~60 层 all-reduce + expert all-to-all 的通信延迟。激活参数仅 13B，**通信开销很可能盖过计算收益**

→ 该平衡点**必须实测**，不能靠推演定论。

### 4.2 参考数据（仅 unified / V4-Pro 有公开数字）

AWS 仓库 `dsv4pro-b300-single-node` 的 benchmark（input 2048 / output 256）：

| 并发 | Req/s | Output tok/s | Median TTFT | Median TPOT | Mean E2E |
|---|---|---|---|---|---|
| **25** | 2.56 | 329.6 | **396 ms** | **56 ms** | 9.7 s |
| 50 | 4.28 | 552.1 | 407 ms | 84 ms | 11.6 s |
| 100 | 6.45 | 831.9 | 475 ms | 119 ms | 15.3 s |
| 200 | 9.99 | 1287.6 | 592 ms | 158 ms | 19.5 s |
| 300 | 12.95 | 1669.3 | 4.4 s | 143 ms | 22.0 s |
| 500 | 14.16 | 1824.7 | 16.8 s | 135 ms | 30.5 s |

**观察**：TTFT 与 TPOT 均在低并发端最优，随并发单调恶化。该表起点已是 c=25，仍高于本场景。
**注意**：此为 V4-**Pro**（1.6T）数据，Flash 更小，同配置下应更快，但需实测。

---

## 5. 硬件候选

### 5.1 筛选标准

本场景只有 3 条硬标准：

1. **原生 FP4 支持** —— 非 Blackwell 需反量化到 FP8（权重翻倍至 284GB，每 token 读取字节数亦翻倍 → TPOT 直接 ~2× 劣化）
2. **装得下 ~142 GB** —— 决定 tp 能开多小、单机能起几副本
3. **HBM 带宽** —— decode 绑定带宽，直接决定 TPOT，即 99% 的 E2E 延迟

### 5.2 候选清单

| 实例 | GPU | 单卡 HBM | 单卡带宽 | FP4 | On-Demand | Region | 测试价值 |
|---|---|---|---|---|---|---|---|
| **p6-b200.48xlarge** | 8× B200 | 180 GB | **7.7 TB/s** | ✅ 原生 | **$113.93/hr** | 6 | 🔥 **最高** |
| p6-b300.48xlarge | 8× B300 | 288 GB | 8 TB/s | ✅ 原生 | $142.42/hr | 2 | ✅ 基线 |
| p5en / p5e.48xlarge | 8× H200 | 141 GB | 4.8 TB/s | ❌ FP8 | ~$85–98/hr* | 多 | 🔶 成本地板 |
| p6e-GB200 UltraServer | 72× GB200 | 186 GB | ~8 TB/s | ✅ | 极高 | 少 | ❌ 过配 |
| trn2.48xlarge | 16× Trainium2 | 96 GB | 高 | ❌ | 低 | 少 | ❌ 软件不成熟 |
| g6e.48xlarge | 8× L40S | 48 GB | 0.86 TB/s | ❌ | 低 | 多 | ❌ 带宽致命 |

\* p5e/p5en 未查到确切 on-demand 价格，需以 AWS 官方价格页为准

### 5.3 🔥 头号推荐：p6-b200

**核心发现：B200 与 B300 的 HBM 带宽几乎相同，但整机便宜 20%。**

| | B200 | B300 | 差异 |
|---|---|---|---|
| HBM 容量 | 180 GB | 288 GB | B300 多 **55.6%** |
| **HBM 带宽** | **7.7 TB/s** | **8 TB/s** | **仅差 4%** ← 关键 |
| 密集 FP4 算力 | ~10 PFLOPS | 15 PFLOPS | B300 多 50% |
| 整机价格 | **$113.93/hr** | $142.42/hr | B200 省 **20%** |
| 可用 Region | 6 | 2 | B200 更易拿货 |
| 量产时间 | 2025 中 | 2026-01 | B200 软件栈更成熟 |

来源：[B200/B300 架构对比](https://verda.com/blog/nvidia-b200-and-b300-gpu-architecture-and-software-stack)、[B300 规格](https://www.spheron.network/blog/nvidia-b300-blackwell-ultra-guide/)、[p6-b200 定价](https://instances.vantage.sh/aws/ec2/p6-b200.48xlarge)（内容已改写以符合授权要求）

**为什么对本场景意义重大**：decode 绑定带宽，带宽仅差 4% → **TPOT 应几乎相同**。而 B300 多出的 55% 显存与 50% FP4 算力，在本场景中：

- 多出的显存 → 仅超长上下文用得上（trip planner 约 10–50k，用不到）
- 多出的算力 → prefill 更快，但 prefill 只占 E2E 的 1%

→ **可能在为用不上的能力付 20% 溢价。**

⚠️ **实际约束**：142 GB 权重放入 180 GB 单卡，仅剩 ~38 GB 给 KV cache + 激活 + CUDA graph，**tp=1 偏紧**。B200 上大概率需走 `tp=2`（4 副本）；B300 的 288 GB 才有余量做真正的 `tp=1`（8 副本）。

由此产生一个高价值待测问题：

| 配置 | 副本数 | 单副本成本 | 优势 |
|---|---|---|---|
| B300 + 8× tp=1 | 8 | $17.80/hr | 零通信、副本多 |
| B200 + 4× tp=2 | 4 | $28.48/hr | 整机便宜 20% |

低并发下副本数用不满 → **B200 的 20% 折扣可能更实在**，但需实测 tp=1 vs tp=2 的 TPOT 差异才能定论。

### 5.4 🔶 次选：p5en / p5e（H200）

测试价值在于**确立成本地板**，而非主力候选。预期劣化（两因素叠加）：

- 带宽 4.8 vs 8 TB/s → TPOT **~1.7×**
- 无原生 FP4（H200 是 Hopper SM90），MoE 专家权重必须换路径 → 再 **~2×**
- 141 GB 单卡装不下整份权重 → 至少 tp=4，通信开销再叠加

> **✅ 2026-08-08 更正（此前这里写「需跑 FP8 checkpoint（284 GB）」，不准确）**
>
> 实际 checkpoint 情况（HuggingFace API + SGLang cookbook 双向核对）：
>
> | 权重 | 精度 | 文件数 | 体积 | 说明 |
> |---|---|---|---|---|
> | `deepseek-ai/DeepSeek-V4-Flash` | **FP4 专家 + FP8 注意力/dense** | 73 | **159.6 GB / 148.7 GiB** | 官方 instruct 权重。`config.json` 里 `expert_dtype=fp4`、`quantization_config.quant_method=fp8`、`num_nextn_predict_layers=1` |
> | `sgl-project/DeepSeek-V4-Flash-FP8` | 纯 FP8（重打包） | 55 | **294.1 GB / 273.9 GiB** | 这个才是原文「约 284 GB FP8」真正对应的东西，而它是**另一个 repo**，不是官方 instruct 权重 |
> | `deepseek-ai/DeepSeek-V4-Flash-0731` | FP4 专家，附带 DSpark draft 头 | 74 | 166.9 GB / 155.4 GiB | cookbook 标注在 8×B200 / 4×GB300 / **4×H200** 已验证 |
>
> 因此 **Hopper（H100/H200）上按上游 cookbook 只有两条路，没有第三条**：
>
> 1. **直接用原始 FP4 权重**，走 **W4A16 Marlin** MoE kernel。这条路
>    **只能纯 TP**，用不了 DP-attention，也用不了 DeepEP。
> 2. **换成重打包的 FP8 权重** `sgl-project/DeepSeek-V4-Flash-FP8`
>    （H100/H200 专用），**解锁 DP-attention + DeepEP**，代价是权重体积几乎翻倍
>    （294.1 GB）。
>
> 另外：`deepseek-ai/DeepSeek-V4-Flash-Base` 确实是纯 FP8（`expert_dtype=fp8`），
> 但 cookbook 明确写了 `*-Base` 仓库**只用于继续预训练，不可用于 chat 或
> tool calling**，所以它**不是**合法替代品。
>
> 两条路各自对应一个可直接使用的 recipe：`scripts/recipes/h200-tp4-fp4-eagle.env`
> 与 `scripts/recipes/h200-tp4-fp8-eagle.env`（第三个是 DSpark 变体）。

**合计 TPOT 可能劣化 3× 以上**，对 TPOT 主导负载基本出局。但仍值得跑一个数据点：

- 便宜且容量充足（B300/B200 可能拿不到货）
- 上线初期量小时，"够用就行"的方案有商业价值
- 给客户量化的"贵 vs 慢"trade-off 曲线，比单一方案更有说服力

### 5.5 ❌ 不建议测试

| 实例 | 原因 |
|---|---|
| **P6e-GB200 UltraServer** | 72 GPU 单一 NVLink 域、13.4 TB HBM，为超大模型/超大 tp 设计。本模型单卡即可装下，NVL72 价值完全用不上 |
| **trn2 (Trainium2)** | 成本诱人，但 SGLang 不支持 Neuron。V4-Flash 的混合注意力（CSA+HCA）+ MTP 头在 Neuron 上支持成熟度几乎必然不足。**值得跟踪，不适合当前 POC** |
| **g6e (L40S)** | 带宽 0.86 TB/s，比 Blackwell 差近 10×。对带宽绑定的 decode 致命；且无 FP4、卡间走 PCIe 而非 NVLink |

---

## 6. 测试矩阵

全部启用 MTP 投机解码，跑同一组低并发参数：

| 优先级 | 硬件 | 拓扑 | 目的 |
|---|---|---|---|
| **P0** | B300 | 8× tp=1 | 基线 |
| **P0** | **B200** | **4× tp=2** | **验证 20% 折扣是否零代价** ← 信息量最高 |
| P1 | B300 | 4× tp=2 | 隔离变量：同硬件下 tp 的影响 |
| P1 | B300 | 8× tp=1，**关闭** MTP | 量化投机解码实际收益 |
| P2 | H200 | tp=4 (FP8) | 成本地板 / 容量兜底 |
| 可选 | B300 | 3P1D | 验证其在 decode 密集负载下确实更差 |

### 6.1 基准命令（已更新，对齐客户验收标准）

```bash
# 对齐客户真实负载：40K input, 1.5K output, 单批
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random \
  --random-input 40000 \
  --random-output 1500 \
  --num-prompts 50 \
  --max-concurrency 1

# 对齐 LMSYS 官方设置（用于对标基线）
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random \
  --random-input 30000 \
  --random-output 4096 \
  --num-prompts 50 \
  --max-concurrency 1
```

### 6.2 关注指标

| 指标 | 权重 | 说明 |
|---|---|---|
| **TPOT (P50 / P95)** | ⭐⭐⭐ | 主指标，决定 99% 的 E2E |
| **E2E (P50 / P95)** | ⭐⭐⭐ | 用户实际感知 |
| TTFT | ⭐ | 流式输出下影响首屏感知；非流式下几乎无关 |
| Output tok/s | ⭐⭐ | 单副本吞吐，用于算密度 |
| 单副本成本 $/hr | ⭐⭐ | 整机价 ÷ 副本数，TCO 对比 |

---

## 7. 待客户确认的关键问题

按重要性排序：

| # | 问题 | 为什么关键 |
|---|---|---|
| **1** | **前端流式输出还是等全文返回？** | 流式下 TPOT 只需超过人类阅读速度（~15 tok/s），55 tok/s 已很舒适 → 延迟问题大幅简化。非流式需等 40s → 必须上投机解码 + 考虑缩短输出。**这是产品决策，收益超过任何基础设施调优** |
| **2** | **典型输出长度多少 token？** | 直接决定 E2E。本文按 2000 估算，若实际为 500 或 5000，结论量级完全不同 |
| **3** | **是否 agentic 多轮？调几次工具？** | trip planner 通常需查航班/酒店/POI。每轮 LLM 调用延迟累加；同时意味着 **prefix 复用率高** → cache-aware 路由收益大 |
| **4** | **实际上下文长度？** | 模型支持 1M，但 trip planner 对话+工具结果约 10–50k。若确认远小于 1M，**tp=1 的 KV 空间完全够用** |
| 5 | 并发峰值预期？ | to-C 有晚间/周末高峰与营销脉冲，"低并发"可能是当前量而非峰值量 → 需弹性余量 |

---

## 8. 两个结构性问题

### 8.1 最小采购单位是 8 卡整机

AWS 上 Blackwell 仅有 48xlarge（8 GPU）一种规格，**无单卡/双卡 B200/B300 实例**。

模型单卡装得下 + 并发低 → 买 8 卡可能只用 1–2 卡。两条路：

- **拥抱密度**：起满副本，整机成本摊到 8 条流（B300 约 $17.80/hr per stream）
- **质疑自建**：若并发确实很低且无增长预期，Bedrock 等按 token 计费方案 TCO 可能更优。$142/hr ≈ 每月 $10.4 万，需算清盈亏平衡的 token 量

### 8.2 时间窗口

现为 2026-08，[Rubin (R100/R200) 预计 H2 2026 出货](https://www.spheron.network/blog/nvidia-rubin-vs-blackwell-vs-hopper/)，同时 B200/B300 价格下行。若为长期部署，采购时机与代际选择需与客户一起评估。

---

## 9. 已完成的环境验证（POC）

为验证工具链，已在 AWS 上完成一次端到端部署演练：

| 项 | 状态 |
|---|---|
| EKS 集群 `sglang-b300-poc` (us-east-1, K8s 1.32) | ✅ 已建 |
| sys 节点组 (c5.2xlarge) | ✅ 运行中 |
| p6b300 节点组 (desiredCapacity=0) | ✅ ACTIVE，待扩容 |
| NVIDIA / EFA Device Plugin | ✅ 已装 |
| 最小化 demo（g4dn.xlarge + Qwen2.5-1.5B） | ✅ 推理服务可用，API 测试通过 |
| 客户端压测脚本 | ✅ 240 请求 100% 成功 |

### 9.1 已知踩坑

| 问题 | 说明 |
|---|---|
| **SGLang 不兼容 T4** | v0.5.12 的 flashinfer 不支持 SM 7.5（Turing），报 `KeyError: 'sm_75'`。最小化 demo 改用 vLLM v0.5.5 替代。**不影响 B200/B300**（SM 100+） |
| **NVMe 路径差异** | HyperPod = `/opt/dlami/nvme/`，自建 EKS(RAID0) = `/mnt/k8s-disks/0/`，裸 EC2 = `/mnt/nvme/`。所有 manifest 需按环境修改，否则权重会写到小根盘 |
| **裸 EC2 本地实例存储不会自动挂载**（2026-08-07，代价约 $353） | `p5en.48xlarge` 自带 8 × 3800 GB = **30.4 TB** 本地 NVMe（`NvmeSupport=required`），但**不挂就等于没有**。那次启动一块都没挂，148.7 GiB 权重全挤在一块 200 GB gp3 根盘上（扣掉 OS 与约 12.75 GB 镜像只剩约 175 GB），第二次尝试「下载 150.98 GB 只写进 19.21 GB」= 盘满。**这正是上一行那条 NVMe 警告本该拦住的事故。** 修复：`scripts/bootstrap/bench-bootstrap.sh` 按 model 识别实例存储盘并组 RAID0 挂到 `/mnt/nvme`，下载前先断言可用空间。完整复盘见 [docs/postmortem-2026-08-07-p5en-run.md](docs/postmortem-2026-08-07-p5en-run.md) |
| **仓库注释错误** | `dsv4flash-pd-deploy.yaml` 的 "500GB+ weights" 属 V4-Pro，Flash 实为 ~142GB |

> ⚠️ 该 POC 使用 T4 + 1.5B 模型 + vLLM，**仅验证部署流程，性能数据不可外推**到 B300 + V4-Flash 场景。

---

## 10. 权威信息源

| 来源 | 用途 |
|---|---|
| [SGLang DeepSeek-V4 Cookbook](https://lmsysorg.mintlify.app/cookbook/autoregressive/DeepSeek/DeepSeek-V4) | **上游权威** —— Flash(284B)/Pro(1.6T) 的已验证启动命令、benchmark、调优参数。AWS 仓库的 `SGLANG_OPT_*` 均源自此处 |
| [SGLang 投机解码文档](https://docs.sglang.io/docs/advanced_features/speculative_decoding) | EAGLE/MTP/DFLASH 配置 |
| [LMSYS DeepSeek-V4 Day-0 博客](https://lmsys.org/blog/2026-04-25-deepseek-v4/) | V4 的推理优化特性清单 |
| [awsome-distributed-ai](https://github.com/awslabs/awsome-distributed-ai/tree/worktree-repo-reorg/examples/inference/sglang) | AWS 侧 EKS/HyperPod 部署样例 |

> 💡 AWS 仓库 3P1D 的注释明确写了它抄的是 cookbook 中 **"high-throughput"** 那一档配置。本场景应查 cookbook 是否有**低延迟**档，可能直接就有官方推荐配置。

---

## 11. 结论中的不确定性声明

为避免误用，明确区分**已核实**与**推演**：

| 已核实（有来源） | 推演（需实测验证） |
|---|---|
| V4-Flash 284B/13B、FP4 ≈142GB | B200 与 B300 的 TPOT "几乎相同" |
| B200/B300/H200 的容量、带宽、价格 | tp=1 vs tp=2 vs tp=8 在稀疏 MoE 下的最优点 |
| V4-Flash 自带 MTP 头，SGLang 支持 | H200 劣化 "3× 以上" |
| EAGLE3 在 Kimi-K2.5 上 TPOT −35.9% | MTP 在 V4-Flash + B300 上的实际收益 |
| AWS 仓库各 manifest 的实际配置 | 输出长度 2000 tokens 的假设 |

**目前无任何 V4-Flash 在 B200/B300 上的实测数据。** 仓库仅公开了 V4-Pro unified 一组参考数字，Flash 的各拓扑均无公开数据。

---

## 12. 客户验收标准与测试需求

### 12.1 硬性验收指标

| 指标 | 目标值 | 对标来源 | 说明 |
|---|---|---|---|
| **TPOT** | **≤ 4.5 ms** | [LMSYS DeepSeek-V4 Day-0 博客](https://www.lmsys.org/blog/2026-04-25-deepseek-v4/) H200 Flash 数据 | 对应 ≥222 tok/s decode 吞吐 |
| **TTFT** | **≤ 1.7 s** | 客户要求 | 40K tokens prefill 时间 |
| **输入 tokens** | **40,000** | 客户场景 | Trip planner 上下文（历史 + 工具结果 + system prompt） |
| **输出 tokens** | **1,500**（含 think） | 客户场景 | 行程规划 + 思考链 |
| **部署方式** | **整机部署** | 客户要求 | 8 卡一套，不拆独立副本 |

### 12.2 官方参考基线（LMSYS Day-0 博客）

来源：[DeepSeek-V4 on Day 0: From Fast Inference to Verified RL with SGLang and Miles](https://www.lmsys.org/blog/2026-04-25-deepseek-v4/)

| 配置 | 模型 | 硬件 | tp | 投机解码 | Decode 吞吐 | TPOT | 备注 |
|---|---|---|---|---|---|---|---|
| SGLang | V4-Flash (284B) | H200 | 4 | EAGLE 3/1/4 (accept ~2.5) | **~266 tok/s** | **~3.76 ms** | ✅ 满足 4.5ms |
| SGLang | V4-Pro (1.6T) | B200 | 8 | EAGLE 3/1/4 (accept ~2.5) | ~199 tok/s | ~5.03 ms | ❌ 不满足 4.5ms |
| SGLang | V4-Flash | H200 | 4 | EAGLE (900K context) | ~240 tok/s | ~4.17 ms | ✅ 满足（长上下文衰减 <10%） |
| SGLang | V4-Flash | B200 | ? | EAGLE (900K context) | ~180 tok/s | ~5.56 ms | ❌ 不满足（但这是 Pro） |

**关键观察：**

- H200 上 Flash 的 **266 tok/s 已含 EAGLE 加速**，对应 TPOT 3.76ms ✅
- 该数字使用 **30K prefix + OSL 4096 + single-batch decode** 测试条件
- 客户场景是 40K input（略长于 30K），但博客表明衰减 <10%
- **B200 上的 ~199 tok/s 是 Pro (1.6T)**，Flash (284B) 在 B200 上应更快，但无直接数据

### 12.3 TPOT 4.5ms 可行性分析

| 硬件 | tp | 投机解码 | 预期 TPOT | 是否达标 | 分析 |
|---|---|---|---|---|---|
| **H200 (p5en)** | 4 | EAGLE 3/1/4 | ~3.76 ms | ✅ **已验证** | LMSYS 官方数据，最确定的方案 |
| **B300** | 8 (unified) | EAGLE 3/1/4 | ~3.0-4.0 ms（推测） | 可能 ✅ | 带宽 8 TB/s > H200 4.8 TB/s，但 tp=8 通信开销更大 |
| **B300** | 4 | EAGLE 3/1/4 | ~3.5-4.5 ms（推测） | 可能 ✅ | 4 卡 × 8TB/s = 32 TB/s 总带宽，但权重需分片 |
| **B200** | 4 | EAGLE 3/1/4 | ~3.5-4.5 ms（推测） | 可能 ✅ | 带宽 7.7 TB/s ≈ H200×1.6，需验证 |
| B300 | 1 (tp=1) | EAGLE 3/1/4 | ~5-8 ms（推测） | ❌ 可能不够 | 单卡 8 TB/s 不足以支撑 4.5ms，稀疏 MoE 也许能补偿 |
| H200 | 4 | 无投机解码 | ~8-10 ms（推测） | ❌ | 无 EAGLE 大概率不达标 |

**⚠️ 重要推翻：**

之前推荐的 `tp=1（8 副本）` 方案，在 4.5ms TPOT 约束下**大概率不可行**：
- 单卡 8 TB/s，即使 V4-Flash 极稀疏（13B 激活），decode 一步仍需读取激活权重 + KV
- 官方在 H200 上用的是 tp=4（4 卡 × 4.8 = 19.2 TB/s 总带宽），接近 4ms
- tp=1 的总带宽仅 8 TB/s，除非 EAGLE accept rate 极高否则达不到 4.5ms

→ **整机 unified (tp=8 或 tp=4+dp=2) 成为必选**，与客户"整机部署"要求一致。

### 12.4 TTFT 1.7s 可行性分析

40K tokens 的 prefill 时间取决于：
- tp 越大 → 单卡处理 token 数越少 → prefill 越快
- Blackwell FP4 tensor core 极强（15 PFLOPS/卡 on B300）
- V4-Flash 只有 13B 激活参数

| 硬件 | tp | 预期 40K prefill | 是否达标 | 分析 |
|---|---|---|---|---|
| H200 | 4 | ~1.0-1.5 s | ✅ | 官方未直接给 TTFT 数据，但参考其他基准 |
| B300 | 8 | ~0.5-1.0 s | ✅ | 8 卡 FP4 算力充足 |
| B200 | 8 | ~0.6-1.2 s | ✅ | 算力略低于 B300 |
| B300 | 4 | ~0.8-1.5 s | ✅ | 4 卡也应足够 |

**预判**：TTFT 1.7s 在所有 Blackwell/Hopper 整机配置下均有较大余量，**不是约束瓶颈**。TPOT 才是真正的 pass/fail 决定因素。

### 12.5 KV Cache 压力评估

40K input 在 V4-Flash 的混合注意力下的 KV 占用：

- **SWA (sliding window)**：仅保留最近 128 tokens → 极小
- **C4 (4:1 top-k compression)**：40K / 4 = 10K compressed positions × 每 position 的 KV 大小
- **C128 (128:1 dense compression)**：40K / 128 = 312 compressed positions → 极小

V4-Flash 的 KV 压缩比极高（ShadowRadix + 混合注意力），40K input 的实际 KV 占用远小于传统 dense attention。**这意味着 KV cache 不太可能成为瓶颈。**

### 12.6 投机解码配置（锁定）

基于 LMSYS 官方验证，锁定以下配置：

```bash
--speculative-algorithm EAGLE
--speculative-num-steps 3
--speculative-eagle-topk 1
--speculative-num-draft-tokens 4
```

> **✅ 2026-08-08 更正：flag 拼写是 `--speculative-algorithm`，不是
> `--speculative-algo`。** 上游 server_arguments 文档与 cookbook 用的都是完整
> 拼写；缩写形式不是有效参数，会让服务在启动时直接失败。
> `scripts/run-benchmark.sh` 里那处错误拼写已一并修掉。

> **➕ 2026-08-08 新增：0731 权重的 DSpark 替代方案**
>
> cookbook 3.4 节记录了另一条投机解码路径：`deepseek-ai/DeepSeek-V4-Flash-0731`
> （74 个文件 / 166.9 GB / 155.4 GiB）**自带 DSpark draft 头**，
> cookbook 标注它在 8×B200 / 4×GB300 / **4×H200** 上已验证。
>
> ```bash
> --speculative-algorithm DSPARK
> # 就这一行。不要加 --speculative-num-steps / --speculative-eagle-topk /
> # --speculative-num-draft-tokens，也不要加 --speculative-draft-model-path：
> # 目标权重与 draft 头在同一个 checkpoint 里，SGLang 直接从权重读 DSpark 形状。
> ```
>
> 附加约束（cookbook 原文）：DSpark 需要 CUDA、`pp_size == 1`、**DP-attention
> 必须关闭**，且与 PD 分离不兼容。`--speculative-dspark-block-size N` 可选，
> 省略时读 checkpoint 的值（当前 0731 权重解析为 5 个提议 token，即已验证默认值）。
>
> 现成 recipe：`scripts/recipes/h200-tp4-dspark-0731.env`。

**为什么不用 MTP（修正之前的推荐）：**

LMSYS 博客明确记录了 MTP 的问题：
- 另一 OSS 引擎用 MTP-3 在 Pro 上接受率仅 ~1.19（接近无效）
- "heavily skewed -- positions 0/1/2 accept 2226 / 354 / 55 tokens"，几乎只有第 0 位被接受
- H200 Flash 上 `num_speculative_tokens >= 2` 直接触发 kernel assertion 启动失败
- SGLang 自己选择的是 EAGLE，accept length ~2.5

**→ MTP 在 V4 上效果差或有 bug；EAGLE 是已验证的正确路径。**

### 12.7 更新后的测试矩阵

全部使用 EAGLE 3/1/4，测试条件：**40K input, 1.5K output (含 think), single-batch (concurrency=1)**

| 优先级 | 硬件 | 拓扑 | tp | 目的 | Pass 标准 |
|---|---|---|---|---|---|
| **P0** | **p5en (H200)** | unified | **4** | **复现官方基线** ← 唯一有实测数据的配置 | TPOT ≤ 4.5ms, TTFT ≤ 1.7s |
| **P0** | **p6-b300 (B300)** | unified | 8 | B300 整机基线 | TPOT ≤ 4.5ms, TTFT ≤ 1.7s |
| P1 | p6-b300 (B300) | unified | 4 (dp=2) | tp=4 是否比 tp=8 更优（减少通信） | TPOT ≤ 4.5ms |
| P1 | p6-b200 (B200) | unified | 8 | B200 能否平替 B300（省 20%） | TPOT ≤ 4.5ms |
| P2 | p6-b300 (B300) | PD 分离 | 各 tp=2 | 验证 PD 在此负载下是否有 TTFT 优势 | TTFT < unified |
| P2 | p6-b300 (B300) | unified tp=8 | **关闭 EAGLE** | 量化 EAGLE 的实际贡献 | 对比 TPOT 差异 |

### 12.8 基准 Benchmark 命令

```bash
# 方式 1：使用 SGLang 内置 bench_serving（对齐官方）
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random \
  --random-input 40000 \
  --random-output 1500 \
  --num-prompts 50 \
  --max-concurrency 1

# 方式 2：使用真实 prompt（更贴近场景）
# 需准备一组 trip planner 真实对话 prompt（~40K tokens）
python3 -m sglang.bench_serving --backend sglang \
  --dataset-path /path/to/trip-planner-prompts.jsonl \
  --num-prompts 50 \
  --max-concurrency 1
```

### 12.9 验收标准汇总（Pass/Fail）

| 编号 | 指标 | Pass 条件 | Fail 条件 | 优先级 |
|---|---|---|---|---|
| **A1** | TPOT P50 | ≤ 4.5 ms | > 4.5 ms | 🔴 必须 |
| **A2** | TPOT P95 | ≤ 6.0 ms（建议，留 headroom） | > 6.0 ms | 🟡 建议 |
| **A3** | TTFT P50 | ≤ 1.7 s | > 1.7 s | 🔴 必须 |
| **A4** | TTFT P95 | ≤ 2.5 s（建议） | > 2.5 s | 🟡 建议 |
| **A5** | E2E P50 | ≤ 8.45 s（推导：1.7 + 1500×4.5ms） | > 8.45 s | 🔴 必须 |
| **A6** | 部署方式 | 整机 8 卡 | 拆分副本 | 🔴 必须 |
| **A7** | 投机解码 | EAGLE 已启用，accept length ≥ 2.0 | EAGLE 未生效或 accept < 2.0 | 🔴 必须 |
| **A8** | 稳定性 | 连续 50 请求无 OOM/crash | 有任何异常 | 🔴 必须 |
| **A9** | 长上下文衰减 | 40K vs 4K 的 TPOT 差异 < 15% | ≥ 15% | 🟡 建议 |

### 12.10 E2E 延迟预算分解

```
┌───────────────────────────────────────────────────────┐
│              E2E 目标 ≤ 8.45 s                        │
├───────────────┬───────────────────────────────────────┤
│   TTFT        │            Decode                     │
│   ≤ 1.7 s     │   1500 tokens × ≤ 4.5 ms = ≤ 6.75 s │
│   (20%)       │            (80%)                      │
├───────────────┼───────────────────────────────────────┤
│  40K prefill  │  EAGLE verify + accept (~2.5 tok/step)│
│  + EAGLE draft│  + KV write + ShadowRadix cache       │
└───────────────┴───────────────────────────────────────┘
```

### 12.11 关于 4.5ms TPOT 目标的风险评估

**这是一个极严格的要求。** 分析如下：

| 风险因素 | 影响 | 缓解措施 |
|---|---|---|
| EAGLE accept rate < 2.5 | 等效 TPOT 劣化 | 调优 num-steps / topk / draft-tokens |
| 40K KV cache 挤压 decode 带宽 | TPOT 升高 | V4-Flash 压缩注意力自带高压缩比，影响应有限 |
| tp=8 下 all-reduce 开销 | TPOT 升高 | NVLink 900GB/s × 8 应足够，但需验证 |
| Hierarchical multi-stream overlap 未生效 | 小 batch 优化缺失 | 确认 SGLang 版本 ≥ v0.5.12 |
| B200 FP4 kernel 不如 B300 优化 | B200 达不到 4.5ms | 有 B300 兜底 |
| Think token 生成模式不同于普通 decode | TPOT 不稳定 | 监控 P95 与 P50 的差异 |

**底线判断：**
- 在 **H200 tp=4** 上已有官方实测 3.76ms（✅ 达标）
- 在 **B300 tp=8** 上预期应更快（带宽更高），但 tp=8 通信未知 → 需验证
- **最安全的方案是照抄官方配置：H200 + tp=4 + EAGLE 3/1/4**
- 如果客户坚持用 B300：需要实测验证，目前无公开数据证明达标

### 12.12 Benchmark 结果矩阵（待填充）

以下矩阵设计用于对比各硬件/配置的性能与性价比，测试完成后填入实际数据：

#### 12.12.1 性能维度

| 硬件 | 拓扑 | tp | TPOT P50 | TPOT P95 | TTFT P50 | TTFT P95 | E2E P50 | 达标? |
|---|---|---|---|---|---|---|---|---|
| p5en (H200) | unified | 4 | _待测_ | _待测_ | _待测_ | _待测_ | _待测_ | - |
| p6-b300 (B300) | unified | 8 | _待测_ | _待测_ | _待测_ | _待测_ | _待测_ | - |
| p6-b300 (B300) | unified | 4 (dp=2) | _待测_ | _待测_ | _待测_ | _待测_ | _待测_ | - |
| p6-b200 (B200) | unified | 8 | _待测_ | _待测_ | _待测_ | _待测_ | _待测_ | - |
| Bedrock (GPT-5.6 Luna) | managed | N/A | _待测_ | _待测_ | _待测_ | _待测_ | _待测_ | - |

#### 12.12.2 性价比维度

| 硬件 | 实例价格 ($/hr) | Spot 价格 ($/hr) | 达标配置 | 单请求成本 | 性价比排名 | 备注 |
|---|---|---|---|---|---|---|
| p5en (H200) | ~$85-98 | _待查_ | tp=4 unified | _待算_ | - | Spot 可用性较好 |
| p6-b300 (B300) | $142.42 | _待查_ | tp=8 unified | _待算_ | - | Region 有限 |
| p6-b200 (B200) | $113.93 | _待查_ | tp=8 unified | _待算_ | - | 比 B300 省 20% |
| Bedrock GPT-5.6 Luna | 按 token 计费 | N/A | managed | _待算_ | - | 无基础设施运维 |

#### 12.12.3 竞品对标：Bedrock GPT-5.6 Luna

| 维度 | 自建 (SGLang + V4-Flash) | Bedrock GPT-5.6 Luna |
|---|---|---|
| TPOT | 目标 ≤ 4.5ms | _待测_ |
| TTFT | 目标 ≤ 1.7s | _待测_ |
| 部署复杂度 | 高（EKS + SGLang + 调优） | 低（API 调用） |
| 成本模型 | 固定实例费 | 按 token 计费 |
| 弹性 | 需自行管理 Spot/扩缩容 | 自动弹性 |
| 定制化 | 完全可控（投机解码、KV 策略等） | 受限于服务端配置 |
| 适用场景 | 高请求量、需极致延迟 | 低量、快速上线、成本敏感 |

> 💡 **决策框架**：若自建方案在 Spot 实例上的单请求成本低于 Bedrock 按 token 计费，且请求量足以摊平运维成本，则自建优；否则 Bedrock 是更务实的选择。

### 12.13 Spot 实例启动策略

为降低测试成本并快速获取 B300/H200 资源，推荐使用 Spot 实例：

#### B300 Spot 启动

```bash
# 方式 1：通过 EKS 节点组配置 Spot
# 在 eks-cluster.yaml 的 nodeGroup 中添加：
managedNodeGroups:
  - name: p6b300-spot
    instanceTypes:
      - p6-b300.48xlarge
    capacityType: SPOT
    desiredCapacity: 1
    minSize: 0
    maxSize: 2
    labels:
      gpu-type: b300
      capacity-type: spot

# 方式 2：直接通过 EC2 API 请求 Spot
aws ec2 run-instances \
  --instance-type p6-b300.48xlarge \
  --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time","MaxPrice":"80.00"}}' \
  --image-id ami-0xxxxxxxx \
  --key-name your-key \
  --security-group-ids sg-xxxxxxxx \
  --subnet-id subnet-xxxxxxxx \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":500,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=tpot-bench-b300-spot}]'

# 方式 3：使用 Fleet API 跨多个 AZ 寻找容量
aws ec2 create-fleet \
  --type instant \
  --launch-template-configs '[{
    "LaunchTemplateSpecification": {"LaunchTemplateId": "lt-xxx", "Version": "$Latest"},
    "Overrides": [
      {"InstanceType": "p6-b300.48xlarge", "AvailabilityZone": "us-east-1a"},
      {"InstanceType": "p6-b300.48xlarge", "AvailabilityZone": "us-east-1b"},
      {"InstanceType": "p6-b300.48xlarge", "AvailabilityZone": "us-west-2a"}
    ]
  }]' \
  --spot-options '{"AllocationStrategy": "lowest-price", "MinTargetCapacity": 1}' \
  --target-capacity-specification '{"TotalTargetCapacity": 1, "SpotTargetCapacity": 1, "DefaultTargetCapacityType": "spot"}'
```

#### H200 Spot 启动

```bash
# H200 (p5en) Spot 可用性通常优于 B300，推荐优先尝试
aws ec2 run-instances \
  --instance-type p5en.48xlarge \
  --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time","MaxPrice":"55.00"}}' \
  --image-id ami-0xxxxxxxx \
  --key-name your-key \
  --security-group-ids sg-xxxxxxxx \
  --subnet-id subnet-xxxxxxxx \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":500,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=tpot-bench-h200-spot}]'

# 查看当前 Spot 价格历史
aws ec2 describe-spot-price-history \
  --instance-types p6-b300.48xlarge p5en.48xlarge p6-b200.48xlarge \
  --product-descriptions "Linux/UNIX" \
  --start-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --query 'SpotPriceHistory[*].{Type:InstanceType,AZ:AvailabilityZone,Price:SpotPrice}' \
  --output table
```

#### Spot 中断处理

```bash
# 在实例上设置中断通知监听（2 分钟预警）
# 在 benchmark 脚本开头加入：
METADATA_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

check_spot_interruption() {
  STATUS=$(curl -s -H "X-aws-ec2-metadata-token: $METADATA_TOKEN" \
    http://169.254.169.254/latest/meta-data/spot/instance-action 2>/dev/null)
  if [ "$STATUS" != "404" ] && [ -n "$STATUS" ]; then
    echo "[WARN] Spot interruption notice received! Saving results..."
    # 保存当前已完成的 benchmark 结果
    cp /tmp/bench_results.json /mnt/s3-backup/
    exit 0
  fi
}

# 每 30 秒检查一次
while true; do check_spot_interruption; sleep 30; done &
```

#### Spot 成本估算

| 实例类型 | On-Demand ($/hr) | Spot 实价 ($/hr) | 节省比例 | 最优 Region/AZ |
|---|---|---|---|---|
| p6-b300.48xlarge | $142.42 | $44.59 – $51.55 | **64–69%** | us-east-1a ($44.59) |
| p6-b200.48xlarge | $113.93 | $40.94 – $42.47 | **63–64%** | us-west-2d ($40.94) |
| p5en.48xlarge | ~$85–98 | $26.69 – $27.24 | **69–72%** | us-east-2a ($26.69) |

> 以上 Spot 实价数据查询于 2026-08-07。Spot 价格实时变动，建议设置 MaxPrice 为 On-Demand 的 55-60%，在拿到实例和节省成本之间取平衡。
>
> **详细 Spot 价格分布：**
> - p6-b300.48xlarge: us-west-2a $51.55, us-west-2b $49.38, us-east-1a $44.59
> - p6-b200.48xlarge: us-west-2a $42.47, us-west-2b $41.73, us-west-2d $40.94, us-east-2a $42.30, us-east-1a $42.23
> - p5en.48xlarge: us-west-2a $27.23, us-west-2d $27.18, us-west-2c $27.24, us-east-2a $26.69, us-east-1a $26.95

