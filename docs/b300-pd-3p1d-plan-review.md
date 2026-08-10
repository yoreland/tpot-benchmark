# B300 PD 分离（3P1D）方案评审 + 下一步执行计划

> 对 `b300-pd-docker-plan` 的核查结果与修正后的执行方案。
> 核查方式：读仓库既有实证（S3 里的 server.log / bench json）+ 本地装 `sglang-router` 跑 `--help` 核对真实参数 + 查 SGLang 官方文档与 issue。
> 结论先说：**方案方向对，但有 4 处会直接导致失败的错误，且前提条件已经不成立（机器没了）。**

---

## 0. 先说三个"现在就不成立"的前提

| 文档假设 | 实际情况 | 影响 |
|---|---|---|
| 有一台跑着的 8×B300 | **实例 `i-0d2500b8c91851a30` 已被 user-initiated 终止**（spot request `sir-dzrfki2p` = `closed / instance-terminated-by-user`），当前账号下只有 3 台 t4g | 必须重新抢稀缺容量 |
| 权重在 `/opt/dlami/nvme/models/...` 可复用 | 实例盘随实例一起消失。**`s3://.../checkpoints/` 是空的（0 objects）**，RUNBOOK §4 的权重镜像一直没做 | 冷启动要重新从 HF 拉 159.6 GB |
| JIT cache 在 `/opt/dlami/nvme/jitcache` | 同上，已消失 | 冷启动多花 ~3m44s（≈$3.2） |

> 这正是 learnings 里"稀缺 GPU spot 抢到别轻易回收"那条的代价：这台机器还有 c2/c3/c4/c5 一整排配置没跑就被放掉了。
> **本轮补救动作：一旦拿到新机器，第一件事是 `aws s3 sync` 权重到 `checkpoints/`（$3.4/月），让下次重试从"HF 拉 160 GB"变成"同 Region S3 sync"。**

---

## 1. 文档里 4 个会直接踩死的错误（已实证）

### 错误 1（致命）：`SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320` 在 v0.5.17 上起不来

文档第 2 节 `docker run` 里写的是 `8320`。这个值 **配 v0.5.17 + megamoe 会在解析参数阶段就 `ValueError` 退出**，容器根本不会跑起来。

这不是猜测——`c1n-tp8-eagle-megamoe-v0517` 就是这么死的，S3 里的 `server.log` 原文：

```
ValueError: DeepSeekV4 with MegaMoE requires SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK
to cover each rank's effective prefill token budget. Current values:
chunked_prefill_size=16384, ..., required_per_rank=16384,
SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320.
Set ... to at least 16384, or lower --chunked-prefill-size ...
```

v0.5.17 新增了这条校验，把 v0.5.12 时代"静默 fallback 到 fused MoE"变成了启动即报错。
**修正：`SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=16384`**（要求 ≥ `chunked_prefill_size`，该模型默认 16384；与 tp 无关，`required_per_rank` 就等于 `chunked_prefill_size`）。

### 错误 2（致命）：router 的 `--prefill` 少了 bootstrap port

文档写：
```bash
--prefill http://127.0.0.1:30000 --prefill http://127.0.0.1:30100 ...
```
我在本地装了 `sglang-router==0.3.2` 跑 `--help`，真实签名是 **`--prefill URL [BOOTSTRAP_PORT]`**，且帮助里明确写了不给端口 = 没有 bootstrap port：

```
--prefill http://prefill1:8000 9000 \    # With bootstrap port
--prefill http://prefill2:8000 none \    # Explicitly no bootstrap port
--prefill http://prefill3:8000 \         # Defaults to no bootstrap port
```

引擎侧我们显式指定了 `--disaggregation-bootstrap-port 9000/9100/9200`，router 侧不带就对不上，PD 握手必然失败。

**修正：**
```bash
python3 -m sglang_router.launch_router --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --prefill http://127.0.0.1:30100 9100 \
  --prefill http://127.0.0.1:30200 9200 \
  --decode  http://127.0.0.1:30300 \
  --host 0.0.0.0 --port 30080 \
  --worker-startup-timeout-secs 2400 \
  --request-timeout-secs 3600
```
> `--worker-startup-timeout-secs` 必须加：默认值远小于本模型 30 分钟级的冷启动，否则 router 会在引擎还在加载时就把 worker 判死。
> router 默认 `--port` 就是 **30000**，和 prefill 0 撞车；文档用 30080 是对的，保持。

