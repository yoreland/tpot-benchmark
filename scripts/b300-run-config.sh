#!/usr/bin/env bash
# =============================================================================
# B300 配置矩阵单配置执行器 (b300-run-config)
# 用途：在那台只能用 SSM 摸到的 p6-b300.48xlarge 上，把「一个命名配置」从
#       起服务 -> 等就绪 -> 跑两条 bench -> 传 S3 -> 记状态 这一整条链跑完，
#       跑完就把产物拉回仓库。一次只做一个配置，配置名是唯一入口。
#
# 为什么要有这个脚本（每条都是踩过的坑，别退回去）：
#   1) 这台机器**没有 SSH**：安全组 sg-0e24f30107d9a84c3 零入站规则，也没有 key
#      pair。唯一通路是 aws ssm send-command + get-command-invocation 轮询。所以
#      所有机上动作都得先变成一段 shell 文本，再发过去执行。
#   2) SSM 命令**挂过**：`curl -sv` 和 `docker exec ps aux` 都能把一条命令吊死。
#      因此机上命令一律短、非交互，curl 一律显式带 -m 超时。
#   3) 一条 bench 要跑 3-7 分钟，绝对不能让 SSM 命令前台等着。做法是 SSM 里只负责
#      `setsid nohup ... </dev/null >log 2>&1 &` 把 driver 甩出去，然后轮询磁盘上的
#      done 标记文件。SSM 命令永远是秒级返回的。
#   4) 这是 Spot 一次性实例（sir-dzrfki2p，interruption behavior = terminate，
#      约 $50/hr）。所以：每跑完一条 bench 就立刻传 S3，不攒到最后；每个阶段切换都
#      落一次状态文件；轮询里顺带查 IMDS 的 spot/instance-action，收到中断通知就
#      先同步产物再以**专用退出码 9** 退出，好让调用方把「被抢占」和「配置跑挂」分开。
#   5) DeepGEMM 的 JIT 缓存住在容器里，`docker rm` 一删就没了，冷启动那 10-20 分钟
#      大头就是它。所以起容器时一律把 $JIT_CACHE_DIR 挂到 /root/.cache，
#      并在删容器前用 --save-jit-cache 把容器里的缓存捞出来合并进去。
#   6) bench_serving 的输出是**追加写的 JSONL**，键名是 median_tpot_ms（这才是 P50）
#      / p95_tpot_ms / median_ttft_ms / output_throughput / accept_length。这套
#      归一化逻辑全仓库只有 scripts/collect-results.sh 一份，这里**直接调用它**，
#      不再写第二个解析器。
#
# 退出码: 0 = 配置跑完，两条 bench 都有结果
#         1 = 配置失败（服务崩了 / bench 非零退出），失败现场已落 S3
#         2 = 用法错误（含未知配置名），未发起任何 SSM 调用
#         3 = 等就绪超时，docker logs 已捞出并上传
#         9 = 收到 Spot 中断通知（专用码，语义 = 不是这个配置的错）
#
# 注意：沙箱默认 AWS_REGION 可能不是目标 Region，所有 aws 调用显式传 --region。
# =============================================================================
set -euo pipefail

# =============================================================================
# 可配置参数（默认值）
# =============================================================================
CONFIG=""
# 刻意用 B300_INSTANCE_ID 而不是 INSTANCE_ID：沙箱环境里 INSTANCE_ID 已经被占用
# （是个 UUID），继承它会把 SSM 发到一个不存在的实例上。
INSTANCE_ID="${B300_INSTANCE_ID:-i-0d2500b8c91851a30}"
REGION="${REGION:-us-west-2}"
ACCOUNT_ID="${ACCOUNT_ID:-077090643075}"
BUCKET="${BUCKET:-}"                       # 留空则推导 tpot-bench-results-<account>-<region>
RUN_ID="${RUN_ID:-b300-matrix-20260809}"
SKIP_LAUNCH=0                              # 服务已经在跑，别动它
BENCH_ONLY=0                               # 连就绪轮询都跳过，直接跑 bench
RECORD_ONLY=0                              # 只补记录：不碰机器，只把 S3 上已有的产物归档进状态文件
CONFIG_NOTE="${CONFIG_NOTE:-}"             # 写进状态文件的人读说明（比如「负载偏离 README 的原因」）
SAVE_JIT_CACHE=0                           # 删容器前先把容器里的 JIT 缓存捞出来
READY_TIMEOUT_SEC="${READY_TIMEOUT_SEC:-2400}"  # 与 recipes/h200-tp4-fp4-eagle.env 的 SERVER_READY_TIMEOUT 对齐
BENCH_TIMEOUT_SEC="${BENCH_TIMEOUT_SEC:-2400}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-30}"
SSM_WAIT_SEC="${SSM_WAIT_SEC:-300}"        # 单条 SSM 命令最多等多久（都是秒级命令）
DRY_RUN="${DRY_RUN:-0}"

# 机上路径（测试里被指到临时目录，所以必须是变量）
BENCH_ROOT="${BENCH_ROOT:-/opt/dlami/nvme/bench}"
JIT_CACHE_DIR="${JIT_CACHE_DIR:-/opt/dlami/nvme/jitcache}"
MODEL_PATH="${MODEL_PATH:-/opt/dlami/nvme/models/deepseek-ai__DeepSeek-V4-Flash}"
CONTAINER="${CONTAINER:-sglang-server}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:30000/health}"

# bench 参数，锁死在 README 6.1，不要在这里「优化」
BENCH_NUM_PROMPTS="${BENCH_NUM_PROMPTS:-50}"
BENCH_CONCURRENCY="${BENCH_CONCURRENCY:-1}"
CUSTOM_INPUT="${CUSTOM_INPUT:-40000}"
CUSTOM_OUTPUT="${CUSTOM_OUTPUT:-1500}"
OFFICIAL_INPUT="${OFFICIAL_INPUT:-30000}"
OFFICIAL_OUTPUT="${OFFICIAL_OUTPUT:-4096}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-}"                     # 留空则用 <repo>/results/<RUN_ID>
STATUS_FILE="${STATUS_FILE:-}"             # 留空则用 <OUT_DIR>/../<RUN_ID>/matrix-status.json

