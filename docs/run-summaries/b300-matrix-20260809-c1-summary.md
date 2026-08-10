# 运行总结：b300-matrix-20260809 / c1-tp8-eagle-megamoe

> 手写总结（不是 `scripts/summarize-run.sh` 生成的：那个脚本读的是 `bench-bootstrap.sh`
> 那套 `runs/<RUN_ID>/results/run_*.json` 产物，而这次是 SSM 手动驱动的配置矩阵，
> 产物布局是 `runs/b300-matrix-20260809/<config>/`）。
> 数据全部来自这次运行自己的产物：
> `s3://tpot-bench-results-077090643075-us-west-2/runs/b300-matrix-20260809/`，
> 仓库内镜像在 `results/b300-matrix-20260809/`。
> 本仓库的规矩：取不到的值一律写「未评估」并写清原因，绝不填一个看着像数字的占位值。

**一句话结论：** B300 整机 tp=8 + EAGLE + megamoe **能起来、能解码、投机解码真的生效
（accept length 2.77）**，但 **README 6.1 锁定的 40K / 30K 长上下文负载在这台机器上
根本跑不起来** —— 一发 16K 以上的请求，8 个 TP rank 同时报
`CUDA error (flash-mla/csrc/smxx/decode/get_decoding_sched_meta.cu:111): invalid argument`
并把整个服务打死。把上下文降到 4K 才拿到了唯一一组真实数据：
**TPOT P50 = 4.503 ms、输出吞吐 182.0 tok/s、accept length 2.772、50/50 请求完成**。
即使在这个对 B300 更有利的短上下文条件下，它仍然**比 H200 tp=4 的 40K 成绩慢 35.2%**。

---

## 1. 这次到底跑了什么

| 项 | 值 | 来源 |
| --- | --- | --- |
| RUN_ID | `b300-matrix-20260809` | 本次手动矩阵的运行 ID |
| 实例 | p6-b300.48xlarge (`i-0d2500b8c91851a30`) | `describe-instances` |
| GPU | NVIDIA B300 x8，每卡 ~237 GB 被占用（`nvidia-smi` 实测合计 1 901 512 MiB） | 就绪轮询里的 `nvidia-smi --query-gpu=memory.used` |
| Region / AZ | us-west-2 / us-west-2b | 实例属性 |
| Spot 请求 | `sir-dzrfki2p`（one-time，interruption behavior = terminate） | 实例属性 |
| 访问方式 | **仅 SSM**（安全组 `sg-0e24f30107d9a84c3` 零入站规则，无 key pair） | 本任务前序结论 |
| 权重 | `/opt/dlami/nvme/models/deepseek-ai__DeepSeek-V4-Flash`（159.6 GB，73 文件，FP4 experts） | 本地 NVMe，全程复用未重新下载 |
| SGLang 镜像 | `lmsysorg/sglang:v0.5.12.post1-cu130`（本地已有 47.3 GB） | `docker images` |
| 注意力后端 | `attention_backend='dsv4'`，服务自己把 `page_size` 定到 256 | `server.log`：`Use dsv4 attention backend for DeepseekV4ForCausalLM, setting page_size to 256.` |
| KV cache | `kv_cache_dtype='fp8_e4m3'`，`full_token=8 385 024` | `server.log` 的 DSV4 pool sizes |
| 驱动脚本 | `scripts/b300-run-config.sh`（本次新增） | 本仓库 |

c1 的启动参数（与 14:35 手工起的那个容器逐字相同，`--skip-launch` 就是照它对齐的）：

```
--model-path /opt/dlami/nvme/models/deepseek-ai__DeepSeek-V4-Flash --tp 8
--moe-a2a-backend megamoe --mem-fraction-static 0.85 --trust-remote-code
--host 0.0.0.0 --port 30000 --cuda-graph-max-bs 64
--speculative-algorithm EAGLE --speculative-num-steps 3 --speculative-eagle-topk 1
--speculative-num-draft-tokens 4 --enable-metrics
```

环境变量 `SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320`。

### 时间线（UTC，全部有产物或日志佐证）

