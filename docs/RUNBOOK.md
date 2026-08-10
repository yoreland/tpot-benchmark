# 操作手册：裸 EC2 上跑 DeepSeek-V4-Flash benchmark

这份手册是给「无法全程盯着」的场景写的：每一条命令都可以直接复制粘贴，每一级
台阶都写清了会花多少钱，任何一级失败之后，下一步该改什么、状态在哪查，都在这里。

前置阅读：为什么要这么麻烦，见
[postmortem-2026-08-07-p5en-run.md](postmortem-2026-08-07-p5en-run.md)
（上一次 13h14m / 约 $353 / 零产出）。

- Region：`us-east-2`，AZ：`us-east-2a`
- 结果桶：`s3://tpot-bench-results-077090643075-us-east-2`
- 实例配置文件：`tpot-bench-ec2-profile`（SSM + 写 S3 + PutMetricData + 带
  `Project=tpot-benchmark` 条件的自终止）
- **沙箱/本机的 `AWS_REGION` 可能不是 us-east-2，所有命令都显式带 `--region us-east-2`。**

---

## 0. 花费闸门：`CONFIRM_SPEND=yes`

`scripts/run-staged.sh`、`scripts/launch-bench-ec2.sh`、
`scripts/mirror-checkpoint.sh --upload` 三处默认**拒绝**动作，必须在命令前面显式
写 `CONFIRM_SPEND=yes`：

```bash
CONFIRM_SPEND=yes bash scripts/run-staged.sh --stage plumbing
```

- 没有它：脚本打印花费画像，然后以**退出码 2** 拒绝，什么都不会启动。
- 退出码约定：`0` = 成功（或 dry-run 通过），`2` = 因为没授权而拒绝，
  `3` = 有一次跑成功的运行还没写总结（见 1.1），`1` = 真的出错了。
- 它只影响当前这一条命令，不要 `export`。

零花费预演（任何 stage 都能这么先跑一遍）：

```bash
bash scripts/run-staged.sh --stage full --dry-run
```

---

## 1. 四级台阶（按顺序做，不要跳级）

| 台阶 | 实例 | 上限 | 现价(us-east-2a) | 这一级最坏花费 | 验证了什么 |
| --- | --- | --- | --- | --- | --- |
| 1 preflight | 无 | - | - | **$0** | 配额 / 本地盘 / Spot 价 / AMI / checkpoint 体积与精度 / 子网安全组 / `run-instances --dry-run` |
| 2 plumbing | `c5d.large` | 20 分钟 | $0.0295/hr | **约 $0.01** | 真机上的实例存储挂载、S3 流式回传、CloudWatch 心跳、Spot 中断轮询、墙上时钟看门狗、自终止 |
| 3 gpu-smoke | `g6e.xlarge` | 60 分钟 | $1.20/hr | **约 $1.21** | `docker --gpus all`、NVIDIA runtime、`nvidia-smi` 遥测、SGLang 起服务、一次短 bench_serving |
| 4 full | `p5en.48xlarge` | 240 分钟 | $26.6617/hr | **约 $106.65** | 按 recipe 跑 README 6.1 的两条完整 bench_serving |

### 1.1 ⛔ 停一下：跑成功一次就先做总结

**这条规则来自操作者的明确要求**：「如果在 h200 / b300 一旦跑成功过一次，记得停
一下，做一下总结。」它不是靠记性，是机械执行的：

- **成功的判据**：launcher 退出码 0 **并且** `logs/status.json` 的 phase 到了
  `completed`。两个条件缺一个都算「还没成功」——退出码只说明实例申请下来了 /
  观察循环结束了，不说明机器里那一轮 benchmark 跑完了。phase 问不出来时脚本
  会明说「按还没成功处理」，不会自己宣布成功。
- **成功之后**：`run-staged.sh` 打印停顿通知，**不再打印任何启动命令**，只给
  收结果与写总结这两条。
- **在总结落地之前**：再跑 `gpu-smoke` 或 `full` 会被拒绝，**退出码 3**。
- **闸门顺序**：总结闸门排在 `CONFIRM_SPEND` 闸门**之前**。所以
  `CONFIRM_SPEND=yes` 绕不过去 —— 否则一个无人值守的会话只要照常带着授权就能
  接着按 $26.67/hr 烧下去，而唯一值得报告的那次结果还躺在 S3 里没人看。
