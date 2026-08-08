#!/usr/bin/env bash
# =============================================================================
# TPOT Benchmark 单次运行总结生成器 (summarize-run)
# 用途：把一次已经跑成功的运行，变成一份写下来的、可以交出去的总结
#       docs/run-summaries/<RUN_ID>-summary.md。
#
# 为什么它必须存在：操作者的要求是「如果在 h200 / b300 一旦跑成功过一次，
# 记得停一下，做一下总结」。scripts/run-staged.sh 的总结闸门会在总结出现之前
# 拒绝继续往 GPU 上花钱（退出码 3），而本脚本写完总结后把台账里那条记录的
# summary_done 置为 true，闸门才放行。所以「停一下做总结」是机械的，不靠记性。
#
# 数据从哪来（全部来自运行自己的产物，不假设、不编）：
#   s3://<bucket>/runs/<RUN_ID>/results/{run_,bench_custom_,bench_official_}*.json
#   s3://<bucket>/runs/<RUN_ID>/logs/{status.json,gpu.csv,bootstrap.log,sglang-server.log}
#   results/stage-ledger.json（启动时记下的 recipe、Spot 现价、实例类型）
#
# bench_serving 的输出形态（追加写 JSONL）和键名归一化（median_tpot_ms 才是 P50、
# p95_tpot_ms、median_ttft_ms、output_throughput、accept_length）**不在这里重写**：
# 本脚本直接调用 scripts/collect-results.sh 做那一层转换，保证两个脚本永远
# 用同一套解析逻辑。改了那边，这边自动跟着变。
#
# 取不到的值一律显式标成「未评估」并写清原因，绝不填一个看着像数字的占位值；
# 连 TPOT / TTFT 这种必然存在的值都取不到时，直接报错退出，不产出总结。
#
# 退出码: 0 = 总结已生成（里面可能全是 FAIL，那是测量结论，不是脚本失败）
#         1 = 产物不全或必需测量值缺失，没有产出总结
# 注意：沙箱默认 AWS_REGION 可能不是目标 Region，所有 aws 调用显式传 --region。
# =============================================================================
set -euo pipefail

# =============================================================================
# 可配置参数（默认值）
# =============================================================================
REGION="${REGION:-us-east-2}"
ACCOUNT_ID="${ACCOUNT_ID:-077090643075}"
BUCKET="${BUCKET:-}"                 # 留空则推导 tpot-bench-results-<account>-<region>
RUN_ID="${RUN_ID:-}"
FIXTURE_DIR="${FIXTURE_DIR:-}"       # 给定则完全不碰 S3（测试与离线复算用）
OUT_DIR="${OUT_DIR:-}"               # 留空则用 <repo>/docs/run-summaries
RESULTS_JSON="${RESULTS_JSON:-}"     # 给定则跳过 collect-results.sh，直接用这份
KEEP_SCRATCH="${KEEP_SCRATCH:-false}"

# 验收阈值。全部来自 README 12.1 / 12.9，改这里等于改验收口径，别随手动。
TPOT_THRESHOLD_MS="${TPOT_THRESHOLD_MS:-4.5}"        # A1
TPOT_P95_THRESHOLD_MS="${TPOT_P95_THRESHOLD_MS:-6.0}" # A2（建议值）
TTFT_THRESHOLD_MS="${TTFT_THRESHOLD_MS:-1700}"      # A3
TTFT_P95_THRESHOLD_MS="${TTFT_P95_THRESHOLD_MS:-2500}" # A4（建议值）
E2E_THRESHOLD_MS="${E2E_THRESHOLD_MS:-8450}"        # A5（1.7s + 1500 x 4.5ms）
ACCEPT_LENGTH_MIN="${ACCEPT_LENGTH_MIN:-2.0}"       # A7
# README 12.2 引的 LMSYS Day-0 博客基线：H200 tp=4 + EAGLE 3/1/4，
# 30K prefix + OSL 4096 + 单 batch 解码，约 266 tok/s = TPOT 约 3.76 ms
BASELINE_TPOT_MS="${BASELINE_TPOT_MS:-3.76}"
BASELINE_THROUGHPUT="${BASELINE_THROUGHPUT:-266}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COLLECTOR="$SCRIPT_DIR/collect-results.sh"
LEDGER="${LEDGER:-$REPO_ROOT/results/stage-ledger.json}"

# =============================================================================
# 命令行参数解析
# =============================================================================
usage() {
    cat <<EOF
用法: $0 [选项]

把一次运行的产物写成 docs/run-summaries/<RUN_ID>-summary.md，并把阶段台账里
那条记录标成「已总结」，从而放行 run-staged.sh 的总结闸门。

选项:
  --run-id ID          运行 ID（launch-bench-ec2.sh 启动时打印的那个）
  --bucket NAME        结果桶 (默认: tpot-bench-results-<account>-$REGION)
  --region REGION      AWS Region (默认: $REGION)
  --fixture DIR        不走 S3，直接读本地目录（结构同 runs/<RUN_ID>/）
  --out DIR            总结输出目录 (默认: $REPO_ROOT/docs/run-summaries)
  --results-json FILE  跳过 collect-results.sh，直接用这份归一化结果
  --ledger FILE        阶段台账路径 (默认: $LEDGER)
  --keep-scratch       保留临时目录，便于排查
  --help               显示帮助信息

示例:
  # 一次真实运行成功之后（这就是总结闸门要求的第二条命令）
  ./scripts/collect-results.sh --run-id 20260807-150955-a1b2
  ./scripts/summarize-run.sh   --run-id 20260807-150955-a1b2

  # 用夹具离线验证生成器（零花费，不碰 AWS）
  ./scripts/summarize-run.sh --fixture tests/fixtures --out /tmp/sumtest

退出码 0 表示总结已经生成。总结里的 PASS/FAIL 是测量结论，不影响退出码；
必需的测量值缺失（比如根本没有 TPOT）时以 1 退出且不产出总结。
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id) RUN_ID="$2"; shift 2 ;;
        --bucket) BUCKET="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --fixture) FIXTURE_DIR="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        --results-json) RESULTS_JSON="$2"; shift 2 ;;
        --ledger) LEDGER="$2"; shift 2 ;;
        --keep-scratch) KEEP_SCRATCH=true; shift ;;
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

