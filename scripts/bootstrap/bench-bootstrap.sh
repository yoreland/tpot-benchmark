#!/usr/bin/env bash
# =============================================================================
# TPOT Benchmark 自驱动 EC2 引导脚本 (bench-bootstrap)
# 用途：作为 EC2 user-data 在实例内部自动执行整条 benchmark 流水线，
#       全程不需要任何交互式会话（不需要 SSH，不需要 kubectl，不需要人盯着）。
#
# 为什么存在：上一次裸 EC2 启动把 benchmark 跑在一个交互式会话里，
#   - 没有 user-data          -> 会话挂掉后实例上什么都不会发生
#   - 没有 IAM 实例配置文件   -> 没有 SSM，进不去机器
#   - 私钥随会话消失          -> SSH 也进不去
#   - 什么都没往盘外持久化    -> 13h14m / 约 $353 花完后 results/ 依然是空的
#   - 30.4 TB 本地 NVMe 一块没挂 -> 148 GiB 权重写进 200 GB 小根盘，写满，重下一次
#   - 没有自终止              -> 没人关机就一直烧钱
# 本脚本逐条修掉上面每一项。
#
# 设计约定：
#   1) 所有可调项都来自 launch-bench-ec2.sh 渲染在脚本正文之上的「环境前言」
#      （export VAR=...），因此同一个文件可以在本地手工设置变量后直接测试。
#   2) DRY_RUN=1 时，真正不可逆的操作（mdadm --create / mkfs / docker data-root
#      迁移 / terminate-instances / shutdown）只记录不执行：命令行会写入
#      $DRY_RUN_LOG。其余控制流（设备发现、容量校验、S3 同步、docker run、
#      轮询、后台 loop、状态机）全部照常执行，所以 tests/ 可以在没有 GPU、
#      没有 NVMe 的沙箱里用 PATH stub 真实地跑一遍这份流程。
#   3) 任何阶段变化都写入 $STATUS_FILE，并由 streamer 持续同步到 S3，
#      所以「跑到哪一步挂的」永远可以从盘外看到。
#
# 注意：沙箱/实例默认 AWS_REGION 可能不是目标 Region，所有 aws 调用显式传 --region。
# =============================================================================
set -Eeuo pipefail   # -E: 让 ERR trap 在函数内部也生效

# =============================================================================
# 可配置参数（默认值；launch-bench-ec2.sh 渲染的前言会覆盖它们）
# =============================================================================
# --- 运行标识 ---
RUN_ID="${RUN_ID:-local-$(date -u '+%Y%m%d-%H%M%S')}"
STAGE="${STAGE:-full}"                     # plumbing | gpu-smoke | full
REGION="${REGION:-us-east-2}"
RESULTS_BUCKET="${RESULTS_BUCKET:-}"
PROJECT_TAG="${PROJECT_TAG:-tpot-benchmark}"
CW_NAMESPACE="${CW_NAMESPACE:-TpotBench}"

# --- 目录布局 ---
LOG_DIR="${LOG_DIR:-/var/log/tpot-bench}"
NVME_MOUNT="${NVME_MOUNT:-/mnt/nvme}"
RESULTS_DIR="${RESULTS_DIR:-$NVME_MOUNT/results}"
HF_CACHE_DIR="${HF_CACHE_DIR:-$NVME_MOUNT/hf-cache}"
MODEL_ROOT="${MODEL_ROOT:-$NVME_MOUNT/models}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-$NVME_MOUNT/docker}"
MOVE_DOCKER_DATA_ROOT="${MOVE_DOCKER_DATA_ROOT:-true}"

# --- 本地 NVMe / RAID0 ---
RAID_DEVICE="${RAID_DEVICE:-/dev/md0}"
INSTANCE_STORE_MODEL_RE="${INSTANCE_STORE_MODEL_RE:-Amazon EC2 NVMe Instance Storage}"
REQUIRE_INSTANCE_STORE="${REQUIRE_INSTANCE_STORE:-true}"

# --- 容量护栏（下载前就必须过关）---
CHECKPOINT_GB="${CHECKPOINT_GB:-160}"      # 权重体积（十进制 GB），preflight 已实测
STORAGE_MARGIN_GB="${STORAGE_MARGIN_GB:-80}"  # 镜像约 13 GB + 解压/临时/日志余量

# --- 模型与镜像 ---
MODEL_NAME="${MODEL_NAME:-deepseek-ai/DeepSeek-V4-Flash}"
CHECKPOINT_S3_URI="${CHECKPOINT_S3_URI:-}"    # 设置则优先用同 Region S3 镜像
FETCH_CHECKPOINT="${FETCH_CHECKPOINT:-true}"
SGLANG_IMAGE="${SGLANG_IMAGE:-lmsysorg/sglang:latest}"
SGLANG_LAUNCH_CMD="${SGLANG_LAUNCH_CMD:-python3 -m sglang.launch_server}"
CONTAINER_NAME="${CONTAINER_NAME:-sglang-server}"

# --- 推理服务参数（recipe 由前言注入，脚本里不写死任何 recipe）---
RUN_SERVER="${RUN_SERVER:-true}"
TP_SIZE="${TP_SIZE:-8}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"
SERVER_HOST="${SERVER_HOST:-0.0.0.0}"
SERVER_PORT="${SERVER_PORT:-30000}"
SGLANG_EXTRA_ARGS="${SGLANG_EXTRA_ARGS:-}"    # 例如 EAGLE / DSPARK / DP-attention
SGLANG_SERVE_ARGS="${SGLANG_SERVE_ARGS:-}"    # 非空则完全覆盖上面的组装结果
SHM_SIZE="${SHM_SIZE:-64g}"
SERVER_READY_TIMEOUT="${SERVER_READY_TIMEOUT:-2400}"   # cookbook: 首次冷启动 10-15 分钟
SERVER_POLL_INTERVAL="${SERVER_POLL_INTERVAL:-15}"

# --- benchmark 负载（README 6.1 的参数，不得改动）---
INPUT_TOKENS="${INPUT_TOKENS:-40000}"
OUTPUT_TOKENS="${OUTPUT_TOKENS:-1500}"
OFFICIAL_INPUT_TOKENS="${OFFICIAL_INPUT_TOKENS:-30000}"
OFFICIAL_OUTPUT_TOKENS="${OFFICIAL_OUTPUT_TOKENS:-4096}"
NUM_PROMPTS="${NUM_PROMPTS:-50}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"

# --- 盘外持久化 / 遥测 / 看门狗 ---
STREAM_INTERVAL_SECONDS="${STREAM_INTERVAL_SECONDS:-30}"
GPU_SAMPLE_INTERVAL_SECONDS="${GPU_SAMPLE_INTERVAL_SECONDS:-30}"
SPOT_POLL_INTERVAL_SECONDS="${SPOT_POLL_INTERVAL_SECONDS:-5}"
MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-240}"      # 硬性墙上时钟上限
SELF_TERMINATE="${SELF_TERMINATE:-true}"
IMDS_BASE="${IMDS_BASE:-http://169.254.169.254}"