EXIT_SPOT_INTERRUPTED=9
EXIT_READY_TIMEOUT=3
EXIT_USAGE=2

# =============================================================================
# 已登记配置一览（usage 与错误提示共用一份，别写两遍）
# =============================================================================
list_configs_indented() {
    cat <<'EOF'
  c1-tp8-eagle-megamoe     tp=8 整机 + EAGLE 3/1/4 + megamoe(DeepGEMM)，README 12.7 的 B300 P0 行
  c1n-tp8-eagle-megamoe-v0517 c1 参数不变、镜像换 v0.5.17-cu130：绕开长上下文崩溃的第一优先级候选
  c1t-tp8-eagle-nsatilelang c1 + NSA 稀疏注意力内核换成 tilelang：已实测**无效**，留作记录
  c1c-tp8-eagle-nochunk    c1 + 关闭 chunked prefill：已实测**无效**，同一个内核同一行照样崩，留作记录
  c1b-tp8-megamoe-noeagle  与 c1 只差「关掉 EAGLE」：c1 在 flash-mla decode 内核崩了，用它定位是不是投机解码这条路的问题
EOF
}

# =============================================================================
# 命令行参数解析
# =============================================================================
usage() {
    cat <<EOF
用法: $0 --config <name> [选项]

在 B300 机器上跑完一个命名配置（起服务 -> 等就绪 -> 两条 bench -> 传 S3 -> 记状态）。

选项:
  --config NAME        配置名（见下面「已登记配置」），必填
  --instance-id ID     目标实例 (默认: $INSTANCE_ID)
  --region REGION      AWS Region (默认: $REGION)
  --skip-launch        服务已经在跑：不 docker rm、不 docker run，直接等就绪 + 跑 bench
  --bench-only         连就绪轮询都跳过，直接跑 bench（你已经确认过 health=200）
  --record-only        完全不碰机器：把 S3 上已有的产物拉回来、归一化、补进状态文件
                       （被 Spot 杀掉之后事后补记录，或者给失败的配置补上真正的内核报错）
  --save-jit-cache     换配置前先把容器里的 /root/.cache 捞到 $JIT_CACHE_DIR
  --timeout-sec N      等就绪超时秒数 (默认: $READY_TIMEOUT_SEC)
  --run-id ID          运行 ID，决定 S3 前缀与 results/ 目录 (默认: $RUN_ID)
  --out-dir DIR        产物拉回目录 (默认: $REPO_ROOT/results/<RUN_ID>)
  --dry-run            不碰真实 AWS/机器：把要做的事写进 \$DRY_RUN_LOG，命令走 PATH 上的 stub
  --help               显示帮助信息

已登记配置:
$(list_configs_indented)

示例:
  # 服务已经手工起好了，只补 bench（本任务 c1 就是这么跑的）
  ./scripts/b300-run-config.sh --config c1-tp8-eagle-megamoe --skip-launch

  # 换配置：先保住 JIT 缓存，再重起
  ./scripts/b300-run-config.sh --config c1b-tp8-megamoe-noeagle --save-jit-cache
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG="${2:-}"; shift 2 ;;
        --instance-id) INSTANCE_ID="${2:-}"; shift 2 ;;
        --region) REGION="${2:-}"; shift 2 ;;
        --run-id) RUN_ID="${2:-}"; shift 2 ;;
        --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
        --bucket) BUCKET="${2:-}"; shift 2 ;;
        --skip-launch) SKIP_LAUNCH=1; shift ;;
        --bench-only) BENCH_ONLY=1; SKIP_LAUNCH=1; shift ;;
        --record-only) RECORD_ONLY=1; BENCH_ONLY=1; SKIP_LAUNCH=1; shift ;;
        --note) CONFIG_NOTE="${2:-}"; shift 2 ;;
        --save-jit-cache) SAVE_JIT_CACHE=1; shift ;;
        --timeout-sec) READY_TIMEOUT_SEC="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help) usage 0 ;;
        *) echo "未知参数: $1" >&2; usage "$EXIT_USAGE" ;;
    esac
done

# =============================================================================
# 工具函数
# =============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# DRY_RUN 下所有「本来要动真格」的动作都写到这里，测试断言读的就是这份日志。
dry_log() {
    printf '%s\n' "$*" >>"${DRY_RUN_LOG:-/dev/stdout}"
}

now_iso() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# =============================================================================
# 配置表：配置名 -> 一条精确的 docker run
# 加新配置只需要在这个 case 里加一支，其余流程（就绪判定 / bench / S3 / 状态）
# 一行都不用改 —— FEAT-002 的 c2/c3、FEAT-003 的 c4/c5 就是这么接进来的。
# =============================================================================
CONFIG_SERVE_ARGS=""
CONFIG_ENV_ARGS=""
CONFIG_DESC=""
# 镜像也是配置的一部分：B300 上那个长上下文内核崩溃就是镜像版本问题的候选，
# 所以它必须能按配置换，而不是写死在启动命令里。
CONFIG_IMAGE_DEFAULT="lmsysorg/sglang:v0.5.12.post1-cu130"
CONFIG_IMAGE=""

