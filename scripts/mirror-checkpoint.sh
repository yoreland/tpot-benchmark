#!/usr/bin/env bash
# =============================================================================
# TPOT Benchmark 权重镜像器 (mirror-checkpoint)
# 用途：把一个 HuggingFace repo 镜像到 s3://<结果桶>/checkpoints/<slug>/，
#       让重试从「再从 HuggingFace 拉 159.6 GB」变成「同 Region S3sync」。
#
# 这条脚本存在的理由写在 CloudWatch 里：上一次失败的实例 NetworkIn 总计
# 315.32 GB，其中两次约 151 GB 的尖峰（08-07 15:15 与 08-08 00:25）就是同一份
# checkpoint 下了两遍。镜像建好之后，recipe 里的 CHECKPOINT_S3_URI 一填，
# bench-bootstrap.sh 就走 `aws s3 sync` 而不再碰 HuggingFace。
#
# 花费提醒（这条脚本是本仓库里唯一会产生持续存储费的东西）：
#   S3 Standard 约 $0.023/GiB-月。159.6 GB(148.7 GiB) 的 FP4 权重约 $3.4/月，
#   294.1 GB(273.9 GiB) 的 FP8 重打包权重约 $6.3/月。入站流量免费，同 Region
#   下载到 EC2 也免费，所以真正的账单就是这份月租。
#   => 默认模式只做「体积与花费报告」，绝不上传。上传必须显式 CONFIRM_SPEND=yes。
#
# 最省钱的填充方式不是从这台沙箱上传，而是在一次 full 运行的实例上做：那台机器
# 本来就已经把权重放在本地 NVMe 上了，`aws s3 sync /mnt/nvme/models/<slug>/
# s3://.../checkpoints/<slug>/` 只是同 Region 的一次内网上传。
# 注意：沙箱默认 AWS_REGION 可能不是目标 Region，所有 aws 调用显式传 --region。
# =============================================================================
set -euo pipefail

# =============================================================================
# 可配置参数（默认值）
# =============================================================================
REGION="${REGION:-us-east-2}"
ACCOUNT_ID="${ACCOUNT_ID:-077090643075}"
BUCKET="${BUCKET:-}"                 # 留空则推导 tpot-bench-results-<account>-<region>
MODEL_NAME="${MODEL_NAME:-deepseek-ai/DeepSeek-V4-Flash}"
S3_PREFIX="${S3_PREFIX:-}"           # 留空则用 checkpoints/<slug>/
SOURCE_DIR="${SOURCE_DIR:-}"         # 本地已有权重目录（推荐：benchmark 实例上的 /mnt/nvme/models/<slug>）
MODE="report"                        # report | verify | upload
DRY_RUN=false
S3_GIB_MONTH_USD="${S3_GIB_MONTH_USD:-0.023}"

# =============================================================================
# 命令行参数解析
# =============================================================================
usage() {
    cat <<EOF
用法: $0 [选项]

默认只做体积与花费报告（零花费、零变更）。上传要显式授权。

选项:
  --model REPO_ID      HuggingFace repo (默认: $MODEL_NAME)
  --region REGION      AWS Region (默认: $REGION)
  --bucket NAME        结果桶 (默认: tpot-bench-results-<account>-<region>)
  --prefix PREFIX      S3 前缀 (默认: checkpoints/<slug>/，slug = repo id 里的 / 换成 __)
  --from DIR           本地权重目录，上传源
  --report             只查体积并算花费，不碰 S3（默认行为）
  --verify             对比 S3 上已有对象数/总字节 与 HuggingFace 清单（只读）
  --upload             真正 aws s3 sync 上传（需要 CONFIRM_SPEND=yes 与 --from）
  --dry-run            与 --upload 配合，给 aws s3 sync 加 --dryrun，只列要传什么
  --help               显示帮助信息

示例:
  # 1) 先看这份权重多大、每月多少钱（零花费）
  ./scripts/mirror-checkpoint.sh --model deepseek-ai/DeepSeek-V4-Flash

  # 2) 在 benchmark 实例上填充镜像（权重已经在本地 NVMe，最省钱）
  CONFIRM_SPEND=yes ./scripts/mirror-checkpoint.sh \\
      --model deepseek-ai/DeepSeek-V4-Flash \\
      --from /mnt/nvme/models/deepseek-ai__DeepSeek-V4-Flash --upload

  # 3) 事后核对镜像是否完整（只读）
  ./scripts/mirror-checkpoint.sh --model deepseek-ai/DeepSeek-V4-Flash --verify
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL_NAME="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --prefix) S3_PREFIX="$2"; shift 2 ;;
        --from) SOURCE_DIR="$2"; shift 2 ;;
        --report) MODE="report"; shift ;;
        --verify) MODE="verify"; shift ;;
        --upload) MODE="upload"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
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