# --- 测试/演练开关 ---
DRY_RUN="${DRY_RUN:-0}"

# =============================================================================
# 命令行参数解析（真实 user-data 不带参数，这里只为本地手工调试提供入口）
# =============================================================================
usage() {
    cat <<EOF
用法: $0 [选项]

EC2 user-data 引导脚本：挂载本地 NVMe -> 容量护栏 -> 持续同步日志/结果到 S3
-> GPU 遥测 -> 拉取权重 -> 起 SGLang -> 跑 bench_serving -> 自终止。
所有可调项都通过环境变量注入（见脚本头部配置区）。

选项:
  --stage STAGE     plumbing | gpu-smoke | full (默认: $STAGE)
  --run-id ID       运行标识，决定 S3 前缀与 CloudWatch 维度 (默认: 自动生成)
  --dry-run         不可逆操作只记录不执行（mdadm/mkfs/docker 迁移/终止实例）
  --help            显示帮助信息

示例:
  # 在本地用 tests/stubs 里的假二进制演练整条流程
  RUN_ID=t1 RESULTS_BUCKET=b LOG_DIR=/tmp/l NVME_MOUNT=/tmp/n $0 --dry-run
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE="$2"; shift 2 ;;
        --run-id) RUN_ID="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help) usage ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

# =============================================================================
# 内部常量
# =============================================================================
LOG_FILE="$LOG_DIR/bootstrap.log"
STATUS_FILE="$LOG_DIR/status.json"
GPU_CSV="$LOG_DIR/gpu.csv"
SERVER_LOG="$LOG_DIR/sglang-server.log"
DRY_RUN_LOG="${DRY_RUN_LOG:-$LOG_DIR/dry-run-commands.log}"
TERMINATE_FLAG="$LOG_DIR/.terminate-requested"
TERMINAL_PHASE_FILE="$LOG_DIR/.terminal-phase"
S3_RUN_PREFIX="runs/$RUN_ID"
MAIN_PID=$$
START_EPOCH="$(date +%s)"
PHASE="starting"
STATUS_MESSAGE="bootstrap 已启动"
STATUS_EXIT_CODE="null"
PERSISTENCE_READY=0
STREAMER_PID=""
GPU_SAMPLER_PID=""
SPOT_WATCHER_PID=""
WATCHDOG_PID=""
SERVER_TAIL_PID=""
INSTANCE_ID=""
NVME_DEVICES=()
NVME_TARGET=""
CUSTOM_PASS=false
OFFICIAL_PASS=false

# =============================================================================
# 工具函数
# =============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

warn() {
    log "[警告] $*"
}

section() {
    echo ""
    echo "# ============================================================================="
    echo "# $*"
    echo "# ============================================================================="
}

# 不可逆操作统一走这里：DRY_RUN=1 只记录命令行，不执行
run_destructive() {
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY-RUN] 仅记录不执行: $*"
        printf '%s\n' "$*" >>"$DRY_RUN_LOG"
        return 0
    fi
    "$@"
}

json_escape() {
    local s="${1//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    printf '%s' "$s"
}

# 终态由后台 worker（Spot 监听 / 看门狗）标记；主流程之后的任何 set_phase 都不得
# 把它降级回去，否则外部只会看到「卡在下载」而不是「被 Spot 回收」
mark_terminal_phase() {
    printf '%s\n' "$1" >"$TERMINAL_PHASE_FILE"
}

read_terminal_phase() {
    if [[ -s "$TERMINAL_PHASE_FILE" ]]; then
        head -n1 "$TERMINAL_PHASE_FILE"
    fi
}

write_status() {
    # 临时文件带 BASHPID：主 shell 与多个后台 worker 会并发写，共用一个 .tmp 会互相
    # 抢掉对方的文件，导致 mv 失败并触发 ERR trap（曾经真的把整轮跑挂掉过）
    local tmp="$STATUS_FILE.$BASHPID.tmp" terminal
    terminal="$(read_terminal_phase)"
    if [[ -n "$terminal" && "$PHASE" != "$terminal" ]]; then
        PHASE="$terminal"
    fi
    cat >"$tmp" <<EOF
{
  "run_id": "$(json_escape "$RUN_ID")",
  "stage": "$(json_escape "$STAGE")",
  "phase": "$(json_escape "$PHASE")",
  "exit_code": $STATUS_EXIT_CODE,
  "message": "$(json_escape "$STATUS_MESSAGE")",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "elapsed_seconds": $(( $(date +%s) - START_EPOCH )),
  "instance_id": "$(json_escape "$INSTANCE_ID")",
  "instance_type": "$(json_escape "${INSTANCE_TYPE:-unknown}")",
  "model": "$(json_escape "$MODEL_NAME")",
  "dry_run": $([[ "$DRY_RUN" == "1" ]] && echo true || echo false)
}
EOF
    mv -f "$tmp" "$STATUS_FILE" 2>/dev/null || true
}

# 每一次阶段推进都落盘，外部观察者据此判断「跑到哪一步停的」
set_phase() {
    PHASE="$1"
    STATUS_MESSAGE="${2:-$1}"
    write_status
    log ">>> 阶段: $PHASE — $STATUS_MESSAGE"
}

current_phase() {
    sed -n 's/.*"phase": "\([^"]*\)".*/\1/p' "$STATUS_FILE" 2>/dev/null | head -n1
}

phase_code() {
    case "$1" in
        starting)          echo 10 ;;
        storage)           echo 20 ;;
        storage_guard)     echo 25 ;;
        streaming)         echo 30 ;;
        telemetry)         echo 35 ;;
        fetching_model)    echo 40 ;;
        starting_server)   echo 50 ;;
        server_ready)      echo 55 ;;
        benchmarking)      echo 60 ;;
        finalizing)        echo 70 ;;
        completed)         echo 100 ;;
        spot_interrupted)  echo 90 ;;
        deadline_exceeded) echo 91 ;;
        failed)            echo 99 ;;
        *)                 echo 0 ;;
    esac
}

# IMDSv2：先 PUT 拿 token，再带 X-aws-ec2-metadata-token 取值
imds_token() {
    curl -sS -X PUT "$IMDS_BASE/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        --max-time 3 2>/dev/null || true
}

imds_get() {
    local path="$1" token
    token="$(imds_token)"
    if [[ -z "$token" ]]; then
        return 1
    fi
    curl -sS -H "X-aws-ec2-metadata-token: $token" \
        "$IMDS_BASE/latest/meta-data/$path" --max-time 3 2>/dev/null || return 1
}

# 浮点比较 a > b（awk 比 bash 可靠，实例上不一定有 bc）
fgt() {
    awk -v a="$1" -v b="$2" 'BEGIN{exit !(a > b)}'
}

bytes_to_gb() {
    awk -v b="$1" 'BEGIN{printf "%.1f", b / 1000000000}'
}

