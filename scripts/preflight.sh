#!/usr/bin/env bash
# =============================================================================
# TPOT Benchmark 零成本预检脚本 (preflight)
# 用途：在启动任何付费 EC2 实例之前，仅用只读 AWS API（describe-* / get-*）、
#       HuggingFace API 以及 run-instances --dry-run，回答所有 go/no-go 问题。
#
# 本脚本不会创建任何 AWS 资源，不会产生任何计算费用（$0）。
#
# 背景：上一次裸 EC2 启动在 13h14m 内烧掉约 $353 且没有产出任何测量数据，
#       根因是 p5en.48xlarge 的 30.4 TB 本地 NVMe 完全没被挂载、权重被写到
#       200 GB 小根盘导致磁盘写满。这里的每一项检查都对应一个当时没人问的问题。
#
# 注意：沙箱环境默认导出 AWS_REGION=us-east-1，而本任务全部面向 us-east-2，
#       因此下面每一个 aws 调用都显式传 --region。
# =============================================================================
set -euo pipefail

# =============================================================================
# 可配置参数（默认值）
# =============================================================================
REGION="${REGION:-us-east-2}"
AZ="${AZ:-us-east-2a}"
INSTANCE_TYPE="${INSTANCE_TYPE:-p5en.48xlarge}"
MODEL_NAME="${MODEL_NAME:-deepseek-ai/DeepSeek-V4-Flash}"
BUCKET="${BUCKET:-}"                       # 留空则按 tpot-bench-results-<account>-<region> 推导
IMAGE_ID="${IMAGE_ID:-}"                   # 留空则动态解析 DLAMI
MAX_PRICE="${MAX_PRICE:-35.00}"            # Spot 价格上限（上次启动用的就是 35.00）
SUBNET_ID="${SUBNET_ID:-subnet-09bfc4e5573173d64}"
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-sg-0775ac013a1b6080d}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-tpot-bench-ec2-profile}"

# 期望的 AWS 账号（防止在错误账号里花钱）
EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-077090643075}"

# P 系列 Spot 配额：L-7212CCBC = "All P Spot Instance Requests"
# 注意不要用 L-3819A6DF，那是 G/VT 系列的配额，曾被误读过
SPOT_QUOTA_CODE="${SPOT_QUOTA_CODE:-L-7212CCBC}"

# DLAMI 的 SSM 公共参数路径（通过 get-parameters-by-path 枚举确认，不是猜的）
# 当前在 us-east-2 解析结果为 ami-0b80a5f61a0bca5dd
#   = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) 20260804"
# 这里只在注释里写死该 AMI id 作为参考，运行时一律动态解析
DLAMI_SSM_PARAM="${DLAMI_SSM_PARAM:-/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id}"
DLAMI_NAME_FILTER="${DLAMI_NAME_FILTER:-Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*}"

# 本地 NVUMe 做 RAID0 后预留给文件系统 / 元数据 / 解压缓冲的比例
STORAGE_RESERVE_PCT="${STORAGE_RESERVE_PCT:-10}"

# 项目标签，setup-infra.sh 的 IAM 条件与 FEAT-002 的 launcher 都依赖它
PROJECT_TAG="${PROJECT_TAG:-tpot-benchmark}"

# 根盘大小（仅用于 dry-run 的 block-device-mappings，与真实启动保持一致）
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-200}"

