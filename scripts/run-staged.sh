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
#
# 「跑成功一次就停下来做总结」闸门（操作者的明确要求）：
#   H200 / B300 上只要成功跑过一次，本脚本就不再往下推荐任何付费 GPU stage，
#   而是打印停顿通知 + 收结果与写总结的两条命令；在总结落地之前，再次尝试
#   gpu-smoke 或 full 会以 **退出码 3** 被拒绝。3 与 2 是两个独立的闸门：
#   2 = 没有 CONFIRM_SPEND=yes，3 = 有一次成功的运行还没总结。
#   总结闸门刻意排在花费闸门**之前**，所以补一个 CONFIRM_SPEND=yes 绕不过去。
#   确实要继续（少数情况）就加 --ack-summary，它会在输出和台账里都留痕。
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
SUBNET_ID="${SUBNET_ID:-}"           # 留空则由下游脚本 auto-resolve
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"  # 留空则由下游脚本 auto-resolve
RECIPE_FILE="${RECIPE_FILE:-}"
CHECKPOINT_S3_URI="${CHECKPOINT_S3_URI:-}"
DRY_RUN=false
WAIT_MODE=false
SHOW_LEDGER_ONLY=false
# 总结闸门的显式放行开关。默认 no —— 这个闸门存在的意义就是「默认拦住」。
SUMMARY_ACK="${SUMMARY_ACK:-no}"
# 闸门检查时，是否用只读的 aws s3 cp 回补台账里 phase 还未知的那些运行。
# 不带 --wait 启动时，退出那一刻 status.json 还不存在，phase 只能事后补。
# 测试与离线场景可以设成 false 让闸门完全不碰网络。
LEDGER_REFRESH="${LEDGER_REFRESH:-true}"

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
  --subnet-id ID            子网（留空则 auto-resolve 目标 Region 的 default VPC）
  --security-group-id ID    安全组（留空则 auto-resolve tpot-bench-noingress-sg）
  --dry-run                 只渲染 + run-instances --dry-run，零花费
  --wait                    真实启动后持续观察（无需 SSH）
  --show-ledger             只打印阶段台账，不执行任何 stage
  --ack-summary             明知有一次未总结的成功运行，仍要继续（会留痕）
  --help                    显示帮助信息

花费闸门:
  preflight 之外的每一级，未设置 CONFIRM_SPEND=yes 时都会先打印该级的实例
  类型与花费预估，然后拒绝执行并以非零状态退出（退出码 2）。

总结闸门（操作者要求：H200 / B300 跑成功一次就停下来做总结）:
  台账里只要有一条「GPU 跑成功但还没写总结」的记录，再跑 gpu-smoke / full
  会以退出码 3 被拒绝。它排在花费闸门之前，CONFIRM_SPEND=yes 绕不过去。
  清闸门的两条命令（成功时脚本自己也会打印）:
    bash scripts/collect-results.sh --run-id <RUN_ID>
    bash scripts/summarize-run.sh   --run-id <RUN_ID>
  真要跳过: 加 --ack-summary（或 SUMMARY_ACK=yes），输出与台账都会记下来。

退出码: 0 成功 / 1 出错 / 2 缺 CONFIRM_SPEND / 3 有成功运行未总结

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
        --subnet-id) SUBNET_ID="$2"; shift 2 ;;
        --security-group-id) SECURITY_GROUP_ID="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --wait) WAIT_MODE=true; shift ;;
        --show-ledger) SHOW_LEDGER_ONLY=true; shift ;;
        --ack-summary) SUMMARY_ACK=yes; shift ;;
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

# 一次运行到底停在哪个 phase。先看 launcher --wait 打印的终态，再退回去直接读
# S3 上的 status.json。两处都问不出来就返回 unknown —— 调用方必须把 unknown
# 当作「还没成功」，绝不能因为退出码是 0 就宣布成功。
resolve_final_phase() {
    local run_id="$1" launch_log="$2" phase=""
    if [[ -f "$launch_log" ]]; then
        phase="$(sed -n 's/.*运行进入终态: *\([A-Za-z_]*\).*/\1/p' "$launch_log" | tail -n1)"
    fi
    if [[ -z "$phase" && -n "$run_id" && "$run_id" != "-" ]] && command -v aws &>/dev/null; then
        phase="$(aws s3 cp "s3://$BUCKET/runs/$run_id/logs/status.json" - \
            --region "$REGION" 2>/dev/null \
            | sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
    fi
    printf '%s' "${phase:-unknown}"
}