| 时刻 | 事件 |
| --- | --- |
| 14:35:08 | c1 容器首次启动（手工，冷缓存） |
| 14:44:39 | `The server is fired up and ready to roll!` —— 冷启动 **9 分 31 秒** |
| 14:48:53 | 启动 README 6.1 的 40000/1500 bench |
| 14:49:10 | bench warmup 请求直接失败，服务已死（第一次撞上内核 bug，当时还不知道原因） |
| 14:51:01 | **在任何 `docker rm` 之前**把容器内 `/root/.cache` 拷到 `/opt/dlami/nvme/jitcache`（1.6 GB） |
| 14:51:05 | 带 `-v /opt/dlami/nvme/jitcache:/root/.cache` 重起 c1 |
| 14:56:52 | 就绪 —— **5 分 47 秒**，比冷缓存快 3 分 44 秒（DeepGEMM warmup 从几分钟变成 3 秒） |
| 14:57:11 | 小请求探针：12 token 输入 + 16 token 输出，200 OK，`spec_accept_rate=0.29` → decode 通路本身是好的 |
| 14:57:54 - 14:58:02 | 阶梯探针定位边界：**4000 token OK，16000 token 崩** |
| 15:02:06 - 15:09:30 | c1c（关闭 chunked prefill）：**同样崩**，同一个内核同一行 |
| 15:12:29 - 15:23:23 | c1 重起，改用 4K 上下文跑通 bench_custom（唯一成功的一组），随后 30K 的 bench_official 照例崩 |
| 15:26:05 - 15:32:26 | c1t（NSA 内核换 tilelang）：**同样崩** |

---

## 2. 崩溃的定位结论（这一段是这次运行最值钱的产出）

### 现象

40K / 30K / 16K 的请求一发出去，8 个 TP rank 同时打印：

```
CUDA error (/sgl-workspace/flash-mla/csrc/smxx/decode/get_decoding_sched_meta/get_decoding_sched_meta.cu:111): invalid argument
[...] Subprocess scheduler_N (pid=...) crashed with exit code 1. Triggering SIGQUIT for cleanup...
```

客户端侧表现为 `aiohttp ClientPayloadError: Response payload is not completed`
（流式响应中途服务没了），HTTP 层随后 500，容器整体退出，8 张卡显存归零。

### 已确认的事实

| 结论 | 证据 |
| --- | --- |
| 服务启动成功 ≠ 能干活 | `/health` 只做 prefill 不做 decode，所以它一路返回 200；真正的 decode 直到第一个 bench 请求才被执行 |
| 短上下文完全正常 | 12 token 输入 / 16 输出 200 OK；4000 token 输入 / 8 输出 200 OK；4000/1500 跑满 50 条请求无一失败 |
| 边界在 4000 与 16000 之间 | 阶梯探针 `ctxprobe.log`：N=4000 → 200 OK；N=16000 → 500 + 服务死亡。**未评估**：4000 与 16000 之间的精确阈值（每次探测都要付一次 6 分钟冷启动，没有继续二分） |
| 不是 chunked prefill 的问题 | c1c 用 `--chunked-prefill-size -1 --max-prefill-tokens 49152`（`server_args` 里确认 `chunked_prefill_size=-1` 生效）**照样崩在同一行** |
| 不是 NSA 后端可选那一层的问题 | c1t 用 `--nsa-prefill-backend tilelang --nsa-decode-backend tilelang` **照样崩在同一行** → 崩的是 `dsv4` 注意力后端固定调用的 flash-mla decode metadata，不是 `--nsa-*-backend` 能换掉的部分 |
| 不是 OOM | `docker inspect` 的 `OOMKilled=false`，主机内存 3.7 TB 空闲，报错是 `invalid argument` 而不是 out of memory |
| 与投机解码无关 | 崩溃发生在 prefill 之后的第一次 decode/verify，而同一份配置在 4K 上下文下 EAGLE 工作正常（accept 2.77） |

### 尚未验证的候选修复

| 候选 | 为什么值得试 | 状态 |
| --- | --- | --- |
| 换更新的镜像 `lmsysorg/sglang:v0.5.17-cu130`（2026-08-08 发布） | 本次用的 `v0.5.12.post1` 已落后 5 个小版本，flash-mla 是 vendored 的第三方内核，这类 arch 相关的 launch 参数 bug 通常靠上游修 | **本次未测完**（镜像正在 `docker pull`，见第 8 节） |
| `--attention-backend` 换掉 `dsv4` | 崩的那一行只在 dsv4 路径上被调用 | 未测。DeepSeek-V4-Flash 的稀疏注意力（DSA + indexer）很可能强依赖 dsv4，换掉大概率直接起不来，属于低成功率尝试 |
| awslabs `dsv4flash-b300-intra-3p1d` 的 tp=2 x 4 进程 PD 分离拓扑 | 那份官方 sample 在 B300 上是跑通的，而它每个引擎只用 tp=2；如果这个 bug 与每 rank 的 head 数（tp=8 → 16 heads/rank）相关，tp=2 就绕过去了 | 未测，属于 FEAT-003 的 P2 行 |

