#!/usr/bin/env bash
# =============================================================================
# TPOT Benchmark 免费前置资源初始化脚本 (setup-infra)
# 用途：创建 benchmark 运行所必需的、完全免费的 AWS 前置资源：
#         1. S3 结果桶（阻断公网访问、默认 SSE、不开版本控制）
#         2. IAM 角色 + 实例配置文件（SSM 会话 + 限定作用域的 S3 写入 +
#            CloudWatch PutMetricData + 按标签限定的自我终止权限）
#       并可选清理上一次失败运行留下的两个安全问题（--harden-existing）。
#
# 本脚本幂等，可反复执行；不创建任何 EC2 资源，不产生任何计算费用。
# IAM 与 S3 桶本身都是免费的。
#
# 背景：上次裸 EC2 启动没有实例配置文件，因此没有 SSM shell、没有 GPU 指标、
#       也没有任何东西被持久化到 S3。会话一挂，13 小时的算力就彻底浪费了。
#
# 注意：沙箱环境默认导出 AWS_REGION=us-east-1，因此每个 aws 调用都显式传 --region。
# =============================================================================
set -euo pipefail

# =============================================================================
# 可配置参数（默认值）
# =============================================================================
REGION="${REGION:-us-east-2}"
BUCKET="${BUCKET:-}"                       # 留空则按 tpot-bench-results-<account>-<region> 推导
ROLE_NAME="${ROLE_NAME:-tpot-bench-ec2-role}"
PROFILE_NAME="${PROFILE_NAME:-tpot-bench-ec2-profile}"
INLINE_POLICY_NAME="${INLINE_POLICY_NAME:-tpot-bench-scoped-access}"
SSM_MANAGED_POLICY_ARN="${SSM_MANAGED_POLICY_ARN:-arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore}"
PROJECT_TAG="${PROJECT_TAG:-tpot-benchmark}"

# --harden-existing 要清理的遗留资源（来自上一次失败运行）
LEGACY_SG_ID="${LEGACY_SG_ID:-sg-0775ac013a1b6080d}"
LEGACY_KEY_NAME="${LEGACY_KEY_NAME:-tpot-bench-key}"

HARDEN_EXISTING=false

# =============================================================================
# 命令行参数解析
# =============================================================================
usage() {
    cat <<EOF
用法: $0 [选项]

创建 benchmark 所需的免费前置资源（S3 结果桶 + IAM 角色/实例配置文件）。
幂等：已存在的资源只做校验与补齐，不会重复创建。不创建任何 EC2 资源。

选项:
  --region REGION           AWS Region (默认: $REGION)
  --bucket NAME             S3 结果桶名 (默认: tpot-bench-results-<account>-<region>)
  --role-name NAME          IAM 角色名 (默认: $ROLE_NAME)
  --profile-name NAME       IAM 实例配置文件名 (默认: $PROFILE_NAME)
  --harden-existing         额外清理上次运行的遗留问题：
                              - 撤销 $LEGACY_SG_ID 上的 SSH 0.0.0.0/0 入站规则
                              - 删除密钥对 $LEGACY_KEY_NAME（私钥已丢失，SSM 方案不需要）
                            两者都带存在性判断，重复执行为 no-op。
                            不会触碰 us-east-2b/2c 那两块无关的 250 GB st1 卷。
  --help                    显示帮助信息

示例:
  # 首次初始化 + 清理遗留问题
  ./scripts/setup-infra.sh --region us-east-2 --harden-existing

  # 仅校验现有资源是否齐全（幂等复跑）
  ./scripts/setup-infra.sh --region us-east-2
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region) REGION="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --role-name) ROLE_NAME="$2"; shift 2 ;;
        --profile-name) PROFILE_NAME="$2"; shift 2 ;;
        --harden-existing) HARDEN_EXISTING=true; shift ;;
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

CREATED=()
FOUND=()
CHANGED=()

created() { CREATED+=("$1"); log "  [创建] $1"; }
found()   { FOUND+=("$1");   log "  [已存在] $1"; }
changed() { CHANGED+=("$1"); log "  [修改] $1"; }

TMPDIR_SI="$(mktemp -d)"
# shellcheck disable=SC2329  # 由下面的 trap cleanup EXIT 间接调用
cleanup() {
    rm -rf "$TMPDIR_SI"
}
trap cleanup EXIT

# =============================================================================
# Step a) 检查工具依赖与身份
# =============================================================================
log "TPOT Benchmark 免费前置资源初始化开始 (region=$REGION)"
for cmd in aws python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "错误: 未找到命令 '$cmd'，请先安装" >&2
        exit 1
    fi
done

ACCOUNT_ID=$(aws sts get-caller-identity --region "$REGION" --query Account --output text)
log "  Account : $ACCOUNT_ID"
if [[ -z "$BUCKET" ]]; then
    BUCKET="tpot-bench-results-${ACCOUNT_ID}-${REGION}"