section() {
    echo ""
    echo "# ============================================================================="
    echo "# $*"
    echo "# ============================================================================="
}

SCRATCH_DIR=""
# shellcheck disable=SC2329  # 由下面的 trap cleanup EXIT 间接调用
cleanup() {
    if [[ -n "$SCRATCH_DIR" && -d "$SCRATCH_DIR" ]]; then
        if [[ "$KEEP_SCRATCH" == "true" ]]; then
            log "保留临时目录: $SCRATCH_DIR"
        else
            rm -rf "$SCRATCH_DIR"
        fi
    fi
}
trap cleanup EXIT

# =============================================================================
# Step a) 参数校验与产物来源
# =============================================================================
if ! command -v python3 &>/dev/null; then
    echo "错误: 未找到命令 'python3'，请先安装" >&2
    exit 1
fi
if [[ ! -f "$COLLECTOR" ]]; then
    echo "错误: 找不到 $COLLECTOR（总结依赖它做 JSONL 解析与键名归一化）" >&2
    exit 1
fi
if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$REPO_ROOT/docs/run-summaries"
fi

SCRATCH_DIR="$(mktemp -d)"
if [[ -n "$FIXTURE_DIR" ]]; then
    if [[ ! -d "$FIXTURE_DIR" ]]; then
        echo "错误: --fixture 目录不存在: $FIXTURE_DIR" >&2
        exit 1
    fi
    SRC_ROOT="$FIXTURE_DIR"
    SOURCE_LABEL="fixture:$FIXTURE_DIR"
    log "来源: 本地夹具 $FIXTURE_DIR（不发起任何 AWS 调用）"
else
    if [[ -z "$RUN_ID" ]]; then
        echo "错误: 必须给 --run-id（或用 --fixture 走本地目录）" >&2
        echo "提示: bash scripts/run-staged.sh --show-ledger 能列出所有跑过的 RUN_ID" >&2
        exit 1
    fi
    if ! command -v aws &>/dev/null; then
        echo "错误: 未找到命令 'aws'，请先安装" >&2
        exit 1
    fi
    if [[ -z "$BUCKET" ]]; then
        BUCKET="tpot-bench-results-${ACCOUNT_ID}-${REGION}"
    fi
    SRC_ROOT="$SCRATCH_DIR/$RUN_ID"
    mkdir -p "$SRC_ROOT"
    SOURCE_LABEL="s3://$BUCKET/runs/$RUN_ID/"
    log "下载 $SOURCE_LABEL -> $SRC_ROOT"
    aws s3 sync "s3://$BUCKET/runs/$RUN_ID/" "$SRC_ROOT/" --region "$REGION" --only-show-errors
fi

# 定位这次运行的目录：结果元数据所在的 results/ 的上一级。与 collect-results.sh
# 用同一套查找规则（sort 后取第一条），两个脚本因此永远指向同一次运行。
RUN_META="$(find "$SRC_ROOT" -type f -name 'run_*.json' -path '*results*' 2>/dev/null | sort | head -n1)"
if [[ -z "$RUN_META" ]]; then
    RUN_META="$(find "$SRC_ROOT" -type f -name 'run_*.json' 2>/dev/null | sort | head -n1)"
fi
if [[ -z "$RUN_META" ]]; then
    echo "错误: 在 $SRC_ROOT 里找不到 run_*.json —— 这次运行没有产出结果元数据，" >&2
    echo "      说明它在写元数据之前就死了，没有什么可总结的。" >&2
    echo "提示: 先看 logs/status.json 的 phase 字段确认它停在哪一步。" >&2
    exit 1
fi
RUN_DIR="$(cd "$(dirname "$RUN_META")/.." && pwd)"
log "运行目录: $RUN_DIR"

STATUS_FILE="$(find "$RUN_DIR" -type f -name 'status.json' 2>/dev/null | sort | head -n1)"
GPU_CSV="$(find "$RUN_DIR" -type f -name 'gpu.csv' 2>/dev/null | sort | head -n1)"
BOOTSTRAP_LOG="$(find "$RUN_DIR" -type f -name 'bootstrap.log' 2>/dev/null | sort | head -n1)"
SERVER_LOG="$(find "$RUN_DIR" -type f -name 'sglang-server.log' 2>/dev/null | sort | head -n1)"
log "status.json      : ${STATUS_FILE:-(缺失)}"
log "gpu.csv          : ${GPU_CSV:-(缺失)}"
log "bootstrap.log    : ${BOOTSTRAP_LOG:-(缺失)}"
log "sglang-server.log: ${SERVER_LOG:-(缺失)}"

# =============================================================================
# Step b) 复用 collect-results.sh 做 JSONL 解析 + 键名归一化
# =============================================================================
section "Step b) 归一化本次结果（复用 collect-results.sh，不另写一套解析）"
if [[ -z "$RESULTS_JSON" ]]; then
    COLLECT_OUT="$SCRATCH_DIR/collected"
    COLLECT_STATUS=0
    bash "$COLLECTOR" --fixture "$RUN_DIR" --out "$COLLECT_OUT" \
        >"$SCRATCH_DIR/collect.log" 2>&1 || COLLECT_STATUS=$?
    # 退出码 1 = 有 benchmark 没达标，结果照样落盘，照样要总结（甚至更要）
    if [[ "$COLLECT_STATUS" -gt 1 ]]; then
        echo "错误: collect-results.sh 以 $COLLECT_STATUS 退出，无法归一化结果" >&2
        sed -n '1,60p' "$SCRATCH_DIR/collect.log" >&2
        exit 1
    fi
    if [[ "$COLLECT_STATUS" == "1" ]]; then
        log "collect-results.sh 退出码 1：有 benchmark 未达标（数值已落盘，继续总结）"
    fi
    RESULTS_JSON="$(find "$COLLECT_OUT" -type f -name '*.json' 2>/dev/null | sort | head -n1)"