# 实例类型 -> GPU 家族。只映射本仓库真正会用到的机型，其余记 unknown，
# 绝不猜（猜错会让「跑成功过一次」这件事记到错的硬件上）。
gpu_family_for() {
    case "$1" in
        p5en.48xlarge|p5e.48xlarge) echo h200 ;;
        p6-b300.48xlarge)           echo b300 ;;
        p6-b200.48xlarge)           echo b200 ;;
        g6e.*)                      echo l40s ;;
        c5d.*)                      echo none ;;
        *)                          echo unknown ;;
    esac
}

# 哪些 GPU 家族的成功需要停下来写总结。
# 操作者的原话是「h200 / b300 跑成功过一次就停一下做总结」，所以验收级硬件
# （h200/b300/b200，README 12.1 的目标就是这几种整机）必须停；
# gpu-smoke 用的 L40S 只是几毛钱的冒烟机，不是验收硬件，它成功不触发停顿 ——
# 但仍然如实记 gpu_success=true，台账不该说谎。
summary_required_for_family() {
    case "$1" in
        h200|b300|b200) echo true ;;
        *)              echo false ;;
    esac
}

# 台账追加一条记录。用 python3 原子重写，避免半截 JSON。
# 除 9 个位置参数外，FEAT-004 的字段由调用方用环境变量给（都有默认值）：
#   LEDGER_GPU_SUCCESS / LEDGER_FINAL_PHASE / LEDGER_SPOT_PRICE / LEDGER_SUMMARY_ACK
ledger_append() {
    local stage="$1" run_id="$2" instance_type="$3" instance_id="$4"
    local started="$5" ended="$6" status="$7" s3_prefix="$8" note="$9"
    local family
    family="$(gpu_family_for "$instance_type")"
    mkdir -p "$(dirname "$LEDGER")"
    LEDGER_PATH="$LEDGER" \
    E_STAGE="$stage" E_RUN_ID="$run_id" E_TYPE="$instance_type" \
    E_IID="$instance_id" E_START="$started" E_END="$ended" \
    E_STATUS="$status" E_PREFIX="$s3_prefix" E_NOTE="$note" \
    E_RECIPE="${RECIPE_FILE:-}" E_MODE="$([[ "$DRY_RUN" == "true" ]] && echo dry-run || echo real)" \
    E_FAMILY="$family" \
    E_GPU_SUCCESS="${LEDGER_GPU_SUCCESS:-false}" \
    E_SUMMARY_REQUIRED="$(summary_required_for_family "$family")" \
    E_FINAL_PHASE="${LEDGER_FINAL_PHASE:-}" \
    E_SPOT_PRICE="${LEDGER_SPOT_PRICE:-}" \
    E_SUMMARY_ACK="$([[ "$SUMMARY_ACK" == "yes" ]] && echo true || echo false)" \
    python3 - <<'PYEOF'
import json
import os
import tempfile

path = os.environ["LEDGER_PATH"]
# schema/2 = schema/1 加上 FEAT-004 的 gpu_success / summary_* 字段。读的时候只要
# entries 是个 list 就接着用，所以 FEAT-003 写下的 /1 老记录不会让这里崩。
ledger = {"schema": "tpot-bench-stage-ledger/2", "entries": []}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict) and isinstance(loaded.get("entries"), list):
            ledger = loaded
    except (json.JSONDecodeError, OSError):
        pass
ledger["schema"] = "tpot-bench-stage-ledger/2"

gpu_success = os.environ.get("E_GPU_SUCCESS") == "true"
# 只有「真的在 GPU 上跑成功了」才谈得上要不要总结
summary_required = gpu_success and os.environ.get("E_SUMMARY_REQUIRED") == "true"
price = os.environ.get("E_SPOT_PRICE") or ""
try:
    price_value = float(price)