---

## 3. 唯一一组真实测量：4000 in / 1500 out

50 条请求、并发 1、`--dataset-name random`，其余参数与 README 6.1 一致，**只把输入长度从
40000 降到 4000**（否则服务会被打死，一个数都拿不到）。产物：
`results/b300-matrix-20260809/c1-tp8-eagle-megamoe/bench_custom.jsonl`。

| 指标 | 实测 | 说明 |
| --- | --- | --- |
| TPOT P50 | **4.503 ms** | `median_tpot_ms`（mean 4.498，std 0.240） |
| TPOT P95 | **未评估** | 本版 `bench_serving` 的输出里**没有** `p95_tpot_ms` 这个键（只有 `p99_tpot_ms`）。P99 = **5.214 ms**，但 P99 不等于 P95，不能拿来充当 A2 的判据 |
| TTFT P50 | **214.99 ms** | `median_ttft_ms`（mean 943.7 —— 均值远高于中位数，说明少数请求的 prefill 排队明显更久） |
| TTFT P95 | **未评估** | 同样没有 `p95_ttft_ms`。P99 = **4 997.7 ms** |
| E2E P50 | **5 050.44 ms** | `median_e2e_latency_ms`（mean 5 120.6，P99 未列入本表：`p99_e2e_latency_ms` 存在，值见 jsonl） |
| 输出吞吐 | **182.00 tok/s** | `output_throughput` |
| ITL P50 / P95 | 4.146 ms / 6.248 ms | `median_itl_ms` / `p95_itl_ms`（ITL 有 P95，TPOT 没有，这是 bench_serving 的键名不对称，不是笔误） |
| accept length | **2.772** | `accept_length`，投机解码确实在工作（服务端日志同期打印 `accept len: 2.98, accept rate: 0.66, cuda graph: True`） |
| 完成请求数 | **50 / 50** | `completed`，无一失败 |
| 实测耗时 | 256.06 s | `duration` |
| 输入 / 输出 token 总量 | 103 349 / 46 603 | `total_input_tokens` / `total_output_tokens` |

30000 in / 4096 out 那一路（`bench_official`）：**未评估 —— 服务在 warmup 请求上就被内核
bug 打死，rc=1，没有产出任何指标**。日志留在
`results/b300-matrix-20260809/c1-tp8-eagle-megamoe/bench_official.log` 与 `server.log`。

---

## 4. README 12.9 验收逐条判定（A1 - A9）

**重要前提：下面 A1 / A2 / A5 / A9 的测试条件与 README 12.7 不一致** ——
README 要的是 40K 输入，而 40K 在这台机器上跑不起来，表里用的是 4K 输入。
**上下文更短对延迟指标是更有利的条件**，所以「4K 下就已经不达标」的结论可以直接
外推到 40K；反过来「4K 下达标」**不能**说明 40K 也达标。