fi
if [[ -z "$RESULTS_JSON" || ! -f "$RESULTS_JSON" ]]; then
    echo "错误: 拿不到归一化后的结果 JSON，没法生成总结" >&2
    exit 1
fi
log "归一化结果: $RESULTS_JSON"

mkdir -p "$OUT_DIR"

# =============================================================================
# Step c) 生成总结 markdown
# =============================================================================
section "Step c) 生成总结"
SUMMARY_PATH="$(
TPOT_THRESHOLD_MS="$TPOT_THRESHOLD_MS" \
TPOT_P95_THRESHOLD_MS="$TPOT_P95_THRESHOLD_MS" \
TTFT_THRESHOLD_MS="$TTFT_THRESHOLD_MS" \
TTFT_P95_THRESHOLD_MS="$TTFT_P95_THRESHOLD_MS" \
E2E_THRESHOLD_MS="$E2E_THRESHOLD_MS" \
ACCEPT_LENGTH_MIN="$ACCEPT_LENGTH_MIN" \
BASELINE_TPOT_MS="$BASELINE_TPOT_MS" \
BASELINE_THROUGHPUT="$BASELINE_THROUGHPUT" \
SOURCE_LABEL="$SOURCE_LABEL" \
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
python3 - "$RESULTS_JSON" "${STATUS_FILE:-}" "${GPU_CSV:-}" "$LEDGER" "$OUT_DIR" \
         "${SERVER_LOG:-}" "${BOOTSTRAP_LOG:-}" <<'PYEOF'
import json
import os
import sys

(results_json, status_path, gpu_csv, ledger_path, out_dir,
 server_log, bootstrap_log) = sys.argv[1:8]

TPOT = float(os.environ["TPOT_THRESHOLD_MS"])
TPOT_P95 = float(os.environ["TPOT_P95_THRESHOLD_MS"])
TTFT = float(os.environ["TTFT_THRESHOLD_MS"])
TTFT_P95 = float(os.environ["TTFT_P95_THRESHOLD_MS"])
E2E = float(os.environ["E2E_THRESHOLD_MS"])
ACCEPT_MIN = float(os.environ["ACCEPT_LENGTH_MIN"])
BASE_TPOT = float(os.environ["BASELINE_TPOT_MS"])
BASE_TPS = float(os.environ["BASELINE_THROUGHPUT"])
SOURCE_LABEL = os.environ["SOURCE_LABEL"]
GENERATED_AT = os.environ["GENERATED_AT"]

# 实例类型 -> GPU 型号。nvidia-smi 的采样列里没有型号名（只有 index/利用率/显存），
# 所以型号只能由机型推出来，来源是 describe-instance-types，写死在这里并注明。
GPU_MODELS = {
    "p5en.48xlarge": "NVIDIA H200 x8（144384 MiB/卡，SM90）",
    "p5e.48xlarge": "NVIDIA H200 x8（SM90）",
    "p6-b300.48xlarge": "NVIDIA B300 x8",
    "p6-b200.48xlarge": "NVIDIA B200 x8",
    "g6e.xlarge": "NVIDIA L40S x1（46068 MiB，SM89）",
    "c5d.large": "无 GPU",
}
# 权重体积：本任务用 HuggingFace API 实测过的三份，精确到字节。
# 不在表里的 repo 一律写「未核对」，不猜。
CHECKPOINT_BYTES = {
    "deepseek-ai/DeepSeek-V4-Flash": 159630041626,
    "deepseek-ai/DeepSeek-V4-Flash-0731": 166898661074,
    "sgl-project/DeepSeek-V4-Flash-FP8": 294055065805,
}
# 兜底参考价（us-east-2a 本任务实测）。台账里有启动时记下的实价就优先用台账。
REFERENCE_PRICES = {
    "p5en.48xlarge": 26.6617,
    "g6e.xlarge": 1.2082,
    "c5d.large": 0.0295,
}

with open(results_json, encoding="utf-8") as fh:
    data = json.load(fh)
meta = data.get("metadata") or {}
custom = data.get("custom_benchmark") or {}
official = data.get("official_benchmark") or {}
run_id = meta.get("run_id") or "unknown"
instance_type = meta.get("instance_type") or "unknown"
tp_size = meta.get("tp_size") or 0


def num(bench, key):
    value = (bench.get("results") or {}).get(key)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


# --- 必需测量值：缺了就报错退出，绝不写占位值 ------------------------------
REQUIRED = [
    ("custom", custom, "tpot_p50_ms"),
    ("custom", custom, "tpot_p95_ms"),
    ("custom", custom, "ttft_p50_ms"),
    ("custom", custom, "ttft_p95_ms"),
    ("custom", custom, "e2e_latency_p50_ms"),
    ("custom", custom, "output_throughput_tok_per_s"),
    ("official", official, "tpot_p50_ms"),
    ("official", official, "output_throughput_tok_per_s"),
]
missing = ["%s.%s" % (name, key) for name, bench, key in REQUIRED
           if not num(bench, key)]
if missing or not tp_size or instance_type == "unknown":
    if not tp_size:
        missing.append("metadata.tp_size")
    if instance_type == "unknown":
        missing.append("metadata.instance_type")
    sys.stderr.write(
        "错误: 这次运行的产物里缺少必需的测量值，拒绝生成一份填着占位符的总结。\n"
        "缺失: %s\n"
        "多半是服务没起来 / bench 没跑完就收尾了。先看 logs/status.json 的 phase 与\n"
        "logs/sglang-server.log，确认这次到底算不算「跑成功过一次」。\n"
        % ", ".join(missing))
    raise SystemExit(1)