fi
BUCKET_ARN="arn:aws:s3:::${BUCKET}"
log "  结果桶  : $BUCKET"

# =============================================================================
# Step b) S3 结果桶
# =============================================================================
echo ""
log "=== Step b) S3 结果桶 ==="
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
    found "S3 桶 $BUCKET_ARN"
else
    if [[ "$REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
    else
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
            --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    fi
    created "S3 桶 $BUCKET_ARN"
fi

# 阻断所有公网访问（四项全 true）
CURRENT_PAB=$(aws s3api get-public-access-block --bucket "$BUCKET" --region "$REGION" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text 2>/dev/null || echo "missing")
if [[ "$CURRENT_PAB" == "True	True	True	True" ]]; then
    found "公网访问阻断（四项均为 true）"
else
    aws s3api put-public-access-block --bucket "$BUCKET" --region "$REGION" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    changed "公网访问阻断 -> 四项均为 true"
fi

# 默认服务端加密（SSE-S3 / AES256）
if aws s3api get-bucket-encryption --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
    found "默认加密已配置"
else
    aws s3api put-bucket-encryption --bucket "$BUCKET" --region "$REGION" \
        --server-side-encryption-configuration \
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
    changed "默认加密 -> SSE-S3 (AES256)"
fi

# 版本控制保持关闭：benchmark 产物是一次性的，开版本控制只会白花存储费
VERSIONING=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --region "$REGION" \
    --query 'Status' --output text 2>/dev/null || echo "None")
if [[ "$VERSIONING" == "Enabled" ]]; then
    aws s3api put-bucket-versioning --bucket "$BUCKET" --region "$REGION" \
        --versioning-configuration "Status=Suspended"
    changed "版本控制 Enabled -> Suspended"
else
    found "版本控制未开启 (Status=$VERSIONING)"
fi

# =============================================================================
# Step c) IAM 角色
# =============================================================================
echo ""
log "=== Step c) IAM 角色 $ROLE_NAME ==="
cat >"$TMPDIR_SI/trust.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

if ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null); then
    found "IAM 角色 $ROLE_ARN"
else
    ROLE_ARN=$(aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$TMPDIR_SI/trust.json" \
        --description "tpot-benchmark EC2 role: SSM + scoped S3 write + CloudWatch metrics + tag-scoped self-terminate" \
        --tags "Key=Project,Value=$PROJECT_TAG" \
        --query 'Role.Arn' --output text)
    created "IAM 角色 $ROLE_ARN"
fi

# 附加 AWS 托管策略：SSM 会话（替代已丢失私钥的 SSH 密钥对）
if aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
        --query 'AttachedPolicies[].PolicyArn' --output text | grep -q "$SSM_MANAGED_POLICY_ARN"; then
    found "托管策略 $SSM_MANAGED_POLICY_ARN 已附加"
else
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$SSM_MANAGED_POLICY_ARN"
    changed "附加托管策略 $SSM_MANAGED_POLICY_ARN"
fi

# 内联策略：S3 只限本桶、CloudWatch 指标、按 Project 标签限定的自我终止
cat >"$TMPDIR_SI/inline.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ScopedResultsBucketObjects",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:AbortMultipartUpload"
      ],
      "Resource": "${BUCKET_ARN}/*"
    },
    {
      "Sid": "ScopedResultsBucketList",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "${BUCKET_ARN}"
    },
    {
      "Sid": "PublishGpuAndProgressMetrics",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricData"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SelfTerminateOnlyProjectTagged",
      "Effect": "Allow",
      "Action": [
        "ec2:TerminateInstances"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Project": "${PROJECT_TAG}"
        }
      }
    }
  ]
}
EOF

EXISTING_INLINE="$TMPDIR_SI/existing-inline.json"
if aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$INLINE_POLICY_NAME" \
        --query 'PolicyDocument' --output json >"$EXISTING_INLINE" 2>/dev/null; then
    if python3 - "$EXISTING_INLINE" "$TMPDIR_SI/inline.json" <<'PYEOF'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
sys.exit(0 if a == b else 1)
PYEOF
    then
        found "内联策略 $INLINE_POLICY_NAME 已是最新"
    else
        aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "$INLINE_POLICY_NAME" \
            --policy-document "file://$TMPDIR_SI/inline.json"
        changed "内联策略 $INLINE_POLICY_NAME 已更新"
    fi
else
    aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "$INLINE_POLICY_NAME" \
        --policy-document "file://$TMPDIR_SI/inline.json"
    created "内联策略 $INLINE_POLICY_NAME（作用域限定到 $BUCKET_ARN）"
fi

