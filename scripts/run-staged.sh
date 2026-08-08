#!/usr/bin/env bash
# =============================================================================
# TPOT Benchmark 渐进式驱动器 (run-staged)
# 用途：把一次 H200 benchmark 拆成四级台阶，每一级都比上一级贵一个数量级，
#       前一级没过就不该动下一级。这样「试错」的单价从每小时 $26.67 降到几分钱。
#
#   preflight   $0            只读 API + run-instances --dry-run，零花费
#   plumbing    约 $0.01/20分  c5d.large：本地 NVMe 挂载 / S3 流式回传 /
#                             CloudWatch 心跳 / Spot 中断轮询 / 墙上时钟看门狗 /
#                             自终止 —— 全部在真机上验证，但不涉及 GPU
#   gpu-smoke   约 $1.20/小时  g6e.xlarge (L40S, SM89)：docker --gpus all /
#                             NVIDIA runtime / nvidia-smi 遥测 / SGLang 起服务 /
#                             一次短 bench_serving
#   full        约 $106.65     p5en.48xlarge (8xH200)：按 recipe 跑完整验收
#                （240 分钟上限）
#
# 为什么用 L40S 而不是更便宜的 T4 做 gpu-smoke：README 9.1 记录过 SGLang v0.5.12
# 的 flashinfer 在 SM 7.5 (Turing/T4) 上直接 KeyError 'sm_75'。L40S 是 SM 89，
# 与 H200 (SM 90) 同代路径，冒烟才有意义。
#
# 每一级的结果都写进 results/stage-ledger.json（gitignored）。迭代状态必须活在
# 仓库和 S3 里，而不是只活在某个会话里 —— 上一次 $353 就是因为状态只在会话里。
#
# 默认 stage 是 preflight。preflight 之后的每一级都必须显式 CONFIRM_SPEND=yes，
# 本脚本自己绝不设置它。
# 注意：沙箱默认 AWS_REGION 可能不是目标 Region，所有 aws 调用显式传 --region。
# =============================================================================
set -euo pipefail

# =============================================================================
# 可配置参数（默认值）
# =============================================================================
STAGE="${STAGE:-preflight}"
REGION="${REGION:-us-east-2}"
AZ="${AZ:-us-east-2a}"
ACCOUNT_ID="${ACCOUNT_ID:-077090643075}"
BUCKET="${BUCKET:-}"                 # 留空则推导 tpot-bench-results-<account>-<region>
RECIPE_FILE="${RECIPE_FILE:-}"
CHECKPOINT_S3_URI="${CHECKPOINT_S3_URI:-}"
DRY_RUN=false
WAIT_MODE=false
SHOW_LEDGER_ONLY=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFLIGHT="$SCRIPT_DIR/preflight.sh"
LAUNCHER="$SCRIPT_DIR/launch-bench-ec2.sh"
LEDGER="${LEDGER:-$REPO_ROOT/results/stage-ledger.json}"

# 各 stage 的实例类型、运行上限与「取不到实时价时」的兜底价（us-east-2a 实测）
STAGE_ORDER=(preflight plumbing gpu-smoke full)