TMPDIR_MC="$(mktemp -d)"
# shellcheck disable=SC2329  # 由下面的 trap cleanup EXIT 间接调用
cleanup() {
    rm -rf "$TMPDIR_MC"
}
trap cleanup EXIT

# =============================================================================
# Step a) 依赖与命名
# =============================================================================
for cmd in aws python3 curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "错误: 未找到命令 '$cmd'，请先安装" >&2
        exit 1
    fi
done

if [[ -z "$BUCKET" ]]; then
    BUCKET="tpot-bench-results-${ACCOUNT_ID}-${REGION}"
fi
MODEL_SLUG="${MODEL_NAME//\//__}"
if [[ -z "$S3_PREFIX" ]]; then
    S3_PREFIX="checkpoints/${MODEL_SLUG}/"
fi
S3_PREFIX="${S3_PREFIX%/}/"
S3_URI="s3://${BUCKET}/${S3_PREFIX}"
# JMESPath：Contents 不存在时 sum(null) 会直接报错，所以两处都要给空数组兜底。
# 反引号是 JMESPath 的字面量语法，不是 shell 命令替换，故用单引号包住。
# shellcheck disable=SC2016
LIST_QUERY='[length(Contents || `[]`), sum(Contents[].Size || [`0`])]'

section "Step a) 目标"
log "模型      : $MODEL_NAME"
log "slug      : $MODEL_SLUG（与 bench-bootstrap.sh 落盘目录 /mnt/nvme/models/<slug> 一致）"
log "S3 目标   : $S3_URI"
log "模式      : $MODE$([[ "$DRY_RUN" == "true" ]] && echo "（dry-run）" || echo "")"

# =============================================================================
# Step b) 用 HuggingFace API 拿精确清单（与 preflight.sh 用的是同一个查询）
# =============================================================================
section "Step b) HuggingFace 清单"
HF_META="$TMPDIR_MC/hf-model.json"
if ! curl -fsSL "https://huggingface.co/api/models/${MODEL_NAME}?blobs=true" \
        -o "$HF_META" 2>"$TMPDIR_MC/hf.err"; then
    echo "错误: HuggingFace API 查询失败: $(cat "$TMPDIR_MC/hf.err")" >&2
    exit 1
fi

HF_SUMMARY="$(python3 - "$HF_META" <<'PYEOF'
import json
import sys

meta = json.load(open(sys.argv[1], encoding="utf-8"))
siblings = meta.get("siblings") or []
total = sum((s.get("size") or 0) for s in siblings)
weights = [s for s in siblings
           if str(s.get("rfilename", "")).endswith((".safetensors", ".bin", ".pt"))]
weight_bytes = sum((s.get("size") or 0) for s in weights)
print("%d\t%d\t%.1f\t%.1f\t%d\t%.1f\t%s" % (
    len(siblings), total, total / 1e9, total / 2 ** 30,
    len(weights), weight_bytes / 2 ** 30, str(meta.get("gated"))))
PYEOF
)"
HF_FILES="$(echo "$HF_SUMMARY" | cut -f1)"
HF_BYTES="$(echo "$HF_SUMMARY" | cut -f2)"
HF_GB="$(echo "$HF_SUMMARY" | cut -f3)"
HF_GIB="$(echo "$HF_SUMMARY" | cut -f4)"
HF_WEIGHT_FILES="$(echo "$HF_SUMMARY" | cut -f5)"
HF_WEIGHT_GIB="$(echo "$HF_SUMMARY" | cut -f6)"
HF_GATED="$(echo "$HF_SUMMARY" | cut -f7)"

log "文件数    : $HF_FILES（其中权重分片 $HF_WEIGHT_FILES 个，约 $HF_WEIGHT_GIB GiB）"
log "总字节    : $HF_BYTES bytes = $HF_GB GB(十进制) / $HF_GIB GiB(二进制)"
log "gated     : $HF_GATED"
if [[ "$HF_GATED" == "True" ]]; then
    warn "该 repo 是 gated 的，下载端必须提供 HF_TOKEN"
fi

