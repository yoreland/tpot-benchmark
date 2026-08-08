# 事后复盘：2026-08-07 p5en.48xlarge 裸 EC2 运行烧掉约 $353，零产出

一句话结论：**30.4 TB 的本地 NVMe 一块都没挂，148.6 GiB 的权重被写进一块 200 GB
的根盘，而且整条流水线活在一个会话里，会话一挂就什么都拿不回来。**

这份文档的唯一目的是让下一个会话不要重演。所有数字都来自 EC2 / CloudWatch /
CloudTrail 的实际查询，推断的地方会明确写「推断」。

---

## 1. 事实

| 项目 | 值 |
| --- | --- |
| 实例 ID | `i-0459cbc565ec484f6` |
| 类型 | `p5en.48xlarge`（192 vCPU / 2048 GiB / 8 x H200 144 GB） |
| 可用区 | `us-east-2a` |
| 计费方式 | Spot，约 $26.67/hr |
| AMI | `ami-0b80a5f61a0bca5dd`（Deep Learning Base OSS Nvidia Driver GPU AMI, Ubuntu 22.04, 20260804） |
| 存活时间 | 2026-08-07T15:09:55Z -> 2026-08-08T04:24:16Z = **13 小时 14 分** |
| 花费 | 13h14m x $26.67/hr = **约 $353** |
| 终止方式 | 与启动同一个 Kiro role，reason `Client.UserInitiatedShutdown` |
| 产出 | **零**。没有一条测量数据 |

## 2. 遥测（CloudWatch）

| 指标 | 观测 | 说明 |
| --- | --- | --- |
| NetworkIn | 合计 **315.32 GB**，其中两次约 151 GB 的尖峰（08-07 15:15 与 08-08 00:25） | 同一份 checkpoint 下载了两遍 |
| EBSWriteBytes | 第一次尝试 **121 GB**，第二次只有 **19.21 GB**，而同期下载了 150.98 GB | 写不进去了 —— 磁盘满的典型签名 |
| CPUUtilization | 峰值只有 **8.34%**（192 vCPU），在 15:55、00:50-00:55、01:35-01:40、02:00-02:20 掉到 **0.08%** | 大部分时间机器在发呆 |
| 磁盘写入 | 多数小时只写约 **10 MB** | 同上 |
| GPU 指标 | **完全没有** | 没装 CloudWatch agent，没有 DCGM，也没有能 PutMetricData 的 IAM 角色 |

> **诚实的边界**：因为一条 GPU 指标都没有，「GPU 全程闲置」是从 CPU / 磁盘 /
> 网络三条曲线推断出来的**强推断，不是证据**。真正能证明这件事的东西
> （`nvidia-smi` 采样、DCGM、CloudWatch 自定义指标）当时一个都不存在。这本身
> 就是需要修的问题之一。

## 3. 根因

### 3.1 主因：本地实例存储一块都没挂（磁盘满）

`describe-instance-types` 确认 `p5en.48xlarge` 自带 **8 x 3800 GB = 30400 GB**
本地 NVMe（`NvmeSupport=required`）。这次启动**一块都没挂**，全部东西挤在
一块 200 GB 的 gp3 根盘上：

```
200 GB 根盘
  - 操作系统与 DLAMI 自带内容
  - SGLang 容器镜像 约 12.75 GB
  = 大约还剩 175 GB 可用
需要放:
  checkpoint 148.6 GiB (= 159.6 GB) + HF 缓存中间态 + tmp
```

于是第二次尝试出现了「下载了 150.98 GB，却只写进 19.21 GB」这种签名。

讽刺的是 README 第 9.1 节早就写了
「所有 manifest 需按环境修改，否则权重会写到小根盘」——
这次启动完全绕过了 manifest，也就绕过了那条警告。

### 3.2 次因（已确认）：instruct checkpoint 是 FP4 专家权重，而 H200 没有原生 FP4

规划阶段用 HuggingFace API 与 SGLang cookbook 双向确认：

- `deepseek-ai/DeepSeek-V4-Flash`：73 个文件 / 159630041626 字节 = 159.6 GB /
  148.7 GiB，`config.json` 里 `expert_dtype=fp4`，
  `quantization_config.quant_method=fp8` —— 即 **FP4 MoE 专家 + FP8 注意力/dense**。
  这正好对上观测到的约 151 GB 下载量。
- H200 是 Hopper SM90，**没有原生 FP4**。cookbook 的 Hopper 注记给了且只给了
  两条路：
  1. 直接用原始 FP4 权重，走 **W4A16 Marlin** MoE kernel —— 纯 TP，
     用不了 DP-attention / DeepEP；
  2. 换 **`sgl-project/DeepSeek-V4-Flash-FP8`** 重打包权重（55 个文件 /
     294.1 GB / 273.9 GiB）—— 解锁 DP-attention + DeepEP。
- 第 2 条**物理上装不进 200 GB 根盘**；第 1 条勉强能装，而「勉强能装」就是
  上面那个磁盘满签名的来源。
- `deepseek-ai/DeepSeek-V4-Flash-Base` 确实是纯 FP8（`expert_dtype=fp8`），
  但 cookbook 明确写了 `*-Base` 仓库**只用于继续预训练，不可用于 chat 或
  tool calling**，所以它不是合法替代。

### 3.3 为什么完全不可恢复