- `--dry-run` 是零花费的，只警告不拦。

清掉闸门就两条命令（都零花费）：

```bash
RUN_ID=<那次成功的 RUN_ID>
bash scripts/collect-results.sh --run-id "$RUN_ID" --region us-east-2
bash scripts/summarize-run.sh   --run-id "$RUN_ID" --region us-east-2
```

`summarize-run.sh` 写出 `docs/run-summaries/<RUN_ID>-summary.md`（配置、两条 bench
对 README 12.1 目标的实测值、与 README 12.2 的 ~266 tok/s / ~3.76 ms 基线对比、
`accept_length` 对 A7 的 2.0 门槛、每张卡的 GPU 利用率与显存、花费、A1-A9 逐条
判定、以及「这一次没有建立什么结论」），并把台账里那条记录的 `summary_done`
置为 `true` —— 闸门随之放行。它**不会自动改 README.md**：12.12 那两张矩阵是要人
过目的交付物，脚本只把该填的两行打印出来。

真要在没有总结的情况下继续（应当是少数情况，输出与台账都会留痕）：

```bash
CONFIRM_SPEND=yes bash scripts/run-staged.sh --stage full --ack-summary \
    --recipe scripts/recipes/h200-tp4-dspark-0731.env
```

退出码约定：`0` 成功 / `1` 出错 / `2` 缺 `CONFIRM_SPEND=yes` / **`3` 有成功运行未总结**。

算术摊开写：

- plumbing：`$0.0295/hr x 20/60 = $0.0098`，再加 80 GB gp3 跑 20 分钟
  （`80 GB x $0.08/GB-月 / 730 hr x 0.33 hr ≈ $0.003`）—— 合计不到两分钱。
- gpu-smoke：`$1.20/hr x 60/60 = $1.20`。实际冒烟通常 15 分钟左右结束，约 $0.30。
  （注意：规划文档里曾写「well under a dollar per hour」，实测 us-east-2a 的
  g6e.xlarge Spot 现价是 **$1.20/hr**，比那个说法贵，这里按实测写。）
- full：`$26.6617/hr x 240/60 = $106.65`。**上一次没有任何上限，跑了 13h14m
  = 约 $353。** 240 分钟的硬上限就是为这件事加的。
- 每一级的实价都由脚本在启动前重新查一次 `describe-spot-price-history`，
  上面这些是本手册写作时的实测值，不是写死在脚本里的假设。

### 台阶 1：预检（零花费）

```bash
bash scripts/run-staged.sh                 # 不带参数 = 只做 preflight
```

8 项全 PASS 才继续。任何一项 FAIL 就先修那一项，退出码非零。

### 台阶 2：管路（约 $0.01）

```bash
CONFIRM_SPEND=yes bash scripts/run-staged.sh --stage plumbing
```

这一级不下载权重、不起服务（`FETCH_CHECKPOINT=false`、`RUN_SERVER=false`），
只在真实 EC2 上把「盘 -> S3 -> 心跳 -> 看门狗 -> 自终止」这条链走通。
20 分钟到点它自己会消失。

### 台阶 3：GPU 冒烟（约 $0.3 - $1.2）

```bash
CONFIRM_SPEND=yes bash scripts/run-staged.sh --stage gpu-smoke
```

用 L40S（SM 89）而不是更便宜的 T4，理由写在 README 9.1：SGLang v0.5.12 的
flashinfer 在 SM 7.5（Turing/T4）上直接 `KeyError 'sm_75'`，用 T4 冒烟等于
在验证一条注定失败的路径。默认模型是小模型 `Qwen/Qwen2.5-0.5B-Instruct`，
只为验证「容器能看到 GPU、服务能起来、bench 能跑」。

想顺便验证 recipe 里的启动 CLI（比如把 `SGLANG_LAUNCH_CMD` 换成
`sglang serve`），就在这一级带上 recipe：

```bash
CONFIRM_SPEND=yes bash scripts/run-staged.sh --stage gpu-smoke \
    --recipe scripts/recipes/h200-tp4-fp4-eagle.env
```

注意 recipe 会同时覆盖模型与 TP，L40S 装不下 DeepSeek-V4-Flash，所以真要这么做
就在命令行上再压回小模型：先复制一份 recipe，只保留 `SGLANG_LAUNCH_CMD` 那一行。