resolve_config() {
    CONFIG_IMAGE="$CONFIG_IMAGE_DEFAULT"
    case "$1" in
        c1-tp8-eagle-megamoe)
            # 这一串与 2026-08-09 14:35 手工起的那个容器**逐字相同**，
            # 所以 --skip-launch 能干净地挂到已经在跑的服务上。
            # megamoe = DeepGEMM 的 all-to-all，是 B300 上唯一验证过能起来的 MoE 路径
            #（H200 上那条是 --moe-runner-backend marlin，别混用）。
            CONFIG_DESC="tp=8 unified + EAGLE 3/1/4 + moe-a2a-backend megamoe"
            CONFIG_ENV_ARGS="-e SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320"
            CONFIG_SERVE_ARGS="--model-path $MODEL_PATH --tp 8 --moe-a2a-backend megamoe --mem-fraction-static 0.85 --trust-remote-code --host 0.0.0.0 --port 30000 --cuda-graph-max-bs 64 --speculative-algorithm EAGLE --speculative-num-steps 3 --speculative-eagle-topk 1 --speculative-num-draft-tokens 4 --enable-metrics"
            ;;
        c1n-tp8-eagle-megamoe-v0517)
            # 启动参数与 c1 **逐字相同**，唯一变量是镜像：v0.5.12.post1 -> v0.5.17。
            # 为什么这是第一优先级：崩的 flash-mla 是 vendored 的第三方内核，
            # v0.5.12.post1 已经落后 5 个小版本，而 --chunked-prefill-size -1 和
            # --nsa-*-backend tilelang 两条绕坑路都已经花钱证伪了（见
            # docs/run-summaries/b300-matrix-20260809-c1-summary.md 第 2 节）。
            # 验证很便宜：起来之后第一个 40K warmup 请求 20 秒内就能告诉你成没成。
            CONFIG_DESC="c1 的参数不变，镜像换成 v0.5.17-cu130（验证长上下文内核崩溃是否已被上游修掉）"
            CONFIG_IMAGE="lmsysorg/sglang:v0.5.17-cu130"
            CONFIG_ENV_ARGS="-e SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320"
            CONFIG_SERVE_ARGS="--model-path $MODEL_PATH --tp 8 --moe-a2a-backend megamoe --mem-fraction-static 0.85 --trust-remote-code --host 0.0.0.0 --port 30000 --cuda-graph-max-bs 64 --speculative-algorithm EAGLE --speculative-num-steps 3 --speculative-eagle-topk 1 --speculative-num-draft-tokens 4 --enable-metrics"
            ;;
        c1t-tp8-eagle-nsatilelang)
            # c1 + 把 DSA/NSA 的稀疏注意力内核从 flash-mla 换成 tilelang。
            # 为什么是这个开关：崩的那个内核就在 flash-mla 里
            # （csrc/smxx/decode/get_decoding_sched_meta.cu:111，invalid argument），
            # 而 --nsa-{prefill,decode}-backend 的可选值里 tilelang 是 JIT 生成的、
            # 不依赖预编译的 SM 特化内核，是「换掉那个坏内核」最直接的一手。
            # 默认（None）走的是 flash-mla 自动选择，也就是崩的那条路。
            # 代价：tilelang 首次用要 JIT 编译，起服务更慢；性能未必是最优路径，
            # 所以拿到数就要在报告里注明这不是 c1 的默认内核路径。
            CONFIG_DESC="tp=8 unified + EAGLE 3/1/4 + megamoe + NSA 内核换 tilelang（绕开 flash-mla 长上下文崩溃）"
            CONFIG_ENV_ARGS="-e SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320"
            CONFIG_SERVE_ARGS="--model-path $MODEL_PATH --tp 8 --moe-a2a-backend megamoe --mem-fraction-static 0.85 --trust-remote-code --host 0.0.0.0 --port 30000 --cuda-graph-max-bs 64 --nsa-prefill-backend tilelang --nsa-decode-backend tilelang --speculative-algorithm EAGLE --speculative-num-steps 3 --speculative-eagle-topk 1 --speculative-num-draft-tokens 4 --enable-metrics"
            ;;
        c1c-tp8-eagle-nochunk)
            # c1 的绕坑版本，唯一改动是**关掉 chunked prefill**。
            # 定位过程（都是这台机器上实测的，别再花钱重走一遍）：
            #   4000 token 请求 + 8 个输出 token   -> 200 OK，spec_accept_rate 有值
            #   16000 token 请求                   -> 500，8 个 TP rank 同时报
            #     CUDA error (flash-mla/csrc/smxx/decode/get_decoding_sched_meta.cu:111):
            #     invalid argument，scheduler_6 退出，整个服务跟着死
            # 差别在于 16000 > chunked_prefill_size 的分块阈值，第二块开始带 cached
            # prefix，走的是「decode 版」sched meta，而这次 query 长度是 4096 而不是
            # 1 或 4 —— 那个内核在 B300 上就是在这种大 query 长度下炸的。
            # 所以 --chunked-prefill-size -1 让 40K 一次性 prefill 完，不产生带 cached
            # prefix 的续块；--max-prefill-tokens 也得跟着放开，否则请求进不了调度。
            CONFIG_DESC="tp=8 unified + EAGLE 3/1/4 + megamoe，关闭 chunked prefill（绕开 flash-mla decode sched meta 崩溃）"
            CONFIG_ENV_ARGS="-e SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320"
            CONFIG_SERVE_ARGS="--model-path $MODEL_PATH --tp 8 --moe-a2a-backend megamoe --mem-fraction-static 0.85 --trust-remote-code --host 0.0.0.0 --port 30000 --cuda-graph-max-bs 64 --chunked-prefill-size -1 --max-prefill-tokens 49152 --speculative-algorithm EAGLE --speculative-num-steps 3 --speculative-eagle-topk 1 --speculative-num-draft-tokens 4 --enable-metrics"
            ;;
        c1b-tp8-megamoe-noeagle)
            # 诊断用配置：c1 在第一个 decode step 就崩在
            # flash-mla/csrc/smxx/decode/get_decoding_sched_meta.cu:111 "invalid argument"
            # （8 个 TP rank 同时报，服务随即退出）。/health 只做 prefill，所以启动成功
            # 并不代表 decode 能跑。这一支把 EAGLE 四个参数全摘掉、其他一模一样，
            # 用来判断崩的是「投机解码的 verify 路径」还是「decode 本身」。
            # 注意：它不是 FEAT-003 里那个「关闭 EAGLE 对照组 c5」，命名故意区分开。
            CONFIG_DESC="tp=8 unified + megamoe，无投机解码（c1 崩溃定位用）"
            CONFIG_ENV_ARGS="-e SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320"
            CONFIG_SERVE_ARGS="--model-path $MODEL_PATH --tp 8 --moe-a2a-backend megamoe --mem-fraction-static 0.85 --trust-remote-code --host 0.0.0.0 --port 30000 --cuda-graph-max-bs 64 --enable-metrics"
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# =============================================================================
# SSM 执行层
# 把一段 shell 文本送到机器上跑。base64 包一层是因为 --parameters 里再套引号非常
# 容易被吃掉；DRY_RUN 下不发 SSM，直接在本地用 PATH 上的 stub 跑同一段文本，
# 于是测试断言的是「脚本真的算出了什么命令」，而不是某段静态字符串。
# =============================================================================
ssm_exec() {
    local label="$1" body="$2"
    if [[ "$DRY_RUN" == "1" ]]; then
        dry_log "ssm send-command label=$label instance=$INSTANCE_ID region=$REGION"
        bash -c "$body"
        return $?
    fi
    local b64 cid status waited=0
    b64="$(printf '%s' "$body" | base64 -w0)"
    cid="$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters "commands=[\"echo $b64 | base64 -d > /tmp/b300-step.sh; bash /tmp/b300-step.sh\"]" \
        --query Command.CommandId --output text)"
    while (( waited < SSM_WAIT_SEC )); do
        status="$(aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
            --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
        case "$status" in
            Success|Failed|Cancelled|TimedOut) break ;;
        esac
        sleep 3
        waited=$((waited + 3))
    done
    aws ssm get-command-invocation --region "$REGION" --command-id "$cid" \
        --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text 2>/dev/null || true
    [[ "$status" == "Success" ]]
}