avail_bytes() {
    local kb
    kb="$(df --output=avail -k "$1" 2>/dev/null | tail -n1 | tr -dc '0-9')"
    if [[ -z "$kb" ]]; then
        echo 0
    else
        echo $(( kb * 1024 ))
    fi
}

# =============================================================================
# Step a) 失败可见化：日志重定向 + 状态文件 + ERR/EXIT/TERM trap
# 上一次失败最贵的部分不是钱，是「什么信息都没留下」
# =============================================================================
init_logging() {
    mkdir -p "$LOG_DIR" "$(dirname "$DRY_RUN_LOG")"
    : >"$DRY_RUN_LOG"
    rm -f "$TERMINAL_PHASE_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1

    trap 'on_error $? $LINENO' ERR
    trap 'on_exit $?' EXIT
    trap 'on_term' TERM INT

    section "Step a) 初始化日志与状态机"
    log "RUN_ID           : $RUN_ID"
    log "STAGE            : $STAGE"
    log "REGION           : $REGION"
    log "RESULTS_BUCKET   : ${RESULTS_BUCKET:-<未设置>}"
    log "LOG_DIR          : $LOG_DIR"
    log "NVME_MOUNT       : $NVME_MOUNT"
    log "MODEL_NAME       : $MODEL_NAME"
    log "MAX_RUNTIME_MIN  : $MAX_RUNTIME_MINUTES"
    log "DRY_RUN          : $DRY_RUN"

    if INSTANCE_ID="$(imds_get instance-id)" && [[ -n "$INSTANCE_ID" ]]; then
        log "INSTANCE_ID      : $INSTANCE_ID"
        INSTANCE_TYPE="$(imds_get instance-type || echo unknown)"
        log "INSTANCE_TYPE    : ${INSTANCE_TYPE:-unknown}"
    else
        INSTANCE_ID=""
        warn "无法通过 IMDSv2 获取 instance-id（本地演练属正常），自终止将退化为 shutdown"
    fi

    set_phase starting "bootstrap 启动，日志 -> $LOG_FILE"
}

# shellcheck disable=SC2329  # 由 trap ... ERR 间接调用
on_error() {
    local code="$1" line="$2"
    STATUS_EXIT_CODE="$code"
    PHASE="failed"
    STATUS_MESSAGE="第 $line 行命令失败（退出码 $code），阶段=$(current_phase)"
    write_status
    log "[错误] $STATUS_MESSAGE"
}

# shellcheck disable=SC2329  # 由 trap ... TERM INT 间接调用
on_term() {
    log "收到终止信号，进入收尾流程（当前阶段 $(current_phase)）"
    exit 0
}

# shellcheck disable=SC2329  # 由 trap ... EXIT 间接调用
on_exit() {
    local code="$1" recorded
    trap - EXIT ERR TERM INT
    section "收尾: 退出码 $code"
    stop_background_workers
    # 后台 worker 改不到主 shell 的变量，终态以标记文件为准，
    # 否则这里会把 spot_interrupted / deadline_exceeded 覆盖回去
    recorded="$(read_terminal_phase)"
    STATUS_EXIT_CODE="$code"
    STATUS_MESSAGE="进程退出，退出码 $code"
    if [[ -n "$recorded" ]]; then
        PHASE="$recorded"
        case "$recorded" in
            spot_interrupted)  STATUS_MESSAGE="Spot 中断，已完成最终同步（退出码 $code）" ;;
            deadline_exceeded) STATUS_MESSAGE="超过 MAX_RUNTIME_MINUTES=${MAX_RUNTIME_MINUTES} 上限，看门狗已收尾（退出码 $code）" ;;
        esac
    elif [[ "$PHASE" != "completed" && "$code" != "0" ]]; then
        PHASE="failed"
    fi
    write_status
    persist_final
    terminate_self "退出码 $code"
    log "收尾完成（退出码 $code）"
}

# shellcheck disable=SC2329  # 由 trap EXIT 调用的 on_exit 间接调用
stop_background_workers() {
    local pid
    for pid in "$STREAMER_PID" "$GPU_SAMPLER_PID" "$SPOT_WATCHER_PID" "$WATCHDOG_PID" "$SERVER_TAIL_PID"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            log "已回收后台进程 PID=$pid"
        fi
    done
    STREAMER_PID=""; GPU_SAMPLER_PID=""; SPOT_WATCHER_PID=""; WATCHDOG_PID=""; SERVER_TAIL_PID=""
}

# 最后一次持久化：streamer 已就绪就整体 sync；还没就绪（例如容量护栏直接拦下）
# 就用单次 s3 cp 把 bootstrap.log 与 status.json 传上去，保证故障永远可见
# shellcheck disable=SC2329  # 由 trap EXIT 调用的 on_exit 间接调用
persist_final() {
    if [[ -z "$RESULTS_BUCKET" ]]; then
        warn "RESULTS_BUCKET 未设置，跳过盘外持久化"
        return 0
    fi
    if [[ "$PERSISTENCE_READY" == "1" ]]; then
        sync_to_s3 "最终同步"
    else
        log "streamer 尚未启动，改用单次 s3 cp 上传故障报告"
        aws s3 cp "$LOG_FILE" "s3://$RESULTS_BUCKET/$S3_RUN_PREFIX/logs/bootstrap.log" \
            --region "$REGION" --only-show-errors 2>/dev/null || warn "故障报告 bootstrap.log 上传失败"
        aws s3 cp "$STATUS_FILE" "s3://$RESULTS_BUCKET/$S3_RUN_PREFIX/logs/status.json" \
            --region "$REGION" --only-show-errors 2>/dev/null || warn "故障报告 status.json 上传失败"
    fi
}