# =============================================================================
# 命令行参数解析
# =============================================================================
usage() {
    cat <<EOF
用法: $0 [选项]

渐进式跑 benchmark：先零花费预检，再几分钱验管路，再约一美元验 GPU，
最后才上 H200。每一级的结果记录在 $LEDGER。

选项:
  --stage STAGE             preflight | plumbing | gpu-smoke | full
                              (默认: $STAGE，即什么都不加就只做零花费预检)
  --recipe FILE             SGLang recipe 环境文件，见 scripts/recipes/
  --checkpoint-s3-uri URI   同 Region 权重镜像，避免重复下载上百 GB
  --region REGION           AWS Region (默认: $REGION)
  --az AZ                   可用区 (默认: $AZ)
  --bucket NAME             结果桶 (默认: tpot-bench-results-<account>-<region>)
  --dry-run                 只渲染 + run-instances --dry-run，零花费
  --wait                    真实启动后持续观察（无需 SSH）
  --show-ledger             只打印阶段台账，不执行任何 stage
  --help                    显示帮助信息

花费闸门:
  preflight 之外的每一级，未设置 CONFIRM_SPEND=yes 时都会先打印该级的实例
  类型与花费预估，然后拒绝执行并以非零状态退出。

推荐顺序（第一次真跑就照这个来）:
  1) $0                                     # 零花费预检
  2) CONFIRM_SPEND=yes $0 --stage plumbing  # 约 \$0.01，验证管路
  3) CONFIRM_SPEND=yes $0 --stage gpu-smoke # 约 \$0.3-1.2，验证 GPU 与 SGLang
  4) CONFIRM_SPEND=yes $0 --stage full --recipe scripts/recipes/h200-tp4-fp4-eagle.env
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE="$2"; shift 2 ;;
        --recipe) RECIPE_FILE="$2"; shift 2 ;;
        --checkpoint-s3-uri) CHECKPOINT_S3_URI="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --az) AZ="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --wait) WAIT_MODE=true; shift ;;
        --show-ledger) SHOW_LEDGER_ONLY=true; shift ;;
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

WORK_DIR="$(mktemp -d)"
# shellcheck disable=SC2329  # 由下面的 trap cleanup EXIT 间接调用
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

now_iso() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# 台账追加一条记录。用 python3 原子重写，避免半截 JSON。
ledger_append() {
    local stage="$1" run_id="$2" instance_type="$3" instance_id="$4"
    local started="$5" ended="$6" status="$7" s3_prefix="$8" note="$9"
    mkdir -p "$(dirname "$LEDGER")"
    LEDGER_PATH="$LEDGER" \
    E_STAGE="$stage" E_RUN_ID="$run_id" E_TYPE="$instance_type" \
    E_IID="$instance_id" E_START="$started" E_END="$ended" \
    E_STATUS="$status" E_PREFIX="$s3_prefix" E_NOTE="$note" \
    E_RECIPE="${RECIPE_FILE:-}" E_MODE="$([[ "$DRY_RUN" == "true" ]] && echo dry-run || echo real)" \
    python3 - <<'PYEOF'
import json
import os
import tempfile

path = os.environ["LEDGER_PATH"]
ledger = {"schema": "tpot-bench-stage-ledger/1", "entries": []}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict) and isinstance(loaded.get("entries"), list):
            ledger = loaded
    except (json.JSONDecodeError, OSError):
        pass

ledger["entries"].append({
    "stage": os.environ["E_STAGE"],
    "run_id": os.environ["E_RUN_ID"],
    "instance_type": os.environ["E_TYPE"],
    "instance_id": os.environ["E_IID"],
    "started_at": os.environ["E_START"],
    "ended_at": os.environ["E_END"],
    "exit_status": int(os.environ["E_STATUS"]),
    "s3_prefix": os.environ["E_PREFIX"],
    "recipe": os.environ["E_RECIPE"],
    "mode": os.environ["E_MODE"],
    "note": os.environ["E_NOTE"],
})
ledger["updated_at"] = os.environ.get("E_END") or ""

directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".stage-ledger-", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(ledger, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, path)
PYEOF
    log "台账已更新: $LEDGER"
}