# =============================================================================
# 状态文件：matrix-status.json
# 为什么不复用 Lambda 那次运行的 status.json —— 那条运行 20260809-083227-e73b 的
# status.json 早就写成 phase: failed，而现在这些手工 docker 重启**不会**回写它。
# 所以每个配置的真实进度必须独立记在这里，被抢占时留下的记录才是准的。
# =============================================================================
status_update() {
    # status_update <字段=值>...  字段：status started_at ended_at time_to_healthy_sec
    #                                   failure_reason custom_json official_json
    local kv
    mkdir -p "$(dirname "$STATUS_FILE")"
    kv="$(printf '%s\n' "$@")"
    CONFIG="$CONFIG" CONFIG_DESC="$CONFIG_DESC" LAUNCH_ARGS="$CONFIG_SERVE_ARGS" \
    S3_PREFIX="s3://$BUCKET/runs/$RUN_ID/$CONFIG/" \
    INSTANCE_ID="$INSTANCE_ID" REGION="$REGION" RUN_ID="$RUN_ID" KV="$kv" \
    python3 - "$STATUS_FILE" <<'PYEOF'
import json
import os
import sys

path = sys.argv[1]
schema = "tpot-benchmark/b300-matrix-status/v1"
try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except (OSError, json.JSONDecodeError):
    doc = {}

doc.setdefault("schema", schema)
doc["instance_id"] = os.environ["INSTANCE_ID"]
doc["instance_type"] = "p6-b300.48xlarge"
doc["region"] = os.environ["REGION"]
doc["spot_request"] = "sir-dzrfki2p"
doc["run_id"] = os.environ["RUN_ID"]
doc["updated_at"] = __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
doc.setdefault("configs", [])

name = os.environ["CONFIG"]
entry = None
for item in doc["configs"]:
    if item.get("name") == name:
        entry = item
if entry is None:
    entry = {"name": name, "status": "pending"}
    doc["configs"].append(entry)
entry["description"] = os.environ.get("CONFIG_DESC") or entry.get("description") or ""
entry["launch_args"] = os.environ.get("LAUNCH_ARGS") or entry.get("launch_args") or ""
entry["s3_prefix"] = os.environ["S3_PREFIX"]

for line in (os.environ.get("KV") or "").splitlines():
    if not line.strip():
        continue
    key, _, value = line.partition("=")
    key = key.strip()
    if key in ("custom_json", "official_json"):
        target = "custom" if key == "custom_json" else "official"
        entry[target] = json.loads(value) if value else None
        continue
    if key == "note":
        entry["note"] = value
        continue
    if key in ("time_to_healthy_sec",):
        entry[key] = int(float(value)) if value else None
        continue
    entry[key] = value if value != "" else None

with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PYEOF
}

# =============================================================================
# 机上小工具（拼成 shell 文本发过去）
# =============================================================================
box_dir() {
    printf '%s/%s' "$BENCH_ROOT" "$CONFIG"
}

s3_prefix() {
    printf 's3://%s/runs/%s/%s' "$BUCKET" "$RUN_ID" "$CONFIG"
}

# 一次性把「失败现场」捞出来并上传。所有失败路径都必须走它：
# 只要还能连上机器，server.log 就一定要进 S3，否则机器一没这次就白烧了。
capture_failure() {
    local reason="$1"
    log "捞失败现场并上传: $reason"
    ssm_exec capture-failure "$(cat <<EOS
set -u
D=$(box_dir)
mkdir -p "\$D"
docker logs $CONTAINER > "\$D/server.log" 2>&1 || true
docker inspect $CONTAINER > "\$D/container_inspect.json" 2>&1 || true
echo "$reason" > "\$D/failure_reason.txt"
aws s3 cp "\$D/server.log" "$(s3_prefix)/server.log" --region $REGION || true
aws s3 cp "\$D/failure_reason.txt" "$(s3_prefix)/failure_reason.txt" --region $REGION || true
exit 0
EOS
)" || true
}

# Spot 中断：先同步，再以专用码退出。顺序不能反 —— 通知到手只剩两分钟。
bail_on_spot() {
    log "收到 Spot 中断通知，先同步产物再退出"
    ssm_exec spot-sync "$(cat <<EOS
set -u
docker logs $CONTAINER > $(box_dir)/server.log 2>&1 || true
aws s3 cp $BENCH_ROOT/ $(s3_prefix | sed "s#/$CONFIG\$##")/ --recursive --region $REGION || true
exit 0
EOS
)" || true
    status_update "status=failed" "failure_reason=spot interruption notice received" "ended_at=$(now_iso)"
    exit "$EXIT_SPOT_INTERRUPTED"
}

# =============================================================================
# Step a) 参数校验
# =============================================================================
if ! command -v python3 &>/dev/null; then
    echo "错误: 未找到命令 'python3'（状态文件与结果归一化都要用它）" >&2
    exit 1
