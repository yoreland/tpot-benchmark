#!/usr/bin/env bash
# =============================================================================
# TPOT Benchmark 结果收集器 (collect-results)
# 用途：把一次裸 EC2 运行留在 S3 上的产物，转成 scripts/compare-results.sh 能读的
#       JSON + 人类可读 summary，落到 results/。
#
# 为什么需要它：实例上的 bench-bootstrap.sh 写的是「原始输入」——
#   runs/<RUN_ID>/results/run_<RUN_ID>.json         运行元数据
#   runs/<RUN_ID>/results/bench_custom_<RUN_ID>.json    bench_serving 输出
#   runs/<RUN_ID>/results/bench_official_<RUN_ID>.json  bench_serving 输出
# 而 compare-results.sh 读的是另一套 schema:
#   metadata.{instance_type,tp_size,region,timestamp}
#   custom_benchmark/official_benchmark 各自的 .config.* / .results.* / .pass
# 这个脚本就是这两者之间的那一层，机器没了也能事后重放。
#
# 两个实测过的坑（写死在实现里，不要退回去）：
#   1) `python3 -m sglang.bench_serving --output-file F` 是「追加一行 JSON」，
#      即 JSONL，`json.load` 会直接抛异常。这里按行解析并取最后一条记录。
#   2) bench_serving 的键名是 median_tpot_ms / p95_tpot_ms / median_ttft_ms /
#      output_throughput 这一套，不是 run-benchmark.sh 里假设的 tpot_p50_ms。
#      这里把它们归一化成 compare-results.sh 认识的键，同时保留原始键。
#
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
OUT_DIR="${OUT_DIR:-}"               # 留空则用 <repo>/results
KEEP_SCRATCH="${KEEP_SCRATCH:-false}"