### 台阶 4：完整 H200 运行（约 $106.65 上限）

```bash
CONFIRM_SPEND=yes bash scripts/run-staged.sh --stage full \
    --recipe scripts/recipes/h200-tp4-fp4-eagle.env --wait
```

`--wait` 会不停打印实例状态、CloudWatch 心跳数据点、`status.json` 的 phase，
并增量 tail 已经流到 S3 的 `bootstrap.log`。它是**观察者**，断掉不影响实例：
实例会自己跑完、自己上传、自己终止。

---

## 2. 没有 SSH 的情况下怎么看一次运行

`RUN_ID` 由 launcher 启动时打印，形如 `20260807-150955-a1b2`；也可以从
`results/stage-ledger.json` 里翻。

```bash
RUN_ID=20260807-150955-a1b2
BUCKET=tpot-bench-results-077090643075-us-east-2

# a) 卡在哪个 phase（最有用的一条）
aws s3 cp "s3://$BUCKET/runs/$RUN_ID/logs/status.json" - --region us-east-2

# b) 完整引导日志（每 30 秒刷新一次）
aws s3 cp "s3://$BUCKET/runs/$RUN_ID/logs/bootstrap.log" - --region us-east-2 | tail -100

# c) SGLang 服务端日志（启动崩溃只能在这里看）
aws s3 cp "s3://$BUCKET/runs/$RUN_ID/logs/sglang-server.log" - --region us-east-2 | tail -200

# d) 已经产出哪些结果
aws s3 ls "s3://$BUCKET/runs/$RUN_ID/results/" --region us-east-2

# e) GPU 遥测（上一次一条都没有，这次有了）
aws s3 cp "s3://$BUCKET/runs/$RUN_ID/logs/gpu.csv" - --region us-east-2 | tail -20

# f) CloudWatch 心跳：有数据点就说明机器还活着并在推进
aws cloudwatch get-metric-statistics --region us-east-2 \
    --namespace TpotBench --metric-name Heartbeat \
    --dimensions Name=RunId,Value=$RUN_ID Name=Stage,Value=full \
    --start-time "$(date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ')" \
    --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --period 60 --statistics Sum

# g) 真要进机器（不需要 SSH，也不需要私钥）
aws ssm start-session --target <instance-id> --region us-east-2
```

`status.json` 的 `phase` 取值按顺序是：
`starting` -> `storage` -> `storage_guard` -> `streaming` -> `telemetry` ->
`fetching_model` -> `starting_server` -> `server_ready` -> `benchmarking` ->
`finalizing` -> `completed`；
终态错误是 `failed` / `spot_interrupted` / `deadline_exceeded`。
**卡在哪个 phase，就直接告诉你该看哪一段日志。**

---

## 3. 收结果

```bash
bash scripts/collect-results.sh --run-id "$RUN_ID" --region us-east-2
bash scripts/compare-results.sh
bash scripts/summarize-run.sh   --run-id "$RUN_ID" --region us-east-2   # 见 1.1，跑成功后必做
```

`collect-results.sh` 把 S3 上的原始产物转成 `compare-results.sh` 认的 schema，
写到 `results/<类型>_tp<N>_<时间戳>.json` 和同名 `_summary.txt`。
两个 benchmark 都达标时退出 0，否则退出 1（数值照样落盘）。

离线验证这条链（零花费，不碰 AWS）：

```bash
bash scripts/collect-results.sh --fixture tests/fixtures --out /tmp/rtest
bash scripts/compare-results.sh /tmp/rtest
bash scripts/summarize-run.sh   --fixture tests/fixtures --out /tmp/sumtest
```

`summarize-run.sh` 不另写一套 bench 输出解析：它调用 `collect-results.sh` 做
JSONL 与键名归一化，两个脚本永远同一套逻辑。必需的测量值（TPOT / TTFT / E2E /
吞吐）一个都取不到时它**报错退出、不产出总结**，绝不给你一份填着占位符的文档。

---

## 4. 权重镜像：让重试不再重下 159.6 GB

上一次的 NetworkIn 是 315.32 GB —— 同一份权重下了两遍。镜像就是修这件事的。