# =============================================================================
# 命令行参数解析
# =============================================================================
usage() {
    cat <<EOF
用法: $0 [选项]

零成本预检：只调用只读 AWS API + HuggingFace API + run-instances --dry-run。
不创建任何资源，不产生任何计算费用。任一检查 FAIL 时以非零状态退出。

选项:
  --region REGION           AWS Region (默认: $REGION)
  --az AZ                   目标可用区 (默认: $AZ)
  --instance-type TYPE      目标实例类型 (默认: $INSTANCE_TYPE)
  --model MODEL             HuggingFace 模型 repo (默认: $MODEL_NAME)
  --bucket NAME             S3 结果桶 (默认: tpot-bench-results-<account>-<region>)
  --image-id AMI            跳过动态解析，直接指定 AMI id
  --max-price PRICE         Spot 价格上限，超过则 FAIL (默认: $MAX_PRICE)
  --subnet-id ID            目标子网 (默认: $SUBNET_ID)
  --security-group-id ID    目标安全组 (默认: $SECURITY_GROUP_ID)
  --instance-profile NAME   IAM 实例配置文件 (默认: $INSTANCE_PROFILE_NAME)
  --help                    显示帮助信息

示例:
  # 标准预检（H200 / us-east-2a）
  ./scripts/preflight.sh --region us-east-2 --az us-east-2a

  # 验证 FAIL 路径确实会非零退出
  ./scripts/preflight.sh --region us-east-2 --az us-east-2a --max-price 1.00

  # 预检便宜的管路验证实例
  ./scripts/preflight.sh --instance-type c5d.large --max-price 0.20

  # 预检 Hopper 上的 FP8 重打包 checkpoint
  ./scripts/preflight.sh --model sgl-project/DeepSeek-V4-Flash-FP8
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        --az) AZ="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --model) MODEL_NAME="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --image-id) IMAGE_ID="$2"; shift 2 ;;
        --max-price) MAX_PRICE="$2"; shift 2 ;;
        --subnet-id) SUBNET_ID="$2"; shift 2 ;;
        --security-group-id) SECURITY_GROUP_ID="$2"; shift 2 ;;
        --instance-profile) INSTANCE_PROFILE_NAME="$2"; shift 2 ;;
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

# 检查结果收集（最后统一打印汇总表）
CHECK_COUNT=0
WARNINGS=()
FAIL_COUNT=0

record() {
    # record <id> <name> <PASS|FAIL|WARN> <detail>
    CHECK_COUNT=$((CHECK_COUNT + 1))
    printf '%s\t%s\t%s\t%s\n' "$1" "$3" "$2" "$4" >>"$ROWS_FILE"
    if [[ "$3" == "FAIL" ]]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "  -> FAIL: $4"
    else
        log "  -> $3: $4"
    fi
}

warn() {
    WARNINGS+=("$*")
    log "  [警告] $*"
}

section() {
    echo ""
    echo "# ============================================================================="
    echo "# $*"
    echo "# ============================================================================="
}

# 浮点比较：a > b ?
gt() {
    python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) > float(sys.argv[2]) else 1)" "$1" "$2"
}

TMPDIR_PF="$(mktemp -d)"
ROWS_FILE="$TMPDIR_PF/rows.tsv"
: >"$ROWS_FILE"
# shellcheck disable=SC2329  # 由下面的 trap cleanup EXIT 间接调用
cleanup() {
    rm -rf "$TMPDIR_PF"
}
trap cleanup EXIT

# 按终端显示宽度对齐（中文占两列，printf 的 %-Ns 只按字符数补齐会错位）
render_table() {
    python3 - "$ROWS_FILE" <<'PYEOF'
import sys, unicodedata

def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)

def pad(s, n):
    return s + " " * max(0, n - width(s))

rows = []
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line:
            rows.append(line.split("\t", 3))

name_w = max([width("检查项")] + [width(r[2]) for r in rows]) if rows else 12
print(" %s %s %s %s" % (pad("#", 3), pad("结果", 6), pad("检查项", name_w), "说明"))
print("-" * 78)
for r in rows:
    print(" %s %s %s %s" % (pad(r[0], 3), pad(r[1], 6), pad(r[2], name_w), r[3]))
PYEOF
}

# =============================================================================
# Step a) 检查工具依赖
# =============================================================================
log "TPOT Benchmark 预检开始（零成本，只读 API + dry-run）"
for cmd in aws python3 curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "错误: 未找到命令 '$cmd'，请先安装" >&2
        exit 1
    fi
done
log "工具依赖检查通过: aws, python3, curl"