# =============================================================================
# Step b) 本地 NVMe：发现 -> RAID0 -> 格式化 -> 挂载 -> 容量护栏
# 这一步就是上次 $353 的头号根因；README 9.1 早就写了「否则权重会写到小根盘」
# =============================================================================
root_base_device() {
    local src base
    src="$(df --output=source / 2>/dev/null | tail -n1 | tr -d ' ')"
    base="${src#/dev/}"
    if [[ "$base" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$base" =~ ^([a-z]+)[0-9]+$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$base"
    fi
}

discover_instance_store() {
    local root_dev name size model
    root_dev="$(root_base_device)"
    log "EBS 根设备（必须排除）: ${root_dev:-未知}"
    NVME_DEVICES=()

    local listing=""
    if command -v lsblk >/dev/null 2>&1; then
        listing="$(lsblk -dn -o NAME,SIZE,MODEL 2>/dev/null || true)"
    fi
    if [[ -z "$listing" ]] && command -v nvme >/dev/null 2>&1; then
        warn "lsblk 无输出，回退到 nvme list"
        listing="$(nvme list 2>/dev/null | awk '/Instance Storage/ {print $1" - "substr($0, index($0,"Amazon"))}' || true)"
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        read -r name size model <<<"$line"
        [[ -z "$name" ]] && continue
        name="${name#/dev/}"
        if [[ "$name" == "$root_dev" ]]; then
            log "  跳过 $name（EBS 根设备）"
            continue
        fi
        if [[ ! "$model" =~ $INSTANCE_STORE_MODEL_RE ]]; then
            log "  跳过 $name（model='$model' 不是本地实例存储）"
            continue
        fi
        log "  命中 $name ($size, model='$model')"
        NVME_DEVICES+=("/dev/$name")
    done <<<"$listing"

    log "本地实例存储设备数: ${#NVME_DEVICES[@]}"
}

setup_storage() {
    section "Step b) 本地 NVMe 发现 / RAID0 / 挂载"
    set_phase storage "枚举本地实例存储设备"

    # ---- 快速路径：DLAMI 已经将 NVMe 设置好 ----
    # Deep Learning AMI 会自动创建 LVM (vg.01/lv_ephemeral) 并挂载到 /opt/dlami/nvme。
    # awslabs/awsome-distributed-ai 的所有样例都直接使用这个路径，不自己做 RAID0。
    # 如果该路径已挂载且可写，直接用它，不拆不重建。
    local dlami_nvme="/opt/dlami/nvme"
    if mountpoint -q "$dlami_nvme" 2>/dev/null; then
        local avail_gb
        avail_gb="$(df -BG --output=avail "$dlami_nvme" 2>/dev/null | tail -1 | tr -d ' G')"
        if [[ -n "$avail_gb" && "$avail_gb" -gt 10 ]]; then
            log "检测到 DLAMI 已挂载 NVMe 于 $dlami_nvme（可用 ${avail_gb}G），直接使用"
            NVME_MOUNT="$dlami_nvme"
            mkdir -p "$NVME_MOUNT/results" "$NVME_MOUNT/hf-cache" "$NVME_MOUNT/models" "$NVME_MOUNT/tmp"
            RESULTS_DIR="$NVME_MOUNT/results"
            HF_CACHE_DIR="$NVME_MOUNT/hf-cache"
            MODEL_ROOT="$NVME_MOUNT/models"
            export HF_HOME="$HF_CACHE_DIR" HF_HUB_CACHE="$HF_CACHE_DIR" TMPDIR="$NVME_MOUNT/tmp"
            log "HF_HOME=$HF_CACHE_DIR  HF_HUB_CACHE=$HF_CACHE_DIR  TMPDIR=$NVME_MOUNT/tmp"
            assert_free_space "初始"
            return 0
        fi
    fi

    # ---- 常规路径：自行发现并挂载 NVMe ----
    discover_instance_store

    if [[ "${#NVME_DEVICES[@]}" -eq 0 ]]; then
        if [[ "$REQUIRE_INSTANCE_STORE" == "true" ]]; then
            echo "错误: 未发现任何本地实例存储设备；整套设计依赖本地 NVMe，" \
                 "绝不能把 ${CHECKPOINT_GB} GB 权重写到 EBS 根盘（上次就是这么写满的）" >&2
            return 1
        fi
        warn "未发现本地实例存储，按 REQUIRE_INSTANCE_STORE=false 继续使用 $NVME_MOUNT"
        NVME_TARGET=""
    elif [[ "${#NVME_DEVICES[@]}" -eq 1 ]]; then
        NVME_TARGET="${NVME_DEVICES[0]}"
        log "只有 1 块本地盘，直接使用 $NVME_TARGET（不做 RAID0）"
    else
        NVME_TARGET="$RAID_DEVICE"
        log "发现 ${#NVME_DEVICES[@]} 块本地盘，目标 RAID0 -> $RAID_DEVICE（先清理再组建）"
    fi

    mkdir -p "$NVME_MOUNT"
    if [[ -n "$NVME_TARGET" ]]; then
        # Deep Learning AMI / udev / systemd / LVM 可能持有 instance store 设备。
        # 正确拆除顺序：systemd unit -> umount -> LVM remove -> dmsetup -> wipefs -> mkfs
        #
        # DLAMI 的典型堆栈：
        #   opt-dlami-nvme.mount -> /dev/vg.01/lv_ephemeral (LVM) -> /dev/nvme1n1 (PV)
        # 必须从顶往下拆。

        # 1) 停止 systemd mount unit（它是整个依赖链的顶端）
        if command -v systemctl >/dev/null 2>&1; then
            local unit
            # 搜索：按设备名或已知 mount point
            for pattern in "$NVME_TARGET" "/opt/dlami/nvme" "/mnt"; do
                unit="$(systemctl list-units --type=mount --no-legend 2>/dev/null \
                       | awk -v p="$pattern" '$0 ~ p {print $1}' | head -1)"
                [[ -n "$unit" ]] && break
            done
            if [[ -n "$unit" ]]; then
                log "发现 systemd mount unit: $unit，stop + disable 它"
                systemctl stop "$unit" 2>/dev/null || true
                systemctl disable "$unit" 2>/dev/null || true
                sleep 1
            fi
            # 也 stop 可能存在的 lvm2-activation 相关 units
            systemctl stop lvm2-lvmpolld.socket 2>/dev/null || true
            systemctl stop lvm2-monitor.service 2>/dev/null || true
        fi

        # 2) umount 所有残留
        local existing_mount
        existing_mount="$(findmnt -n -o TARGET "$NVME_TARGET" 2>/dev/null || true)"
        if [[ -n "$existing_mount" ]]; then
            log "检测到 $NVME_TARGET 已挂载于 $existing_mount，先 umount"
            run_destructive umount "$NVME_TARGET" || run_destructive umount -l "$NVME_TARGET" || true
        fi
        # 也 umount LVM 路径
        umount /opt/dlami/nvme 2>/dev/null || true
        umount /dev/vg.01/lv_ephemeral 2>/dev/null || true
        for dev in "${NVME_DEVICES[@]}"; do
            local m
            m="$(findmnt -n -o TARGET "$dev" 2>/dev/null || true)"
            if [[ -n "$m" && "$m" != "$NVME_MOUNT" ]]; then
                log "检测到成员盘 $dev 已挂载于 $m，先 umount"
                run_destructive umount "$dev" || run_destructive umount -l "$dev" || true
            fi
        done

        # 杀掉所有仍在使用该设备的进程（blkid probe, lvm scan 等）
        if command -v fuser >/dev/null 2>&1; then
            fuser -mk "$NVME_TARGET" 2>/dev/null || true
            for dev in "${NVME_DEVICES[@]}"; do
                fuser -mk "$dev" 2>/dev/null || true
            done
        fi

        # LVM：DLAMI 在 instance store 上创建了 VG/LV（vg.01/lv_ephemeral）
        # 必须先移除 LV/VG/PV，否则 device-mapper 锁住设备，mkfs 会 "Device busy"
        if command -v lvs >/dev/null 2>&1; then
            local lv_list vg_list
            lv_list="$(lvs --noheadings -o lv_path 2>/dev/null || true)"
            if [[ -n "$lv_list" ]]; then
                log "发现 LVM logical volume(s)，移除:"
                while IFS= read -r lv; do
                    lv="$(echo "$lv" | xargs)"  # trim whitespace
                    [[ -z "$lv" ]] && continue
                    # 先 deactivate，再 remove
                    log "  lvchange -an $lv"
                    lvchange -an "$lv" 2>/dev/null || true
                    log "  lvremove -f $lv"
                    lvremove -f "$lv" 2>/dev/null || true
                done <<<"$lv_list"
            fi
            vg_list="$(vgs --noheadings -o vg_name 2>/dev/null || true)"
            if [[ -n "$vg_list" ]]; then
                while IFS= read -r vg; do
                    vg="$(echo "$vg" | xargs)"
                    [[ -z "$vg" ]] && continue
                    log "  vgchange -an $vg"
                    vgchange -an "$vg" 2>/dev/null || true
                    log "  vgremove -f $vg"
                    vgremove -f "$vg" 2>/dev/null || true
                done <<<"$vg_list"
            fi
            # pvremove on instance store devices
            for dev in "${NVME_DEVICES[@]}"; do
                pvremove -f "$dev" 2>/dev/null || true
            done
        fi

        # 如果 LVM remove 失败，直接用 dmsetup 强制移除所有 device-mapper 映射
        if command -v dmsetup >/dev/null 2>&1; then
            local dm_devs
            dm_devs="$(dmsetup ls 2>/dev/null | awk '{print $1}' || true)"
            if [[ -n "$dm_devs" && "$dm_devs" != "No devices found" ]]; then
                log "dmsetup 强制移除残留 device-mapper 设备:"
                while IFS= read -r dm; do
                    [[ -z "$dm" ]] && continue
                    log "  dmsetup remove -f $dm"
                    dmsetup remove -f "$dm" 2>/dev/null || true
                done <<<"$dm_devs"
            fi
        fi

        # 清残留签名，防止 mdadm auto-assemble 或 LVM 扫描再次抢占
        if command -v wipefs >/dev/null 2>&1; then
            log "wipefs -a $NVME_TARGET"
            wipefs -a "$NVME_TARGET" 2>/dev/null || true
            for dev in "${NVME_DEVICES[@]}"; do
                wipefs -a "$dev" 2>/dev/null || true
            done
        fi

        # 等 udev 事件队列清空
        udevadm settle --timeout=5 2>/dev/null || true

        # 多盘场景：清理完毕后才组建 RAID0
        if [[ "${#NVME_DEVICES[@]}" -gt 1 && "$NVME_TARGET" == "$RAID_DEVICE" ]]; then
            log "组建 RAID0: ${NVME_DEVICES[*]} -> $RAID_DEVICE"
            run_destructive mdadm --create "$RAID_DEVICE" --level=0 \
                --raid-devices="${#NVME_DEVICES[@]}" --force --run "${NVME_DEVICES[@]}"
        fi

        # 最终重试循环：等待内核释放设备（最多 15s）
        local attempts=0
        while [[ $attempts -lt 15 ]]; do
            if command -v mkfs.xfs >/dev/null 2>&1; then
                if run_destructive mkfs.xfs -f "$NVME_TARGET" 2>/dev/null; then break; fi
            else
                if run_destructive mkfs.ext4 -F "$NVME_TARGET" 2>/dev/null; then break; fi
            fi
            attempts=$((attempts + 1))
            log "mkfs 重试 $attempts/15（等待设备释放）"
            sleep 1
        done
        if [[ $attempts -ge 15 ]]; then
            log "[错误] 尝试 15 次后仍无法格式化 $NVME_TARGET"
            log "lsblk 输出:"
            lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL 2>&1 | tee -a "$LOG_FILE" || true
            log "fuser 输出:"
            fuser -v "$NVME_TARGET" 2>&1 | tee -a "$LOG_FILE" || true
            log "mount 输出:"
            mount | grep nvme 2>&1 | tee -a "$LOG_FILE" || true
            return 1
        fi
        run_destructive mount "$NVME_TARGET" "$NVME_MOUNT"
        log "已挂载 $NVME_TARGET -> $NVME_MOUNT"
    fi

    mkdir -p "$RESULTS_DIR" "$HF_CACHE_DIR" "$MODEL_ROOT" "$NVME_MOUNT/tmp"

    # 让所有大文件（HF 缓存、临时文件）都落在 NVMe 上
    export HF_HOME="$HF_CACHE_DIR"
    export HF_HUB_CACHE="$HF_CACHE_DIR"
    export HUGGINGFACE_HUB_CACHE="$HF_CACHE_DIR"
    export TMPDIR="$NVME_MOUNT/tmp"
    log "HF_HOME=$HF_HOME  HF_HUB_CACHE=$HF_HUB_CACHE  TMPDIR=$TMPDIR"
}

# 容量护栏：下载一个字节之前就判死刑，而不是写满盘之后才发现
assert_free_space() {
    local label="$1" required avail avail_gb
    required="$(awk -v a="$CHECKPOINT_GB" -v b="$STORAGE_MARGIN_GB" 'BEGIN{printf "%.1f", a + b}')"
    avail="$(avail_bytes "$NVME_MOUNT")"
    avail_gb="$(bytes_to_gb "$avail")"
    log "容量检查 ($label): $NVME_MOUNT 可用 ${avail_gb} GB，需要 ${required} GB" \
        "(权重 ${CHECKPOINT_GB} GB + 余量 ${STORAGE_MARGIN_GB} GB)"
    if fgt "$required" "$avail_gb"; then
        echo "错误: 容量不足 — $NVME_MOUNT 只有 ${avail_gb} GB，少于所需 ${required} GB。" \
             "在下载任何数据之前中止（上次正是写满 200 GB 根盘后反复重下 151 GB）" >&2
        return 1
    fi
    log "容量检查通过 ($label)"
}

# docker data-root 也要搬到 NVMe，否则约 13 GB 镜像还是躺在根盘上
relocate_docker_data_root() {
    if [[ "$MOVE_DOCKER_DATA_ROOT" != "true" ]]; then
        log "MOVE_DOCKER_DATA_ROOT=false，保持 docker data-root 不变"
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        warn "未找到 docker，跳过 data-root 迁移"
        return 0
    fi
    local current
    current="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo '')"
    if [[ -n "$current" && "$current" == "$DOCKER_DATA_ROOT"* ]]; then
        log "docker data-root 已经是 $current，无需迁移"
        return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY-RUN] 仅记录不执行: 迁移 docker data-root $current -> $DOCKER_DATA_ROOT"
        printf 'docker-data-root-relocate %s -> %s\n' "${current:-unknown}" "$DOCKER_DATA_ROOT" >>"$DRY_RUN_LOG"
        return 0
    fi
    log "迁移 docker data-root: ${current:-unknown} -> $DOCKER_DATA_ROOT（必须在 docker pull 之前）"
    mkdir -p "$DOCKER_DATA_ROOT" /etc/docker
    systemctl stop docker 2>/dev/null || warn "systemctl stop docker 失败，继续尝试"
    if [[ -n "$current" && -d "$current" ]]; then
        cp -a "$current/." "$DOCKER_DATA_ROOT/" 2>/dev/null || warn "复制旧 data-root 内容失败（可忽略）"
    fi
    python3 - "$DOCKER_DATA_ROOT" <<'PYEOF'
import json, os, sys
path = "/etc/docker/daemon.json"
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as fh:
            cfg = json.load(fh)
    except Exception:
        cfg = {}
cfg["data-root"] = sys.argv[1]
with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
PYEOF
    systemctl start docker 2>/dev/null || warn "systemctl start docker 失败"
    log "docker data-root 现为: $(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo unknown)"
}

# =============================================================================
# Step c) 持续盘外持久化：每 STREAM_INTERVAL_SECONDS 把日志与结果 sync 到 S3
# 只要这一步活着，编排会话挂掉也至少留下部分日志与部分结果
# =============================================================================
sync_to_s3() {
    local reason="${1:-周期同步}"
    [[ -z "$RESULTS_BUCKET" ]] && return 0
    aws s3 sync "$LOG_DIR/" "s3://$RESULTS_BUCKET/$S3_RUN_PREFIX/logs/" \
        --region "$REGION" --only-show-errors 2>/dev/null \
        || warn "日志 s3 sync 失败 ($reason)"
    if [[ -d "$RESULTS_DIR" ]]; then
        aws s3 sync "$RESULTS_DIR/" "s3://$RESULTS_BUCKET/$S3_RUN_PREFIX/results/" \
            --region "$REGION" --only-show-errors 2>/dev/null \
            || warn "结果 s3 sync 失败 ($reason)"
    fi
}

put_metric() {
    local name="$1" value="$2" dims="$3"
    aws cloudwatch put-metric-data --region "$REGION" \
        --namespace "$CW_NAMESPACE" --metric-name "$name" \
        --value "$value" --dimensions "$dims" 2>/dev/null \
        || warn "put-metric-data $name 失败"
}

heartbeat() {
    local phase code
    phase="$(current_phase)"
    code="$(phase_code "$phase")"
    put_metric Heartbeat 1 "RunId=$RUN_ID,Stage=$STAGE"
    put_metric PhaseCode "$code" "RunId=$RUN_ID,Phase=$phase"
}

start_streamer() {
    section "Step c) 启动 S3 流式同步 + CloudWatch 心跳"
    if [[ -z "$RESULTS_BUCKET" ]]; then
        warn "RESULTS_BUCKET 未设置，streamer 不启动（这会让本次运行重回「盘外无痕」状态）"
        return 0
    fi
    set_phase streaming "每 ${STREAM_INTERVAL_SECONDS}s 同步到 s3://$RESULTS_BUCKET/$S3_RUN_PREFIX/"
    (
        trap - EXIT ERR TERM INT
        local cycle=0
        while true; do
            cycle=$((cycle + 1))
            sync_to_s3 "周期同步" || true
            heartbeat || true
            # 每轮留一行痕迹：外部只看日志就能判断 streamer 是否还活着
            log "[streamer] 第 ${cycle} 次同步完成（阶段 $(current_phase)）"
            sleep "$STREAM_INTERVAL_SECONDS"
        done
    ) &
    STREAMER_PID=$!
    PERSISTENCE_READY=1
    log "streamer 已启动 PID=$STREAMER_PID，前缀 s3://$RESULTS_BUCKET/$S3_RUN_PREFIX/"
}

# =============================================================================
# Step d) GPU 遥测：上次连一条 GPU 指标都没有，只能靠 CPU/磁盘/网络反推空转
# =============================================================================
start_gpu_sampler() {
    section "Step d) 启动 GPU 遥测采样"
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        warn "未找到 nvidia-smi（plumbing 阶段的 c5d.large 无 GPU 属正常），跳过 GPU 采样"
        return 0
    fi
    if [[ ! -s "$GPU_CSV" ]]; then
        echo "timestamp,index,util_gpu_pct,util_mem_pct,mem_used_mib,mem_total_mib,temp_c" >"$GPU_CSV"
    fi
    (
        trap - EXIT ERR TERM INT
        while true; do
            local ts idx util_gpu util_mem mem_used mem_total temp
            ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            while IFS=, read -r idx util_gpu util_mem mem_used mem_total temp; do
                [[ -z "$idx" ]] && continue
                idx="$(echo "$idx" | tr -d ' ')"
                util_gpu="$(echo "$util_gpu" | tr -d ' ')"
                util_mem="$(echo "$util_mem" | tr -d ' ')"
                mem_used="$(echo "$mem_used" | tr -d ' ')"
                mem_total="$(echo "$mem_total" | tr -d ' ')"
                temp="$(echo "$temp" | tr -d ' ')"
                printf '%s,%s,%s,%s,%s,%s,%s\n' \
                    "$ts" "$idx" "$util_gpu" "$util_mem" "$mem_used" "$mem_total" "$temp" >>"$GPU_CSV"
                put_metric GpuUtilization "$util_gpu" "RunId=$RUN_ID,GpuIndex=$idx" || true
                put_metric GpuMemoryUsedMiB "$mem_used" "RunId=$RUN_ID,GpuIndex=$idx" || true
            done < <(nvidia-smi --query-gpu=index,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu \
                        --format=csv,noheader,nounits 2>/dev/null || true)
            sleep "$GPU_SAMPLE_INTERVAL_SECONDS"
        done
    ) &
    GPU_SAMPLER_PID=$!
    log "GPU 采样已启动 PID=$GPU_SAMPLER_PID -> $GPU_CSV（每 ${GPU_SAMPLE_INTERVAL_SECONDS}s）"
}

# =============================================================================
# Step g) Spot 中断处理（IMDSv2）：收到通知就抢在回收前把东西同步出去
# 注：编号沿用 FEAT-002 的步骤编号；实际启动顺序见文末主流程
# =============================================================================
start_spot_watcher() {
    section "Step g) 启动 Spot 中断监听 (IMDSv2)"
    (
        trap - EXIT ERR TERM INT
        while true; do
            local action=""
            action="$(imds_get spot/instance-action 2>/dev/null || true)"
            if [[ -n "$action" && "$action" != *"404"* && "$action" != "None" ]]; then
                log "[Spot] 收到中断通知: $action"
                mark_terminal_phase spot_interrupted
                PHASE="spot_interrupted"
                STATUS_MESSAGE="Spot 中断通知: $action，正在做最后一次同步"
                STATUS_EXIT_CODE=0
                write_status
                log "[Spot] 开始中断前最终同步"
                sync_to_s3 "Spot 中断前最终同步" || true
                heartbeat || true
                log "[Spot] 最终同步完成，通知主流程退出"
                kill -TERM "$MAIN_PID" 2>/dev/null || true
                exit 0
            fi
            sleep "$SPOT_POLL_INTERVAL_SECONDS"
        done
    ) &
    SPOT_WATCHER_PID=$!
    log "Spot 监听已启动 PID=$SPOT_WATCHER_PID（每 ${SPOT_POLL_INTERVAL_SECONDS}s 轮询）"
}

# =============================================================================
# Step h) 看门狗与自终止：两个独立触发点，主流程挂死也必须停机
# 上次 13h14m x $26.67/hr = 约 $353；240 分钟上限把最坏情况压到约 $107
# =============================================================================
terminate_self() {
    local reason="$1"
    if [[ "$SELF_TERMINATE" != "true" ]]; then
        warn "SELF_TERMINATE=false，跳过自终止（$reason）—— 请记得手工关机"
        return 0
    fi
    # 无论从主流程、看门狗还是 EXIT trap 进来，都保证只终止一次
    if ! ( set -o noclobber; : >"$TERMINATE_FLAG" ) 2>/dev/null; then
        log "自终止已被触发过，跳过重复调用（$reason）"
        return 0
    fi
    log "自终止: $reason"
    if [[ -n "$INSTANCE_ID" ]]; then
        if run_destructive aws ec2 terminate-instances \
                --region "$REGION" --instance-ids "$INSTANCE_ID"; then
            log "已请求终止实例 $INSTANCE_ID"
            return 0
        fi
        warn "terminate-instances 调用失败（IAM 条件要求实例带 Project=$PROJECT_TAG 标签），回退 shutdown"
    else
        warn "未知 instance-id，直接使用 shutdown"
    fi
    run_destructive shutdown -h now || warn "shutdown 也失败了，实例可能需要人工回收"
}

start_watchdog() {
    section "Step h) 启动墙上时钟看门狗 (${MAX_RUNTIME_MINUTES} 分钟)"
    local deadline
    deadline="$(awk -v m="$MAX_RUNTIME_MINUTES" 'BEGIN{printf "%.0f", m * 60}')"
    if [[ "$deadline" -lt 1 ]]; then
        deadline=1
    fi
    log "硬性上限 ${MAX_RUNTIME_MINUTES} 分钟 = ${deadline}s；到点无论主流程在做什么都同步并终止"
    (
        trap - EXIT ERR TERM INT
        sleep "$deadline"
        log "[看门狗] 已到 ${MAX_RUNTIME_MINUTES} 分钟硬性上限，强制收尾"
        mark_terminal_phase deadline_exceeded
        PHASE="deadline_exceeded"
        STATUS_MESSAGE="超过 MAX_RUNTIME_MINUTES=${MAX_RUNTIME_MINUTES}，看门狗强制终止"
        STATUS_EXIT_CODE=124
        write_status
        sync_to_s3 "看门狗最终同步" || true
        heartbeat || true
        terminate_self "墙上时钟看门狗超时" || true
        kill -TERM "$MAIN_PID" 2>/dev/null || true
        exit 0
    ) &
    WATCHDOG_PID=$!
    log "看门狗已启动 PID=$WATCHDOG_PID"
}

# =============================================================================
# Step e) 权重获取：优先同 Region S3 镜像（FEAT-003 负责建镜像），否则回退 HF
# 上次 NetworkIn 315 GB = 同一份 151 GB 权重下了两遍
# =============================================================================
model_local_dir() {
    printf '%s/%s' "$MODEL_ROOT" "${MODEL_NAME//\//__}"
}

fetch_checkpoint() {
    section "Step e) 获取模型权重"
    if [[ "$FETCH_CHECKPOINT" != "true" ]]; then
        log "FETCH_CHECKPOINT=false（$STAGE 阶段只验证管路），跳过权重下载"
        return 0
    fi
    local dest start_epoch elapsed bytes
    dest="$(model_local_dir)"
    mkdir -p "$dest"
    set_phase fetching_model "下载 $MODEL_NAME -> $dest"
    start_epoch="$(date +%s)"

    if [[ -n "$CHECKPOINT_S3_URI" ]]; then
        log "使用同 Region S3 镜像: $CHECKPOINT_S3_URI（可断点续传，不再重复下 ${CHECKPOINT_GB} GB）"
        aws s3 sync "$CHECKPOINT_S3_URI" "$dest" --region "$REGION" --only-show-errors
    elif command -v hf >/dev/null 2>&1; then
        log "使用 hf download（自带断点续传）"
        hf download "$MODEL_NAME" --local-dir "$dest"
    elif command -v huggingface-cli >/dev/null 2>&1; then
        log "使用 huggingface-cli download（自带断点续传）"
        huggingface-cli download "$MODEL_NAME" --local-dir "$dest" --resume-download
    else
        log "回退到 huggingface_hub.snapshot_download"
        # DLAMI 的系统 Python 可能没装 huggingface_hub，先确保安装
        python3 -c "import huggingface_hub" 2>/dev/null || pip3 install -q huggingface_hub
        python3 - "$MODEL_NAME" "$dest" <<'PYEOF'
import sys
from huggingface_hub import snapshot_download
print(snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2], resume_download=True))
PYEOF
    fi

    elapsed=$(( $(date +%s) - start_epoch ))
    bytes="$(du -sb "$dest" 2>/dev/null | awk '{print $1}')"
    bytes="${bytes:-0}"
    log "权重获取完成: $(bytes_to_gb "$bytes") GB / ${elapsed}s -> $dest"

    # 下载完再验一次，避免刚好写满
    assert_free_space "下载后"
}