```bash
# a) 先看体积与月租（零花费、零变更）
bash scripts/mirror-checkpoint.sh --model deepseek-ai/DeepSeek-V4-Flash
```

实测报告：

| 权重 | 文件数 | 体积 | S3 Standard 月租 | 一次性 PUT |
| --- | --- | --- | --- | --- |
| `deepseek-ai/DeepSeek-V4-Flash` | 73 | 159.6 GB / 148.7 GiB | 约 **$3.42/月** | 约 $0.10 |
| `deepseek-ai/DeepSeek-V4-Flash-0731` | 74 | 166.9 GB / 155.4 GiB | 约 **$3.57/月** | 约 $0.10 |
| `sgl-project/DeepSeek-V4-Flash-FP8` | 55 | 294.1 GB / 273.9 GiB | 约 **$6.30/月** | 约 $0.18 |

入站流量免费，同 Region 下载到 EC2 也不收流量费，所以账单就是这份月租。

**最省钱的填充方式是在一次 full 运行的实例上做**，因为那台机器本来就已经把权重
放在本地 NVMe 上了，上传只是同 Region 内网流量；从沙箱做等于先下 159.6 GB
再上 159.6 GB，纯浪费：

```bash
# b) 在 benchmark 实例上（aws ssm start-session 进去）
CONFIRM_SPEND=yes bash scripts/mirror-checkpoint.sh \
    --model deepseek-ai/DeepSeek-V4-Flash \
    --from /mnt/nvme/models/deepseek-ai__DeepSeek-V4-Flash --upload

# c) 事后核对完整性（比对象数与总字节 vs HuggingFace 清单，只读）
bash scripts/mirror-checkpoint.sh --model deepseek-ai/DeepSeek-V4-Flash --verify

# d) 不需要了就删，别让它一直收月租
aws s3 rm s3://tpot-bench-results-077090643075-us-east-2/checkpoints/deepseek-ai__DeepSeek-V4-Flash/ \
    --recursive --region us-east-2
```

镜像建好后，在 recipe 里打开对应的那一行即可启用（每个 recipe 末尾都有一行
注释掉的 `CHECKPOINT_S3_URI`）：

```bash
export CHECKPOINT_S3_URI='s3://tpot-bench-results-077090643075-us-east-2/checkpoints/deepseek-ai__DeepSeek-V4-Flash/'
```

设了它，引导脚本就走 `aws s3 sync` 落到 `/mnt/nvme/models/<slug>`，
完全不访问 HuggingFace。**一次失败的重试从「重下 159.6 GB」变成「同 Region 同步」。**

耗时是估算而不是实测（本任务没有启动任何实例）：同 Region S3 -> EC2 用
`aws s3 sync` 常见能到 1-2 GB/s，159.6 GB 大约 **2-3 分钟**；从 HuggingFace 拉
同样的量在上一次的观测里是以**十几分钟到几十分钟**计的。第一次真跑请把实测值
记回这张表。

---

## 5. recipe 迭代循环（失败之后改什么）

三个 recipe 在 `scripts/recipes/`，每个文件头部都写了上游依据和 checkpoint 的
精确字节数。**换 recipe 只改一个 `--recipe` 参数，不需要改任何脚本。**

> ⛔ **这个循环不是一口气跑完的。** 任何一发只要跑成功（退出码 0 且
> phase=`completed`），循环就在那里停住：先按 1.1 收结果、写总结，再决定要不要
>试下一个 recipe。没写总结就往下跑会被总结闸门以退出码 3 拒绝。
> 换 recipe 的前提是**上一发失败了**，而不是「反正还有两个没试」。

**失败之后的推荐顺序：A -> C -> B。理由：**

1. **A `h200-tp4-fp4-eagle.env`（先跑这个）** —— 官方 instruct 权重、体积最小
   （159.6 GB）、cookbook 明确写了 Hopper 可跑的 W4A16 Marlin 路径、EAGLE 是
   README 12.3 标记为「已验证」那条配置的算法。它同时是**下载最少、失败面最小、
   与验收目标最接近**的一个，所以第一发必须是它。
2. **C `h200-tp4-dspark-0731.env`（第二发）** —— 相对 A 只换了一个变量：推测
   解码从 EAGLE 换成 DSpark（cookbook 说 0731 权重在 **4xH200 上已验证**）。
   A 如果是「服务起不来」，DSpark 是一条完全不同的 draft 路径，值得试；
   A 如果是「起来了但 TPOT 不达标」，DSpark 也是首选下一发。权重只多 7 GB。