# =============================================================================
# Check 1) 身份与 Region
# =============================================================================
section "Check 1) 身份与 Region"
if ! IDENTITY=$(aws sts get-caller-identity --region "$REGION" --output json 2>&1); then
    record 1 "身份与 Region" FAIL "aws sts get-caller-identity 失败: $IDENTITY"
    ACCOUNT_ID=""
else
    ACCOUNT_ID=$(echo "$IDENTITY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Account"])')
    CALLER_ARN=$(echo "$IDENTITY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Arn"])')
    log "  Account : $ACCOUNT_ID"
    log "  Arn     : $CALLER_ARN"
    log "  Region  : $REGION"
    log "  AZ      : $AZ"
    if [[ "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT" ]]; then
        record 1 "身份与 Region" FAIL "账号不匹配：期望 $EXPECTED_ACCOUNT，实际 $ACCOUNT_ID"
    elif [[ "$AZ" != "$REGION"* ]]; then
        record 1 "身份与 Region" FAIL "AZ $AZ 不属于 Region $REGION"
    else
        record 1 "身份与 Region" PASS "账号 $ACCOUNT_ID / $REGION / $AZ"
    fi
fi

# 账号确定后再推导默认桶名
if [[ -z "$BUCKET" ]]; then
    BUCKET="tpot-bench-results-${ACCOUNT_ID:-$EXPECTED_ACCOUNT}-${REGION}"
fi
log "  结果桶  : $BUCKET"

# =============================================================================
# Check 2) Spot 配额 vs 实例 vCPU 需求
# =============================================================================
section "Check 2) Spot 配额 ($SPOT_QUOTA_CODE)"
INSTANCE_JSON="$TMPDIR_PF/instance-type.json"
if ! aws ec2 describe-instance-types --region "$REGION" \
        --instance-types "$INSTANCE_TYPE" --output json >"$INSTANCE_JSON" 2>"$TMPDIR_PF/it.err"; then
    record 2 "Spot 配额" FAIL "describe-instance-types 失败: $(cat "$TMPDIR_PF/it.err")"
    REQUIRED_VCPUS=0
else
    REQUIRED_VCPUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["InstanceTypes"][0]["VCpuInfo"]["DefaultVCpus"])' "$INSTANCE_JSON")
    if ! QUOTA_JSON=$(aws service-quotas get-service-quota --region "$REGION" \
            --service-code ec2 --quota-code "$SPOT_QUOTA_CODE" --output json 2>&1); then
        record 2 "Spot 配额" FAIL "get-service-quota $SPOT_QUOTA_CODE 失败: $QUOTA_JSON"
    else
        QUOTA_NAME=$(echo "$QUOTA_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Quota"]["QuotaName"])')
        QUOTA_VALUE=$(echo "$QUOTA_JSON" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["Quota"]["Value"]))')
        log "  配额名称: $QUOTA_NAME ($SPOT_QUOTA_CODE)"
        log "  配额额度: $QUOTA_VALUE vCPUs"
        log "  本次需要: $REQUIRED_VCPUS vCPUs ($INSTANCE_TYPE)"
        if (( REQUIRED_VCPUS > QUOTA_VALUE )); then
            record 2 "Spot 配额" FAIL "需要 $REQUIRED_VCPUS vCPUs 超过配额 $QUOTA_VALUE vCPUs"
        else
            record 2 "Spot 配额" PASS "$QUOTA_VALUE vCPUs 配额 >= $REQUIRED_VCPUS vCPUs 需求"
        fi
    fi
fi

# =============================================================================
# Check 3) 本地实例存储（Instance Store）
# 上次失败的头号根因：30.4 TB 本地 NVMe 一块都没挂
# =============================================================================
section "Check 3) 本地实例存储 (Instance Store)"
STORE_TOTAL_GB=0
if [[ ! -s "$INSTANCE_JSON" ]]; then
    record 3 "本地实例存储" FAIL "无法获取实例类型信息，跳过存储检查"