# =============================================================================
# Step c) 花费与耗时画像
# S3 按 GiB-月计价，所以下面用 GiB 而不是十进制 GB 算月租
# =============================================================================
section "Step c) 花费画像"
MONTHLY="$(awk -v g="$HF_GIB" -v p="$S3_GIB_MONTH_USD" 'BEGIN{printf "%.2f", g * p}')"
YEARLY="$(awk -v m="$MONTHLY" 'BEGIN{printf "%.2f", m * 12}')"
# multipart 分片默认 8 MB，PUT 请求 $0.005/1000
PUT_PARTS="$(awk -v b="$HF_BYTES" 'BEGIN{printf "%d", b / (8 * 1024 * 1024) + 1}')"
PUT_COST="$(awk -v n="$PUT_PARTS" 'BEGIN{printf "%.2f", n / 1000 * 0.005}')"
cat <<EOF

------------------------------------------------------------------------------
 镜像 $MODEL_NAME 的花费画像
------------------------------------------------------------------------------
 体积             : $HF_GB GB(十进制) / $HF_GIB GiB(二进制)，$HF_FILES 个文件
 S3 Standard 月租 : $HF_GIB GiB x \$$S3_GIB_MONTH_USD/GiB-月 = 约 \$$MONTHLY/月（约 \$$YEARLY/年）
 一次性 PUT 请求  : 约 $PUT_PARTS 个 8 MiB 分片 x \$0.005/1000 = 约 \$$PUT_COST
 入站流量         : \$0（S3 上传不收流量费）
 同 Region 下载   : \$0 流量费（EC2 与 S3 同 Region），只有 GET 请求费，可忽略
 省下来的东西     : 每次重试少一遍 $HF_GB GB 的 HuggingFace 下载。上一次的
                    CloudWatch NetworkIn 是 315.32 GB = 同一份权重下了两遍。
 不用了记得删     : aws s3 rm $S3_URI --recursive --region $REGION
------------------------------------------------------------------------------
EOF

# =============================================================================
# Step d) 看 S3 上现在有什么（只读，report/verify/upload 都会做）
# =============================================================================
section "Step d) S3 现状"
S3_STATE="$TMPDIR_MC/s3-state.txt"
if aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$S3_PREFIX" \
        --region "$REGION" \
        --query "$LIST_QUERY" \
        --output text >"$S3_STATE" 2>"$TMPDIR_MC/s3.err"; then
    S3_OBJECTS="$(cut -f1 "$S3_STATE")"
    S3_BYTES="$(cut -f2 "$S3_STATE" | cut -d. -f1)"
else
    warn "list-objects-v2 失败: $(cat "$TMPDIR_MC/s3.err")"
    S3_OBJECTS=0
    S3_BYTES=0
fi
S3_GIB="$(awk -v b="${S3_BYTES:-0}" 'BEGIN{printf "%.1f", b / 2 ** 30}')"
log "已有对象  : ${S3_OBJECTS:-0} 个，共 ${S3_BYTES:-0} bytes = $S3_GIB GiB"

completeness_verdict() {
    # 完整性判定：对象数 >= HF 文件数，且总字节 >= HF 总字节
    if (( ${S3_OBJECTS:-0} == 0 )); then
        echo "empty"
    elif (( ${S3_OBJECTS:-0} >= HF_FILES )) && (( ${S3_BYTES:-0} >= HF_BYTES )); then
        echo "complete"
    else
        echo "partial"
    fi
}
VERDICT="$(completeness_verdict)"
case "$VERDICT" in
    empty)    log "结论      : 镜像还不存在" ;;
    complete) log "结论      : 镜像完整（对象数与总字节均不小于 HuggingFace 清单）" ;;
    partial)  log "结论      : 镜像不完整（期望 $HF_FILES 个文件 / $HF_BYTES bytes），aws s3 sync 可续传" ;;
esac

# =============================================================================
# Step e) 按模式收尾
# =============================================================================
if [[ "$MODE" == "report" ]]; then
    section "Step e) 报告模式：未做任何变更"
    cat <<EOF
这次运行只查了 HuggingFace 清单和 S3 现状，没有上传任何字节，花费 \$0。

填充镜像（推荐在一次 full 运行的实例上做，那里权重已经在本地 NVMe 上）:
  CONFIRM_SPEND=yes $0 --model $MODEL_NAME \\
      --from /mnt/nvme/models/$MODEL_SLUG --upload

先看会传什么（不真传）:
  CONFIRM_SPEND=yes $0 --model $MODEL_NAME \\
      --from <DIR> --upload --dry-run