fi
if [[ -z "$CONFIG" ]]; then
    echo "错误: 必须给 --config" >&2
    usage "$EXIT_USAGE"
fi
# 未知配置名必须在**任何** SSM 调用之前就挡掉：一次误起容器就是十几分钟 + 十几美元。
if ! resolve_config "$CONFIG"; then
    echo "错误: 未知配置名 '$CONFIG'。已登记的配置：" >&2
    list_configs_indented >&2
    exit "$EXIT_USAGE"
fi
if [[ -z "$BUCKET" ]]; then
    BUCKET="tpot-bench-results-${ACCOUNT_ID}-${REGION}"
fi
if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$REPO_ROOT/results/$RUN_ID"
fi
if [[ -z "$STATUS_FILE" ]]; then
    STATUS_FILE="$OUT_DIR/matrix-status.json"
fi

log "配置      : $CONFIG（$CONFIG_DESC）"
log "实例      : $INSTANCE_ID @ $REGION"
log "S3 前缀   : $(s3_prefix)/"
log "状态文件  : $STATUS_FILE"
log "模式      : skip_launch=$SKIP_LAUNCH bench_only=$BENCH_ONLY dry_run=$DRY_RUN"

STARTED_AT="$(now_iso)"
if [[ "$RECORD_ONLY" == "1" ]]; then
    # 补记录模式下时间戳要从产物里还原，不能用「现在」把真实时间覆盖掉。
    log "--record-only：时间戳从 container_started_at.txt / timing.log 还原"
else
    status_update "status=running" "started_at=$STARTED_AT" "failure_reason="
fi

# =============================================================================
# Step b) 起服务（--skip-launch 时整段跳过）
# =============================================================================
LAUNCH_EPOCH="$(date -u +%s)"
if [[ "$SKIP_LAUNCH" == "1" ]]; then
    log "--skip-launch：不 docker rm、不 docker run，直接挂到已经在跑的服务上"
else
    if [[ "$SAVE_JIT_CACHE" == "1" ]]; then
        # 必须在 docker rm 之前。DeepGEMM 的 JIT 产物在容器内 /root/.cache，
        # 删容器等于把 10-20 分钟的编译扔掉。
        log "先把容器里的 JIT 缓存捞到 $JIT_CACHE_DIR"
        ssm_exec save-jit-cache "$(cat <<EOS
set -u
mkdir -p $JIT_CACHE_DIR $BENCH_ROOT/jitcache-src
docker cp $CONTAINER:/root/.cache $BENCH_ROOT/jitcache-src/ || echo "docker cp 失败（容器可能已经不在），继续"
if [ -d $BENCH_ROOT/jitcache-src/.cache ]; then
  cp -a $BENCH_ROOT/jitcache-src/.cache/. $JIT_CACHE_DIR/ || true
fi
du -sh $JIT_CACHE_DIR 2>/dev/null || true
exit 0
EOS
)" || log "JIT 缓存保存失败，继续（只是下次冷启动更慢）"
    fi

    log "重起容器：docker rm -f $CONTAINER 然后 docker run"
    ssm_exec launch "$(cat <<EOS
set -u
D=$(box_dir)
mkdir -p "\$D" $JIT_CACHE_DIR
docker rm -f $CONTAINER >/dev/null 2>&1 || true
docker run -d --name $CONTAINER --gpus all --ipc=host --net=host --shm-size=64g \
  -v /opt/dlami/nvme:/opt/dlami/nvme \
  -v $JIT_CACHE_DIR:/root/.cache \
  $CONFIG_ENV_ARGS \
  $CONFIG_IMAGE \
  python3 -m sglang.launch_server $CONFIG_SERVE_ARGS
echo "image=$CONFIG_IMAGE" > "\$D/launch_cmd.txt"
echo "$CONFIG_SERVE_ARGS" >> "\$D/launch_cmd.txt"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "\$D/container_started_at.txt"
exit 0
EOS
)" || { capture_failure "docker run 失败"; status_update "status=failed" "failure_reason=docker run 失败" "ended_at=$(now_iso)"; exit 1; }
fi

# =============================================================================
# Step c) 等就绪
# 判定三件事，缺一不可：容器还活着、health 是 200、GPU 上真有显存。
# 第三条是上一次踩过的坑：--enable-dp-attention 那次 HTTP 壳子活着、health 也通，
# 但 8 张卡全是 0 MiB —— 那不是「就绪」，那是空壳，不能就这么去跑 bench。
# 同时每轮顺带查一次 IMDS 的 spot/instance-action。
# =============================================================================
TIME_TO_HEALTHY=""
if [[ "$BENCH_ONLY" == "1" ]]; then
    log "--bench-only：跳过就绪轮询"