# =============================================================================
# Step d) IAM 实例配置文件
# =============================================================================
echo ""
log "=== Step d) IAM 实例配置文件 $PROFILE_NAME ==="
if PROFILE_ARN=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
        --query 'InstanceProfile.Arn' --output text 2>/dev/null); then
    found "实例配置文件 $PROFILE_ARN"
else
    PROFILE_ARN=$(aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" \
        --tags "Key=Project,Value=$PROJECT_TAG" \
        --query 'InstanceProfile.Arn' --output text)
    created "实例配置文件 $PROFILE_ARN"
fi

PROFILE_ROLES=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --query 'InstanceProfile.Roles[].RoleName' --output text)
if echo "$PROFILE_ROLES" | grep -qw "$ROLE_NAME"; then
    found "角色 $ROLE_NAME 已在实例配置文件中"
else
    aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME"
    changed "把角色 $ROLE_NAME 加入实例配置文件 $PROFILE_NAME"
fi

# =============================================================================
# Step e) 清理上次运行的遗留问题（--harden-existing）
# =============================================================================
if [[ "$HARDEN_EXISTING" == "true" ]]; then
    echo ""
    log "=== Step e) 清理遗留问题 (--harden-existing) ==="

    # e1) 撤销 SSH 0.0.0.0/0
    if SG_HAS_OPEN_SSH=$(aws ec2 describe-security-groups --region "$REGION" \
            --group-ids "$LEGACY_SG_ID" \
            --query "SecurityGroups[0].IpPermissions[?FromPort==\`22\` && ToPort==\`22\` && IpProtocol=='tcp'] | [].IpRanges[] | [?CidrIp=='0.0.0.0/0'].CidrIp" \
            --output text 2>/dev/null) && [[ -n "$SG_HAS_OPEN_SSH" ]]; then
        aws ec2 revoke-security-group-ingress --region "$REGION" \
            --group-id "$LEGACY_SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
        changed "撤销 $LEGACY_SG_ID 的 SSH 22/tcp 0.0.0.0/0 入站规则"
    else
        found "$LEGACY_SG_ID 上没有 SSH 0.0.0.0/0 入站规则（无需处理）"
    fi

    # e2) 删除私钥已丢失的密钥对（新的 SSM 方案不需要密钥对）
    if KEY_ID=$(aws ec2 describe-key-pairs --region "$REGION" --key-names "$LEGACY_KEY_NAME" \
            --query 'KeyPairs[0].KeyPairId' --output text 2>/dev/null) && [[ -n "$KEY_ID" && "$KEY_ID" != "None" ]]; then
        aws ec2 delete-key-pair --region "$REGION" --key-name "$LEGACY_KEY_NAME" >/dev/null
        changed "删除密钥对 $LEGACY_KEY_NAME ($KEY_ID) —— 私钥已随上次会话丢失，无法使用"
    else
        found "密钥对 $LEGACY_KEY_NAME 不存在（无需处理）"
    fi

    log "  注意：us-east-2b/2c 那两块 2024-02-09 创建的 250 GB st1 卷与本项目无关，未触碰"
fi

# =============================================================================
# 汇总
# =============================================================================
echo ""
echo "=============================================================================="
echo " TPOT Benchmark 前置资源汇总"
echo "=============================================================================="
echo " Region              : $REGION"
echo " Account             : $ACCOUNT_ID"
echo " S3 结果桶           : $BUCKET"
echo " S3 桶 ARN           : $BUCKET_ARN"
echo " IAM 角色            : $ROLE_NAME"
echo " IAM 角色 ARN        : $ROLE_ARN"
echo " 托管策略            : $SSM_MANAGED_POLICY_ARN"
echo " 内联策略            : $INLINE_POLICY_NAME (作用域: $BUCKET_ARN)"
echo " 实例配置文件        : $PROFILE_NAME"
echo " 实例配置文件 ARN    : $PROFILE_ARN"
echo "------------------------------------------------------------------------------"
echo " 本次创建 (${#CREATED[@]} 项):"
if (( ${#CREATED[@]} == 0 )); then
    echo "   （无 —— 全部已存在，幂等复跑）"
else
    for x in "${CREATED[@]}"; do echo "   + $x"; done
fi
echo " 本次修改 (${#CHANGED[@]} 项):"
if (( ${#CHANGED[@]} == 0 )); then
    echo "   （无）"
else
    for x in "${CHANGED[@]}"; do echo "   ~ $x"; done
fi
echo " 已存在/无需处理 (${#FOUND[@]} 项)"
echo "------------------------------------------------------------------------------"
echo " 计算费用: \$0（未创建任何 EC2 资源；IAM 与 S3 桶本身免费）"
echo " 下一步  : ./scripts/preflight.sh --region $REGION --az ${REGION}a"
echo "=============================================================================="
exit 0
