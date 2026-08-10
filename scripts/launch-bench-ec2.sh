#!/usr/bin/env bash
# =============================================================================
# TPOT Benchmark 裸 EC2 启动器 (launch-bench-ec2)
# 用途：把 scripts/bootstrap/bench-bootstrap.sh 连同「环境前言」渲染成 user-data，
#       校验语法，然后以 Spot 方式启动一台自驱动、自持久化、自终止的实例。
#
# 与上一次失败的差别（每一条都对应一个当时缺失的东西）：
#   - 一定带 user-data          -> 实例自己会跑完整条流水线，不依赖任何会话
#   - 一定带 IAM 实例配置文件   -> SSM 可进（无需 SSH），可写 S3，可自终止
#   - 一定不开任何入站端口      -> SSM 纯出站，安全组入站为空
#   - 一定打 Project 标签       -> 否则 IAM 条件会拒绝 TerminateInstances，自终止失效
#   - 一定要求 IMDSv2           -> Spot 中断监听与 instance-id 获取都走 IMDSv2
#   - 一定有花费闸门            -> 没有 CONFIRM_SPEND=yes 就只打印账单预估并拒绝启动
#
# 本脚本默认「拒绝启动」。加 --dry-run 只做 run-instances --dry-run，零花费。
# 注意：沙箱默认 AWS_REGION 可能不是目标 Region，所有 aws 调用显式传 --region。
# =============================================================================
set -euo pipefail

# =============================================================================
# 可配置参数（默认值）
# =============================================================================
REGION="${REGION:-us-east-2}"
AZ="${AZ:-us-east-2a}"
STAGE="${STAGE:-full}"                    # plumbing | gpu-smoke | full
EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-077090643075}"

# 网络（FEAT-001 已把 sg-0775ac013a1b6080d 的全网 SSH 入站规则撤销，现在入站为空）
# 注意：这些默认值是 us-east-2 的资源。当 --region 指向其他 Region 时，下面的
# auto-resolve 逻辑会自动从目标 Region 的 default VPC 解析出正确的子网与安全组。
SUBNET_ID="${SUBNET_ID:-}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"
SG_NAME="${SG_NAME:-tpot-bench-noingress-sg}"
VPC_ID="${VPC_ID:-}"
CREATE_SG="${CREATE_SG:-false}"

# 各 Region 已知的资源 ID（避免每次都查 API；新 Region 走 auto-resolve）
_KNOWN_SUBNET_us_east_2a="subnet-09bfc4e5573173d64"
_KNOWN_SG_us_east_2="sg-0775ac013a1b6080d"
_KNOWN_VPC_us_east_2="vpc-0351dd9bb2f63a9e1"
_KNOWN_SUBNET_us_east_1a="subnet-0ae36a5845b616649"
_KNOWN_SG_us_east_1="sg-0b381611fbbee9dcd"
_KNOWN_VPC_us_east_1="vpc-032f909768a4fba75"
ALLOW_SSH_FROM="${ALLOW_SSH_FROM:-}"      # 留空=不开任何入站；auto=解析本机出口 IP/32

# FEAT-001 建好的资源
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-tpot-bench-ec2-profile}"
BUCKET="${BUCKET:-}"                      # 留空则推导 tpot-bench-results-<account>-<region>
PROJECT_TAG="${PROJECT_TAG:-tpot-benchmark}"

# AMI（动态解析，不写死；FEAT-001 已确认下面的 SSM 公共参数路径可用）
IMAGE_ID="${IMAGE_ID:-}"
DLAMI_SSM_PARAM="${DLAMI_SSM_PARAM:-/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id}"
DLAMI_NAME_FILTER="${DLAMI_NAME_FILTER:-Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*}"

# 由 --stage 决定默认值的参数（留空 = 用 stage 默认，非空 = 用户显式覆盖）
INSTANCE_TYPE="${INSTANCE_TYPE:-}"
MAX_PRICE="${MAX_PRICE:-}"
MODEL_NAME="${MODEL_NAME:-}"
TP_SIZE="${TP_SIZE:-}"
CHECKPOINT_GB="${CHECKPOINT_GB:-}"
STORAGE_MARGIN_GB="${STORAGE_MARGIN_GB:-}"
MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-}"
FETCH_CHECKPOINT="${FETCH_CHECKPOINT:-}"
RUN_SERVER="${RUN_SERVER:-}"
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-}"
REQUIRE_INSTANCE_STORE="${REQUIRE_INSTANCE_STORE:-}"

# 推理 / benchmark 参数（recipe 文件可覆盖，见 --recipe）
SGLANG_IMAGE="${SGLANG_IMAGE:-lmsysorg/sglang:latest}"
SGLANG_LAUNCH_CMD="${SGLANG_LAUNCH_CMD:-python3 -m sglang.launch_server}"
SGLANG_EXTRA_ARGS="${SGLANG_EXTRA_ARGS:-}"
SGLANG_SERVE_ARGS="${SGLANG_SERVE_ARGS:-}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"
SERVER_PORT="${SERVER_PORT:-30000}"
SERVER_READY_TIMEOUT="${SERVER_READY_TIMEOUT:-2400}"
SHM_SIZE="${SHM_SIZE:-64g}"
INPUT_TOKENS="${INPUT_TOKENS:-40000}"
OUTPUT_TOKENS="${OUTPUT_TOKENS:-1500}"
OFFICIAL_INPUT_TOKENS="${OFFICIAL_INPUT_TOKENS:-30000}"
OFFICIAL_OUTPUT_TOKENS="${OFFICIAL_OUTPUT_TOKENS:-4096}"
NUM_PROMPTS="${NUM_PROMPTS:-50}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"
# 并发扫描：留空即不跑，与改动前行为一致；recipe 里打开
SWEEP_SPEC="${SWEEP_SPEC:-}"
SWEEP_INPUT_TOKENS="${SWEEP_INPUT_TOKENS:-8000}"
SWEEP_OUTPUT_TOKENS="${SWEEP_OUTPUT_TOKENS:-1500}"
SWEEP_NUM_PROMPTS="${SWEEP_NUM_PROMPTS:-32}"
CHECKPOINT_S3_URI="${CHECKPOINT_S3_URI:-}"
RECIPE_FILE="${RECIPE_FILE:-}"