else
    log "轮询就绪（每 ${POLL_INTERVAL_SEC}s，最多 ${READY_TIMEOUT_SEC}s）"
    READY=0
    ELAPSED=0
    while (( ELAPSED <= READY_TIMEOUT_SEC )); do
        PROBE="$(ssm_exec ready-probe "$(cat <<EOS
set -u
echo "health=\$(curl -m 5 -s -o /dev/null -w '%{http_code}' $HEALTH_URL 2>/dev/null)"
echo "running=\$(docker inspect -f '{{.State.Running}}' $CONTAINER 2>/dev/null)"
echo "started=\$(docker inspect -f '{{.State.StartedAt}}' $CONTAINER 2>/dev/null)"
echo "gpumem=\$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '{s+=\$1} END {print s+0}')"
TOKEN=\$(curl -m 3 -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)
echo "spot=\$(curl -m 3 -s -H "X-aws-ec2-metadata-token: \$TOKEN" http://169.254.169.254/latest/meta-data/spot/instance-action 2>/dev/null)"
docker logs --tail 3 $CONTAINER 2>&1 | sed 's/^/logtail: /'
exit 0
EOS
)" || true)"
        HEALTH="$(printf '%s\n' "$PROBE" | sed -n 's/^health=//p' | head -n1)"
        RUNNING="$(printf '%s\n' "$PROBE" | sed -n 's/^running=//p' | head -n1)"
        GPUMEM="$(printf '%s\n' "$PROBE" | sed -n 's/^gpumem=//p' | head -n1)"
        SPOT="$(printf '%s\n' "$PROBE" | sed -n 's/^spot=//p' | head -n1)"
        log "  health=${HEALTH:-?} running=${RUNNING:-?} gpumem=${GPUMEM:-?}MiB elapsed=${ELAPSED}s"

        if [[ -n "$SPOT" && "$SPOT" != "null" && "$SPOT" == *action* ]]; then
            bail_on_spot
        fi
        # 容器退出 = 立刻失败，不要把 40 分钟超时等完（那是 $33 的等待）
        if [[ "$RUNNING" == "false" ]]; then
            capture_failure "容器已退出（docker inspect State.Running=false）"
            status_update "status=failed" "failure_reason=容器已退出，详见 server.log" "ended_at=$(now_iso)"
            exit 1
        fi
        if [[ "$HEALTH" == "200" ]]; then
            if [[ -n "$GPUMEM" && "$GPUMEM" == "0" ]]; then
                capture_failure "health=200 但 8 张卡显存合计 0 MiB：HTTP 空壳，不是就绪"
                status_update "status=failed" \
                    "failure_reason=health=200 但 GPU 显存为 0，服务是空壳（参考 --enable-dp-attention 那次失败）" \
                    "ended_at=$(now_iso)"
                exit 1
            fi
            READY=1
            TIME_TO_HEALTHY="$(( $(date -u +%s) - LAUNCH_EPOCH ))"
            # --skip-launch 时脚本不是启动者，用容器自己的 StartedAt 算才是真的
            # 冷启动耗时（这是用来验证「JIT 缓存挂载有没有省下时间」的那个数）。
            STARTED_AT_BOX="$(printf '%s\n' "$PROBE" | sed -n 's/^started=//p' | head -n1)"
            if [[ "$SKIP_LAUNCH" == "1" && -n "$STARTED_AT_BOX" ]]; then
                BOX_EPOCH="$(date -u -d "$STARTED_AT_BOX" +%s 2>/dev/null || echo "")"
                if [[ -n "$BOX_EPOCH" ]]; then
                    TIME_TO_HEALTHY="$(( $(date -u +%s) - BOX_EPOCH ))"
                fi
            fi
            log "就绪：health=200，GPU 显存合计 ${GPUMEM} MiB，耗时 ${TIME_TO_HEALTHY}s"
            break
        fi
        sleep "$POLL_INTERVAL_SEC"
        ELAPSED=$((ELAPSED + POLL_INTERVAL_SEC))
    done
    if [[ "$READY" != "1" ]]; then
        capture_failure "等就绪超时 ${READY_TIMEOUT_SEC}s，health 始终不是 200"
        status_update "status=failed" "failure_reason=等就绪超时 ${READY_TIMEOUT_SEC}s" "ended_at=$(now_iso)"
        exit "$EXIT_READY_TIMEOUT"
    fi
    status_update "time_to_healthy_sec=$TIME_TO_HEALTHY"
fi

# =============================================================================
# Step d) 跑两条 bench
# driver 甩到后台，SSM 命令秒回；然后按 done 标记轮询。每条 bench 一跑完就传 S3。
# bench_serving 是**追加**写 --output-file 的，所以每次跑前先删掉旧文件，
# 免得把上一次的记录也算进来（collect-results.sh 取最后一条，但别给它添乱）。
# =============================================================================
BENCH_DONE=0
CUSTOM_RC=""
OFFICIAL_RC=""
if [[ "$RECORD_ONLY" == "1" ]]; then
log "--record-only：不碰机器，直接归档 S3 上已有的产物"
else
log "启动 bench driver（后台）"
DETACH_PREFIX="setsid nohup"
DETACH_SUFFIX="</dev/null >$(box_dir)/driver.log 2>&1 &"
if [[ "$DRY_RUN" == "1" ]]; then
    # dry-run 下同步执行，测试才好断言 docker exec 的参数与 s3 cp 的发生
    DETACH_PREFIX=""
    DETACH_SUFFIX=">$(box_dir)/driver.log 2>&1"
fi

FRESH_CONTAINER=1
[[ "$SKIP_LAUNCH" == "1" ]] && FRESH_CONTAINER=0

ssm_exec bench "$(cat <<EOS
set -u
D=$(box_dir)
mkdir -p "\$D"
# 清掉上一轮留下的标记，否则轮询会读到**上一次**的 rc/all.done 然后秒判结束。
# 这个坑在这台机器上真的踩到了一次：14:49 那次失败留下的 all.done 让 15:18 这次
# 刚起的 driver 被判成「已经跑完且失败」，而实际上 bench 正在跑。
rm -f "\$D/all.done" "\$D/all.attempted"
if [ "$FRESH_CONTAINER" = "1" ]; then
  # 换了容器，之前那个容器产出的结果一律作废，不许混进这一轮
  rm -f "\$D"/bench_custom.done "\$D"/bench_custom.rc "\$D"/bench_custom.jsonl \
        "\$D"/bench_official.done "\$D"/bench_official.rc "\$D"/bench_official.jsonl