# =============================================================================
# Step f) 起 SGLang 服务并跑 bench_serving
# 服务端 stdout/stderr 无条件落盘：实例消失后这是唯一能查启动崩溃的东西
# =============================================================================
build_serve_args() {
    if [[ -n "$SGLANG_SERVE_ARGS" ]]; then
        printf '%s' "$SGLANG_SERVE_ARGS"
        return 0
    fi
    local model_path args
    model_path="$(model_local_dir)"
    if [[ "$FETCH_CHECKPOINT" != "true" ]]; then
        model_path="$MODEL_NAME"
    fi
    args="--model-path $model_path"
    args+=" --tp $TP_SIZE"
    args+=" --mem-fraction-static $MEM_FRACTION_STATIC"
    args+=" --trust-remote-code"
    args+=" --host $SERVER_HOST"
    args+=" --port $SERVER_PORT"
    if [[ -n "$SGLANG_EXTRA_ARGS" ]]; then
        args+=" $SGLANG_EXTRA_ARGS"
    fi
    printf '%s' "$args"
}

start_server() {
    local serve_args
    serve_args="$(build_serve_args)"
    log "SGLang 镜像 : $SGLANG_IMAGE"
    log "SGLang 命令 : $SGLANG_LAUNCH_CMD $serve_args"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086  # serve_args 是有意按空格拆分的参数串
    docker run -d --name "$CONTAINER_NAME" \
        --gpus all \
        --ipc=host \
        --shm-size "$SHM_SIZE" \
        --ulimit memlock=-1 \
        --ulimit stack=67108864 \
        --network host \
        -v "$NVME_MOUNT:$NVME_MOUNT" \
        -e HF_HOME="$HF_CACHE_DIR" \
        -e HF_HUB_CACHE="$HF_CACHE_DIR" \
        -e TMPDIR="$NVME_MOUNT/tmp" \
        ${HF_TOKEN:+-e HF_TOKEN="$HF_TOKEN"} \
        "$SGLANG_IMAGE" \
        $SGLANG_LAUNCH_CMD $serve_args
    # 无条件把容器日志接到文件：启动崩溃时这是唯一线索
    ( trap - EXIT ERR TERM INT; docker logs -f "$CONTAINER_NAME" >>"$SERVER_LOG" 2>&1 || true ) &
    SERVER_TAIL_PID=$!
    log "容器已启动，日志 -> $SERVER_LOG (tail PID=$SERVER_TAIL_PID)"
}