except ValueError:
    price_value = None

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
    "gpu_family": os.environ["E_FAMILY"],
    "gpu_success": gpu_success,
    "final_phase": os.environ.get("E_FINAL_PHASE") or "",
    "spot_price_usd_per_hour": price_value,
    "summary_required": summary_required,
    "summary_done": False,
    "summary_path": None,
    "summary_ack": os.environ.get("E_SUMMARY_ACK") == "true",
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
          ("时间(UTC)", 22), ("总结", 8), ("recipe", 30)]
print(" " + " ".join(pad(h, w) for h, w in header))
print(" " + "-" * 108)
for stage in ("preflight", "plumbing", "gpu-smoke", "full"):
    entry = latest.get(stage)
    if not entry:
        cells = [stage, "未尝试", "-", "-", "-", "-", "-"]
    else:
        status = entry.get("exit_status", 1)
        if status == 0:
            verdict = "PASS"
        elif status == 2:
            verdict = "已拒绝"
        elif status == 3:
            verdict = "待总结"
        else:
            verdict = "FAIL(%s)" % status
        # 老记录（schema/1）没有这些字段，一律按「不需要总结」处理而不是崩掉
        if entry.get("summary_done"):
            summary_cell = "已写"
        elif entry.get("gpu_success") and entry.get("summary_required", True):
            summary_cell = "待写"
        else:
            summary_cell = "-"
        cells = [
            stage,
            verdict,
            entry.get("instance_type") or "-",
            entry.get("mode") or "-",
            entry.get("ended_at") or "-",
            summary_cell,
            os.path.basename(entry.get("recipe") or "") or "-",
        ]
    print(" " + " ".join(pad(c, w) for c, (_, w) in zip(cells, header)))
print()
print(" 台账共 %d 条记录，完整内容见 %s" % (len(entries), os.environ["LEDGER_PATH"]))

# 「跑成功一次就停下来做总结」的待办，单独再喊一遍：这是花钱的闸门依据
pending = [e for e in entries
           if e.get("gpu_success") and e.get("summary_required", True)
           and not e.get("summary_done")]
for entry in pending:
    print(" [待总结] RUN_ID %s (%s / %s) 已成功但还没有总结 -> "
          "bash scripts/summarize-run.sh --run-id %s"
          % (entry.get("run_id") or "-", entry.get("instance_type") or "-",
             entry.get("gpu_family") or "-", entry.get("run_id") or "<RUN_ID>"))
if pending:
    print(" 在总结落地之前，gpu-smoke / full 会被总结闸门以退出码 3 拒绝。")
PYEOF
}

# 把某个 RUN_ID 的最终 phase 与「是否算 GPU 成功」写回台账（原子、幂等）
ledger_set_phase() {
    local run_id="$1" phase="$2"
    [[ -f "$LEDGER" ]] || return 0
    LEDGER_PATH="$LEDGER" U_RUN_ID="$run_id" U_PHASE="$phase" python3 - <<'PYEOF'
import json
import os
import tempfile

path = os.environ["LEDGER_PATH"]
run_id = os.environ["U_RUN_ID"]
phase = os.environ["U_PHASE"]
try:
    with open(path, encoding="utf-8") as fh:
        ledger = json.load(fh)
except (json.JSONDecodeError, OSError):
    raise SystemExit(0)
if not isinstance(ledger.get("entries"), list):
    raise SystemExit(0)

def family_for(instance_type):
    """与上面的 gpu_family_for() 一份逻辑两处实现，改一处必须改另一处。

    存在的理由：FEAT-003 写下的 schema/1 记录里根本没有 gpu_family 字段，
    回填时得能从 instance_type 现推一个出来，否则老记录永远推不出「要不要总结」。
    """
    it = instance_type or ""
    if it in ("p5en.48xlarge", "p5e.48xlarge"):
        return "h200"
    if it == "p6-b300.48xlarge":
        return "b300"
    if it == "p6-b200.48xlarge":
        return "b200"
    if it.startswith("g6e."):
        return "l40s"
    if it.startswith("c5d."):
        return "none"
    return "unknown"


for entry in ledger["entries"]:
    if entry.get("run_id") != run_id or entry.get("mode") != "real":
        continue
    if entry.get("stage") not in ("gpu-smoke", "full"):
        continue
    entry["final_phase"] = phase
    if not entry.get("gpu_family"):
        entry["gpu_family"] = family_for(entry.get("instance_type"))
    success = phase == "completed" and entry.get("exit_status") == 0
    entry["gpu_success"] = bool(success)
    entry["summary_required"] = bool(
        success and entry["gpu_family"] in ("h200", "b300", "b200"))
    entry.setdefault("summary_done", False)
    entry.setdefault("summary_path", None)
ledger["schema"] = "tpot-bench-stage-ledger/2"

directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".stage-ledger-", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(ledger, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, path)
PYEOF
}