fi
cat > "\$D/run-benches.sh" <<'DRIVER'
set -u
D=$(box_dir)
S3=$(s3_prefix)
run_bench() {
  name=\$1; inp=\$2; out=\$3
  # 只有「标记在 + 结果文件也在」才算真的跑过，可以跳过（被抢占后续跑用得上）。
  # 光看标记会把上一轮的空壳当成结果。
  if [ -f "\$D/\$name.done" ] && [ -s "\$D/\$name.jsonl" ]; then
    echo "skip \$name (已完成且有结果)"; return 0
  fi
  rm -f "\$D/\$name.jsonl"
  echo "\$(date -u +%FT%TZ) START \$name" >> "\$D/timing.log"
  docker exec $CONTAINER python3 -m sglang.bench_serving \
    --backend sglang --dataset-name random \
    --random-input "\$inp" --random-output "\$out" \
    --num-prompts $BENCH_NUM_PROMPTS --max-concurrency $BENCH_CONCURRENCY \
    --output-file "\$D/\$name.jsonl" > "\$D/\$name.log" 2>&1
  rc=\$?
  echo "\$(date -u +%FT%TZ) END \$name rc=\$rc" >> "\$D/timing.log"
  echo "\$rc" > "\$D/\$name.rc"
  [ "\$rc" = 0 ] && touch "\$D/\$name.done"
  docker logs $CONTAINER > "\$D/server.log" 2>&1 || true
  aws s3 cp "\$D/" "\$S3/" --recursive --region $REGION >> "\$D/s3.log" 2>&1 || true
  return \$rc
}
run_bench bench_custom $CUSTOM_INPUT $CUSTOM_OUTPUT
run_bench bench_official $OFFICIAL_INPUT $OFFICIAL_OUTPUT
echo "\$(date -u +%FT%TZ) ALLDONE" >> "\$D/timing.log"
# all.attempted = driver 跑完了（不管成没成），all.done = 两条 bench 都成功。
# 这两个必须分开：第一版把 all.done 无条件 touch 掉，结果 bench 崩了也被判成
# completed —— 在这台机器上实测踩到过一次，别再合并回去。
touch "\$D/all.attempted"
if [ -f "\$D/bench_custom.done" ] && [ -f "\$D/bench_official.done" ]; then
  touch "\$D/all.done"
fi
DRIVER
$DETACH_PREFIX bash "\$D/run-benches.sh" $DETACH_SUFFIX
exit 0
EOS
)" || { capture_failure "bench driver 启动失败"; status_update "status=failed" "failure_reason=bench driver 启动失败" "ended_at=$(now_iso)"; exit 1; }

log "轮询 bench 完成标记（每 ${POLL_INTERVAL_SEC}s，最多 ${BENCH_TIMEOUT_SEC}s）"
ELAPSED=0
while (( ELAPSED <= BENCH_TIMEOUT_SEC )); do
    PROBE="$(ssm_exec bench-probe "$(cat <<EOS
set -u
D=$(box_dir)
echo "alldone=\$([ -f "\$D/all.done" ] && echo 1 || echo 0)"
echo "attempted=\$([ -f "\$D/all.attempted" ] && echo 1 || echo 0)"
echo "customrc=\$(cat "\$D/bench_custom.rc" 2>/dev/null)"
echo "officialrc=\$(cat "\$D/bench_official.rc" 2>/dev/null)"
echo "running=\$(docker inspect -f '{{.State.Running}}' $CONTAINER 2>/dev/null)"
TOKEN=\$(curl -m 3 -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)
echo "spot=\$(curl -m 3 -s -H "X-aws-ec2-metadata-token: \$TOKEN" http://169.254.169.254/latest/meta-data/spot/instance-action 2>/dev/null)"
tail -n 3 "\$D/timing.log" 2>/dev/null | sed 's/^/timing: /'
exit 0
EOS
)" || true)"
    ALLDONE="$(printf '%s\n' "$PROBE" | sed -n 's/^alldone=//p' | head -n1)"
    ATTEMPTED="$(printf '%s\n' "$PROBE" | sed -n 's/^attempted=//p' | head -n1)"
    CUSTOM_RC="$(printf '%s\n' "$PROBE" | sed -n 's/^customrc=//p' | head -n1)"
    OFFICIAL_RC="$(printf '%s\n' "$PROBE" | sed -n 's/^officialrc=//p' | head -n1)"
    SPOT="$(printf '%s\n' "$PROBE" | sed -n 's/^spot=//p' | head -n1)"
    log "  alldone=${ALLDONE:-0} custom_rc=${CUSTOM_RC:-...} official_rc=${OFFICIAL_RC:-...} elapsed=${ELAPSED}s"
    if [[ -n "$SPOT" && "$SPOT" != "null" && "$SPOT" == *action* ]]; then
        bail_on_spot
    fi
    # 等 driver 自己跑完（all.attempted），成没成看下面的 rc。不要一看到 all.done
    # 就当成功 —— all.done 只有两条都成功才会出现。
    if [[ "$ATTEMPTED" == "1" || "$ALLDONE" == "1" ]]; then
        BENCH_DONE=1
        break
    fi
    sleep "$POLL_INTERVAL_SEC"
    ELAPSED=$((ELAPSED + POLL_INTERVAL_SEC))
done
fi   # RECORD_ONLY

BENCH_FAILURE=""
if [[ "$RECORD_ONLY" == "1" ]]; then
    : # rc 从下面拉回来的产物里读，这里先不判
elif [[ "$BENCH_DONE" != "1" ]]; then
    BENCH_FAILURE="bench 超时 ${BENCH_TIMEOUT_SEC}s，driver 没有跑完"
elif [[ "${CUSTOM_RC:-1}" != "0" || "${OFFICIAL_RC:-1}" != "0" ]]; then
    BENCH_FAILURE="bench 非零退出（custom rc=${CUSTOM_RC:-?}, official rc=${OFFICIAL_RC:-?}）"
fi
# 无论成败都要把现场和已经跑出来的那部分产物收干净：机器随时可能被回收，
# 「跑挂了但留下了一条有效结果」和「什么都没留下」是两回事。
if [[ -n "$BENCH_FAILURE" ]]; then
    capture_failure "$BENCH_FAILURE"
fi

# =============================================================================
# Step e) 把产物拉回仓库，归一化指标写进状态文件
# 键名归一化不在这里重写：读 JSONL 取最后一条 + median_tpot_ms 才是 P50 这套逻辑
# 全仓库只有 collect-results.sh 一份，这里只把它认的那几个键取出来。
# =============================================================================
mkdir -p "$OUT_DIR/$CONFIG"
log "从 S3 拉回产物 -> $OUT_DIR/$CONFIG/"
if [[ "$DRY_RUN" == "1" ]]; then
    dry_log "aws s3 cp $(s3_prefix)/ $OUT_DIR/$CONFIG/ --recursive --region $REGION"
    aws s3 cp "$(s3_prefix)/" "$OUT_DIR/$CONFIG/" --recursive --region "$REGION" || true
    # 假 aws 不会真的搬文件，这里把机上目录直接拷过来，模拟「传上去再拉回来」这趟
    # 往返，好让归一化那一段在测试里也真的被执行到。
    cp -a "$(box_dir)/." "$OUT_DIR/$CONFIG/" 2>/dev/null || true