wait_for_server() {
    local waited=0
    log "等待 http://localhost:$SERVER_PORT/health 就绪（上限 ${SERVER_READY_TIMEOUT}s；" \
        "cookbook 提示首次冷启动需 10-15 分钟做 FlashInfer autotune 与 CUDA graph capture）"
    while (( waited < SERVER_READY_TIMEOUT )); do
        if curl -fsS --max-time 5 "http://localhost:$SERVER_PORT/health" >/dev/null 2>&1; then
            set_phase server_ready "SGLang 已就绪（等待 ${waited}s）"
            return 0
        fi
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
            echo "错误: 容器 $CONTAINER_NAME 已退出，SGLang 启动失败，详见 $SERVER_LOG" >&2
            return 1
        fi
        sleep "$SERVER_POLL_INTERVAL"
        waited=$(( waited + SERVER_POLL_INTERVAL ))
        log "  等待服务就绪... ${waited}s / ${SERVER_READY_TIMEOUT}s"
    done
    echo "错误: 等待 SGLang 就绪超时 (${SERVER_READY_TIMEOUT}s)，详见 $SERVER_LOG" >&2
    return 1
}

# README 6.1 的两条命令，参数一字不改
run_bench_case() {
    local label="$1" in_tok="$2" out_tok="$3" outfile="$4"
    log "运行 bench_serving [$label]: input=$in_tok output=$out_tok prompts=$NUM_PROMPTS concurrency=$MAX_CONCURRENCY"
    if docker exec "$CONTAINER_NAME" \
            python3 -m sglang.bench_serving --backend sglang \
                --dataset-name random \
                --random-input "$in_tok" \
                --random-output "$out_tok" \
                --num-prompts "$NUM_PROMPTS" \
                --max-concurrency "$MAX_CONCURRENCY" \
                --output-file "$outfile" >>"$LOG_DIR/bench-$label.log" 2>&1; then
        log "  [$label] 完成 -> $outfile"
        return 0
    fi
    warn "[$label] bench_serving 退出非零，日志见 $LOG_DIR/bench-$label.log"
    return 1
}