# --- status.json 与台账 -----------------------------------------------------
status = {}
if status_path and os.path.isfile(status_path):
    try:
        with open(status_path, encoding="utf-8") as fh:
            status = json.load(fh)
    except (json.JSONDecodeError, OSError):
        status = {}
phase = status.get("phase") or meta.get("final_phase") or "unknown"

ledger_entry = {}
if ledger_path and os.path.isfile(ledger_path):
    try:
        with open(ledger_path, encoding="utf-8") as fh:
            for entry in json.load(fh).get("entries") or []:
                if entry.get("run_id") == run_id:
                    ledger_entry = entry
    except (json.JSONDecodeError, OSError):
        ledger_entry = {}

elapsed = status.get("elapsed_seconds")
if not isinstance(elapsed, (int, float)):
    elapsed = meta.get("elapsed_seconds")
if not isinstance(elapsed, (int, float)):
    elapsed = 0

price = ledger_entry.get("spot_price_usd_per_hour")
price_source = "台账（启动时 describe-spot-price-history 的实价）"
if not isinstance(price, (int, float)):
    price = REFERENCE_PRICES.get(instance_type)
    price_source = "参考价（本任务在 us-east-2a 实测，不是本次运行的实际出价）"
if not isinstance(price, (int, float)):
    price = None
    price_source = "未知"