镜像建好后，在 recipe 里打开这一行即可让引导脚本改走 S3:
  export CHECKPOINT_S3_URI='$S3_URI'
EOF
    exit 0
fi

if [[ "$MODE" == "verify" ]]; then
    section "Step e) 校验模式"
    if [[ "$VERDICT" == "complete" ]]; then
        log "校验通过：可以在 recipe 里设置 CHECKPOINT_S3_URI='$S3_URI'"
        exit 0
    fi
    log "校验未通过（$VERDICT）。用 --upload 续传即可，aws s3 sync 只补缺的部分。"
    exit 1
fi

# ---- MODE == upload ----
section "Step e) 上传模式"
if [[ -z "$SOURCE_DIR" ]]; then
    echo "错误: --upload 需要 --from DIR 指定本地权重目录。" >&2
    echo "      这条脚本刻意不从沙箱下载权重再上传：那是 $HF_GB GB 的无谓往返。" >&2
    echo "      正确做法是在已经持有权重的 benchmark 实例上执行本脚本。" >&2
    exit 1
fi
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "错误: --from 目录不存在: $SOURCE_DIR" >&2
    exit 1
fi

LOCAL_BYTES="$(du -sb "$SOURCE_DIR" 2>/dev/null | cut -f1 || echo 0)"
LOCAL_GIB="$(awk -v b="$LOCAL_BYTES" 'BEGIN{printf "%.1f", b / 2 ** 30}')"
log "上传源    : $SOURCE_DIR（$LOCAL_GIB GiB）"
if (( LOCAL_BYTES < HF_BYTES )); then
    warn "本地目录比 HuggingFace 清单小（$LOCAL_GIB GiB < $HF_GIB GiB），可能还没下载完；sync 之后请再 --verify"
fi

if [[ "$DRY_RUN" != "true" && "${CONFIRM_SPEND:-}" != "yes" ]]; then
    cat <<EOF
拒绝上传: 未设置 CONFIRM_SPEND=yes。

这一步会往 S3 写约 $HF_GIB GiB，从此每月产生约 \$$MONTHLY 的存储费，
直到显式删除。确认后用：

  CONFIRM_SPEND=yes $0 --model $MODEL_NAME --from $SOURCE_DIR --upload

或者先看它会传什么（不真传）：

  $0 --model $MODEL_NAME --from $SOURCE_DIR --upload --dry-run
EOF
    log "未发起任何上传，退出码 2"
    exit 2
fi

SYNC_ARGS=(s3 sync "$SOURCE_DIR/" "$S3_URI" --region "$REGION" --no-progress)
if [[ "$DRY_RUN" == "true" ]]; then
    SYNC_ARGS+=(--dryrun)
    log "dry-run：只列出会传哪些对象，不写入任何字节"
fi
log "执行: aws ${SYNC_ARGS[*]}"
aws "${SYNC_ARGS[@]}"

if [[ "$DRY_RUN" == "true" ]]; then
    log "dry-run 结束，未产生任何存储费"
    exit 0
fi

# 上传后复核一次对象数与总字节
log "上传结束，复核 S3 现状..."
if aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$S3_PREFIX" \
        --region "$REGION" \
        --query "$LIST_QUERY" \
        --output text >"$S3_STATE" 2>/dev/null; then
    S3_OBJECTS="$(cut -f1 "$S3_STATE")"
    S3_BYTES="$(cut -f2 "$S3_STATE" | cut -d. -f1)"
fi
VERDICT="$(completeness_verdict)"
log "复核结果  : ${S3_OBJECTS:-0} 个对象 / ${S3_BYTES:-0} bytes -> $VERDICT"
if [[ "$VERDICT" != "complete" ]]; then
    echo "错误: 镜像仍不完整（期望 $HF_FILES 个文件 / $HF_BYTES bytes），再跑一次 --upload 续传" >&2
    exit 1
fi

section "镜像完成"
cat <<EOF
 S3 位置          : $S3_URI
 对象数 / 字节    : $S3_OBJECTS / $S3_BYTES
 每月存储费       : 约 \$$MONTHLY
 启用方式         : 在 recipe 里设置
                    export CHECKPOINT_S3_URI='$S3_URI'
                    之后 bench-bootstrap.sh 会 aws s3 sync 到
                    /mnt/nvme/models/$MODEL_SLUG，不再访问 HuggingFace
 删除方式         : aws s3 rm $S3_URI --recursive --region $REGION
EOF
exit 0