3. **B `h200-tp4-fp8-eagle.env`（最后）** —— 换的是权重本身（294.1 GB，几乎
   翻倍，下载和镜像都更贵），换来 FP4 路径拿不到的 DP-attention。**只有在
   A 和 C 都因为 MoE kernel / 精度相关原因失败时才值得付这个代价。**

```bash
# 第一发
CONFIRM_SPEND=yes bash scripts/run-staged.sh --stage full \
    --recipe scripts/recipes/h200-tp4-fp4-eagle.env --wait

# 成功 -> 到此为止，先做总结（1.1），后面两条这时候不要跑
bash scripts/collect-results.sh --run-id "$RUN_ID" --region us-east-2
bash scripts/summarize-run.sh   --run-id "$RUN_ID" --region us-east-2

# 只有在第一发失败时：先看死在哪个 phase，再换第二发
CONFIRM_SPEND=yes bash scripts/run-staged.sh --stage full \
    --recipe scripts/recipes/h200-tp4-dspark-0731.env --wait

# 只有在前两发都因为 MoE kernel / 精度问题失败时，才上第三发
CONFIRM_SPEND=yes bash scripts/run-staged.sh --stage full \
    --recipe scripts/recipes/h200-tp4-fp8-eagle.env --wait
```

每一次尝试都会追加一条记录到 `results/stage-ledger.json`（gitignored）。随时查：

```bash
bash scripts/run-staged.sh --show-ledger
```

台账里有 stage、RUN_ID、实例类型、实例 ID、起止时间、退出码、S3 前缀、用的哪个
recipe，以及 FEAT-004 加的 `gpu_family` / `gpu_success` / `final_phase` /
`summary_required` / `summary_done` / `summary_path` / `spot_price_usd_per_hour`
（schema `tpot-bench-stage-ledger/2`，老的 `/1` 记录照样读得动）。
`--show-ledger` 的「总结」列显示 `待写` / `已写`，末尾还会把等着总结的 RUN_ID
单独再喊一遍。**迭代状态活在文件和 S3 里，不活在某个会话里** —— 上一次就是因为
状态只在会话里，会话一死就什么都不剩。

不带 `--wait` 启动时，脚本退出那一刻 `status.json` 往往还没上传，台账里那条记录
的 phase 因此是空的。下一次执行 `run-staged.sh` 时，总结闸门会用只读的
`aws s3 cp` 把这些记录的 phase 补成真值再判断（想完全离线就设 `LEDGER_REFRESH=false`）。
所以「不带 --wait 起完就跑下一个 recipe」这条路也照样会被拦住。

想自己造第四个 recipe：复制一份改 `SGLANG_EXTRA_ARGS`，同时把 `CHECKPOINT_GB`
改成新权重的实际体积（`bash scripts/mirror-checkpoint.sh --model <repo>` 会打印
精确字节数），否则磁盘护栏挡的就是错的数。

### 5.1 顺带跑并发扫描（`SWEEP_SPEC`）

`SWEEP_SPEC` 留空时行为与以前完全一致（只跑 README 6.1 的两条 bench）。
填上之后，会在**同一个 server 进程**上、两条基线 bench 之后按档位追加扫描——
同进程是刻意的：B300 报告的 40K/30K 与扫描来自两个不同版本的 server，
导致两组数字无法相互印证，别再重复那个错误。

```bash
# 现成的 H200 并发扫描 recipe（镜像钉 v0.5.17，8 档，80 分钟硬上限）
CONFIRM_SPEND=yes bash scripts/launch-bench-ec2.sh --stage full \
    --region us-east-2 --az us-east-2a --instance-type p5en.48xlarge \
    --max-runtime-minutes 80 \
    --recipe scripts/recipes/h200-tp4-fp4-eagle-sweep.env \
    --bucket tpot-bench-results-077090643075-us-east-2
```

| 变量 | 默认 | 含义 |
|------|------|------|
| `SWEEP_SPEC` | 空（不跑） | 空格分隔的 `并发[:prompts]`，如 `1 2 4 8 16 32 32:128` |
| `SWEEP_INPUT_TOKENS` | 8000 | 扫描负载输入长度（B300 报告的口径，换了就没法对比） |
| `SWEEP_OUTPUT_TOKENS` | 1500 | 扫描负载输出长度 |
| `SWEEP_NUM_PROMPTS` | 32 | 不带 `:prompts` 的档位用这个样本量 |