# 打印台账：一眼看出哪级过了、上次用的是哪个 recipe
ledger_show() {
    if [[ ! -f "$LEDGER" ]]; then
        echo " (台账还是空的：$LEDGER 尚未生成)"
        return 0
    fi
    LEDGER_PATH="$LEDGER" python3 - <<'PYEOF'
import json
import os
import unicodedata


def width(text):
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def pad(text, n):
    return text + " " * max(0, n - width(text))


with open(os.environ["LEDGER_PATH"], encoding="utf-8") as fh:
    ledger = json.load(fh)
entries = ledger.get("entries") or []
if not entries:
    print(" (台账里还没有记录)")
    raise SystemExit(0)

latest = {}
for entry in entries:
    latest[entry.get("stage", "?")] = entry

header = [("stage", 10), ("最近结果", 10), ("实例", 16), ("模式", 8),
          ("时间(UTC)", 22), ("recipe", 34)]
print(" " + " ".join(pad(h, w) for h, w in header))
print(" " + "-" * 100)
for stage in ("preflight", "plumbing", "gpu-smoke", "full"):
    entry = latest.get(stage)
    if not entry:
        cells = [stage, "未尝试", "-", "-", "-", "-"]
    else:
        status = entry.get("exit_status", 1)
        if status == 0:
            verdict = "PASS"
        elif status == 2:
            verdict = "已拒绝"
        else:
            verdict = "FAIL(%s)" % status
        cells = [
            stage,
            verdict,
            entry.get("instance_type") or "-",
            entry.get("mode") or "-",
            entry.get("ended_at") or "-",
            os.path.basename(entry.get("recipe") or "") or "-",
        ]
    print(" " + " ".join(pad(c, w) for c, (_, w) in zip(cells, header)))
print()
print(" 台账共 %d 条记录，完整内容见 %s" % (len(entries), os.environ["LEDGER_PATH"]))
PYEOF
}

# 实时 Spot 价（只读、免费）；取不到就用兜底价并明确说明
resolve_spot_price() {
    local instance_type="$1" fallback="$2" price=""
    if command -v aws &>/dev/null; then
        price="$(aws ec2 describe-spot-price-history --region "$REGION" \
            --instance-types "$instance_type" \
            --product-descriptions "Linux/UNIX" \
            --availability-zone "$AZ" \
            --start-time "$(now_iso)" \
            --query 'SpotPriceHistory[0].SpotPrice' --output text 2>/dev/null || true)"
    fi
    if [[ -z "$price" || "$price" == "None" ]]; then
        warn "取不到 $instance_type 在 $AZ 的实时 Spot 价，改用兜底价 \$$fallback/hr" >&2
        price="$fallback"
    fi
    printf '%s' "$price"
}

# =============================================================================
# Step a) stage 参数与各级画像
# =============================================================================
case "$STAGE" in
    preflight)
        STAGE_INSTANCE="(无)"
        STAGE_MINUTES=0
        STAGE_FALLBACK_PRICE=0
        STAGE_DESC="只读 API + run-instances --dry-run，不启动任何实例"
        ;;
    plumbing)
        STAGE_INSTANCE="c5d.large"
        STAGE_MINUTES=20
        STAGE_FALLBACK_PRICE=0.0295
        STAGE_DESC="单块 50 GB 本地 NVMe + S3 回传 + 心跳 + 看门狗 + 自终止（无 GPU）"
        ;;
    gpu-smoke)
        STAGE_INSTANCE="g6e.xlarge"
        STAGE_MINUTES=60
        STAGE_FALLBACK_PRICE=1.20
        STAGE_DESC="L40S (SM89)：docker --gpus all + nvidia-smi 遥测 + SGLang 起服务 + 短 bench"
        ;;
    full)
        STAGE_INSTANCE="p5en.48xlarge"
        STAGE_MINUTES=240
        STAGE_FALLBACK_PRICE=26.6617
        STAGE_DESC="8xH200：按 recipe 跑 README 6.1 的两条完整 bench_serving"
        ;;
    *)
        echo "错误: 未知 stage '$STAGE'（可选 ${STAGE_ORDER[*]}）" >&2
        exit 1
        ;;
esac

if [[ -z "$BUCKET" ]]; then
    BUCKET="tpot-bench-results-${ACCOUNT_ID}-${REGION}"
fi
if [[ -n "$RECIPE_FILE" && ! -f "$RECIPE_FILE" ]]; then
    echo "错误: recipe 文件不存在: $RECIPE_FILE" >&2
    exit 1
fi

section "阶段台账（迭代状态活在仓库里，不在会话里）"
ledger_show
if [[ "$SHOW_LEDGER_ONLY" == "true" ]]; then
    exit 0
fi