| 编号 | 指标 | Pass 条件 | 实测 | 判定 | 说明 |
| --- | --- | --- | --- | --- | --- |
| **A1** | TPOT P50 | ≤ 4.5 ms | 4.503 ms（4K 输入） | ❌ **FAIL** | 超出 0.003 ms（+0.06%），是「刚好压线不过」。而且这还是 4K 上下文；README 要求的 40K 只会更慢 |
| **A2** | TPOT P95 | ≤ 6.0 ms（建议） | 未评估 | ⚠️ **未评估** | 本版 bench_serving 不输出 `p95_tpot_ms`。参考值 P99 = 5.214 ms |
| **A3** | TTFT P50 | ≤ 1.7 s | 0.215 s（**4K** prefill） | ⚠️ **未评估** | 数值本身远优于阈值，但 A3 的口径是 40K prefill。4K 的 TTFT 说明不了 40K —— H200 在 40K 下是 0.665 s。40K 无法测，故不判 PASS |
| **A4** | TTFT P95 | ≤ 2.5 s（建议） | 未评估 | ⚠️ **未评估** | 无 `p95_ttft_ms`。参考值 P99 = 5.00 s（若 P95 接近 P99，这一条会是 FAIL） |
| **A5** | E2E P50 | ≤ 8.45 s | 5.050 s（4K in / 1500 out） | ⚠️ **未评估** | 输出长度 1500 与 README 一致，但输入是 4K 不是 40K，缺的那 36K prefill 时间没算进去，不能直接判 PASS |
| **A6** | 部署方式 | 整机 8 卡，不拆独立副本 | tp=8，8 张卡各 ~237 GB，单一服务实例 | ✅ **PASS** | `nvidia-smi` 实测 8 张卡合计 1 901 512 MiB；没有拆副本 |
| **A7** | 投机解码 accept length | ≥ 2.0 | **2.772** | ✅ **PASS** | EAGLE 3/1/4 真的生效；服务端日志同期 `accept len: 2.98`。这是本次最干净的一条结论 |
| **A8** | 稳定性 | 连续 50 请求无 OOM/crash | 4K 负载下 50/50 完成，无 OOM | ⚠️ **有条件 PASS** | **只在 ≤4K 上下文成立**。同一个服务在 16K 以上请求下 100% 崩溃 —— 按客户真实负载（40K）的口径，这一条是 **FAIL** |
| **A9** | 长上下文衰减 | 40K vs 4K 的 TPOT 差异 < 15% | 未评估 | ⚠️ **未评估** | 40K 侧的数拿不到（服务会死）。本次只有 4K 一个点，做不了差异 |

**合计：2 条 PASS（A6、A7）、1 条 FAIL（A1）、1 条有条件 PASS（A8）、5 条未评估。**

**未评估 ≠ 通过。** 按客户真实负载（40K 输入）的口径，这台 B300 在当前镜像下
**不具备可用性** —— 不是性能不够，是服务会崩。

---

## 5. 与 H200 基线对比

H200 基线（本仓库 RUN_ID `20260809-000033-504a`，p5en.48xlarge，tp=4，EAGLE 3/1/4，
`--moe-runner-backend marlin`）：

| 项 | H200 tp=4（40K in / 1500 out） | B300 tp=8（**4K** in / 1500 out） | 差异 |
| --- | --- | --- | --- |
| TPOT P50 | 3.330 ms | 4.503 ms | **+35.2%（B300 更慢）** |
| 输出吞吐 | 224.2 tok/s | 182.0 tok/s | **-18.8%（B300 更低）** |
| TTFT P50 | 665.1 ms（40K prefill） | 214.99 ms（4K prefill） | 不可比（prefill 长度差 10 倍） |
| E2E P50 | 3 240.1 ms | 5 050.4 ms | 不可比（H200 那一路输出 1500 且输入 40K；两边输入不同） |
| accept length | 未评估（H200 产物里没有该字段） | 2.772 | 不可比 |

**判断：** 在**对 B300 更有利**的短上下文条件下（4K vs H200 的 40K），B300 的
TPOT 仍然比 H200 慢 35%、吞吐低 19%。这不像硬件差距，更像 B300 上这套内核路径
（dsv4 + megamoe/DeepGEMM + FP4）还没调好 —— 与「长上下文直接崩内核」是同一个
成熟度问题的两面。**不建议基于这一次的数字下「B300 不如 H200」的硬结论**，
正确的结论是「当前 SGLang v0.5.12.post1 在 B300 上不可用于本负载」。

## 6. 与 LMSYS 公开基线对比（README 12.2）

LMSYS Day-0 博客的口径是 **30K prefix + OSL 4096 + 单 batch 解码，H200 tp=4 + EAGLE，
约 266 tok/s / TPOT 约 3.76 ms**。

**未评估。** 原因：这个口径要求 30K prefix 与 4096 输出长度，而 30K 请求在这台
B300 上必崩（`bench_official` rc=1，无任何指标产出），4K/1500 的成绩与它既不同
输入长度也不同输出长度，拿来相除只会得出一个看着像结论的假数字。
要补这一格，必须先解决第 2 节那个内核崩溃。

---

## 7. JIT 缓存：本次唯一被验证有效的优化