输出命名规则：用默认样本量的档位落 `bench_c<N>.json`（与 B300 报告同名，便于对照），
覆盖了样本量的落 `bench_c<N>_p<P>.json`。每档跑完**立刻单独** sync 一次 S3，
不攒批——spot 随时可能被回收，已完成的档位不能丢。单档失败只记账不中断后续档位
（高并发档 OOM 是预期可能结果，不该让排好队的其他档位一起报废）。
逐档记账写在 `run_<RUN_ID>.json` 的 `concurrency_sweep.levels` 里。

⚠️ 两个坑：
1. **`--max-runtime-minutes` 要显式传。** recipe 里的 `MAX_RUNTIME_MINUTES` 只覆盖
   实例内的看门狗，launcher 自己的花费预估仍用 stage 默认值（full = 240 分钟），
   不传的话你看到的「最坏花费」是虚高的。
2. **样本量别照抄 32。** 32 条 prompts 在 c=32 时一波就发完，根本没进稳态：
   实测 H200 c=32 从 32 条加到 128 条，TPOT P50 涨 65%、E2E P50 涨 60%
   （详见 H200 报告 5.4）。要拿去签 SLA 的数字必须用大样本量那一档。

---

## 6. 放弃一次运行时怎么收摊

正常情况下**不需要做任何事**：完成会自终止，`MAX_RUNTIME_MINUTES` 到点也会
自终止，Spot 回收也会先把日志同步完再退出。下面是兜底手段：

```bash
# a) 还有什么在跑？（这条应该永远返回空）
aws ec2 describe-instances --region us-east-2 \
    --filters Name=instance-state-name,Values=pending,running \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime]' --output table

# b) 立刻停掉
aws ec2 terminate-instances --region us-east-2 --instance-ids <instance-id>

# c) 还有没有挂着的 Spot 请求
aws ec2 describe-spot-instance-requests --region us-east-2 \
    --query 'SpotInstanceRequests[?State==`open` || State==`active`].[SpotInstanceRequestId,State]' \
    --output table

# d) 产物不会随实例消失，S3 上都在
aws s3 ls "s3://$BUCKET/runs/" --region us-east-2

# e) 长期成本只剩权重镜像的月租，删掉即可清零
aws s3 ls "s3://$BUCKET/checkpoints/" --region us-east-2
```

---

## 7. 故障速查表