# --- gpu.csv：每张卡的 min/mean/max ---------------------------------------
gpu_stats = {}
gpu_samples = 0
gpu_note = ""
if gpu_csv and os.path.isfile(gpu_csv):
    header = None
    rows = 0
    with open(gpu_csv, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            cells = line.split(",")
            if header is None:
                header = cells
                continue
            if len(cells) != len(header):
                continue
            record = dict(zip(header, cells))
            try:
                idx = int(record["index"])
                util = float(record["util_gpu_pct"])
                mem_used = float(record["mem_used_mib"])
                mem_total = float(record["mem_total_mib"])
                temp = float(record["temp_c"])
            except (KeyError, ValueError):
                continue
            slot = gpu_stats.setdefault(
                idx, {"util": [], "mem": [], "temp": [], "mem_total": mem_total})
            slot["util"].append(util)
            slot["mem"].append(mem_used)
            slot["temp"].append(temp)
            rows += 1
    gpu_samples = rows
    if not gpu_stats:
        gpu_note = "gpu.csv 存在但没有可解析的采样行"
else:
    gpu_note = "产物里没有 gpu.csv（上一次失败的运行同样一条 GPU 指标都没有）"

gpu_count = len(gpu_stats)
busy_gpus = sum(1 for s in gpu_stats.values() if max(s["util"]) > 5)


# --- 日志里找 OOM / crash 痕迹（A8 用） -----------------------------------
CRASH_PATTERNS = ("CUDA out of memory", "OutOfMemoryError", "torch.OutOfMemoryError",
                  "Segmentation fault", "CUDA error", "Traceback (most recent call last)")
log_hits = []
logs_present = []
for path in (server_log, bootstrap_log):
    if not path or not os.path.isfile(path):
        continue
    logs_present.append(os.path.basename(path))
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()[-5 * 1024 * 1024:]
    except OSError:
        continue
    for pattern in CRASH_PATTERNS:
        if pattern in text:
            log_hits.append("%s: %s" % (os.path.basename(path), pattern))


# --- 格式化助手 -------------------------------------------------------------
def ms(value):
    return "%.2f ms" % value if value is not None else "未评估"


def secs(value):
    return "%.3f s" % (value / 1000.0) if value is not None else "未评估"


def pct(delta):
    return "%+.1f%%" % (delta * 100)


def verdict_cell(ok):
    return "✅ PASS" if ok else "❌ FAIL"


custom_res = custom.get("results") or {}
official_res = official.get("results") or {}
custom_cfg = custom.get("config") or {}
official_cfg = official.get("config") or {}
c_tpot = num(custom, "tpot_p50_ms")
c_tpot95 = num(custom, "tpot_p95_ms")
c_ttft = num(custom, "ttft_p50_ms")
c_ttft95 = num(custom, "ttft_p95_ms")
c_e2e = num(custom, "e2e_latency_p50_ms")
c_tps = num(custom, "output_throughput_tok_per_s")
o_tpot = num(official, "tpot_p50_ms")
o_tpot95 = num(official, "tpot_p95_ms")
o_ttft = num(official, "ttft_p50_ms")
o_ttft95 = num(official, "ttft_p95_ms")
o_e2e = num(official, "e2e_latency_p50_ms")
o_tps = num(official, "output_throughput_tok_per_s")
c_accept = num(custom, "accept_length")
o_accept = num(official, "accept_length")
c_completed = num(custom, "completed")
o_completed = num(official, "completed")
num_prompts = custom_cfg.get("num_prompts") or 0


# --- README 12.9 A1..A9 逐条判定 ------------------------------------------
# 约定：A1..A5 按 README 12.7 的测试条件（40K in / 1.5K out / 并发 1）判，
# 也就是「自定义负载」这一路；官方对标那一路单独列出来做基线对比。
rows = []


def add(cid, metric, criterion, measured, state, note):
    rows.append((cid, metric, criterion, measured, state, note))


add("A1", "TPOT P50", "≤ %g ms" % TPOT, ms(c_tpot),
    verdict_cell(c_tpot <= TPOT), "40K in / 1.5K out / 并发 1")
add("A2", "TPOT P95", "≤ %g ms（建议）" % TPOT_P95, ms(c_tpot95),
    verdict_cell(c_tpot95 <= TPOT_P95), "单次运行只能说明这一次的 P95")
add("A3", "TTFT P50", "≤ %g s" % (TTFT / 1000.0), secs(c_ttft),
    verdict_cell(c_ttft <= TTFT), "40K tokens prefill")
add("A4", "TTFT P95", "≤ %g s（建议）" % (TTFT_P95 / 1000.0), secs(c_ttft95),
    verdict_cell(c_ttft95 <= TTFT_P95), "")
add("A5", "E2E P50", "≤ %g s（README 12.9 推导：1.7 + 1500 x 4.5ms）" % (E2E / 1000.0),
    secs(c_e2e), verdict_cell(c_e2e <= E2E), "")

# A6 部署方式：整机 8 卡、不拆副本
if gpu_count == 0:
    add("A6", "部署方式", "整机 8 卡，不拆独立副本", "未评估", "⚠️ 未评估",
        "缺 gpu.csv，无法确认这台机器上有几张卡、实际用了几张")
elif tp_size == gpu_count:
    add("A6", "部署方式", "整机 8 卡，不拆独立副本",
        "tp=%s / 机上 %d 卡" % (tp_size, gpu_count), verdict_cell(True),
        "并行度覆盖全部 GPU，且只有一个服务实例")
else:
    add("A6", "部署方式", "整机 8 卡，不拆独立副本",
        "tp=%s / 机上 %d 卡（活跃 %d 卡）" % (tp_size, gpu_count, busy_gpus),
        "⚠️ 未评估",
        "没有拆成多副本（符合「不拆副本」），但 tp=%s 只用了 %d 卡中的 %d 卡，"
        "算不算「整机部署」需要人工与客户确认。注意 README 12.7 的 P0 行本身"
        "就是 H200 tp=4" % (tp_size, gpu_count, tp_size))

# A7 投机解码接受长度
if c_accept is None:
    add("A7", "投机解码 accept length", "≥ %g" % ACCEPT_MIN, "未评估", "⚠️ 未评估",
        "bench_serving 输出里没有 accept_length 字段，无法判断推测解码是否真的生效")
else:
    add("A7", "投机解码 accept length", "≥ %g" % ACCEPT_MIN, "%.2f" % c_accept,
        verdict_cell(c_accept >= ACCEPT_MIN),
        "接受长度接近 1 就等于推测解码没起作用"
        + ("；官方对标那一路是 %.2f" % o_accept if o_accept is not None else ""))

# A8 稳定性：连续 50 请求无 OOM / crash
stability_ok = (
    num_prompts and c_completed == num_prompts and o_completed == num_prompts
    and phase == "completed")
if log_hits:
    add("A8", "稳定性", "连续 %s 请求无 OOM/crash" % (num_prompts or 50),
        "日志命中: %s" % "; ".join(sorted(set(log_hits))), verdict_cell(False),
        "日志里出现了 OOM/crash 特征")
elif not stability_ok:
    add("A8", "稳定性", "连续 %s 请求无 OOM/crash" % (num_prompts or 50),
        "completed %s/%s、%s/%s，phase=%s" % (
            "%g" % c_completed if c_completed is not None else "?", num_prompts or "?",
            "%g" % o_completed if o_completed is not None else "?", num_prompts or "?",
            phase),
        verdict_cell(False), "请求没有全部完成，或运行没有走到 phase=completed")
elif not logs_present:
    add("A8", "稳定性", "连续 %s 请求无 OOM/crash" % num_prompts,
        "两路各 %g/%s 完成，phase=completed" % (c_completed, num_prompts),
        "⚠️ 未评估",
        "产物里没有 sglang-server.log / bootstrap.log，无法确认过程中没有 OOM 或"
        "重启；而且单次运行本身也不足以证明稳定性")
else:
    add("A8", "稳定性", "连续 %s 请求无 OOM/crash" % num_prompts,
        "两路各 %g/%s 完成，phase=completed，%s 里无 OOM/crash 特征"
        % (c_completed, num_prompts, "/".join(logs_present)),
        verdict_cell(True), "仅代表这一次运行；不构成长期稳定性结论")

# A9 长上下文衰减：README 要的是 40K vs 4K，本方案两条 bench 是 40K 与 30K
if c_tpot and o_tpot:
    delta = (c_tpot - o_tpot) / o_tpot
    a9_measured = "40K=%.2f ms vs 30K=%.2f ms（%s）" % (c_tpot, o_tpot, pct(delta))
else:
    a9_measured = "未评估"
add("A9", "长上下文衰减", "40K vs 4K 的 TPOT 差异 < 15%", a9_measured, "⚠️ 未评估",
    "README 6.1 锁定的两条 bench 是 40K/1.5K 与 30K/4096，没有 4K 基线这个点。"
    "上面给的是 40K vs 30K 的差异，只能当参考，不能当 A9 的结论")

pass_count = sum(1 for r in rows if r[4].endswith("PASS"))
fail_count = sum(1 for r in rows if r[4].endswith("FAIL"))
skip_count = sum(1 for r in rows if "未评估" in r[4])

# --- 花费 -------------------------------------------------------------------
if price is not None and elapsed:
    cost = price * elapsed / 3600.0
    cost_line = ("$%.4f/hr x %d s / 3600 = **$%.2f**" % (price, elapsed, cost))
    per_request = None
    if c_e2e:
        per_request = price / 3600.0 * (c_e2e / 1000.0)
else:
    cost = None
    per_request = None
    cost_line = "未评估（缺少 Spot 单价或运行耗时）"

checkpoint_repo = meta.get("model") or "unknown"
ckpt_bytes = CHECKPOINT_BYTES.get(checkpoint_repo)
if ckpt_bytes:
    ckpt_desc = "%s（%d 字节 = %.1f GB / %.1f GiB，HuggingFace API 实测）" % (
        checkpoint_repo, ckpt_bytes, ckpt_bytes / 1e9, ckpt_bytes / 2 ** 30)
else:
    ckpt_desc = "%s（体积未核对：不在本仓库实测过的三份权重清单里）" % checkpoint_repo

recipe = os.path.basename(ledger_entry.get("recipe") or "") or "未记录（台账里没有这次运行的 recipe 字段）"
synthetic = SOURCE_LABEL.startswith("fixture:")

# --- markdown ---------------------------------------------------------------
out = []
w = out.append
w("# 运行总结：%s" % run_id)
w("")
if synthetic:
    w("> ⚠️ **本总结基于合成夹具（%s），不是真实测量结果。**" % SOURCE_LABEL)
    w("> 它的用途是验证生成器本身。本仓库到目前为止没有任何真实 benchmark 数据。")
    w("")
w("> 由 `scripts/summarize-run.sh` 生成于 %s。数据全部来自这次运行自己的产物：" % GENERATED_AT)
w("> `%s`。这份总结的存在本身就是操作者要求的那个停顿点 ——" % SOURCE_LABEL)
w("> 「一旦跑成功过一次，记得停一下，做一下总结」。")
w("")
w("**一句话结论：** README 12.9 的 9 条里 %d 条 PASS、%d 条 FAIL、%d 条未评估；"
  "40K/1.5K 负载下 TPOT P50 = %.2f ms（目标 ≤ %g ms）。"
  % (pass_count, fail_count, skip_count, c_tpot, TPOT))
w("")
w("---")
w("")
w("## 1. 这次到底跑了什么")
w("")
w("| 项 | 值 | 来源 |")
w("| --- | --- | --- |")
w("| RUN_ID | `%s` | 运行元数据 |" % run_id)
w("| stage | %s | 运行元数据 |" % (meta.get("stage") or "unknown"))
w("| 实例 | %s (`%s`) | 运行元数据 |" % (instance_type, meta.get("instance_id") or "unknown"))
w("| GPU | %s | 由机型推出（describe-instance-types），nvidia-smi 采样列里没有型号 |"
  % GPU_MODELS.get(instance_type, "未知机型，未推断"))
w("| Region / AZ | %s | 运行元数据 |" % (meta.get("region") or "unknown"))
w("| tp | %s | 运行元数据 |" % tp_size)
w("| 权重 | %s | 运行元数据 + 实测字节数 |" % ckpt_desc)
w("| SGLang 镜像 | `%s` | 运行元数据 |" % (meta.get("sglang_image") or "unknown"))
w("| recipe | `%s` | 阶段台账 |" % recipe)
w("| 启动参数 | `%s` | 运行元数据（服务端真实收到的那一串） |" % (meta.get("serve_args") or ""))
w("| 最终 phase | `%s` | `logs/status.json` |" % phase)
w("| 运行耗时 | %d 秒（%.1f 分钟） | %s |" % (
    elapsed, elapsed / 60.0,
    "status.json" if status.get("elapsed_seconds") else "运行元数据"))
w("| bench 输出形态 | %s / %s | collect-results.sh 的解析报告 |" % (
    (meta.get("bench_output_form") or {}).get("custom", "?"),
    (meta.get("bench_output_form") or {}).get("official", "?")))
w("")
w("## 2. 测量值 vs README 12.1 验收目标")
w("")
w("两条 bench 的参数是 README 6.1 锁定的，未改动。")
w("")
w("| 指标 | 客户负载 40000 in / 1500 out | LMSYS 对标 30000 in / 4096 out | 目标 |")
w("| --- | --- | --- | --- |")
w("| TPOT P50 | %s | %s | ≤ %g ms |" % (ms(c_tpot), ms(o_tpot), TPOT))
w("| TPOT P95 | %s | %s | ≤ %g ms（建议） |" % (ms(c_tpot95), ms(o_tpot95), TPOT_P95))
w("| TTFT P50 | %s | %s | ≤ %g s |" % (secs(c_ttft), secs(o_ttft), TTFT / 1000.0))
w("| TTFT P95 | %s | %s | ≤ %g s（建议） |" % (secs(c_ttft95), secs(o_ttft95), TTFT_P95 / 1000.0))
w("| E2E P50 | %s | %s | ≤ %g s（README 12.9 A5） |" % (secs(c_e2e), secs(o_e2e), E2E / 1000.0))
w("| 输出吞吐 | %.1f tok/s | %.1f tok/s | 对应 TPOT，越高越好 |" % (c_tps, o_tps))
w("| accept length | %s | %s | ≥ %g（A7） |" % (
    "%.2f" % c_accept if c_accept is not None else "未评估",
    "%.2f" % o_accept if o_accept is not None else "未评估", ACCEPT_MIN))
w("| 完成请求数 | %s / %s | %s / %s | 全部完成（A8） |" % (
    "%g" % c_completed if c_completed is not None else "?", num_prompts or "?",
    "%g" % o_completed if o_completed is not None else "?", num_prompts or "?"))
w("")
w("## 3. 与公开基线对比（README 12.2 引的 LMSYS Day-0 博客）")
w("")
w("博客那个数字的测试条件是 **30K prefix + OSL 4096 + 单 batch 解码**，"
  "所以只有「LMSYS 对标」这一路可以直接比 —— 这也是跑一次 H200 的意义所在。")
w("")
w("| 项 | 博客基线（H200 tp=4 + EAGLE 3/1/4） | 本次 30000/4096 | 差异 |")
w("| --- | --- | --- | --- |")
w("| TPOT | ~%g ms | %.2f ms | %s |" % (
    BASE_TPOT, o_tpot, pct((o_tpot - BASE_TPOT) / BASE_TPOT)))
w("| Decode 吞吐 | ~%g tok/s | %.1f tok/s | %s |" % (
    BASE_TPS, o_tps, pct((o_tps - BASE_TPS) / BASE_TPS)))
w("| accept length | ~2.5（博客口径） | %s | %s |" % (
    "%.2f" % o_accept if o_accept is not None else "未评估",
    pct((o_accept - 2.5) / 2.5) if o_accept is not None else "未评估"))
w("")
if o_tpot <= BASE_TPOT * 1.05 and o_tps >= BASE_TPS * 0.95:
    w("**判断：复现成立。** 本次 30K/4096 的 TPOT 与吞吐都落在博客数字的 ±5% 以内。")
else:
    w("**判断：没有复现博客数字。** 差异超过 ±5%，先按 docs/RUNBOOK.md 第 7 节查 "
      "`accept_length` 与 `sglang-server.log` 里推测解码是否真的加载了，再谈换配置。")
w("")
w("## 4. GPU 利用率与显存（上一次失败的运行一条都没有）")
w("")
if gpu_stats:
    w("采样 %d 行，来自 `logs/gpu.csv`（`nvidia-smi` 每隔 GPU_SAMPLE_INTERVAL_SECONDS 一次）。"
      % gpu_samples)
    w("")
    w("| GPU | 利用率 min/mean/max | 显存峰值 | 显存总量 | 温度峰值 |")
    w("| --- | --- | --- | --- | --- |")
    for idx in sorted(gpu_stats):
        s = gpu_stats[idx]
        w("| %d | %.0f%% / %.1f%% / %.0f%% | %.0f MiB | %.0f MiB | %.0f °C |" % (
            idx, min(s["util"]), sum(s["util"]) / len(s["util"]), max(s["util"]),
            max(s["mem"]), s["mem_total"], max(s["temp"])))
    w("")
    w("活跃（峰值利用率 > 5%%）卡数 %d / %d，与 tp=%s %s。" % (
        busy_gpus, gpu_count, tp_size,
        "一致" if busy_gpus == tp_size else "不一致，值得查一下"))
else:
    w("**未评估：** %s。" % gpu_note)
    w("")
    w("这一项没有数据就等于回到了上一次的处境（无 GPU 指标，只能从 CPU/磁盘/网络"
      "反推 GPU 是否在干活）。确认 bench-bootstrap.sh 的 GPU 采样起来了没有。")
w("")
w("## 5. 花费")
w("")
w("| 项 | 值 |")
w("| --- | --- |")
w("| 运行耗时 | %d 秒（%.1f 分钟） |" % (elapsed, elapsed / 60.0))
w("| Spot 单价 | %s |" % ("$%.4f/hr" % price if price is not None else "未知"))
w("| 单价来源 | %s |" % price_source)
w("| 本次花费 | %s |" % cost_line)
if per_request is not None:
    w("| 单请求成本 | $%.6f（并发 1，按 E2E P50 %.3f s 折算） |" % (
        per_request, c_e2e / 1000.0))
w("")
w("对照：上一次没有任何上限的运行跑了 13h14m x $26.67/hr ≈ **$353**，零产出。")
w("")
w("## 6. README 12.9 验收逐条判定（A1 - A9）")
w("")
w("**未评估 ≠ 通过。** 产物里拿不到判据的条目一律标未评估并写明原因。")
w("")
w("| 编号 | 指标 | Pass 条件 | 实测 | 判定 | 说明 |")
w("| --- | --- | --- | --- | --- | --- |")
for cid, metric, criterion, measured, state, note in rows:
    w("| **%s** | %s | %s | %s | %s | %s |" % (
        cid, metric, criterion, measured, state, note or "-"))
w("")
w("合计：%d PASS / %d FAIL / %d 未评估。" % (pass_count, fail_count, skip_count))
w("")
w("## 7. 下一步")
w("")
w("### 这一次运行**没有**建立的结论")
w("")
w("- **P95 稳定性**：一次运行只给出这一次的 P95。README 12.11 明确担心 think token "
  "会让 TPOT 不稳定，要证明这件事得多跑几次同配置，而不是看一次的 P95。")
w("- **A8（连续 50 请求无 OOM/crash）**：%s" % (
    "本次判定为 %s，但仍只覆盖一次运行。" % rows[7][4] if len(rows) > 7 else "见上表。"))
w("- **A9（长上下文衰减）**：README 要的是 40K vs 4K，本方案的两条 bench 是 40K 与 30K，"
  "缺 4K 这个点。要补就再跑一条 `--random-input 4000` 的 bench_serving。")
w("- **README 12.7 测试矩阵里仍未测的行**：")
w("")
w("| 优先级 | 硬件 | 拓扑 | tp | 状态 |")
w("| --- | --- | --- | --- | --- |")
# 最后一列 = 这一行能不能由产物自动判定「已测」。PD 分离和「关闭 EAGLE」两行
# 靠机型+tp 认不出来（同样是 tp=8），一律留给人工，不假装知道。
matrix = [
    ("P0", "p5en (H200)", "unified", "4", True),
    ("P0", "p6-b300 (B300)", "unified", "8", True),
    ("P1", "p6-b300 (B300)", "unified", "4 (dp=2)", False),
    ("P1", "p6-b200 (B200)", "unified", "8", True),
    ("P2", "p6-b300 (B300)", "PD 分离", "各 tp=2", False),
    ("P2", "p6-b300 (B300)", "unified（关闭 EAGLE）", "8", False),
]
for prio, hardware, topo, tp, matchable in matrix:
    prefix = hardware.split(" ")[0]
    if matchable and instance_type.startswith(prefix) and str(tp_size) == tp:
        state = "✅ 本次已测"
    elif not matchable:
        state = "⬜ 未测（这一行认不出来，需人工确认）"
    else:
        state = "⬜ 未测"
    w("| %s | %s | %s | %s | %s |" % (prio, hardware, topo, tp, state))
w("")
w("### 下一个候选配置")
w("")
w("按 docs/RUNBOOK.md 第 5 节的 A -> C -> B 顺序（A = `h200-tp4-fp4-eagle.env`，"
  "C = `h200-tp4-dspark-0731.env`，B = `h200-tp4-fp8-eagle.env`）：")
w("")
if fail_count == 0:
    w("- 本次已经全部达标（未评估项另说），**先把这份总结和 README 12.12 的矩阵补齐"
      "再决定要不要继续花钱**。要继续的话，下一步的价值在 README 12.7 的 B300 行，"
      "而不是再换一个 H200 recipe。")
else:
    w("- 本次有 %d 条 FAIL。如果 FAIL 的是 A1/A7（TPOT 或 accept length），"
      "下一发换 C（DSpark，相对当前只变了推测解码这一个变量）；A 和 C 都因为 "
      "MoE kernel / 精度失败才值得付 B（294.1 GB 权重）的代价。" % fail_count)
w("")
w("### 手工收尾（脚本不会替你做）")
w("")
w("1. 把下面两行填进 README 12.12.1 / 12.12.2 —— 脚本**故意不自动改 README**，"
  "那两张矩阵是要人过目的交付物。")
w("2. `git add docs/run-summaries/%s-summary.md` 并提交，让这次结论进版本库。" % run_id)
w("")
w("```markdown")
w("# 12.12.1 性能维度（替换 p5en 那一行）")
w("| %s | unified | %s | %.2f ms | %.2f ms | %.1f ms | %.1f ms | %.1f ms | %s |" % (
    "p5en (H200)" if instance_type.startswith("p5en") else instance_type,
    tp_size, c_tpot, c_tpot95, c_ttft, c_ttft95, c_e2e,
    "✅" if fail_count == 0 else "❌"))
w("")
w("# 12.12.2 性价比维度（替换同一行）")
w("| %s | ~$85-98 | %s | tp=%s unified | %s | - | RUN_ID %s |" % (
    "p5en (H200)" if instance_type.startswith("p5en") else instance_type,
    "$%.4f" % price if price is not None else "_待查_", tp_size,
    "$%.6f/请求" % per_request if per_request is not None else "_待算_", run_id))
w("```")
w("")
w("---")
w("")
w("生成命令：`bash scripts/summarize-run.sh --run-id %s`。"
  "重跑会原地覆盖这份文件，不会追加。" % run_id)
w("")

summary_path = os.path.join(out_dir, "%s-summary.md" % run_id)
with open(summary_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(out))

# stdout 的最后一行给 bash 用（总结文件路径），前面的说明写到 stderr，
# 免得污染那一行。
sys.stderr.write("\n验收判定: %d PASS / %d FAIL / %d 未评估\n"
                 % (pass_count, fail_count, skip_count))
sys.stderr.write("需要人工补的 README 编辑建议已写在总结的第 7 节末尾。\n")
print(summary_path)
PYEOF
)"