else
    STORE_SUMMARY=$(python3 - "$INSTANCE_JSON" <<'PYEOF'
import json, sys
it = json.load(open(sys.argv[1]))["InstanceTypes"][0]
info = it.get("InstanceStorageInfo")
if not info:
    print("NULL\t0\t0\t0\tnone\tfalse")
    sys.exit(0)
disks = info.get("Disks") or []
count = sum(d.get("Count", 0) for d in disks)
size = disks[0].get("SizeInGB", 0) if disks else 0
kind = disks[0].get("Type", "unknown") if disks else "unknown"
print("OK\t%d\t%d\t%d\t%s\t%s" % (
    count, size, info.get("TotalSizeInGB", 0), kind, str(info.get("NvmeSupport", "unknown"))))
PYEOF
)
    STORE_FLAG=$(echo "$STORE_SUMMARY" | cut -f1)
    STORE_DISKS=$(echo "$STORE_SUMMARY" | cut -f2)
    STORE_DISK_GB=$(echo "$STORE_SUMMARY" | cut -f3)
    STORE_TOTAL_GB=$(echo "$STORE_SUMMARY" | cut -f4)
    STORE_TYPE=$(echo "$STORE_SUMMARY" | cut -f5)
    STORE_NVME=$(echo "$STORE_SUMMARY" | cut -f6)
    if [[ "$STORE_FLAG" == "NULL" ]]; then
        record 3 "本地实例存储" FAIL "$INSTANCE_TYPE 的 InstanceStorageInfo 为 null；整套设计依赖本地 NVMe，不能只靠 EBS 根盘"
    else
        log "  磁盘数量: $STORE_DISKS"
        log "  单盘容量: $STORE_DISK_GB GB ($STORE_TYPE)"
        log "  总容量  : $STORE_TOTAL_GB GB"
        log "  NVMe    : $STORE_NVME"
        record 3 "本地实例存储" PASS "$STORE_DISKS x $STORE_DISK_GB GB = $STORE_TOTAL_GB GB ($STORE_TYPE, NVMe=$STORE_NVME)"
    fi
fi

# 规划的权重落盘目标：本地 NVMe RAID0，扣掉预留比例后的可用空间
USABLE_GB=$(python3 -c "print(int(int('$STORE_TOTAL_GB') * (100 - int('$STORAGE_RESERVE_PCT')) / 100))")
log "  规划可用: $USABLE_GB GB（RAID0 总量扣除 ${STORAGE_RESERVE_PCT}% 预留）"

# =============================================================================
# Check 4) Spot 实时价格
# =============================================================================
section "Check 4) Spot 实时价格 (上限 \$$MAX_PRICE/hr)"
SPOT_FILE="$TMPDIR_PF/spot.txt"
if ! aws ec2 describe-spot-price-history --region "$REGION" \
        --instance-types "$INSTANCE_TYPE" \
        --product-descriptions "Linux/UNIX" \
        --start-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' \
        --output text >"$SPOT_FILE" 2>"$TMPDIR_PF/spot.err"; then
    record 4 "Spot 实时价格" FAIL "describe-spot-price-history 失败: $(cat "$TMPDIR_PF/spot.err")"
    AZ_PRICE=""
else
    AZ_PRICE=""
    while IFS=$'\t' read -r sp_az sp_price; do
        [[ -z "$sp_az" ]] && continue
        if [[ "$sp_az" == "$AZ" ]]; then
            AZ_PRICE="$sp_price"
            log "  $sp_az : \$$sp_price/hr   <= 目标 AZ"
        else
            log "  $sp_az : \$$sp_price/hr"
        fi
    done <"$SPOT_FILE"

    if [[ -z "$AZ_PRICE" ]]; then
        record 4 "Spot 实时价格" FAIL "目标 AZ $AZ 没有 $INSTANCE_TYPE 的 Spot 报价（可能该 AZ 无此机型容量）"
    elif gt "$AZ_PRICE" "$MAX_PRICE"; then
        record 4 "Spot 实时价格" FAIL "$AZ 现价 \$$AZ_PRICE/hr 超过上限 \$$MAX_PRICE/hr"
    else
        record 4 "Spot 实时价格" PASS "$AZ 现价 \$$AZ_PRICE/hr <= 上限 \$$MAX_PRICE/hr"
    fi