section "Step a) 本次要执行的 stage"
log "stage        : $STAGE"
log "说明         : $STAGE_DESC"
log "实例类型     : $STAGE_INSTANCE"
log "Region / AZ  : $REGION / $AZ"
log "结果桶       : s3://$BUCKET"
log "recipe       : ${RECIPE_FILE:-(未指定，用 launcher 的 stage 默认值)}"
log "模式         : $([[ "$DRY_RUN" == "true" ]] && echo "dry-run（零花费）" || echo "真实执行")"

# =============================================================================
# Step b) preflight：零花费，不需要 CONFIRM_SPEND
# =============================================================================
if [[ "$STAGE" == "preflight" ]]; then
    section "Step b) 执行 preflight（零花费）"
    if [[ ! -x "$PREFLIGHT" && ! -f "$PREFLIGHT" ]]; then
        echo "错误: 找不到 $PREFLIGHT" >&2
        exit 1
    fi
    STARTED="$(now_iso)"
    PRE_ARGS=(--region "$REGION" --az "$AZ" --bucket "$BUCKET")
    PRE_STATUS=0
    bash "$PREFLIGHT" "${PRE_ARGS[@]}" || PRE_STATUS=$?
    ledger_append preflight "-" "$STAGE_INSTANCE" "-" "$STARTED" "$(now_iso)" \
        "$PRE_STATUS" "-" "零花费预检（只读 API + run-instances --dry-run）"
    section "preflight 结束"
    if [[ "$PRE_STATUS" == "0" ]]; then
        log "预检通过。下一级: CONFIRM_SPEND=yes $0 --stage plumbing （约 \$0.01）"
    else
        log "预检未通过（退出码 $PRE_STATUS）。先把 FAIL 项修掉，再谈启动实例。"
    fi
    exit "$PRE_STATUS"
fi

# =============================================================================
# Step c) 花费预估（在闸门之前打印，这样被拒绝的人也知道自己拒绝了多少钱）
# =============================================================================
section "Step c) 花费预估"
SPOT_PRICE="$(resolve_spot_price "$STAGE_INSTANCE" "$STAGE_FALLBACK_PRICE")"
WORST_CASE="$(awk -v p="$SPOT_PRICE" -v m="$STAGE_MINUTES" 'BEGIN{printf "%.2f", p * m / 60}')"
cat <<EOF

------------------------------------------------------------------------------
 stage $STAGE 的花费画像
------------------------------------------------------------------------------
 实例类型         : $STAGE_INSTANCE
 可用区           : $AZ ($REGION)
 Spot 现价        : \$$SPOT_PRICE/hr
 运行时间上限     : $STAGE_MINUTES 分钟（实例内看门狗强制自终止）
 最坏花费         : \$$SPOT_PRICE/hr x $STAGE_MINUTES/60 = \$$WORST_CASE
 参考             : 上一次没有任何上限，跑了 13h14m x \$26.67/hr = 约 \$353，零产出
------------------------------------------------------------------------------
EOF

# =============================================================================
# Step d) 花费闸门：preflight 之后的每一级都必须显式授权
# =============================================================================
section "Step d) 花费闸门"
if [[ "$DRY_RUN" == "true" ]]; then
    log "--dry-run 模式：只渲染 user-data 并做 run-instances --dry-run，不会计费"
elif [[ "${CONFIRM_SPEND:-}" != "yes" ]]; then
    cat <<EOF
拒绝执行 stage $STAGE: 未设置 CONFIRM_SPEND=yes。

这一级会真的启动 $STAGE_INSTANCE，最坏花费 \$$WORST_CASE。确认上面的画像后，
用下面的命令显式授权：

  CONFIRM_SPEND=yes $0 --stage $STAGE${RECIPE_FILE:+ --recipe $RECIPE_FILE}

或者先零花费校验：

  $0 --stage $STAGE --dry-run
EOF
    ledger_append "$STAGE" "-" "$STAGE_INSTANCE" "-" "$(now_iso)" "$(now_iso)" \
        2 "-" "拒绝执行：未设置 CONFIRM_SPEND=yes，未发起任何 run-instances"
    log "未发起任何 run-instances 调用，退出码 2"
    exit 2