# 台账里那些「真实跑过 GPU stage、退出码 0、但 phase 还不知道」的运行。
# 不带 --wait 启动时，脚本退出那一刻 status.json 还没上传，成功与否只能事后补。
# 不补的话，一个无人值守的会话可以连着烧三份 $106 而闸门一次都不响。
ledger_refresh_phases() {
    [[ "$LEDGER_REFRESH" != "true" ]] && return 0
    [[ -f "$LEDGER" ]] || return 0
    command -v aws &>/dev/null || return 0
    local candidates run_id phase
    candidates="$(LEDGER_PATH="$LEDGER" python3 - <<'PYEOF'
import json
import os

try:
    with open(os.environ["LEDGER_PATH"], encoding="utf-8") as fh:
        entries = json.load(fh).get("entries") or []
except (json.JSONDecodeError, OSError):
    entries = []
seen = set()
for entry in entries:
    if entry.get("mode") != "real" or entry.get("exit_status") != 0:
        continue
    if entry.get("stage") not in ("gpu-smoke", "full"):
        continue
    if entry.get("gpu_success") or entry.get("final_phase"):
        continue
    run_id = entry.get("run_id") or ""
    if run_id and run_id != "-" and run_id not in seen:
        seen.add(run_id)
        print(run_id)
PYEOF
)"
    [[ -z "$candidates" ]] && return 0
    while read -r run_id; do
        [[ -z "$run_id" ]] && continue
        phase="$(aws s3 cp "s3://$BUCKET/runs/$run_id/logs/status.json" - \
            --region "$REGION" 2>/dev/null \
            | sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1 || true)"
        if [[ -z "$phase" ]]; then
            warn "RUN_ID $run_id 的 status.json 还取不到，phase 仍未知，按「还没成功」处理"
            continue
        fi
        log "回补台账: RUN_ID $run_id 的最终 phase = $phase"
        ledger_set_phase "$run_id" "$phase"
    done <<<"$candidates"
}