| 缺失的东西 | 后果 |
| --- | --- |
| 没有 user-data | 流水线只存在于交互会话里，会话卡住就没有任何东西在推进 |
| 没有 IAM 实例配置文件 | 进不去 SSM（没有 SSM 就没有第二条进机器的路） |
| key pair `tpot-bench-key` 的私钥只存在于那个已死的会话里 | SSH 也进不去 |
| 根盘 `DeleteOnTermination=true` | 实例一终止，盘和盘上的一切一起消失 |
| 没有任何 off-box 持久化 | CloudTrail 里**没有一次 S3 PutObject** |
| 没有快照 / AMI | 自有快照与自有 AMI 数量都是 **0** |
| 没有自终止与运行上限 | 13h14m 一直计费，直到有人手工点终止 |

留下的痕迹：`results/` 是空的，`4138e92` 之后没有任何提交。也就是说，
**$353 换回来的信息量等于零。**

## 4. 每一条失败，对应哪一条修复

| 失败 | 修复 | 落在哪 |
| --- | --- | --- |
| 30.4 TB 本地 NVMe 没挂 | 用 `lsblk`/`nvme list` 按 model 识别实例存储盘（显式排除 EBS 根盘），多盘组 RAID0、单盘直接用，挂到 `/mnt/nvme` | `scripts/bootstrap/bench-bootstrap.sh` Step b) |
| 权重写进小根盘 | `HF_HOME` / `HF_HUB_CACHE` / `TMPDIR` / Docker data-root 全部指向 `/mnt/nvme`（data-root 迁移在 `docker pull` 之前做，约 13 GB 镜像也不落根盘） | 同上 Step b) |
| 磁盘满才发现 | **下载前**就断言可用空间 >= `CHECKPOINT_GB + STORAGE_MARGIN_GB`，不够立刻失败，一个字节都不下 | 同上 `assert_free_space` |
| checkpoint 下了两遍（315 GB） | 可续传下载 + S3 同 Region 权重镜像（`CHECKPOINT_S3_URI`） | `scripts/mirror-checkpoint.sh` |
| FP4-on-Hopper 精度陷阱 | 预检直接查 `expert_dtype` 并给出两条 Hopper 路线的告警；三个可换的 recipe 各自写清代价 | `scripts/preflight.sh` Check 6、`scripts/recipes/` |
| 没有 user-data，流水线依赖会话 | 全自驱动引导脚本作为 user-data 投递（超 16 KB 时自动改 S3 托管 + 小 stub） | `scripts/launch-bench-ec2.sh` |
| 进不去机器 | IAM 实例配置文件 + `AmazonSSMManagedInstanceCore`，`aws ssm start-session` 即可进；安全组入站为空，不需要 SSH | `scripts/setup-infra.sh`、launcher |
| 私钥随会话消失 | 删掉不可用的 key pair，整条路径不依赖 SSH 私钥 | `scripts/setup-infra.sh` |
| 没有 off-box 持久化 | 每 30 秒把日志与结果 `aws s3 sync` 到 `s3://<桶>/runs/<RUN_ID>/`，失败路径也会单独 `s3 cp` 兜底 | bootstrap Step c) |
| 观测不到进度 | `status.json` 记录 phase，CloudWatch `TpotBench` 命名空间发心跳与 phase 码 | bootstrap Step a)/c) |
| 一条 GPU 指标都没有 | `nvidia-smi` 采样落 `gpu.csv` 并发 CloudWatch；没有 GPU 时优雅跳过 | bootstrap Step d) |
| Spot 回收无处理 | IMDSv2 轮询 `spot/instance-action`，收到就最后同步一次并标记 `spot_interrupted` | bootstrap Step g) |
| 13h14m 无上限 | 两条独立的终止触发：正常完成自终止 + `MAX_RUNTIME_MINUTES`（默认 240）墙上时钟看门狗 | bootstrap Step h) |
| 事前不知道会失败 | 8 项零花费预检（配额 / 本地盘 / Spot 价 / AMI / checkpoint 体积与精度 / 子网安全组 / `run-instances --dry-run`） | `scripts/preflight.sh` |
| 一上手就是 $26.67/hr | 四级台阶：preflight($0) -> plumbing(约 $0.01) -> gpu-smoke(约 $1.2/hr) -> full | `scripts/run-staged.sh` |
| 迭代状态只活在会话里 | 阶段台账 `results/stage-ledger.json` + S3 里的每次运行产物 | `scripts/run-staged.sh` |
| 结果拿不回来 | 从 S3 收集并转成 `compare-results.sh` 认的 schema | `scripts/collect-results.sh` |
| 无意中启动 | 每一级都要显式 `CONFIRM_SPEND=yes`，默认是拒绝 | launcher 与 run-staged |

## 5. 下一次动手前的三条硬规矩

1. **先 `bash scripts/run-staged.sh`**（零花费预检），8 项全 PASS 再谈启动。
2. **按台阶来**：plumbing -> gpu-smoke -> full。前一级没 PASS 就不要跳，跳一级
   省下的几分钱远不如 H200 上白烧的一小时。
3. **永远不要为了「等下再看」把实例留着**。要调试就用
   `aws ssm start-session`，看完让看门狗按时把它收走。上一次的账单就是
   「留着待会儿看」的价格。

操作手册见 [RUNBOOK.md](RUNBOOK.md)。