if [[ -z "$SUMMARY_PATH" || ! -f "$SUMMARY_PATH" ]]; then
    echo "错误: 总结没有生成" >&2
    exit 1
fi
log "总结已写入: $SUMMARY_PATH"

# =============================================================================
# Step d) 回写台账：summary_done=true 就是总结闸门的放行条件
# =============================================================================
section "Step d) 回写阶段台账"
SUMMARY_RUN_ID="$(basename "$SUMMARY_PATH" -summary.md)"
if [[ ! -f "$LEDGER" ]]; then
    log "台账不存在（$LEDGER），跳过回写。"
    log "  说明: 台账是 run-staged.sh 启动 stage 时写的。用夹具离线生成总结时没有它是正常的；"
    log "  真实运行如果也没有，说明这次不是用 run-staged.sh 起的，闸门自然也无从触发。"
else
    LEDGER_PATH="$LEDGER" U_RUN_ID="$SUMMARY_RUN_ID" U_PATH="$SUMMARY_PATH" \
    U_PHASE="$(sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${STATUS_FILE:-/dev/null}" 2>/dev/null | head -n1)" \
    python3 - <<'PYEOF'
import json
import os
import tempfile

path = os.environ["LEDGER_PATH"]
run_id = os.environ["U_RUN_ID"]
summary_path = os.environ["U_PATH"]
phase = os.environ.get("U_PHASE") or ""