| 现象 | `status.json` 的 phase | 大概率原因 | 怎么办 |
| --- | --- | --- | --- |
| 起来几分钟就非零退出，日志里有「空间不足」 | `storage_guard` | 磁盘护栏在下载前就挡住了：`CHECKPOINT_GB + STORAGE_MARGIN_GB` 超过了 `/mnt/nvme` 可用空间；或者本地盘没识别出来（`REQUIRE_INSTANCE_STORE`） | 看 `bootstrap.log` 里 `lsblk` 的输出确认盘认到了几块；recipe 里的 `CHECKPOINT_GB` 是否比实际权重小；换了权重就同步改 `STORAGE_MARGIN_GB` |
| 长时间停在下载 | `fetching_model` | HuggingFace 侧慢/限流，或 repo 是 gated 缺 `HF_TOKEN` | 先建 S3 镜像并设 `CHECKPOINT_S3_URI`（第 4 节）；gated repo 要传 `HF_TOKEN` |
| 服务一直不 ready，最后超时 | `starting_server` | 冷启动本来就要 10-15 分钟（FlashInfer autotune + CUDA graph 捕获）；或者启动参数本身不合法 | 先看 `sglang-server.log`：真在 autotune 就把 `SERVER_READY_TIMEOUT` 调大（默认 2400s）；如果是参数报错，那就是 recipe 的问题 |
| `sglang-server.log` 里 MoE / kernel 相关报错（类似 README 9.1 里 `KeyError 'sm_75'` 那种形态） | `starting_server` | FP4 专家权重在 Hopper SM90 上没有原生支持，只能走 W4A16 Marlin | 确认走的是 recipe A（含 `--moe-runner-backend marlin`）；仍失败就按第 5 节换 C，最后才换 B（FP8 重打包权重） |
| 服务起来了但 TPOT 明显偏高 | `benchmarking` -> `completed` | 推测解码没真正生效，或 batch/图捕获配置不合适 | `sglang-server.log` 里确认 EAGLE/DSpark 确实加载了；结果 JSON 里看 `accept_length`（接受长度接近 1 就等于推测解码没起作用）；按第 5 节换算法 |
| 机器突然消失，phase 是 `spot_interrupted` | `spot_interrupted` | Spot 被回收（正常事件） | 日志与部分结果已经同步到 S3，直接重跑同一条命令；必要时提高 `--max-price` 或换 AZ |
| phase 是 `deadline_exceeded` | `deadline_exceeded` | 墙上时钟看门狗按 `MAX_RUNTIME_MINUTES` 强制收工 | 这是**保护**不是故障。看日志判断慢在哪一步，必要时用 `--max-runtime-minutes` 放宽，但要重新算最坏花费 |
| 完成了但 `compare-results.sh` 全是 N/A | `completed` | 结果没有经过 `collect-results.sh`，或 bench 输出键名变了 | 一定要用 `collect-results.sh` 做转换（它处理 JSONL 与 `median_*` 键名）；`bash tests/run-tests.sh` 的用例 13 就是守这条契约的 |
| launcher 直接以 2 退出 | 还没启动 | 没有 `CONFIRM_SPEND=yes` | 这是设计如此。看完花费画像再显式授权 |
| `run-staged.sh` 以 **3** 退出，说「已经有一次 GPU 运行成功了，但还没有写总结」 | 还没启动 | 总结闸门（第 1.1 节）。注意补 `CONFIRM_SPEND=yes` 也一样是 3 | 按它打印的两条命令收结果 + 写总结；确实要跳过就加 `--ack-summary`（会在输出和台账里留痕） |
| `summarize-run.sh` 报「缺少必需的测量值」并以 1 退出 | 多半是 `starting_server` / `benchmarking` | 这次运行没有产出可用的 TPOT/TTFT，本质上算不上「跑成功过一次」 | 先看 `sglang-server.log` 与 `status.json` 的 phase。脚本刻意不生成一份填着占位符的总结 |
| 总结里 A6 / A8 / A9 是「未评估」 | `completed` | 产物里确实没有判据：A6 需要 tp 覆盖全部卡、A8 需要 `sglang-server.log`、A9 需要一条 4K 输入的 bench | **未评估不等于通过。** 要补 A8 就确认日志同步上来了；要补 A9 就再跑一条 `--random-input 4000` |
| launcher 报安全组有全网入站规则 | 还没启动 | `sg-0775ac013a1b6080d` 上又出现了 0.0.0.0/0 入站 | `bash scripts/setup-infra.sh --harden-existing`，或用 `--create-sg` 新建一个完全没有入站规则的组 |

---

## 8. 命令速查

```bash
bash scripts/preflight.sh --region us-east-2 --az us-east-2a   # 零花费预检
bash scripts/setup-infra.sh --region us-east-2                 # 免费前置资源（幂等）
bash scripts/run-staged.sh                                     # = preflight
bash scripts/run-staged.sh --show-ledger                       # 看阶段台账
bash scripts/run-staged.sh --stage full --dry-run              # 零花费预演
bash scripts/launch-bench-ec2.sh --stage full --dry-run        # 只做 run-instances --dry-run
bash scripts/mirror-checkpoint.sh --model <repo>               # 权重体积与月租报告
bash scripts/collect-results.sh --run-id <RUN_ID>              # 从 S3 收结果
bash scripts/compare-results.sh                                # 对比表 + 性价比排名
bash scripts/summarize-run.sh --run-id <RUN_ID>                # 写总结 + 放行总结闸门（1.1）
bash scripts/summarize-run.sh --fixture tests/fixtures --out /tmp/sumtest  # 离线验证生成器
bash scripts/run-staged.sh --stage full --ack-summary           # 明知未总结仍要继续（留痕）
bash tests/run-tests.sh                                        # 22 个用例，零花费
```

退出码：`0` 成功 / `1` 出错 / `2` 缺 `CONFIRM_SPEND=yes` / `3` 有成功运行未总结。