fi

# =============================================================================
# Step e) 交给 launcher，并把 RUN_ID / 实例 ID 记进台账
# =============================================================================
section "Step e) 执行 stage $STAGE"
if [[ ! -f "$LAUNCHER" ]]; then
    echo "错误: 找不到 $LAUNCHER" >&2
    exit 1
fi

LAUNCH_ARGS=(--stage "$STAGE" --region "$REGION" --az "$AZ" --bucket "$BUCKET")
[[ -n "$RECIPE_FILE" ]] && LAUNCH_ARGS+=(--recipe "$RECIPE_FILE")
[[ -n "$CHECKPOINT_S3_URI" ]] && LAUNCH_ARGS+=(--checkpoint-s3-uri "$CHECKPOINT_S3_URI")
[[ "$DRY_RUN" == "true" ]] && LAUNCH_ARGS+=(--dry-run)
[[ "$WAIT_MODE" == "true" ]] && LAUNCH_ARGS+=(--wait)

LAUNCH_LOG="$WORK_DIR/launch.log"
STARTED="$(now_iso)"
LAUNCH_STATUS=0
bash "$LAUNCHER" "${LAUNCH_ARGS[@]}" 2>&1 | tee "$LAUNCH_LOG" || LAUNCH_STATUS=$?
# tee 在管道尾部，真正的退出码在 PIPESTATUS[0]
if [[ "${PIPESTATUS[0]}" != "0" ]]; then
    LAUNCH_STATUS="${PIPESTATUS[0]}"
fi
ENDED="$(now_iso)"

RUN_ID_OUT="$(sed -n 's/.*RUN_ID  *: *\([^ ]*\).*/\1/p' "$LAUNCH_LOG" | head -n1)"
INSTANCE_ID_OUT="$(sed -n 's/.*实例 ID  *: *\(i-[0-9a-f]*\).*/\1/p' "$LAUNCH_LOG" | head -n1)"
S3_PREFIX="-"
if [[ -n "$RUN_ID_OUT" ]]; then
    S3_PREFIX="s3://$BUCKET/runs/$RUN_ID_OUT/"
fi

NOTE="stage $STAGE"
if [[ "$DRY_RUN" == "true" ]]; then
    NOTE="$NOTE（dry-run，未计费）"
fi
ledger_append "$STAGE" "${RUN_ID_OUT:--}" "$STAGE_INSTANCE" "${INSTANCE_ID_OUT:--}" \
    "$STARTED" "$ENDED" "$LAUNCH_STATUS" "$S3_PREFIX" "$NOTE"

section "stage $STAGE 结束（退出码 $LAUNCH_STATUS）"
if [[ "$LAUNCH_STATUS" != "0" ]]; then
    log "这一级失败了。排查顺序："
    log "  1) aws s3 cp $S3_PREFIX""logs/status.json - --region $REGION   # 死在哪个 phase"
    log "  2) aws s3 cp $S3_PREFIX""logs/bootstrap.log - --region $REGION | tail -100"
    log "  3) 换 recipe 重试，见 docs/RUNBOOK.md 的「recipe 迭代循环」"
    exit "$LAUNCH_STATUS"
fi

if [[ "$DRY_RUN" == "true" ]]; then
    log "dry-run 通过，本次花费 \$0。去掉 --dry-run 并加 CONFIRM_SPEND=yes 才会真启动。"
    exit 0
fi

case "$STAGE" in
    plumbing)
        log "下一级: CONFIRM_SPEND=yes $0 --stage gpu-smoke （约 \$$WORST_CASE 量级的下一档）"
        ;;
    gpu-smoke)
        log "下一级: CONFIRM_SPEND=yes $0 --stage full --recipe scripts/recipes/h200-tp4-fp4-eagle.env"
        ;;
    full)
        log "收结果: bash scripts/collect-results.sh --run-id ${RUN_ID_OUT:-<RUN_ID>} --region $REGION"
        log "        bash scripts/compare-results.sh"
        ;;
esac
exit 0