# 盘外持久化与看门狗
STREAM_INTERVAL_SECONDS="${STREAM_INTERVAL_SECONDS:-30}"
GPU_SAMPLE_INTERVAL_SECONDS="${GPU_SAMPLE_INTERVAL_SECONDS:-30}"
SPOT_POLL_INTERVAL_SECONDS="${SPOT_POLL_INTERVAL_SECONDS:-5}"
SELF_TERMINATE="${SELF_TERMINATE:-true}"
NVME_MOUNT="${NVME_MOUNT:-/mnt/nvme}"

# 行为开关
DRY_RUN=false
WAIT_MODE=false
WAIT_TIMEOUT_MINUTES="${WAIT_TIMEOUT_MINUTES:-30}"
USER_DATA_LIMIT="${USER_DATA_LIMIT:-16384}"   # EC2user-data 原文上限 16 KB

# =============================================================================
# 命令行参数解析
# =============================================================================
usage() {
    cat <<EOF
用法: $0 [选项]

渲染 user-data（环境前言 + bench-bootstrap.sh）-> bash -n 校验 -> Spot 启动一台
自驱动实例。默认拒绝启动：必须显式 CONFIRM_SPEND=yes 才会真正下单。

选项:
  --stage STAGE             plumbing | gpu-smoke | full (默认: $STAGE)
                              plumbing  = c5d.large，只验证 NVMe/S3/看门狗管路
                              gpu-smoke = g6e.xlarge，验证 docker + GPU + SGLang 启动
                              full      = p5en.48xlarge，完整 H200 benchmark
  --region REGION           AWS Region (默认: $REGION)
  --az AZ                   可用区 (默认: $AZ)
  --instance-type TYPE      覆盖 stage 默认实例类型
  --model MODEL             覆盖 stage 默认模型
  --tp SIZE                 张量并行度
  --recipe FILE             recipe 环境文件，内容追加到环境前言（FEAT-003 使用）
  --checkpoint-s3-uri URI   同 Region S3 权重镜像，避免重复下载上百 GB
  --max-price PRICE         Spot 出价上限 (\$/hr)
  --max-runtime-minutes N   硬性墙上时钟上限，实例到点自终止
  --bucket NAME             结果桶 (默认: tpot-bench-results-<account>-<region>)
  --subnet-id ID            子网 (默认: $SUBNET_ID)
  --security-group-id ID    安全组 (默认: $SECURITY_GROUP_ID，入站为空)
  --create-sg               新建一个完全没有入站规则的安全组并使用它
  --allow-ssh-from CIDR|auto  可选：仅放行指定 CIDR 或本机出口 IP/32 的 22 端口
  --image-id AMI            跳过动态解析，直接指定 AMI
  --dry-run                 只做 run-instances --dry-run，零花费
  --wait                    真实启动后持续观察 S3 与 CloudWatch 心跳
  --help                    显示帮助信息

花费闸门:
  未设置 CONFIRM_SPEND=yes 时，脚本打印实例类型、Spot 上限、每小时预估、
  运行上限与最坏总花费，然后拒绝启动并以非零状态退出。

示例:
  # 零花费校验（渲染 + bash -n + run-instances --dry-run）
  ./scripts/launch-bench-ec2.sh --stage full --dry-run

  # 先花几分钱验证管路
  CONFIRM_SPEND=yes ./scripts/launch-bench-ec2.sh --stage plumbing

  # 真正跑 H200 完整 benchmark
  CONFIRM_SPEND=yes ./scripts/launch-bench-ec2.sh --stage full --wait
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --az) AZ="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --model) MODEL_NAME="$2"; shift 2 ;;
        --tp) TP_SIZE="$2"; shift 2 ;;
        --recipe) RECIPE_FILE="$2"; shift 2 ;;
        --checkpoint-s3-uri) CHECKPOINT_S3_URI="$2"; shift 2 ;;
        --max-price) MAX_PRICE="$2"; shift 2 ;;
        --max-runtime-minutes) MAX_RUNTIME_MINUTES="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --subnet-id) SUBNET_ID="$2"; shift 2 ;;
        --security-group-id) SECURITY_GROUP_ID="$2"; shift 2 ;;
        --create-sg) CREATE_SG=true; shift ;;
        --allow-ssh-from) ALLOW_SSH_FROM="$2"; shift 2 ;;
        --image-id) IMAGE_ID="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --wait) WAIT_MODE=true; shift ;;
        --help) usage ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SRC="$SCRIPT_DIR/bootstrap/bench-bootstrap.sh"
WORK_DIR="$(mktemp -d)"
USER_DATA_FILE="$WORK_DIR/user-data.sh"
BOOTSTRAP_RENDERED="$WORK_DIR/bench-bootstrap.sh"