fi

# =============================================================================
# Check 5) AMI 动态解析
# =============================================================================
section "Check 5) AMI 解析 (Deep Learning Base OSS Nvidia Driver GPU AMI)"
RESOLVED_AMI=""
AMI_SOURCE=""
if [[ -n "$IMAGE_ID" ]]; then
    RESOLVED_AMI="$IMAGE_ID"
    AMI_SOURCE="--image-id 覆盖"
elif SSM_AMI=$(aws ssm get-parameter --region "$REGION" --name "$DLAMI_SSM_PARAM" \
        --query 'Parameter.Value' --output text 2>/dev/null) && [[ -n "$SSM_AMI" && "$SSM_AMI" != "None" ]]; then
    RESOLVED_AMI="$SSM_AMI"
    AMI_SOURCE="SSM 公共参数 $DLAMI_SSM_PARAM"
else
    log "  SSM 参数不可用，回退到 describe-images 按名称过滤"
    FALLBACK_AMI=$(aws ec2 describe-images --region "$REGION" --owners amazon \
        --filters "Name=name,Values=$DLAMI_NAME_FILTER" "Name=state,Values=available" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text 2>/dev/null || echo "None")
    if [[ -n "$FALLBACK_AMI" && "$FALLBACK_AMI" != "None" ]]; then
        RESOLVED_AMI="$FALLBACK_AMI"
        AMI_SOURCE="describe-images 名称过滤（按 CreationDate 取最新）"
    fi
fi

if [[ -z "$RESOLVED_AMI" ]]; then
    record 5 "AMI 解析" FAIL "无法解析 DLAMI（SSM 参数与 describe-images 回退均失败）"
else
    AMI_META=$(aws ec2 describe-images --region "$REGION" --image-ids "$RESOLVED_AMI" \
        --query 'Images[0].[Name,CreationDate,Architecture,RootDeviceType]' --output text 2>/dev/null || echo -e "unknown\tunknown\tunknown\tunknown")
    AMI_NAME=$(echo "$AMI_META" | cut -f1)
    AMI_DATE=$(echo "$AMI_META" | cut -f2)
    AMI_ARCH=$(echo "$AMI_META" | cut -f3)
    log "  来源    : $AMI_SOURCE"
    log "  AMI id  : $RESOLVED_AMI"
    log "  名称    : $AMI_NAME"
    log "  创建时间: $AMI_DATE"
    log "  架构    : $AMI_ARCH"
    record 5 "AMI 解析" PASS "$RESOLVED_AMI ($AMI_NAME, $AMI_DATE)"
fi

# =============================================================================
# Check 6) Checkpoint 体积与精度
# 上次失败的第二根因：FP4 MoE 专家权重 + Hopper 无原生 FP4
# =============================================================================
section "Check 6) Checkpoint 体积与精度 ($MODEL_NAME)"
HF_META="$TMPDIR_PF/hf-model.json"
HF_CONFIG="$TMPDIR_PF/hf-config.json"
CKPT_GB=0
if ! curl -fsSL "https://huggingface.co/api/models/${MODEL_NAME}?blobs=true" -o "$HF_META" 2>"$TMPDIR_PF/hf.err"; then
    record 6 "Checkpoint 体积与精度" FAIL "HuggingFace API 查询失败: $(cat "$TMPDIR_PF/hf.err")"