try:
    with open(path, encoding="utf-8") as fh:
        ledger = json.load(fh)
except (json.JSONDecodeError, OSError) as exc:
    print("台账无法解析（%s），跳过回写：%s" % (exc, path))
    raise SystemExit(0)
if not isinstance(ledger.get("entries"), list):
    print("台账里没有 entries 数组，跳过回写")
    raise SystemExit(0)

touched = 0
for entry in ledger["entries"]:
    if entry.get("run_id") != run_id:
        continue
    if entry.get("stage") not in ("gpu-smoke", "full"):
        continue
    # 幂等：重复生成同一份总结只是把同样的值再写一遍，不追加、不叠加
    entry["summary_done"] = True
    entry["summary_path"] = summary_path
    # 顺手把 phase 补成真值：不带 --wait 启动时，run-staged.sh 退出那一刻
    # status.json 还不存在，台账里的 gpu_success 可能是保守的 false。
    # 总结是读着 status.json 生成的，这里的判断才是有依据的那个。
    if phase:
        entry["final_phase"] = phase
        if phase == "completed" and entry.get("exit_status") == 0:
            entry["gpu_success"] = True
            entry.setdefault("summary_required",
                             entry.get("gpu_family") in ("h200", "b300", "b200"))
    touched += 1

if not touched:
    print("台账里没有 run_id=%s 的 GPU stage 记录，未回写（总结本身已生成）" % run_id)
    raise SystemExit(0)

ledger["schema"] = "tpot-bench-stage-ledger/2"
directory = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".stage-ledger-", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(ledger, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, path)
print("台账已更新 %d 条记录：summary_done=true，summary_path=%s" % (touched, summary_path))
PYEOF
fi

# =============================================================================
# Step e) 收尾
# =============================================================================
section "总结完成"
log "总结文件: $SUMMARY_PATH"
log "复核一眼: sed -n '1,40p' $SUMMARY_PATH"
log "台账状态: bash scripts/run-staged.sh --show-ledger"
log "README 12.12.1 / 12.12.2 的两行编辑建议在总结第 7 节末尾 —— 那两张矩阵要人过目，"
log "          本脚本刻意不自动改 README.md。"
exit 0