### 错误 3（致命，风险最高）：单机 NVLink KV 传输，默认 backend **做不到**

文档第 0 节说"KV 传输走 NVLink（NIXL / CUDA IPC），所以必须同容器 + `--ipc=host`"。

实际情况：`disaggregation_transfer_backend` 默认是 **`mooncake`**（从 v0.5.17 自己 dump 的 server_args 确认）。而 SGLang issue [#12661](https://github.com/sgl-project/sglang/issues/12661) 里维护者 @ShangmingCai 明确说：**同节点场景当前 Mooncake Transfer Engine V0 还不支持**，要等 V1 / 用特定 PR，并且要自己带 `-DUSE_INTRA_NVLINK=ON` 从源码编译、再 `export MC_INTRANODE_NVLINK=1`；提问者照做之后仍然撞上 `KVPoll.Bootstrapping` 300s 超时。（内容已改写以符合许可要求）

也就是说：**`--ipc=host` 并不会让 mooncake 走 CUDA IPC**，这个因果关系是文档臆测的。同机 PD 真正可行的路是 **NIXL/UCX**（UCX 原生支持 intra-node CUDA IPC / shm）：
```
--disaggregation-transfer-backend nixl
```
但 NIXL 需要镜像里装了 `nixl`（官方文档：pip 安装，或源码编译）。**v0.5.17 镜像里有没有，必须上机确认**。

**这条是整个方案的头号风险，必须用一个便宜的门禁先验证（见 §3 Phase 2），绝不能拿 160 GB 权重去试。**

### 错误 4：`--enable-dp-attention` 应该去掉

文档把它放进了 `COMMON`。但本仓库已经反复证明这条在该模型/该硬件上是雷：
`AssertionError: short-circuiting allreduce will lead to hangs`，GPU 掉到 0 MiB，健康检查返回 200 但其实是个空壳（`b300-run-config.sh` 专门为此加了 gpumem==0 的守卫）。

每个引擎 `--tp 2` 且不给 `--dp`，`dp_size` 就是 1，`--enable-dp-attention` 此时无收益纯风险。
**修正：首次尝试去掉 `--enable-dp-attention`。** 去掉之后"端口必须间隔 100（port+233 派生）"的理由也不存在了，但端口照旧间隔 100 无害，保留。

### 附带一个可读性问题（不致命）

文档把 `--disaggregation-mode` 放在 `COMMON` 末尾，靠拼接 `$COMMON prefill` 让它变成 `--disaggregation-mode prefill`。能跑，但谁一改顺序就静默坏掉。建议 `COMMON` 里不含该 flag，各引擎显式写 `--disaggregation-mode prefill|decode`。

---

## 2. 一个比"效果一般"更重要的发现：基线本身是混着两个 build 的

我把 S3 里所有 B300 结果的 `server_info.version` 都对了一遍：

| 结果 | image 版本 | 负载 | 结论 |
|---|---|---|---|
| `runs/b300-tp8-eagle/bench_custom.json` → TPOT P50 **3.337 ms** | **0.5.17** | 40K/1.5K | ✅ 通过 |
| `runs/b300-tp8-eagle/bench_official.json` → TPOT P50 3.359 ms | **0.5.17** | 30K/4096 | ✅ 通过 |
| `runs/b300-tp8-eagle-sweep-8k/bench_c*.json`（c1→c32 并发扫描） | **0.5.12.post1** | 8K/1.5K | ⚠️ 旧 build |
| `c1-tp8-eagle-megamoe`（env=8320） | 0.5.12.post1 | 40K | ❌ flash-mla 崩 |
| `c1m-...-tok16384`（env 提到 16384） | 0.5.12.post1 | 40K | ❌ **仍然** flash-mla 崩 |
| `c1n-...-v0517`（env 仍 8320） | 0.5.17 | — | ❌ 启动即 ValueError |

由此可以确定两件事：

1. **能跑通的配方是唯一的：image `v0.5.17` + `SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=16384`。**
   `c1m` 证明了 ≥16K 崩溃**不是** MegaMoE token budget 的问题（把 env 提到 16384 照样崩），而是 v0.5.12 里 `flash-mla/.../get_decoding_sched_meta.cu:111` 的 kernel bug，v0.5.17 修掉了。文档"镜像钉 v0.5.17"这个判断是对的，理由比文档写的更硬。
2. **并发扫描那 6 个点是旧 build 出来的，不能当 A 组基线用。**
   而"PD 分离在高并发才显现优势"这个论断，恰恰要靠并发扫描来对比。拿 0.5.12 的 sweep 去比 0.5.17 的 PD，比出来的差异分不清是 PD 的功劳还是版本的功劳。

> **所以 A 组基线必须补跑**：v0.5.17 上重跑一遍 8K 并发扫描。这是 §3 Phase 3，不是可选项。

---

## 3. 修正后的执行方案（分阶段门禁）

设计原则：**把便宜的验证放在贵的加载之前**；每过一个门禁才允许往下花钱。

### Phase 0 — 零成本准备（现在就能做，不需要机器）

1. 给 `scripts/b300-run-config.sh` 加多引擎能力。当前它硬编码单 `$CONTAINER` + 单 `$HEALTH_URL`，PD 跑不了。需要动 4 处：`resolve_config()`（改成支持"一个 config → N 个引擎参数集 + 1 个 router"）、launch 步、readiness 步（多端口全绿 + gpumem>0）、`capture_failure()`（必须捞全 4 个引擎的日志，否则真正的报错行会丢）。
2. 补 `tests/run-tests.sh` 的 dry-run 用例（现有下限 22 cases / 220 assertions）：断言 4 个引擎的 `--base-gpu-id` 是 0/2/4/6、端口 30000/30100/30200/30300、bootstrap 9000/9100/9200/9300、router 在 30080 且 `--prefill` 带 bootstrap port、全程无 `--dp`、env 是 16384 不是 8320。
3. 把 `us-west-2b` 补进 `scripts/poll-b300-h200.sh` 的 `SUBNET_MAP`。**现在缺**（只有 2a/2c/2d），而上一台 B300 恰恰是在 2b 抢到的 —— 等于把一个已知有容量的 AZ 排除在轮询之外。可用 `subnet-0594a48bad1aef4a6`。
4. 顺手把 `c1m` / `c1n` 的结果从 S3 归档进 `results/` 并写进 `matrix-status.json`（目前 repo 里没有，这两个配置的教训只存在于 S3）。

### Phase 1 — 抢容量 + 起机器（$0 直到抢到）

- 目标机型 `p6-b300.48xlarge`。近 6 小时 spot 价：**us-west-2a $51.48 / us-west-2b $51.97 / us-east-1a $44.54**。
- us-west-2 有现成的 SG（`sg-0e24f30107d9a84c3`，0 条 ingress，已确认存在）+ IAM profile（`tpot-bench-ec2-profile`，已确认存在）+ 结果桶，**优先 us-west-2**；us-east-1a 便宜 14% 但要新建 SG/profile，作为备选。
- `SELF_TERMINATE=false`，不设看门狗 —— 这次要在同一台机器上把 Phase 2→6 全部跑完（learnings 明确要求）。
- **抢到后立刻**：`aws s3 sync /opt/dlami/nvme/models/<slug>/ s3://.../checkpoints/<slug>/`（同 Region 内网上传，$3.4/月），以及 `--save-jit-cache`。

### Phase 2 — PD 管道门禁：小模型 + 10 分钟（关键，先于 160 GB 加载）

**目的：在不加载 DeepSeek 的前提下，回答"这台机器上同机 PD 的 KV 传输到底能不能通"。**

先核参数与依赖（就是文档第 6 节第 3 条，但要查得更全）：
```bash
python3 -m sglang.launch_server --help | grep -i disagg
python3 -c "import importlib.util as u; print('nixl:', bool(u.find_spec('nixl')))"
python3 -c "import importlib.util as u; print('router:', bool(u.find_spec('sglang_router')))"
python3 -c "import mooncake, sys; print('mooncake:', getattr(mooncake,'__version__','?'))" 2>&1 | tail -1
ibv_devinfo 2>&1 | head -20; fi_info 2>&1 | head -20   # 看 EFA/IB 有没有
```
然后用一个 **1B 级小模型**（例如 `Qwen/Qwen3-0.6B`，几百 MB，1 分钟加载）起 **1P1D、各 tp=1**，占 GPU 0 和 1，把 router 串上，发一个请求：

```bash
# 判定：能返回 completion = KV 通路打通；报 KVPoll.Bootstrapping timeout = 不通
curl -s -m 120 http://127.0.0.1:30080/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<small>","prompt":"hello","max_tokens":8}'
```

**门禁判定：**
- 走 `nixl` 通 → 用 nixl 进 Phase 4/5，成本 ~10 分钟。
- nixl 不可用、mooncake 走 TCP 能通 → **记录下来，但先不做 3P1D**。同机 TCP 的 TTFT 惩罚会把结论污染成"PD 很差"，而那其实是传输后端的锅，不是架构的锅。
- 都不通 → **放弃 3P1D，只做 Phase 4**，并在报告里如实写"当前镜像/驱动组合下同机 PD 的 KV 通路不可用"。

> 这一步 10 分钟、约 $9，能挡掉一次 30~50 分钟、$40 级的无效 4 引擎冷启动。

### Phase 3 — 补齐可比基线：v0.5.17 上重跑 tp8（约 45 分钟）

- 配方：`v0.5.17` + env `16384` + 现有 c1 serve args。
- 跑 40K/1.5K、30K/4096（复现 3.337 / 3.359 ms，确认机器状态正常），**外加 8K 并发扫描 c=1,2,4,8,16,32**。
- 产出即 §5 表格的 **A 组**。跑完先 `--save-jit-cache`，后面换配置省 ~4 分钟。

### Phase 4 — 低风险对照：4×tp2 DP 副本 + 普通 router（约 40 分钟）

这一组 **`.agents/tasks/task-b300-full-matrix/features/FEAT-003.json` 里已经设计好了**（`c5-4x-tp2-router`），且**不需要任何 KV 传输**：4 个独立 tp=2 引擎（`CUDA_VISIBLE_DEVICES` 分别 0,1 / 2,3 / 4,5 / 6,7），前面挂 `launch_router --worker-urls ...`。

我建议**把它排在 3P1D 之前**，理由是它能把两个混在一起的问题拆开：

- "tp=8 对这个模型是不是切太宽了？" → 由 Phase 4 回答（4 个 tp=2 副本 vs 1 个 tp=8）
- "把 prefill 和 decode 解耦有没有额外收益？" → 由 Phase 5 回答（3P1D vs 4×tp2）

如果 Phase 4 就已经把聚合吞吐拉上去，那"tp8 意义不大"这个结论**不依赖 PD 是否跑通**就能成立 —— 这是最省钱的路径。
注意 FEAT-003 已记录的坑：`--max-concurrency 1` 时 DP router 只会打到一个 worker，那个数据点测的是"tp=2 单引擎 TPOT"，不是聚合吞吐，别误读。

### Phase 5 — 3P1D PD 分离（仅当 Phase 2 门禁通过）

按文档第 2 节，但套用 §1 的 4 处修正。GPU/端口分配沿用文档表格（0,1→30000/9000；2,3→30100/9100；4,5→30200/9200；6,7→30300/9300）。

额外要加的东西：
- `--disaggregation-transfer-backend nixl`（或 Phase 2 验证通过的那个）
- 放宽超时：`SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=600`、`SGLANG_DISAGGREGATION_WAITING_TIMEOUT=600`（默认都只有 300s；4 个引擎同时从 NVMe 读同一份 159.6 GB 权重，I/O 抢占会让启动严重错位，decode 侧对 prefill 的心跳 2 次失败就判离线）
- **错开启动**：不要 4 个引擎同时 `docker exec -d`。建议先起 3 个 prefill，等它们健康后再起 decode，避免 decode 在 prefill 就绪前就开始心跳并超时。
- bench 要用 `--pd-separated`（`bench_serving` 有这个参数，默认 False），否则 PD 场景的指标拆分不对。
- MLA 模型**不要**开 `SGLANG_DISAGG_STAGING_BUFFER`（官方文档明确说 staging buffer 是给 GQA/MHA 的，DeepSeek 这类 MLA 不该开）；本例 P/D 两侧 tp 都是 2，同构 TP 下它本来也会被自动绕过。

### Phase 6 — 报告 + 收尾

`reports/b300-pd-3p1d-<date>/` + `docs/run-summaries/`，按 README 12.9 A1–A9 判定；`matrix-status.json` 与 `results/stage-ledger.json` 落盘；确认权重镜像已在 S3；**跑完整个矩阵再终止实例**。

---

## 4. 必须先对齐的一个预期：PD 很可能让 TPOT 变差

这点文档没提，但会直接决定"成功"怎么定义。

客户验收指标 A1 是 **TPOT ≤ 4.5 ms @ 并发 1**。TPOT 是 decode 阶段的指标。
- A 组：decode 跑在 **tp=8**（8 张卡的算力与带宽）→ 实测 3.337 ms
- B 组 3P1D：decode 只跑在 **tp=2**（2 张卡）→ 每个 token 的可用带宽约为 1/4

**单流 TPOT 几乎必然退化，可能直接顶穿 4.5 ms。** 这不是 PD 失败，而是 PD 本来就不是优化单流 TPOT 的手段 —— 它优化的是 TTFT（prefill 不再打断 decode）和高并发聚合吞吐。

所以判定口径要分开写，否则会得出自相矛盾的结论：

| 指标 | 期望方向 | 说明 |
|---|---|---|
| 单流 TPOT @ c=1 | **预期变差** | tp=2 decode，带宽变窄 |
| TTFT P95 @ 40K | **预期显著改善** | A 组这一项是 5220 ms，已经 ❌ 不达标；PD 正是治这个的 |
| 高并发聚合吞吐 / \$百万token | **这才是 PD 的成败判据** | 对应文档 §5 的核心问题 |

**建议把 §5 那句"结论要回答"改成两问：**
1. 高并发下 PD 的 吞吐/\$ 是否显著优于 tp8？（PD 的主张）
2. 如果 PD 的单流 TPOT 顶穿 4.5 ms，那 A1 与"高吞吐"就是互斥的 —— 需要客户明确哪个优先。

---

## 5. 时间与成本估算

按 us-west-2 $51.72/hr（us-east-1a $44.54/hr 可省约 14%）：

| Phase | 内容 | 时长 | 成本 |
|---|---|---|---|
| 0 | 本地改脚本 + 补测试 | — | **$0** |
| 1 | 抢容量 + 启动 + HF 拉 160 GB + 镜像到 S3 | ~50 min | ~$43 |
| 2 | PD 管道门禁（小模型） | ~10 min | ~$9 |
| 3 | A 组：tp8 v0.5.17（40K + 30K + 8K sweep） | ~45 min | ~$39 |
| 4 | C 组：4×tp2 DP router | ~40 min | ~$35 |
| 5 | B 组：3P1D PD（含 4 引擎冷启动） | ~70 min | ~$60 |
| 6 | 收尾归档 | ~10 min | ~$9 |
| | **合计** | **~3.6 hr** | **~$195** |

省钱点：Phase 2 失败就跳过 Phase 5，省 ~$60；Phase 4 若已给出结论，Phase 5 可降级为可选。
另有持续成本 **$3.4/月**（权重镜像），换来下次重试少花 ~$43 的下载时间 —— 强烈建议做。

---

## 6. 需要你拍板的 3 件事

1. **区域**：us-west-2（工具链/SG/IAM/桶都现成，$51.72/hr）还是 us-east-1a（便宜 14%，但要新建 SG + instance profile）？
2. **Phase 4 与 Phase 5 的顺序**：我建议先做低风险的 4×tp2 DP（它可能已足够回答"tp8 意义不大"），PD 作为进阶。你也可以要求直接冲 3P1D。
3. **权重镜像到 S3**：$3.4/月，是否批准？（RUNBOOK 要求 `CONFIRM_SPEND=yes` 才会上传）

另外确认一下预算口径：本轮预计 ~$195。要我按 Phase 0 先把脚本和测试改好（零成本），等你确认后再开始抢容量吗？

---

## 7. 核查依据

- 实例/spot 状态：`aws ec2 describe-spot-instance-requests --spot-instance-request-ids sir-dzrfki2p` → `closed / instance-terminated-by-user`
- 权重镜像为空：`aws s3 ls s3://tpot-bench-results-077090643075-us-west-2/checkpoints/ --recursive --summarize` → `Total Objects: 0`
- env 校验报错原文：`s3://.../runs/b300-matrix-20260809/c1n-tp8-eagle-megamoe-v0517/server.log`
- 提高 env 后仍崩：`s3://.../c1m-tp8-eagle-megamoe-tok16384/server.log`（`get_decoding_sched_meta.cu:111`）
- 各结果的 build 版本：各 `bench_*.json` 的 `server_info.version`
- router 真实参数：本地 `pip install sglang-router==0.3.2` + `python -m sglang_router.launch_router --help`
- 同机 NVLink 现状：[SGLang issue #12661](https://github.com/sgl-project/sglang/issues/12661)（内容已改写以符合许可要求）
- transfer backend / 超时 / staging buffer：[SGLang PD Disaggregation 文档](https://lmsysorg.mintlify.app/docs/advanced_features/pd_disaggregation)（内容已改写以符合许可要求）
- spot 价格：`aws ec2 describe-spot-price-history --instance-types p6-b300.48xlarge`