else
    curl -fsSL "https://huggingface.co/${MODEL_NAME}/resolve/main/config.json" -o "$HF_CONFIG" 2>/dev/null || echo '{}' >"$HF_CONFIG"
    CKPT_SUMMARY=$(python3 - "$HF_META" "$HF_CONFIG" <<'PYEOF'
import json, sys
meta = json.load(open(sys.argv[1]))
try:
    cfg = json.load(open(sys.argv[2]))
except Exception:
    cfg = {}
siblings = meta.get("siblings") or []
total = sum((s.get("size") or 0) for s in siblings)
quant = (cfg.get("quantization_config") or {}).get("quant_method") or "unknown"
print("%d\t%d\t%.1f\t%.1f\t%s\t%s\t%s\t%s" % (
    len(siblings),
    total,
    total / 1e9,
    total / 2 ** 30,
    cfg.get("expert_dtype") or "unknown",
    quant,
    str(meta.get("gated")),
    str(cfg.get("num_nextn_predict_layers", "unknown")),
))
PYEOF
)
    CKPT_FILES=$(echo "$CKPT_SUMMARY" | cut -f1)
    CKPT_BYTES=$(echo "$CKPT_SUMMARY" | cut -f2)
    CKPT_GB=$(echo "$CKPT_SUMMARY" | cut -f3)
    CKPT_GIB=$(echo "$CKPT_SUMMARY" | cut -f4)
    CKPT_EXPERT_DTYPE=$(echo "$CKPT_SUMMARY" | cut -f5)
    CKPT_QUANT=$(echo "$CKPT_SUMMARY" | cut -f6)
    CKPT_GATED=$(echo "$CKPT_SUMMARY" | cut -f7)
    CKPT_NEXTN=$(echo "$CKPT_SUMMARY" | cut -f8)

    log "  文件数量: $CKPT_FILES"
    log "  总体积  : $CKPT_GB GB / $CKPT_GIB GiB ($CKPT_BYTES bytes)"
    log "  专家精度: expert_dtype=$CKPT_EXPERT_DTYPE"
    log "  量化方式: quantization_config.quant_method=$CKPT_QUANT"
    log "  gated   : $CKPT_GATED"
    log "  MTP 头  : num_nextn_predict_layers=$CKPT_NEXTN"

    # 与规划阶段已核对过的已知值做交叉校验（发现漂移就提示，不直接 FAIL）
    case "$MODEL_NAME" in
        deepseek-ai/DeepSeek-V4-Flash)       EXPECT_FILES=73; EXPECT_GB=159.6 ;;
        deepseek-ai/DeepSeek-V4-Flash-0731)  EXPECT_FILES=74; EXPECT_GB=166.9 ;;
        sgl-project/DeepSeek-V4-Flash-FP8)   EXPECT_FILES=55; EXPECT_GB=294.1 ;;
        *)                                   EXPECT_FILES=""; EXPECT_GB="" ;;
    esac
    if [[ -n "$EXPECT_FILES" ]]; then
        if [[ "$CKPT_FILES" != "$EXPECT_FILES" ]] || [[ "$CKPT_GB" != "$EXPECT_GB" ]]; then
            warn "checkpoint 与规划记录不一致：期望 ${EXPECT_FILES} 文件 / ${EXPECT_GB} GB，实测 ${CKPT_FILES} 文件 / ${CKPT_GB} GB（上游可能更新了权重）"
        else
            log "  交叉校验: 与规划记录一致（$EXPECT_FILES 文件 / $EXPECT_GB GB）"
        fi
    fi

    if [[ "$CKPT_GATED" == "True" ]]; then
        warn "该 repo 是 gated 的，实例上必须提供 HF_TOKEN 才能下载"
    fi

    # GPU 架构与 FP4 兼容性
    GPU_NAME=$(python3 -c 'import json,sys
try:
    it = json.load(open(sys.argv[1]))["InstanceTypes"][0]
    g = (it.get("GpuInfo") or {}).get("Gpus") or []
    print(g[0]["Name"] if g else "none")
except Exception:
    print("unknown")' "$INSTANCE_JSON" 2>/dev/null || echo unknown)
    log "  目标 GPU: $GPU_NAME"
    if [[ "$CKPT_EXPERT_DTYPE" == "fp4" ]] && [[ "$GPU_NAME" == "H200" || "$GPU_NAME" == "H100" ]]; then
        warn "expert_dtype=fp4 但目标 GPU 是 $GPU_NAME（Hopper SM90，无原生 FP4）。上游 cookbook 只给了两条路："
        warn "  (a) 直接跑原始 FP4 checkpoint，走 W4A16 Marlin MoE kernels —— 只能纯 TP，不能用 DP-attention 或 DeepEP"
        warn "  (b) 换成预打包的 FP8 checkpoint sgl-project/DeepSeek-V4-Flash-FP8（55 文件 / 294.1 GB / 273.9 GiB）—— 可用 DP-attention + DeepEP"
        warn "  注意 deepseek-ai/DeepSeek-V4-Flash-Base 虽然是纯 FP8，但 cookbook 明确只用于继续预训练，不可用于 chat / tool calling"
    fi

    # 容量能不能装下
    if [[ "$STORE_TOTAL_GB" == "0" ]]; then
        record 6 "Checkpoint 体积与精度" FAIL "无本地实例存储可用，$CKPT_GB GB 权重无处安放"
    elif gt "$CKPT_GB" "$USABLE_GB"; then
        record 6 "Checkpoint 体积与精度" FAIL "权重 $CKPT_GB GB 装不进规划的 $USABLE_GB GB 可用空间"
    else
        record 6 "Checkpoint 体积与精度" PASS "$CKPT_FILES 文件 / $CKPT_GB GB / $CKPT_GIB GiB, expert_dtype=$CKPT_EXPERT_DTYPE, 可装入 $USABLE_GB GB"
    fi
fi

# =============================================================================
# Check 7) 子网与安全组
# =============================================================================
section "Check 7) 子网与安全组"
if ! SUBNET_META=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$SUBNET_ID" \
        --query 'Subnets[0].[AvailabilityZone,VpcId,AvailableIpAddressCount,MapPublicIpOnLaunch]' \
        --output text 2>&1); then
    record 7 "子网与安全组" FAIL "describe-subnets $SUBNET_ID 失败: $SUBNET_META"
else
    SUBNET_AZ=$(echo "$SUBNET_META" | cut -f1)
    SUBNET_VPC=$(echo "$SUBNET_META" | cut -f2)
    SUBNET_IPS=$(echo "$SUBNET_META" | cut -f3)
    SUBNET_PUBIP=$(echo "$SUBNET_META" | cut -f4)
    log "  子网    : $SUBNET_ID"
    log "  AZ      : $SUBNET_AZ"
    log "  VPC     : $SUBNET_VPC"
    log "  可用 IP : $SUBNET_IPS"
    log "  自动公网IP: $SUBNET_PUBIP"

    log "  安全组  : $SECURITY_GROUP_ID 入站规则:"
    # shellcheck disable=SC2016  # JMESPath 表达式里的反引号是 AWS 语法，不能让 shell 展开
    SG_RULES=$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$SECURITY_GROUP_ID" \
        --query 'SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,join(`,`,IpRanges[].CidrIp)]' \
        --output text 2>&1 || echo "")
    if [[ -z "$SG_RULES" || "$SG_RULES" == "None" ]]; then
        log "    （无入站规则 —— SSM 会话不需要任何入站放行，这是期望状态）"
    else
        while IFS= read -r sg_line; do
            [[ -z "$sg_line" ]] && continue
            echo "    $sg_line"
        done <<<"$SG_RULES"
        if echo "$SG_RULES" | grep -q '0\.0\.0\.0/0'; then
            warn "安全组 $SECURITY_GROUP_ID 仍存在 0.0.0.0/0 入站规则，建议运行 setup-infra.sh --harden-existing"
        fi
    fi

    if [[ "$SUBNET_AZ" != "$AZ" ]]; then
        record 7 "子网与安全组" FAIL "子网 $SUBNET_ID 在 $SUBNET_AZ，与目标 AZ $AZ 不符"
    else
        record 7 "子网与安全组" PASS "$SUBNET_ID 位于 $SUBNET_AZ (VPC $SUBNET_VPC), 可用 IP $SUBNET_IPS"
    fi
fi

# =============================================================================
# Check 8) run-instances --dry-run
# 用与 FEAT-002 launcher 完全一致的参数表演练一次，DryRunOperation 即为通过
# =============================================================================
section "Check 8) run-instances --dry-run（不会启动任何实例）"
if [[ -z "$RESOLVED_AMI" ]]; then
    record 8 "启动 dry-run" FAIL "AMI 未解析，无法组装 run-instances 参数"
else
    DRY_ARGS=(
        ec2 run-instances
        --region "$REGION"
        --dry-run
        --image-id "$RESOLVED_AMI"
        --instance-type "$INSTANCE_TYPE"
        --count 1
        --subnet-id "$SUBNET_ID"
        --security-group-ids "$SECURITY_GROUP_ID"
        --instance-initiated-shutdown-behavior terminate
        --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2"
        --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${ROOT_VOLUME_GB},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"
        --instance-market-options "MarketType=spot,SpotOptions={MaxPrice=${MAX_PRICE},SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=${PROJECT_TAG}},{Key=Name,Value=tpot-bench-${INSTANCE_TYPE//./-}}]"
    )

    # 实例配置文件只在已存在时加入；否则 dry-run 会因为找不到 profile 而报无关错误
    if aws iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
        DRY_ARGS+=(--iam-instance-profile "Name=$INSTANCE_PROFILE_NAME")
        log "  IAM 实例配置文件: $INSTANCE_PROFILE_NAME（已存在，纳入 dry-run）"
    else
        warn "IAM 实例配置文件 $INSTANCE_PROFILE_NAME 不存在，dry-run 将不带它；请先运行 setup-infra.sh"
    fi

    log "  执行: aws ${DRY_ARGS[*]}"
    if DRY_OUT=$(aws "${DRY_ARGS[@]}" 2>&1); then
        # --dry-run 正常绝不会成功返回；真成功了说明参数被忽略，属于异常
        record 8 "启动 dry-run" FAIL "dry-run 意外返回成功，请检查 AWS CLI 是否忽略了 --dry-run: $DRY_OUT"
    elif echo "$DRY_OUT" | grep -q 'DryRunOperation'; then
        record 8 "启动 dry-run" PASS "DryRunOperation —— 参数与权限均有效，未启动任何实例"
    else
        record 8 "启动 dry-run" FAIL "$DRY_OUT"
    fi
fi

# =============================================================================
# 汇总表（放在最后，方便 log tail 直接看结论）
# =============================================================================
echo ""
echo "=============================================================================="
echo " TPOT Benchmark 预检汇总"
echo "=============================================================================="
render_table
echo "------------------------------------------------------------------------------"
if (( ${#WARNINGS[@]} > 0 )); then
    echo " 警告 (${#WARNINGS[@]} 条):"
    for w in "${WARNINGS[@]}"; do
        echo "   - $w"
    done
    echo "------------------------------------------------------------------------------"
fi
echo " 目标        : $INSTANCE_TYPE @ $AZ ($REGION)"
echo " AMI         : ${RESOLVED_AMI:-未解析}"
echo " 模型        : $MODEL_NAME (${CKPT_GB} GB)"
echo " 结果桶      : s3://$BUCKET"
echo " 实例配置文件: $INSTANCE_PROFILE_NAME"
echo " Spot 现价   : \$${AZ_PRICE:-N/A}/hr (上限 \$$MAX_PRICE)"
echo " 本次预检花费: \$0（只读 API + dry-run，未启动任何实例）"
echo "=============================================================================="
if (( FAIL_COUNT > 0 )); then
    echo " 结论: FAIL —— $FAIL_COUNT / $CHECK_COUNT 项检查未通过，禁止启动"
    echo "=============================================================================="
    exit 1
fi
echo " 结论: PASS —— $CHECK_COUNT / $CHECK_COUNT 项检查通过，可以进入下一阶段"
echo "=============================================================================="
exit 0