# shellcheck disable=SC2329  # 由下面的 trap cleanup EXIT 间接调用
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# 单引号安全的 export 行
emit_export() {
    local name="$1" value="$2"
    printf "export %s='%s'\n" "$name" "${value//\'/\'\\\'\'}"
}

# 全网 CIDR：故意不在源码里出现字面量，避免任何脚本再把它写进安全组
world_cidr() {
    printf '%s/%d' '0.0.0.0' 0
}

# =============================================================================
# Step a) 检查工具依赖与 stage 默认值
# =============================================================================
section "Step a) 依赖检查与 stage 默认值"
for cmd in aws python3 base64; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "错误: 未找到命令 '$cmd'，请先安装" >&2
        exit 1
    fi
done
log "工具依赖检查通过: aws, python3, base64"

if [[ ! -f "$BOOTSTRAP_SRC" ]]; then
    echo "错误: 找不到引导脚本 $BOOTSTRAP_SRC" >&2
    exit 1
fi

# 每个 stage 的默认值；渐进式验证：先几分钱，再不到一美元，最后才上 H200
case "$STAGE" in
    plumbing)
        INSTANCE_TYPE="${INSTANCE_TYPE:-c5d.large}"
        MAX_PRICE="${MAX_PRICE:-0.20}"
        MODEL_NAME="${MODEL_NAME:-deepseek-ai/DeepSeek-V4-Flash}"
        TP_SIZE="${TP_SIZE:-1}"
        CHECKPOINT_GB="${CHECKPOINT_GB:-1}"
        STORAGE_MARGIN_GB="${STORAGE_MARGIN_GB:-5}"
        MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-20}"
        FETCH_CHECKPOINT="${FETCH_CHECKPOINT:-false}"
        RUN_SERVER="${RUN_SERVER:-false}"
        # DLAMI 的根快照是 75 GB，根盘不能小于它（30 GB 会被
        # InvalidBlockDeviceMapping 拒掉，dry-run 时已经踩过）
        ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-80}"
        ;;
    gpu-smoke)
        INSTANCE_TYPE="${INSTANCE_TYPE:-g6e.xlarge}"
        MAX_PRICE="${MAX_PRICE:-2.00}"
        MODEL_NAME="${MODEL_NAME:-Qwen/Qwen2.5-0.5B-Instruct}"
        TP_SIZE="${TP_SIZE:-1}"
        CHECKPOINT_GB="${CHECKPOINT_GB:-2}"
        STORAGE_MARGIN_GB="${STORAGE_MARGIN_GB:-30}"
        MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-60}"
        FETCH_CHECKPOINT="${FETCH_CHECKPOINT:-true}"
        RUN_SERVER="${RUN_SERVER:-true}"
        ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-100}"
        # 小模型冒烟只验证「能起来能跑通」，不用 40K/1500 的重负载
        INPUT_TOKENS="${INPUT_TOKENS_OVERRIDE:-2000}"
        OUTPUT_TOKENS="${OUTPUT_TOKENS_OVERRIDE:-256}"
        OFFICIAL_INPUT_TOKENS="${OFFICIAL_INPUT_TOKENS_OVERRIDE:-2000}"
        OFFICIAL_OUTPUT_TOKENS="${OFFICIAL_OUTPUT_TOKENS_OVERRIDE:-256}"
        NUM_PROMPTS="${NUM_PROMPTS_OVERRIDE:-4}"
        ;;
    full)
        INSTANCE_TYPE="${INSTANCE_TYPE:-p5en.48xlarge}"
        MAX_PRICE="${MAX_PRICE:-35.00}"
        MODEL_NAME="${MODEL_NAME:-deepseek-ai/DeepSeek-V4-Flash}"
        TP_SIZE="${TP_SIZE:-8}"
        CHECKPOINT_GB="${CHECKPOINT_GB:-160}"
        STORAGE_MARGIN_GB="${STORAGE_MARGIN_GB:-80}"
        MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-240}"
        FETCH_CHECKPOINT="${FETCH_CHECKPOINT:-true}"
        RUN_SERVER="${RUN_SERVER:-true}"
        ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-200}"
        ;;
    *)
        echo "错误: 未知 stage '$STAGE'（可选 plumbing | gpu-smoke | full）" >&2
        exit 1
        ;;
esac
REQUIRE_INSTANCE_STORE="${REQUIRE_INSTANCE_STORE:-true}"

# RUN_ID 决定所有 S3 前缀与 CloudWatch 维度，必须显眼
RUN_ID="${RUN_ID:-$(date -u '+%Y%m%d-%H%M%S')-$(printf '%04x' "$RANDOM")}"
ACCOUNT_ID="${ACCOUNT_ID:-$EXPECTED_ACCOUNT}"
if [[ -z "$BUCKET" ]]; then
    BUCKET="tpot-bench-results-${ACCOUNT_ID}-${REGION}"
fi
NAME_TAG="tpot-bench-${INSTANCE_TYPE//./-}"
BOOTSTRAP_S3_KEY="bootstrap/$RUN_ID/bench-bootstrap.sh"

log "STAGE          : $STAGE"
log "RUN_ID         : $RUN_ID"
log "INSTANCE_TYPE  : $INSTANCE_TYPE"
log "MODEL          : $MODEL_NAME"
log "结果桶         : s3://$BUCKET"