else
    aws s3 cp "$(s3_prefix)/" "$OUT_DIR/$CONFIG/" --recursive --region "$REGION" --only-show-errors || true
fi

extract_metrics() {
    # 用 collect-results.sh 里那套键名（median_* 才是 P50）把一条 JSONL 归一化成
    # 一行紧凑 JSON。取最后一条记录，因为 bench_serving 是追加写的。
    local file="$1"
    [[ -f "$file" ]] || { echo ""; return 0; }
    python3 - "$file" <<'PYEOF'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    raw = fh.read().strip()
records = []
if raw:
    try:
        obj = json.loads(raw)
        records = [obj] if isinstance(obj, dict) else [o for o in obj if isinstance(o, dict)]
    except json.JSONDecodeError:
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(rec, dict):
                records.append(rec)
if not records:
    print("")
    raise SystemExit(0)
r = records[-1]


def pick(*keys):
    for key in keys:
        v = r.get(key)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            return float(v)
    return None


out = {
    "median_tpot_ms": pick("median_tpot_ms", "tpot_p50_ms"),
    "p95_tpot_ms": pick("p95_tpot_ms", "tpot_p95_ms"),
    "median_ttft_ms": pick("median_ttft_ms", "ttft_p50_ms"),
    "p95_ttft_ms": pick("p95_ttft_ms", "ttft_p95_ms"),
    "median_e2e_latency_ms": pick("median_e2e_latency_ms", "e2e_latency_p50_ms"),
    "output_throughput": pick("output_throughput", "output_throughput_tok_per_s"),
    "accept_length": pick("accept_length"),
    "completed": pick("completed"),
    "input_tokens": pick("random_input_len", "input_tokens"),
    "output_tokens": pick("random_output_len", "output_tokens"),
}
print(json.dumps(out, ensure_ascii=False))
PYEOF
}

CUSTOM_JSON="$(extract_metrics "$OUT_DIR/$CONFIG/bench_custom.jsonl")"
OFFICIAL_JSON="$(extract_metrics "$OUT_DIR/$CONFIG/bench_official.jsonl")"

# --record-only 时 rc 只能从产物里读
if [[ "$RECORD_ONLY" == "1" ]]; then
    CUSTOM_RC="$(cat "$OUT_DIR/$CONFIG/bench_custom.rc" 2>/dev/null || echo "")"
    OFFICIAL_RC="$(cat "$OUT_DIR/$CONFIG/bench_official.rc" 2>/dev/null || echo "")"
    if [[ "${CUSTOM_RC:-1}" != "0" || "${OFFICIAL_RC:-1}" != "0" ]]; then
        BENCH_FAILURE="bench 非零退出（custom rc=${CUSTOM_RC:-未跑}, official rc=${OFFICIAL_RC:-未跑}）"
    fi
fi

# 失败原因必须是**从 server.log 里读出来的那一行**，不是「bench 挂了」这种转述。
# 机器一被回收，这行字就是唯一能解释「为什么这个配置不行」的东西。
if [[ -n "$BENCH_FAILURE" && -f "$OUT_DIR/$CONFIG/server.log" ]]; then
    FATAL_LINE="$(grep -m1 -oE "CUDA error \([^)]*\): [a-z ]+|AssertionError: [^\"]{0,120}|torch\.OutOfMemoryError[^\"]{0,80}|CUDA out of memory[^\"]{0,80}|NotImplementedError: [^\"]{0,120}" \
        "$OUT_DIR/$CONFIG/server.log" 2>/dev/null | head -n1 || true)"
    if [[ -n "$FATAL_LINE" ]]; then
        BENCH_FAILURE="$BENCH_FAILURE；server.log 里的致命错误: $FATAL_LINE"
    fi
fi
ENDED_AT="$(now_iso)"
EXTRA_KV=()
if [[ "$RECORD_ONLY" == "1" ]]; then
    # 时间戳全部来自产物：container_started_at.txt 是启动那一刻写的，
    # timing.log 最后一行是 driver 收尾那一刻写的。
    RSTART="$(head -n1 "$OUT_DIR/$CONFIG/container_started_at.txt" 2>/dev/null || true)"
    REND="$(awk 'NF{last=$1} END{print last}' "$OUT_DIR/$CONFIG/timing.log" 2>/dev/null || true)"
    [[ -n "$RSTART" ]] && EXTRA_KV+=("started_at=$RSTART")
    [[ -n "$REND" ]] && ENDED_AT="$REND"
fi
[[ -n "$CONFIG_NOTE" ]] && EXTRA_KV+=("note=$CONFIG_NOTE")
if [[ -n "$BENCH_FAILURE" ]]; then
    status_update "status=failed" "ended_at=$ENDED_AT" "failure_reason=$BENCH_FAILURE" \
        "custom_json=$CUSTOM_JSON" "official_json=$OFFICIAL_JSON" "${EXTRA_KV[@]}"
else
    status_update "status=completed" "ended_at=$ENDED_AT" "failure_reason=" \
        "custom_json=$CUSTOM_JSON" "official_json=$OFFICIAL_JSON" "${EXTRA_KV[@]}"
fi

log "配置 $CONFIG 的产物："
log "  机上 : $(box_dir)/"
log "  S3   : $(s3_prefix)/"
log "  仓库 : $OUT_DIR/$CONFIG/"
log "  状态 : $STATUS_FILE"
if [[ -n "$BENCH_FAILURE" ]]; then
    log "结果: 失败 —— $BENCH_FAILURE"
    log "已经跑出来的那部分结果仍然落在上面的目录与 S3 里，别重跑就丢了"
    exit 1
fi
log "结果: 两条 bench 都完成"
log "下一步: 按 README 12.9 A1-A9 写总结（这是 run-staged.sh 的总结闸门要求的停顿点）"
exit 0