# 输出「已成功但没总结」的最新一条（run_id|instance_type|gpu_family|s3_prefix），
# 没有就什么都不输出。这是总结闸门的唯一判据。
summary_gate_pending() {
    [[ -f "$LEDGER" ]] || return 0
    LEDGER_PATH="$LEDGER" python3 - <<'PYEOF'
import json
import os

try:
    with open(os.environ["LEDGER_PATH"], encoding="utf-8") as fh:
        entries = json.load(fh).get("entries") or []
except (json.JSONDecodeError, OSError):
    entries = []
pending = None
for entry in entries:
    # 老的 schema/1 记录没有这些键：缺 gpu_success 就当没成功过，
    # 有 gpu_success 但缺 summary_required 就按「需要总结」从严处理。
    if not entry.get("gpu_success"):
        continue
    if not entry.get("summary_required", True):
        continue
    if entry.get("summary_done"):
        continue
    pending = entry
if pending:
    print("|".join([
        pending.get("run_id") or "-",
        pending.get("instance_type") or "-",
        pending.get("gpu_family") or "-",
        pending.get("s3_prefix") or "-",
    ]))
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
    [[ -n "$SUBNET_ID" ]] && PRE_ARGS+=(--subnet-id "$SUBNET_ID")
    [[ -n "$SECURITY_GROUP_ID" ]] && PRE_ARGS+=(--security-group-id "$SECURITY_GROUP_ID")
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
# Step b-2) 总结闸门（操作者要求：跑成功一次就停下来做总结）
#
# 刻意排在 Step d) 的花费闸门**之前**：如果放在后面，只要补一个
# CONFIRM_SPEND=yes 就能绕过停顿，那这个闸门等于不存在。
# 只拦真花钱的路径；--dry-run 零花费，只警告不拦，否则连零成本校验都做不了。
# =============================================================================
if [[ "$STAGE" == "gpu-smoke" || "$STAGE" == "full" ]]; then
    section "Step b-2) 总结闸门（在花费闸门之前）"
    ledger_refresh_phases
    PENDING_ENTRY="$(summary_gate_pending)"
    if [[ -z "$PENDING_ENTRY" ]]; then
        log "台账里没有「已成功但未总结」的运行，放行"
    else
        IFS='|' read -r P_RUN_ID P_TYPE P_FAMILY P_PREFIX <<<"$PENDING_ENTRY"
        if [[ "$DRY_RUN" == "true" ]]; then
            warn "RUN_ID $P_RUN_ID（$P_TYPE / $P_FAMILY）已成功但还没写总结。"
            warn "本次是 --dry-run（零花费），只警告不拦；真启动会以退出码 3 被拒绝。"
        elif [[ "$SUMMARY_ACK" == "yes" ]]; then
            warn "=============================================================="
            warn "已用 --ack-summary 跳过总结闸门（这一步会记进台账）"
            warn "被跳过的是 RUN_ID $P_RUN_ID（$P_TYPE / $P_FAMILY）的总结"
            warn "操作者的要求是「跑成功一次就停一下做总结」，跳过应当是少数情况"
            warn "=============================================================="
        else
            cat <<EOF

拒绝执行 stage $STAGE: 已经有一次 GPU 运行成功了，但还没有写总结。

  RUN_ID       : $P_RUN_ID
  实例 / 家族  : $P_TYPE / $P_FAMILY
  产物         : $P_PREFIX

这是操作者的明确要求：「如果在 h200 / b300 一旦跑成功过一次，记得停一下，
做一下总结。」——在总结落地之前，不再往 GPU 上花钱。

清掉这个闸门（两条命令，都零花费）：

  bash scripts/collect-results.sh --run-id $P_RUN_ID --region $REGION
  bash scripts/summarize-run.sh   --run-id $P_RUN_ID --region $REGION

总结会写到 docs/run-summaries/$P_RUN_ID-summary.md，同时把台账里这条记录的
summary_done 置为 true，闸门自动放行。

确实要在没有总结的情况下继续（少数情况，会在输出和台账里都留痕）：

  CONFIRM_SPEND=yes $0 --stage $STAGE --ack-summary${RECIPE_FILE:+ --recipe $RECIPE_FILE}

退出码 3 = 有成功运行未总结（区别于 2 = 缺 CONFIRM_SPEND=yes）。
EOF
            ledger_append "$STAGE" "-" "$STAGE_INSTANCE" "-" "$(now_iso)" "$(now_iso)" \
                3 "-" "拒绝执行：RUN_ID $P_RUN_ID 已成功但未总结，未发起任何 run-instances"
            log "未发起任何 run-instances 调用，退出码 3"
            exit 3
        fi
    fi
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
[[ -n "$SUBNET_ID" ]] && LAUNCH_ARGS+=(--subnet-id "$SUBNET_ID")
[[ -n "$SECURITY_GROUP_ID" ]] && LAUNCH_ARGS+=(--security-group-id "$SECURITY_GROUP_ID")
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

# GPU 成功的判定 = 退出码 0 **加上** status.json 真的到了 phase=completed。
# 只看退出码不够：launcher 的 0 只说明 run-instances 成功、或 --wait 的观察循环
# 正常结束，并不说明机器里那一轮 benchmark 跑完了。phase 问不出来就算没成功。
STAGE_FAMILY="$(gpu_family_for "$STAGE_INSTANCE")"
STAGE_SUMMARY_REQUIRED="$(summary_required_for_family "$STAGE_FAMILY")"
FINAL_PHASE=""
LEDGER_GPU_SUCCESS=false
LEDGER_FINAL_PHASE=""
LEDGER_SPOT_PRICE="$SPOT_PRICE"
if [[ "$DRY_RUN" != "true" && "$LAUNCH_STATUS" == "0" ]] \
        && [[ "$STAGE" == "gpu-smoke" || "$STAGE" == "full" ]]; then
    FINAL_PHASE="$(resolve_final_phase "${RUN_ID_OUT:-}" "$LAUNCH_LOG")"
    LEDGER_FINAL_PHASE="$FINAL_PHASE"
    if [[ "$FINAL_PHASE" == "completed" ]]; then
        LEDGER_GPU_SUCCESS=true
        NOTE="$NOTE（phase=completed，记为一次 GPU 成功）"
    else
        NOTE="$NOTE（phase=$FINAL_PHASE，不算成功）"
    fi
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
    gpu-smoke|full)
        if [[ "$LEDGER_GPU_SUCCESS" == "true" && "$STAGE_SUMMARY_REQUIRED" == "true" ]]; then
            # 停顿点。这里刻意**不打印任何启动命令** —— 操作者要的就是「停一下」。
            section "停一下：GPU 上已经成功跑完一次"
            cat <<EOF