serve_and_bench() {
    section "Step f) 启动 SGLang 并运行 benchmark"
    if [[ "$RUN_SERVER" != "true" ]]; then
        log "RUN_SERVER=false（$STAGE 阶段只验证管路），跳过推理服务与 benchmark"
        return 0
    fi
    set_phase starting_server "docker run $SGLANG_IMAGE"
    start_server
    wait_for_server

    set_phase benchmarking "跑 README 6.1 的两条 bench_serving"
    local custom_out official_out
    custom_out="$RESULTS_DIR/bench_custom_${RUN_ID}.json"
    official_out="$RESULTS_DIR/bench_official_${RUN_ID}.json"
    if run_bench_case custom "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$custom_out"; then
        CUSTOM_PASS=true
    fi
    if run_bench_case official "$OFFICIAL_INPUT_TOKENS" "$OFFICIAL_OUTPUT_TOKENS" "$official_out"; then
        OFFICIAL_PASS=true
    fi
    log "benchmark 结束: custom=$CUSTOM_PASS official=$OFFICIAL_PASS"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

# =============================================================================
# 运行元数据：写在结果目录里，FEAT-003 的收集器据此拼出 compare-results.sh 的 schema
# =============================================================================
write_run_metadata() {
    local meta="$RESULTS_DIR/run_${RUN_ID}.json"
    mkdir -p "$RESULTS_DIR"
    cat >"$meta" <<EOF
{
  "run_id": "$(json_escape "$RUN_ID")",
  "stage": "$(json_escape "$STAGE")",
  "region": "$(json_escape "$REGION")",
  "instance_id": "$(json_escape "$INSTANCE_ID")",
  "instance_type": "$(json_escape "${INSTANCE_TYPE:-unknown}")",
  "model": "$(json_escape "$MODEL_NAME")",
  "sglang_image": "$(json_escape "$SGLANG_IMAGE")",
  "tp_size": $TP_SIZE,
  "serve_args": "$(json_escape "$(build_serve_args)")",
  "custom_benchmark_file": "bench_custom_${RUN_ID}.json",
  "official_benchmark_file": "bench_official_${RUN_ID}.json",
  "custom_pass": $CUSTOM_PASS,
  "official_pass": $OFFICIAL_PASS,
  "config": {
    "input_tokens": $INPUT_TOKENS,
    "output_tokens": $OUTPUT_TOKENS,
    "official_input_tokens": $OFFICIAL_INPUT_TOKENS,
    "official_output_tokens": $OFFICIAL_OUTPUT_TOKENS,
    "num_prompts": $NUM_PROMPTS,
    "max_concurrency": $MAX_CONCURRENCY
  },
  "elapsed_seconds": $(( $(date +%s) - START_EPOCH ))
}
EOF
    log "运行元数据已写入: $meta"
}

finalize() {
    section "Step h-1) 正常完成收尾"
    set_phase finalizing "写元数据并做最终同步"
    write_run_metadata
    sync_to_s3 "完成前最终同步"
    heartbeat || true
    PHASE="completed"
    STATUS_MESSAGE="全流程完成，结果已在 s3://$RESULTS_BUCKET/$S3_RUN_PREFIX/"
    STATUS_EXIT_CODE=0
    write_status
    sync_to_s3 "状态置为 completed 后再同步一次"
    log "全部完成。结果位置: s3://${RESULTS_BUCKET:-<未设置>}/$S3_RUN_PREFIX/"
}

# =============================================================================
# 主流程：后台看门狗最先起，容量护栏在任何下载之前，收尾一定自终止
# =============================================================================
init_logging                         # Step a)
start_watchdog                       # Step h) 先起，主流程挂死也能停机
setup_storage                        # Step b)
assert_free_space "下载前"           # Step b) 护栏：不达标就直接失败，绝不开始下载
start_streamer                       # Step c)
start_gpu_sampler                    # Step d)
start_spot_watcher                   # Step g)
relocate_docker_data_root            # Step b) 迁移 data-root 必须早于 docker pull
fetch_checkpoint                     # Step e)
serve_and_bench                      # Step f)
finalize                             # Step h)
exit 0