# =============================================================================
# Step a-2) 网络资源 auto-resolve
# 当 --subnet-id / --security-group-id / VPC_ID 未显式传入时，先看已知映射表，
# 再退回 describe-* API 从目标 Region 的 default VPC 动态解析。
# =============================================================================
_resolve_region_key="${REGION//-/_}"  # e.g. us_east_1
_resolve_az_key="${AZ//-/_}"         # e.g. us_east_1a

if [[ -z "$VPC_ID" ]]; then
    _known_vpc_var="_KNOWN_VPC_${_resolve_region_key}"
    if [[ -n "${!_known_vpc_var:-}" ]]; then
        VPC_ID="${!_known_vpc_var}"
        log "网络(VPC): 使用已知映射 $VPC_ID"
    else
        VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
            --filters "Name=is-default,Values=true" \
            --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
        if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
            echo "错误: $REGION 没有 default VPC，请用 --subnet-id / --security-group-id 显式指定" >&2
            exit 1
        fi
        log "网络(VPC): auto-resolve -> $VPC_ID"
    fi
fi

if [[ -z "$SUBNET_ID" ]]; then
    _known_subnet_var="_KNOWN_SUBNET_${_resolve_az_key}"
    if [[ -n "${!_known_subnet_var:-}" ]]; then
        SUBNET_ID="${!_known_subnet_var}"
        log "网络(子网): 使用已知映射 $SUBNET_ID ($AZ)"
    else
        SUBNET_ID=$(aws ec2 describe-subnets --region "$REGION" \
            --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ" \
            --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo "")
        if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]]; then
            echo "错误: $AZ 的 default VPC ($VPC_ID) 没有子网，请用 --subnet-id 显式指定" >&2
            exit 1
        fi
        log "网络(子网): auto-resolve -> $SUBNET_ID ($AZ)"
    fi
fi