==============================================================================
 $STAGE_INSTANCE（$STAGE_FAMILY）上的 benchmark 已经成功跑完一次
==============================================================================
 判据        : launcher 退出码 0，且 status.json 的 phase = $FINAL_PHASE
 RUN_ID      : ${RUN_ID_OUT:-<未知>}
 产物        : $S3_PREFIX
 本次上限    : \$$WORST_CASE（$STAGE_MINUTES 分钟 x \$$SPOT_PRICE/hr）
------------------------------------------------------------------------------
 按操作者的要求「一旦跑成功过一次，记得停一下，做一下总结」，这里不再推荐
 下一个 recipe、也不打印任何启动命令。先把这一次的结果收好、写成总结：

   bash scripts/collect-results.sh --run-id ${RUN_ID_OUT:-<RUN_ID>} --region $REGION
   bash scripts/summarize-run.sh   --run-id ${RUN_ID_OUT:-<RUN_ID>} --region $REGION

 总结落在 docs/run-summaries/${RUN_ID_OUT:-<RUN_ID>}-summary.md。在它出现之前，
 再跑 gpu-smoke / full 会被总结闸门以**退出码 3** 拒绝（区别于缺
 CONFIRM_SPEND=yes 的 2）。确实要继续再说，加 --ack-summary，会留痕。
==============================================================================
EOF
        elif [[ "$LEDGER_GPU_SUCCESS" == "true" ]]; then
            # L40S 冒烟成功：如实记 gpu_success，但它不是验收硬件，不触发停顿
            log "gpu-smoke（$STAGE_FAMILY）跑通了，phase=$FINAL_PHASE。它不是验收硬件，不触发总结停顿。"
            log "下一级: CONFIRM_SPEND=yes $0 --stage full --recipe scripts/recipes/h200-tp4-fp4-eagle.env"
        else
            log "launcher 退出码是 0，但这一轮的最终 phase = ${FINAL_PHASE:-unknown}，按「还没成功」处理。"
            log "  不带 --wait 启动时，脚本退出那一刻 status.json 往往还没上传，这是正常的。"
            log "  等它跑完后确认 phase，再决定要不要做总结："
            log "    aws s3 cp $S3_PREFIX""logs/status.json - --region $REGION"
            log "    bash scripts/summarize-run.sh --run-id ${RUN_ID_OUT:-<RUN_ID>} --region $REGION"
            log "  下一次执行本脚本时，闸门也会自己用只读方式回补这条记录的 phase。"
        fi
        ;;
esac
exit 0
