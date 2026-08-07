# DeepSeek-V4-Flash 推理选型测试方案

> 场景：to-C Trip Planner ｜ 目标：时延敏感、低并发 ｜ 平台：AWS EKS + SGLang

---

## 1. 结论摘要（TL;DR）

| 项 | 结论 |
|---|---|
| **核心指标** | **TPOT**（不是 TTFT）—— 占端到端延迟 ~99% |
| **首选优化** | **MTP 投机解码** —— 唯一能显著降 TPOT 的手段，低并发是其最佳工况 |
| **推荐拓扑** | 副本制（`8× tp=1` 或 `4× tp=2`）+ cache-aware router |
| **不推荐拓扑** | **3P1D PD 分离** —— 6 卡给 prefill、2 卡给 decode，与 decode 密集负载正好相反 |
| **头号待测硬件** | **p6-b200**（B200）—— 带宽仅比 B300 低 4%，整机便宜 20% |
| **最大不确定项** | 客户真实输出长度 & 是否流式输出（整个分析依赖此假设） |

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

### 2.3 关键洞察：负载是 decode 密集型

一份行程规划输出长文本（多天行程、活动、餐厅、交通），保守估计 **1000–3000 output tokens**。端到端延迟拆解：

| 组成 | 典型值 | 占 E2E |
|---|---|---|
| TTFT | ~400 ms | **1%** |
| Decode（2000 tokens × 20 ms TPOT） | **~40 s** | **99%** |
| **E2E** | **~40.4 s** | 100% |

**优化收益对比：**

| 优化方向 | 幅度 | 实际节省 |
|---|---|---|
| TTFT 400ms → 100ms | 4× | **0.3 s**（无感） |
| TPOT 20ms → 13ms | 1.5× | **14 s**（决定性） |

**→ 这是"不推荐 3P1D"的根本原因**：3P1D 把 6 张卡分配给 prefill、仅 2 张给 decode。对一个 decode 占 99% 延迟的负载，算力堆在了不影响体验的环节，真正的瓶颈只有 1/4 资源。

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
- 无原生 FP4，需跑 FP8 checkpoint（284 GB，每 token 读双倍字节）→ 再 **~2×**
- 141 GB 单卡装不下 FP8 的 284 GB → 至少 tp=4，通信开销再叠加

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

### 6.1 基准命令

```bash
python3 -m sglang.bench_serving --backend sglang \
  --dataset-name random \
  --random-input 8000 --random-output 2000 \   # 按 trip planner 特征：中等输入、长输出
  --num-prompts 100 \
  --max-concurrency 4                          # 低并发档
```

> ⚠️ `--random-output 2000` **必须按客户真实输出长度调整** —— 整个分析都依赖此数字。

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
| **NVMe 路径差异** | HyperPod = `/opt/dlami/nvme/`，自建 EKS(RAID0) = `/mnt/k8s-disks/0/`。所有 manifest 需按环境修改，否则权重会写到小根盘 |
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