if [[ -z "$SECURITY_GROUP_ID" ]]; then
    _known_sg_var="_KNOWN_SG_${_resolve_region_key}"
    if [[ -n "${!_known_sg_var:-}" ]]; then
        SECURITY_GROUP_ID="${!_known_sg_var}"
        log "网络(安全组): 使用已知映射 $SECURITY_GROUP_ID"
    else
        # 先查看是否已有名为 tpot-bench-noingress-sg 的安全组
        SECURITY_GROUP_ID=$(aws ec2 describe-security-groups --region "$REGION" \
            --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
        if [[ -z "$SECURITY_GROUP_ID" || "$SECURITY_GROUP_ID" == "None" ]]; then
            # 标记需要创建
            CREATE_SG=true
            SECURITY_GROUP_ID="pending-create"
            log "网络(安全组): $REGION 没有 $SG_NAME，将在 Step g) 自动创建"
        else
            log "网络(安全组): auto-resolve -> $SECURITY_GROUP_ID ($SG_NAME)"
        fi
    fi
fi

# =============================================================================
# Step b) 渲染 user-data 并用 bash -n 校验（在任何 AWS 调用之前）
# =============================================================================
section "Step b) 渲染 user-data 并做语法校验"

render_env_prelude() {
    cat <<'EOF'
#!/usr/bin/env bash
# =============================================================================
# 本文件由 scripts/launch-bench-ec2.sh 渲染，勿手工编辑实例上的副本。
# 结构 = 环境前言（下面的 export）+ scripts/bootstrap/bench-bootstrap.sh 原文
# =============================================================================
set -euo pipefail
mkdir -p /var/log/tpot-bench
EOF
    emit_export RUN_ID "$RUN_ID"
    emit_export STAGE "$STAGE"
    emit_export REGION "$REGION"
    emit_export AWS_DEFAULT_REGION "$REGION"
    emit_export RESULTS_BUCKET "$BUCKET"
    emit_export PROJECT_TAG "$PROJECT_TAG"
    emit_export NVME_MOUNT "$NVME_MOUNT"
    emit_export REQUIRE_INSTANCE_STORE "$REQUIRE_INSTANCE_STORE"
    emit_export CHECKPOINT_GB "$CHECKPOINT_GB"
    emit_export STORAGE_MARGIN_GB "$STORAGE_MARGIN_GB"
    emit_export MODEL_NAME "$MODEL_NAME"
    emit_export CHECKPOINT_S3_URI "$CHECKPOINT_S3_URI"
    emit_export FETCH_CHECKPOINT "$FETCH_CHECKPOINT"
    emit_export RUN_SERVER "$RUN_SERVER"
    emit_export SGLANG_IMAGE "$SGLANG_IMAGE"
    emit_export SGLANG_LAUNCH_CMD "$SGLANG_LAUNCH_CMD"
    emit_export SGLANG_EXTRA_ARGS "$SGLANG_EXTRA_ARGS"
    emit_export SGLANG_SERVE_ARGS "$SGLANG_SERVE_ARGS"
    emit_export TP_SIZE "$TP_SIZE"
    emit_export MEM_FRACTION_STATIC "$MEM_FRACTION_STATIC"
    emit_export SERVER_PORT "$SERVER_PORT"
    emit_export SERVER_READY_TIMEOUT "$SERVER_READY_TIMEOUT"
    emit_export SHM_SIZE "$SHM_SIZE"
    emit_export INPUT_TOKENS "$INPUT_TOKENS"
    emit_export OUTPUT_TOKENS "$OUTPUT_TOKENS"
    emit_export OFFICIAL_INPUT_TOKENS "$OFFICIAL_INPUT_TOKENS"
    emit_export OFFICIAL_OUTPUT_TOKENS "$OFFICIAL_OUTPUT_TOKENS"
    emit_export NUM_PROMPTS "$NUM_PROMPTS"
    emit_export MAX_CONCURRENCY "$MAX_CONCURRENCY"
    emit_export SWEEP_SPEC "$SWEEP_SPEC"
    emit_export SWEEP_INPUT_TOKENS "$SWEEP_INPUT_TOKENS"
    emit_export SWEEP_OUTPUT_TOKENS "$SWEEP_OUTPUT_TOKENS"
    emit_export SWEEP_NUM_PROMPTS "$SWEEP_NUM_PROMPTS"
    emit_export STREAM_INTERVAL_SECONDS "$STREAM_INTERVAL_SECONDS"
    emit_export GPU_SAMPLE_INTERVAL_SECONDS "$GPU_SAMPLE_INTERVAL_SECONDS"
    emit_export SPOT_POLL_INTERVAL_SECONDS "$SPOT_POLL_INTERVAL_SECONDS"
    emit_export MAX_RUNTIME_MINUTES "$MAX_RUNTIME_MINUTES"
    emit_export SELF_TERMINATE "$SELF_TERMINATE"
    if [[ -n "${HF_TOKEN:-}" ]]; then
        emit_export HF_TOKEN "${HF_TOKEN}"
    fi
    if [[ -n "$RECIPE_FILE" ]]; then
        echo "# --- recipe: $(basename "$RECIPE_FILE") ---"
        cat "$RECIPE_FILE"
    fi
}

if [[ -n "$RECIPE_FILE" && ! -f "$RECIPE_FILE" ]]; then
    echo "错误: recipe 文件不存在: $RECIPE_FILE" >&2
    exit 1
fi

# 内联版本：前言 + 引导脚本原文
{
    render_env_prelude
    echo "# --- 以下为 scripts/bootstrap/bench-bootstrap.sh 原文 ---"
    cat "$BOOTSTRAP_SRC"
} >"$USER_DATA_FILE"

# 先校验引导脚本本体，再校验渲染结果；任何一处语法错误都必须在下单之前拦住
if ! bash -n "$BOOTSTRAP_SRC"; then
    echo "错误: 引导脚本 $BOOTSTRAP_SRC 语法校验失败，拒绝启动" >&2
    exit 1
fi
if ! bash -n "$USER_DATA_FILE"; then
    echo "错误: 渲染后的 user-data 语法校验失败，拒绝启动（未发起任何 AWS 调用）" >&2
    exit 1
fi
log "bash -n 校验通过: $BOOTSTRAP_SRC 与渲染结果"

INLINE_BYTES="$(wc -c <"$USER_DATA_FILE" | tr -d ' ')"
INLINE_B64_BYTES="$(base64 -w0 <"$USER_DATA_FILE" | wc -c | tr -d ' ')"
log "内联 user-data 大小: ${INLINE_BYTES} 字节（base64 后 ${INLINE_B64_BYTES} 字节），上限 ${USER_DATA_LIMIT} 字节"

USER_DATA_MODE="inline"
if (( INLINE_BYTES > USER_DATA_LIMIT )); then
    USER_DATA_MODE="s3"
    log "超过 16 KB 上限，切换为 S3 托管模式：引导脚本上传到 S3，user-data 只留一个取回并 exec 的小 stub"
    cp "$BOOTSTRAP_SRC" "$BOOTSTRAP_RENDERED"
    {
        render_env_prelude
        cat <<EOF
# --- S3 托管模式 stub：取回 bench-bootstrap.sh 并 exec ---
BOOTSTRAP_URI="s3://$BUCKET/$BOOTSTRAP_S3_KEY"
BOOTSTRAP_LOCAL="/opt/tpot-bench/bench-bootstrap.sh"
mkdir -p /opt/tpot-bench
exec > >(tee -a /var/log/tpot-bench/user-data.log) 2>&1
echo "[user-data] 取回 \$BOOTSTRAP_URI"
for attempt in \$(seq 1 30); do
    if aws s3 cp "\$BOOTSTRAP_URI" "\$BOOTSTRAP_LOCAL" --region "$REGION"; then
        break
    fi
    echo "[user-data] 第 \$attempt 次取回失败（实例配置文件可能还没生效），10s 后重试"
    sleep 10
done
if [[ ! -s "\$BOOTSTRAP_LOCAL" ]]; then
    echo "[user-data] 致命错误: 无法取回引导脚本，立即停机以免空转烧钱" >&2
    TOKEN="\$(curl -sS -X PUT http://169.254.169.254/latest/api/token \\
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' --max-time 3 || true)"
    IID="\$(curl -sS -H "X-aws-ec2-metadata-token: \$TOKEN" \\
        http://169.254.169.254/latest/meta-data/instance-id --max-time 3 || true)"
    if [[ -n "\$IID" ]]; then
        aws ec2 terminate-instances --region "$REGION" --instance-ids "\$IID" || shutdown -h now
    else
        shutdown -h now
    fi
    exit 1
fi
chmod +x "\$BOOTSTRAP_LOCAL"
exec "\$BOOTSTRAP_LOCAL"
EOF
    } >"$USER_DATA_FILE"
    if ! bash -n "$USER_DATA_FILE"; then
        echo "错误: S3 stub 版 user-data 语法校验失败，拒绝启动" >&2
        exit 1
    fi
    STUB_BYTES="$(wc -c <"$USER_DATA_FILE" | tr -d ' ')"
    log "stub user-data 大小: ${STUB_BYTES} 字节（base64 后 $(base64 -w0 <"$USER_DATA_FILE" | wc -c | tr -d ' ') 字节）"
    log "bash -n 校验通过: S3 stub 版 user-data"
fi

# =============================================================================
# Step c) 身份校验（只读）
# =============================================================================
section "Step c) 身份校验"
if ! IDENTITY=$(aws sts get-caller-identity --region "$REGION" --output json 2>&1); then
    echo "错误: aws sts get-caller-identity 失败: $IDENTITY" >&2
    exit 1
fi
ACCOUNT_ID=$(echo "$IDENTITY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])')
log "Account: $ACCOUNT_ID / Region: $REGION / AZ: $AZ"
if [[ "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT" ]]; then
    echo "错误: 账号不匹配（期望 $EXPECTED_ACCOUNT，实际 $ACCOUNT_ID），拒绝启动" >&2
    exit 1
fi

# =============================================================================
# Step d) AMI 动态解析（只读）
# =============================================================================
section "Step d) AMI 解析"
if [[ -z "$IMAGE_ID" ]]; then
    if SSM_AMI=$(aws ssm get-parameter --region "$REGION" --name "$DLAMI_SSM_PARAM" \
            --query 'Parameter.Value' --output text 2>/dev/null) \
            && [[ -n "$SSM_AMI" && "$SSM_AMI" != "None" ]]; then
        IMAGE_ID="$SSM_AMI"
        log "来源: SSM 公共参数 $DLAMI_SSM_PARAM"
    else
        warn "SSM 参数不可用，回退 describe-images 名称过滤"
        IMAGE_ID=$(aws ec2 describe-images --region "$REGION" --owners amazon \
            --filters "Name=name,Values=$DLAMI_NAME_FILTER" "Name=state,Values=available" \
            --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text 2>/dev/null || echo "None")
    fi
fi
if [[ -z "$IMAGE_ID" || "$IMAGE_ID" == "None" ]]; then
    echo "错误: 无法解析 AMI，拒绝启动" >&2
    exit 1
fi
log "AMI: $IMAGE_ID"

# =============================================================================
# Step e) Spot 价格与花费预估（只读）
# =============================================================================
section "Step e) Spot 价格与花费预估"
SPOT_PRICE=""
if SPOT_OUT=$(aws ec2 describe-spot-price-history --region "$REGION" \
        --instance-types "$INSTANCE_TYPE" \
        --product-descriptions "Linux/UNIX" \
        --availability-zone "$AZ" \
        --start-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --query 'SpotPriceHistory[0].SpotPrice' --output text 2>/dev/null); then
    if [[ -n "$SPOT_OUT" && "$SPOT_OUT" != "None" ]]; then
        SPOT_PRICE="$SPOT_OUT"
    fi
fi
if [[ -z "$SPOT_PRICE" ]]; then
    warn "无法取到 $AZ 的 $INSTANCE_TYPE Spot 现价，预估将使用出价上限 \$$MAX_PRICE"
    SPOT_PRICE="$MAX_PRICE"
fi
WORST_CASE=$(awk -v p="$SPOT_PRICE" -v m="$MAX_RUNTIME_MINUTES" 'BEGIN{printf "%.2f", p * m / 60}')
CEILING_CASE=$(awk -v p="$MAX_PRICE" -v m="$MAX_RUNTIME_MINUTES" 'BEGIN{printf "%.2f", p * m / 60}')
log "Spot 现价: \$$SPOT_PRICE/hr（出价上限 \$$MAX_PRICE/hr）"

print_cost_table() {
    cat <<EOF

------------------------------------------------------------------------------
 本次启动的花费画像
------------------------------------------------------------------------------
 Stage            : $STAGE
 实例类型         : $INSTANCE_TYPE
 可用区           : $AZ ($REGION)
 Spot 现价        : \$$SPOT_PRICE/hr
 Spot 出价上限    : \$$MAX_PRICE/hr
 运行时间上限     : $MAX_RUNTIME_MINUTES 分钟（实例内看门狗强制自终止）
 最坏花费(现价)   : \$$WORST_CASE
 最坏花费(上限价) : \$$CEILING_CASE
 参考             : 上一次没有上限，跑了 13h14m x \$26.67/hr = 约 \$353，且零产出
------------------------------------------------------------------------------
EOF
}
print_cost_table

# =============================================================================
# Step f) 花费闸门：默认拒绝启动
# =============================================================================
section "Step f) 花费闸门"
if [[ "$DRY_RUN" == "true" ]]; then
    log "--dry-run 模式：只做 run-instances --dry-run，不会产生任何花费"
elif [[ "${CONFIRM_SPEND:-}" != "yes" ]]; then
    cat <<EOF
拒绝启动: 未设置 CONFIRM_SPEND=yes。

这台机器一旦启动就开始计费，而默认拒绝正是上一次 \$353 教训的直接产物。
确认上面的花费画像后，用下面的命令显式授权：

  CONFIRM_SPEND=yes $0 --stage $STAGE

或者先零花费校验：

  $0 --stage $STAGE --dry-run
EOF
    log "未发起任何 run-instances 调用，退出码 2"
    exit 2
fi

# =============================================================================
# Step g) 安全组：入站为空（SSM 纯出站，不需要放行任何入站端口）
# =============================================================================
section "Step g) 安全组"
ensure_security_group() {
    if [[ "$CREATE_SG" != "true" ]]; then
        return 0
    fi
    local existing
    existing=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
    if [[ -n "$existing" && "$existing" != "None" ]]; then
        SECURITY_GROUP_ID="$existing"
        log "复用已有安全组 $SG_NAME = $SECURITY_GROUP_ID"
        return 0
    fi
    log "创建安全组 $SG_NAME（不添加任何入站规则；出站默认全开，SSM 走出站 HTTPS）"
    SECURITY_GROUP_ID=$(aws ec2 create-security-group --region "$REGION" \
        --group-name "$SG_NAME" --vpc-id "$VPC_ID" \
        --description "TPOT bench: no inbound rules, SSM outbound only" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=$PROJECT_TAG}]" \
        --query 'GroupId' --output text)
    log "已创建安全组: $SECURITY_GROUP_ID"
}
ensure_security_group

# 只有显式传 --allow-ssh-from 才会有入站规则，且永远只放行一个 /32
maybe_allow_ssh() {
    [[ -z "$ALLOW_SSH_FROM" ]] && return 0
    local cidr="$ALLOW_SSH_FROM"
    if [[ "$cidr" == "auto" ]]; then
        local ip
        ip="$(curl -fsS --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]')"
        if [[ -z "$ip" ]]; then
            echo "错误: 无法解析本机出口 IP，拒绝放行入站" >&2
            exit 1
        fi
        cidr="$ip/32"
        log "本机出口 IP 解析结果: $cidr（运行时解析，不写死任何 IP）"
    fi
    if [[ "$cidr" == "$(world_cidr)" ]]; then
        echo "错误: 拒绝把 22 端口放行给全网；请指定具体 /32" >&2
        exit 1
    fi
    log "放行 tcp/22 来自 $cidr（仅此一个 CIDR）"
    aws ec2 authorize-security-group-ingress --region "$REGION" \
        --group-id "$SECURITY_GROUP_ID" --protocol tcp --port 22 --cidr "$cidr" \
        >/dev/null 2>&1 || warn "authorize-security-group-ingress 失败（可能规则已存在）"
}
maybe_allow_ssh

SG_INGRESS=$(aws ec2 describe-security-groups --region "$REGION" \
    --group-ids "$SECURITY_GROUP_ID" \
    --query 'SecurityGroups[0].IpPermissions | [].IpRanges[] | [].CidrIp' \
    --output text 2>/dev/null || echo "")
if [[ -z "$SG_INGRESS" || "$SG_INGRESS" == "None" ]]; then
    log "安全组 $SECURITY_GROUP_ID 入站规则为空（期望状态）"
else
    log "安全组 $SECURITY_GROUP_ID 入站 CIDR: $SG_INGRESS"
    if [[ "$SG_INGRESS" == *"$(world_cidr)"* ]]; then
        echo "错误: 安全组 $SECURITY_GROUP_ID 存在全网入站规则，拒绝启动。" \
             "先运行 scripts/setup-infra.sh --harden-existing 或改用 --create-sg" >&2
        exit 1
    fi
fi

# =============================================================================
# Step h) S3 托管模式：先上传引导脚本，再下单
# =============================================================================
section "Step h) 引导脚本投递方式: $USER_DATA_MODE"
if [[ "$USER_DATA_MODE" == "s3" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[dry-run] 跳过上传 s3://$BUCKET/$BOOTSTRAP_S3_KEY（真实启动时会先上传再下单）"
    else
        log "上传引导脚本 -> s3://$BUCKET/$BOOTSTRAP_S3_KEY"
        aws s3 cp "$BOOTSTRAP_RENDERED" "s3://$BUCKET/$BOOTSTRAP_S3_KEY" \
            --region "$REGION" --only-show-errors
        log "上传完成"
    fi
else
    log "引导脚本内联在 user-data 中，无需上传"
fi

# =============================================================================
# Step i) run-instances
# =============================================================================
section "Step i) run-instances"
RUN_ARGS=(
    ec2 run-instances
    --region "$REGION"
    --image-id "$IMAGE_ID"
    --instance-type "$INSTANCE_TYPE"
    --count 1
    --subnet-id "$SUBNET_ID"
    --security-group-ids "$SECURITY_GROUP_ID"
    --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME"
    --instance-initiated-shutdown-behavior terminate
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2"
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"
    --instance-market-options "MarketType=spot,SpotOptions={MaxPrice=${MAX_PRICE},SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}"
    --tag-specifications
        "ResourceType=instance,Tags=[{Key=Project,Value=${PROJECT_TAG}},{Key=Name,Value=${NAME_TAG}},{Key=RunId,Value=${RUN_ID}},{Key=Stage,Value=${STAGE}}]"
        "ResourceType=volume,Tags=[{Key=Project,Value=${PROJECT_TAG}},{Key=Name,Value=${NAME_TAG}},{Key=RunId,Value=${RUN_ID}},{Key=Stage,Value=${STAGE}}]"
    --user-data "file://$USER_DATA_FILE"
)
# Project 标签是自终止的前提：IAM 里的 ec2:TerminateInstances 带
# StringEquals aws:ResourceTag/Project = tpot-benchmark 条件

if [[ "$DRY_RUN" == "true" ]]; then
    RUN_ARGS+=(--dry-run)
    log "执行（dry-run）: aws ec2 run-instances --dry-run ... （不会创建实例）"
    if DRY_OUT=$(aws "${RUN_ARGS[@]}" 2>&1); then
        echo "错误: --dry-run 竟然返回成功，AWS CLI 可能忽略了 --dry-run: $DRY_OUT" >&2
        exit 1
    fi
    if echo "$DRY_OUT" | grep -q 'DryRunOperation'; then
        log "DryRunOperation —— 参数与权限均有效，未创建任何实例"
        echo ""
        echo "=============================================================================="
        echo " dry-run 结果: PASS"
        echo "=============================================================================="
        echo " AWS 响应        : $DRY_OUT"
        echo " Stage / 实例    : $STAGE / $INSTANCE_TYPE @ $AZ"
        echo " AMI             : $IMAGE_ID"
        echo " 安全组          : $SECURITY_GROUP_ID (入站: ${SG_INGRESS:-空})"
        echo " 实例配置文件    : $INSTANCE_PROFILE_NAME"
        echo " user-data 方式  : $USER_DATA_MODE（内联 ${INLINE_BYTES} 字节 / base64 ${INLINE_B64_BYTES} 字节，上限 ${USER_DATA_LIMIT}）"
        echo " RUN_ID          : $RUN_ID"
        echo " 结果前缀        : s3://$BUCKET/runs/$RUN_ID/"
        echo " 本次花费        : \$0（dry-run）"
        echo "=============================================================================="
        exit 0
    fi
    echo "错误: dry-run 未返回 DryRunOperation: $DRY_OUT" >&2
    exit 1
fi

log "执行真实启动（CONFIRM_SPEND=yes 已确认）..."
LAUNCH_JSON="$WORK_DIR/run-instances.json"
aws "${RUN_ARGS[@]}" --output json >"$LAUNCH_JSON"
INSTANCE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Instances"][0]["InstanceId"])' "$LAUNCH_JSON")
log "实例已启动: $INSTANCE_ID"

echo ""
echo "=============================================================================="
echo " 启动完成"
echo "=============================================================================="
echo " RUN_ID       : $RUN_ID"
echo " 实例 ID      : $INSTANCE_ID ($INSTANCE_TYPE @ $AZ)"
echo " 运行上限     : $MAX_RUNTIME_MINUTES 分钟（到点实例自终止，最坏约 \$$WORST_CASE）"
echo " 日志         : aws s3 cp s3://$BUCKET/runs/$RUN_ID/logs/bootstrap.log - --region $REGION"
echo " 状态         : aws s3 cp s3://$BUCKET/runs/$RUN_ID/logs/status.json - --region $REGION"
echo " 结果         : aws s3 ls s3://$BUCKET/runs/$RUN_ID/results/ --region $REGION"
echo " 进机器       : aws ssm start-session --target $INSTANCE_ID --region $REGION"
echo " 手工停机     : aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION"
echo "=============================================================================="

# =============================================================================
# Step j) --wait：不靠 SSH、不靠常驻会话地观察进度
# =============================================================================
if [[ "$WAIT_MODE" != "true" ]]; then
    log "未开启 --wait，脚本退出；实例会自己跑完并自终止"
    exit 0
fi

section "Step j) 观察模式（--wait）"
LAST_LOG_SIZE=0
DEADLINE=$(( $(date +%s) + WAIT_TIMEOUT_MINUTES * 60 ))
while (( $(date +%s) < DEADLINE )); do
    STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)
    HEARTBEAT=$(aws cloudwatch get-metric-statistics --region "$REGION" \
        --namespace TpotBench --metric-name Heartbeat \
        --dimensions "Name=RunId,Value=$RUN_ID" "Name=Stage,Value=$STAGE" \
        --start-time "$(date -u -d '10 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --period 60 --statistics Sum \
        --query 'length(Datapoints)' --output text 2>/dev/null || echo 0)
    STATUS_JSON=$(aws s3 cp "s3://$BUCKET/runs/$RUN_ID/logs/status.json" - \
        --region "$REGION" 2>/dev/null || echo "")
    PHASE_NOW=$(echo "$STATUS_JSON" | sed -n 's/.*"phase": "\([^"]*\)".*/\1/p' | head -n1)
    log "实例=$STATE 心跳数据点=$HEARTBEAT 阶段=${PHASE_NOW:-未知}"
    aws s3 ls "s3://$BUCKET/runs/$RUN_ID/results/" --region "$REGION" 2>/dev/null || true

    # 增量 tail 已流到 S3 的 bootstrap.log
    LOG_LOCAL="$WORK_DIR/bootstrap.log"
    if aws s3 cp "s3://$BUCKET/runs/$RUN_ID/logs/bootstrap.log" "$LOG_LOCAL" \
            --region "$REGION" --only-show-errors 2>/dev/null; then
        NEW_SIZE=$(wc -c <"$LOG_LOCAL" | tr -d ' ')
        if (( NEW_SIZE > LAST_LOG_SIZE )); then
            tail -c "$(( NEW_SIZE - LAST_LOG_SIZE ))" "$LOG_LOCAL"
            LAST_LOG_SIZE="$NEW_SIZE"
        fi
    fi

    case "$PHASE_NOW" in
        completed|failed|spot_interrupted|deadline_exceeded)
            log "运行进入终态: $PHASE_NOW"
            break ;;
    esac
    if [[ "$STATE" == "terminated" || "$STATE" == "shutting-down" ]]; then
        log "实例已进入 $STATE，停止观察"
        break
    fi
    sleep 30
done
log "观察结束。完整产物: s3://$BUCKET/runs/$RUN_ID/"
exit 0