# 验收标准阈值（与 scripts/run-benchmark.sh 一致）
TPOT_THRESHOLD_MS="${TPOT_THRESHOLD_MS:-4.5}"
TTFT_THRESHOLD_MS="${TTFT_THRESHOLD_MS:-1700}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# =============================================================================
# 命令行参数解析
# =============================================================================
usage() {
    cat <<EOF
用法: $0 [选项]

把一次运行的 S3 产物转成 results/ 下的对比用 JSON + summary。

选项:
  --run-id ID        运行 ID（launch-bench-ec2.sh 启动时打印的那个）
  --bucket NAME      结果桶 (默认: tpot-bench-results-<account>-$REGION)
  --region REGION    AWS Region (默认: $REGION)
  --fixture DIR      不走 S3，直接读本地目录（目录结构同 runs/<RUN_ID>/）
  --out DIR          输出目录 (默认: $REPO_ROOT/results)
  --keep-scratch     保留下载用的临时目录，便于排查
  --help             显示帮助信息

示例:
  # 一次真实运行结束后
  ./scripts/collect-results.sh --run-id 20260807-150955-a1b2
  ./scripts/compare-results.sh

  # 用测试夹具验证 schema 兼容性（零花费，不碰 AWS）
  ./scripts/collect-results.sh --fixture tests/fixtures --out /tmp/rtest
  ./scripts/compare-results.sh /tmp/rtest
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
# Step a) 参数校验与来源确定
# =============================================================================
if ! command -v python3 &>/dev/null; then
    echo "错误: 未找到命令 'python3'，请先安装" >&2
    exit 1
fi

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$REPO_ROOT/results"
fi

if [[ -n "$FIXTURE_DIR" ]]; then
    if [[ ! -d "$FIXTURE_DIR" ]]; then
        echo "错误: --fixture 目录不存在: $FIXTURE_DIR" >&2
        exit 1
    fi
    SRC_DIR="$FIXTURE_DIR"
    SOURCE_LABEL="fixture:$FIXTURE_DIR"
    log "来源: 本地夹具 $FIXTURE_DIR（不发起任何 AWS 调用）"
else
    if [[ -z "$RUN_ID" ]]; then
        echo "错误: 必须给 --run-id（或用 --fixture 走本地目录）" >&2
        echo "提示: aws s3 ls s3://<bucket>/runs/ --region $REGION 可以列出所有运行" >&2
        exit 1
    fi
    if ! command -v aws &>/dev/null; then
        echo "错误: 未找到命令 'aws'，请先安装" >&2
        exit 1
    fi
    if [[ -z "$BUCKET" ]]; then
        BUCKET="tpot-bench-results-${ACCOUNT_ID}-${REGION}"
    fi
    SCRATCH_DIR="$(mktemp -d)"
    SRC_DIR="$SCRATCH_DIR/$RUN_ID"
    mkdir -p "$SRC_DIR"
    SOURCE_LABEL="s3://$BUCKET/runs/$RUN_ID/"
    log "下载 $SOURCE_LABEL -> $SRC_DIR"
    aws s3 sync "s3://$BUCKET/runs/$RUN_ID/" "$SRC_DIR/" --region "$REGION" --only-show-errors
fi

# =============================================================================
# Step b) 定位运行元数据（run_<RUN_ID>.json）
# =============================================================================
RUN_META="$(find "$SRC_DIR" -type f -name 'run_*.json' -path '*results*' 2>/dev/null | sort | head -n1)"
if [[ -z "$RUN_META" ]]; then
    RUN_META="$(find "$SRC_DIR" -type f -name 'run_*.json' 2>/dev/null | sort | head -n1)"
fi
if [[ -z "$RUN_META" ]]; then
    echo "错误: 在 $SRC_DIR 里找不到 run_*.json（运行可能在写元数据之前就死了）" >&2
    echo "提示: 看 logs/status.json 的 phase 字段能确定它停在哪一步" >&2
    exit 1
fi
log "运行元数据: $RUN_META"

STATUS_FILE="$(find "$SRC_DIR" -type f -name 'status.json' 2>/dev/null | sort | head -n1)"
if [[ -n "$STATUS_FILE" ]]; then
    log "状态文件  : $STATUS_FILE"
fi

mkdir -p "$OUT_DIR"

# =============================================================================
# Step c) 转成 compare-results.sh 的 schema 并落盘
# =============================================================================
COLLECT_STATUS=0
TPOT_THRESHOLD_MS="$TPOT_THRESHOLD_MS" \
TTFT_THRESHOLD_MS="$TTFT_THRESHOLD_MS" \
SOURCE_LABEL="$SOURCE_LABEL" \
python3 - "$RUN_META" "$(dirname "$RUN_META")" "$OUT_DIR" "${STATUS_FILE:-}" <<'PYEOF' || COLLECT_STATUS=$?
import json
import os
import sys

run_meta_path, results_dir, out_dir, status_path = sys.argv[1:5]
tpot_threshold = float(os.environ["TPOT_THRESHOLD_MS"])
ttft_threshold = float(os.environ["TTFT_THRESHOLD_MS"])
source_label = os.environ["SOURCE_LABEL"]

with open(run_meta_path, encoding="utf-8") as fh:
    meta = json.load(fh)


def load_bench(path):
    """bench_serving --output-file 写的是 JSONL（每跑一次追加一行 JSON）。

    json.load 对多行 JSONL 会抛异常，所以这里按行解析并取最后一条有效记录：
    同一个文件被复用时，最后一条才是本次的结果。为了兼容手工造的单对象 JSON，
    先试整体解析，失败再退回逐行解析。
    """
    if not path or not os.path.isfile(path):
        return {}, "缺失"
    with open(path, encoding="utf-8") as fh:
        raw = fh.read().strip()
    if not raw:
        return {}, "空文件"
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return obj, "单对象 JSON"
        if isinstance(obj, list) and obj and isinstance(obj[-1], dict):
            return obj[-1], "JSON 数组，取最后一条"
    except json.JSONDecodeError:
        pass
    records = []
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
        return {}, "无法解析"
    return records[-1], "JSONL，共 %d 条，取最后一条" % len(records)


def pick(data, *keys):
    """按优先级取第一个存在且为数值的键。"""
    for key in keys:
        value = data.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return float(value)
    return 0.0


def normalize(raw):
    """把 bench_serving 的真实键名归一化成 compare-results.sh 认识的键名。

    左边是 compare-results.sh / run-benchmark.sh 读的名字，右边的候选按优先级
    排列，第一个是当前 sglang.benchmark.serving 实际写出的名字（median_* 就是
    P50），后面几个是历史/别名写法。原始键会被一起保留，不丢信息。
    """
    out = dict(raw)
    out["tpot_p50_ms"] = pick(
        raw, "median_tpot_ms", "tpot_p50_ms", "inter_token_latency_p50_ms",
        "median_itl_ms", "mean_tpot_ms")
    out["tpot_p95_ms"] = pick(
        raw, "p95_tpot_ms", "tpot_p95_ms", "inter_token_latency_p95_ms",
        "p95_itl_ms", "p99_tpot_ms")
    out["ttft_p50_ms"] = pick(
        raw, "median_ttft_ms", "ttft_p50_ms", "time_to_first_token_p50_ms",
        "mean_ttft_ms")
    out["ttft_p95_ms"] = pick(
        raw, "p95_ttft_ms", "ttft_p95_ms", "time_to_first_token_p95_ms",
        "p99_ttft_ms")
    out["e2e_latency_p50_ms"] = pick(
        raw, "median_e2e_latency_ms", "e2e_latency_p50_ms",
        "request_latency_p50_ms", "mean_e2e_latency_ms")
    out["e2e_latency_p95_ms"] = pick(
        raw, "p95_e2e_latency_ms", "e2e_latency_p95_ms",
        "request_latency_p95_ms", "p99_e2e_latency_ms")
    out["output_throughput_tok_per_s"] = pick(
        raw, "output_throughput", "output_throughput_tok_per_s",
        "output_token_throughput")
    return out


def judge(results):
    """复用 run-benchmark.sh 的判定：两个 P50 都要有值且都要达标。"""
    tpot = results.get("tpot_p50_ms", 0.0)
    ttft = results.get("ttft_p50_ms", 0.0)
    tpot_ok = tpot > 0 and tpot <= tpot_threshold
    ttft_ok = ttft > 0 and ttft <= ttft_threshold
    return bool(tpot_ok and ttft_ok), tpot_ok, ttft_ok


cfg = meta.get("config") or {}
run_id = meta.get("run_id") or "unknown"
instance_type = meta.get("instance_type") or "unknown"
tp_size = meta.get("tp_size") or 0

custom_raw, custom_form = load_bench(
    os.path.join(results_dir, meta.get("custom_benchmark_file") or ""))
official_raw, official_form = load_bench(
    os.path.join(results_dir, meta.get("official_benchmark_file") or ""))
custom = normalize(custom_raw)
official = normalize(official_raw)
custom_pass, custom_tpot_ok, custom_ttft_ok = judge(custom)
official_pass, official_tpot_ok, official_ttft_ok = judge(official)

# TIMESTAMP 与 run-benchmark.sh 的 %Y%m%d_%H%M%S 对齐；RUN_ID 形如
# 20260807-150955-a1b2，前两段正好可以拼出同样的形状，事后复算结果稳定。
parts = run_id.split("-")
if len(parts) >= 2 and len(parts[0]) == 8 and len(parts[1]) == 6:
    timestamp = "%s_%s" % (parts[0], parts[1])
else:
    timestamp = run_id.replace("-", "_")

status_phase = "unknown"
if status_path and os.path.isfile(status_path):
    try:
        with open(status_path, encoding="utf-8") as fh:
            status_phase = json.load(fh).get("phase", "unknown")
    except (json.JSONDecodeError, OSError):
        status_phase = "unknown"

result = {
    "metadata": {
        "timestamp": timestamp,
        "instance_type": instance_type,
        "region": meta.get("region") or "unknown",
        "cluster_name": "bare-ec2",
        "model": meta.get("model") or "unknown",
        "tp_size": tp_size,
        "dp_size": 0,
        "sglang_image": meta.get("sglang_image") or "unknown",
        "run_id": run_id,
        "stage": meta.get("stage") or "unknown",
        "instance_id": meta.get("instance_id") or "unknown",
        "serve_args": meta.get("serve_args") or "",
        "elapsed_seconds": meta.get("elapsed_seconds", 0),
        "final_phase": status_phase,
        "collected_from": source_label,
        "bench_output_form": {
            "custom": custom_form,
            "official": official_form,
        },
        "pass_reported_by_instance": {
            "custom": meta.get("custom_pass"),
            "official": meta.get("official_pass"),
        },
    },
    "custom_benchmark": {
        "config": {
            "input_tokens": cfg.get("input_tokens", 0),
            "output_tokens": cfg.get("output_tokens", 0),
            "num_prompts": cfg.get("num_prompts", 0),
            "max_concurrency": cfg.get("max_concurrency", 0),
        },
        "results": custom,
        "pass": custom_pass,
    },
    "official_benchmark": {
        "config": {
            "input_tokens": cfg.get("official_input_tokens", 0),
            "output_tokens": cfg.get("official_output_tokens", 0),
            "num_prompts": cfg.get("num_prompts", 0),
            "max_concurrency": cfg.get("max_concurrency", 0),
        },
        "results": official,
        "pass": official_pass,
    },
    "acceptance_criteria": {
        "tpot_threshold_ms": tpot_threshold,
        "ttft_threshold_ms": ttft_threshold,
    },
}

prefix = "%s_tp%s_%s" % (instance_type.replace(".", "-"), tp_size, timestamp)
json_path = os.path.join(out_dir, prefix + ".json")
summary_path = os.path.join(out_dir, prefix + "_summary.txt")

with open(json_path, "w", encoding="utf-8") as fh:
    json.dump(result, fh, indent=2, ensure_ascii=False)


def verdict(ok):
    return "PASS" if ok else "FAIL"


def fmt(value):
    """阈值按 run-benchmark.sh 的样子打印：4.5 还是 4.5，1700 不要变成 1700.0。"""
    return "%g" % value


def block(label, cfg_in, cfg_out, results, passed, tpot_ok, ttft_ok, form):
    return "\n".join([
        "%s (input=%s, output=%s, prompts=%s, concurrency=%s):" % (
            label, cfg_in, cfg_out,
            cfg.get("num_prompts", 0), cfg.get("max_concurrency", 0)),
        "  bench_serving 输出形态: %s" % form,
        "  TPOT P50:   %.2f ms  (阈值: <= %s ms) %s" % (
            results["tpot_p50_ms"], fmt(tpot_threshold), verdict(tpot_ok)),
        "  TPOT P95:   %.2f ms" % results["tpot_p95_ms"],
        "  TTFT P50:   %.2f ms  (阈值: <= %s ms) %s" % (
            results["ttft_p50_ms"], fmt(ttft_threshold), verdict(ttft_ok)),
        "  TTFT P95:   %.2f ms" % results["ttft_p95_ms"],
        "  E2E P50:    %.2f ms" % results["e2e_latency_p50_ms"],
        "  E2E P95:    %.2f ms" % results["e2e_latency_p95_ms"],
        "  Throughput: %.1f tok/s" % results["output_throughput_tok_per_s"],
        "  综合判定:   %s" % verdict(passed),
    ])


summary = "\n".join([
    "==========================================================",
    "SGLang Benchmark 测试报告（裸 EC2 路径，由 collect-results.sh 生成）",
    "==========================================================",
    "RUN_ID:       %s" % run_id,
    "Stage:        %s" % (meta.get("stage") or "unknown"),
    "实例:         %s (%s)" % (instance_type, meta.get("instance_id") or "unknown"),
    "Region:       %s" % (meta.get("region") or "unknown"),
    "模型:         %s" % (meta.get("model") or "unknown"),
    "镜像:         %s" % (meta.get("sglang_image") or "unknown"),
    "TP:           %s" % tp_size,
    "启动参数:     %s" % (meta.get("serve_args") or ""),
    "运行耗时:     %s 秒" % meta.get("elapsed_seconds", 0),
    "最终 phase:   %s" % status_phase,
    "来源:         %s" % source_label,
    "",
    "----------------------------------------------------------",
    "验收标准:",
    "  TPOT P50 <= %s ms" % fmt(tpot_threshold),
    "  TTFT P50 <= %s ms" % fmt(ttft_threshold),
    "",
    "----------------------------------------------------------",
    block("自定义测试", cfg.get("input_tokens", 0), cfg.get("output_tokens", 0),
          custom, custom_pass, custom_tpot_ok, custom_ttft_ok, custom_form),
    "",
    block("官方对标测试", cfg.get("official_input_tokens", 0),
          cfg.get("official_output_tokens", 0), official, official_pass,
          official_tpot_ok, official_ttft_ok, official_form),
    "==========================================================",
    "",
])

with open(summary_path, "w", encoding="utf-8") as fh:
    fh.write(summary)

print(summary)
print("JSON:    %s" % json_path)
print("Summary: %s" % summary_path)
if not (custom_pass and official_pass):
    sys.exit(1)
PYEOF

# =============================================================================
# Step d) 收尾
# =============================================================================
log "结果已写入: $OUT_DIR/"
log "下一步: bash scripts/compare-results.sh $OUT_DIR"
if [[ "$COLLECT_STATUS" != "0" ]]; then
    log "注意: 有 benchmark 未达标（退出码 $COLLECT_STATUS），数值见上面的报告"
fi
exit "$COLLECT_STATUS"