DeepGEMM / FlashInfer / triton 的 JIT 产物住在容器内 `/root/.cache`，`docker rm` 一删就没，
而它正是冷启动时间的大头。做法：在第一次 `docker rm` **之前** `docker cp` 出来，
之后每次起容器都 `-v /opt/dlami/nvme/jitcache:/root/.cache`。

| 启动 | 缓存 | 容器启动 → health=200 | 备注 |
| --- | --- | --- | --- |
| 14:35:08 | 冷（无缓存） | **9 分 31 秒** | DeepGEMM warmup 走完整 JIT 编译 |
| 14:51:05 | 挂载 1.6 GB 缓存 | **5 分 47 秒** | `DeepGEMM warmup: 100%|██████████| 32768/32768 [00:03<00:00]` —— 3 秒 |
| 15:12:29 | 挂载缓存 | 6 分 03 秒 | c1 重跑 |
| 15:26:05 | 挂载缓存 | 6 分 03 秒 | c1t（tilelang） |
| 15:02:06 | 挂载缓存 | 7 分 24 秒 | c1c，关闭 chunked prefill 后 buffer 更大，启动更久 |

**净收益：每次换配置省 3 分 44 秒（约 39%），按 $51.72/hr 算约 $3.2 / 次。**
缓存内容：`deep_gemm`、`flashinfer`、`sglang`、`torch_extensions`、`tvm-ffi`、`huggingface`、`pip`。

---

## 8. 花费

| 项 | 值 | 来源 |
| --- | --- | --- |
| Spot 单价 | **$51.7203/hr** | `describe-spot-price-history`，us-west-2b，2026-08-09T13:00Z 实价 |
| 本次配置矩阵时段 | 14:35:08 → 15:40（约 65 分钟） | 上面的时间线 |
| 该时段花费 | 约 **$56** | 51.7203 x 65/60 |
| 实例总寿命花费 | **未评估** | 实例 08:32:29 就起来了（属于之前那次失败的 Lambda 运行 `20260809-083227-e73b`），那段时间不在本次 feature 的范围内 |
| 单请求成本 | 约 **$0.0726/请求** | 51.7203/3600 x E2E P50 5.050 s，仅对 4K 负载、并发 1 成立 |

四次容器启动里有三次的钱是花在「确认这个内核 bug 绕不过去」上的 —— 这是负面结论，
但它把 FEAT-002 / FEAT-003 从「照着 README 往下跑」改成「先解决可用性」，
避免了后面几个配置继续每次花 6 分钟起服务再崩一次。

---

## 9. 下一步

1. **先解决可用性，再谈矩阵。** 在 40K 能跑通之前，c2 / c3 / c4 / c5 全部会在同一个
   内核上崩，一个一个试等于按 $51.72/hr 重复付同一个失败。
2. **第一优先级：换镜像 `lmsysorg/sglang:v0.5.17-cu130`。** 本次已经在机器上
   `docker pull` 了（`/opt/dlami/nvme/bench/pull.log`），但没跑完就到了本 feature 的边界。
   验证成本很低：起服务后先发一个 16K 请求，10 秒内就知道成没成，不用等整条 bench。
   `scripts/b300-run-config.sh` 里加一支新 config 即可，流程一行都不用改。
3. **第二优先级：awslabs 的 tp=2 x 4 进程 PD 分离拓扑**（README 12.7 的 P2 行）。
   那份 sample 在 B300 上是跑通的，而它每个引擎只用 tp=2。
4. **不要再试的方向**（本次已花钱证伪，写进 `context.json` 的 key_patterns）：
   - `--chunked-prefill-size -1`：无效
   - `--nsa-prefill-backend / --nsa-decode-backend tilelang`：无效
   - 以及此前已证伪的 `--enable-dp-attention --dp N`（B300 上 allreduce 短路断言）
     和 p6-b200（fused_moe hidden size mismatch）
5. **README 12.12 的两张矩阵先别填 B300 那一行**，或者填成「不可用（内核崩溃）」，
   不要填 4K 的数字冒充 40K 的成绩。

---

生成说明：本文件由人工依据 `results/b300-matrix-20260809/` 与
`s3://tpot-bench-results-077090643075-us-west-2/runs/b300-matrix-20260809/` 下的实测产物写成。
每个配置的机读记录见 `results/b300-matrix-20260809/matrix-status.json`。
