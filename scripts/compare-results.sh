#!/usr/bin/env bash
# =============================================================================
# Benchmark 结果对比脚本
# 用途：读取 results/ 目录下所有 JSON 结果文件，输出对比表格和性价比排名
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="${1:-$(cd "$SCRIPT_DIR/.." && pwd)/results}"

if [[ ! -d "$RESULTS_DIR" ]]; then
    echo "错误: 结果目录不存在: $RESULTS_DIR" >&2
    echo "用法: $0 [results_directory]" >&2
    exit 1
fi

# 查找所有 JSON 结果文件
JSON_FILES=$(find "$RESULTS_DIR" -name "*.json" -type f | sort)
if [[ -z "$JSON_FILES" ]]; then
    echo "错误: 结果目录中没有 JSON 文件: $RESULTS_DIR" >&2
    exit 1
fi

echo "找到 $(echo "$JSON_FILES" | wc -l) 个结果文件"
echo ""

# 使用 Python 解析和对比结果
python3 <<'PYEOF'
import json
import os
import sys
from pathlib import Path

results_dir = os.environ.get("RESULTS_DIR", sys.argv[1] if len(sys.argv) > 1 else "results")

# Spot 小时成本（用于性价比计算）
SPOT_COSTS = {
    "p6-b300.48xlarge": 44.59,
    "p6-b200.48xlarge": 40.94,
    "p5en.48xlarge": 26.69,
}

# 收集所有结果
all_results = []

for json_file in sorted(Path(results_dir).glob("*.json")):
    try:
        with open(json_file) as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        continue

    meta = data.get("metadata", {})
    instance_type = meta.get("instance_type", "unknown")
    tp_size = meta.get("tp_size", 0)
    region = meta.get("region", "unknown")
    timestamp = meta.get("timestamp", "unknown")

    for bench_key, bench_label in [("custom_benchmark", "custom"), ("official_benchmark", "official")]:
        bench = data.get(bench_key, {})
        results = bench.get("results", {})
        passed = bench.get("pass", False)

        # 提取指标（兼容不同输出格式）
        tpot_p50 = results.get("tpot_p50_ms", results.get("inter_token_latency_p50_ms", 0))
        tpot_p95 = results.get("tpot_p95_ms", results.get("inter_token_latency_p95_ms", 0))
        ttft_p50 = results.get("ttft_p50_ms", results.get("time_to_first_token_p50_ms", 0))
        ttft_p95 = results.get("ttft_p95_ms", results.get("time_to_first_token_p95_ms", 0))
        e2e_p50 = results.get("e2e_latency_p50_ms", results.get("request_latency_p50_ms", 0))
        config = bench.get("config", {})

        all_results.append({
            "file": json_file.name,
            "instance_type": instance_type,
            "tp": tp_size,
            "region": region,
            "timestamp": timestamp,
            "benchmark": bench_label,
            "input_tokens": config.get("input_tokens", 0),
            "output_tokens": config.get("output_tokens", 0),
            "tpot_p50": tpot_p50,
            "tpot_p95": tpot_p95,
            "ttft_p50": ttft_p50,
            "ttft_p95": ttft_p95,
            "e2e_p50": e2e_p50,
            "pass": passed,
        })

if not all_results:
    print("没有可用的测试结果")
    sys.exit(0)

# =============================================================================
# 输出对比表格
# =============================================================================
print("=" * 120)
print(" SGLang Benchmark 结果对比")
print("=" * 120)
print()

# 表头
header = f"{'硬件':<22} {'TP':>3} {'Region':<12} {'测试类型':<10} {'TPOT P50':>10} {'TPOT P95':>10} {'TTFT P50':>10} {'TTFT P95':>10} {'E2E P50':>12} {'达标':>6}"
print(header)
print("-" * 120)

for r in all_results:
    pass_str = "PASS" if r["pass"] else "FAIL"
    tpot_p50_str = f"{r['tpot_p50']:.2f}ms" if r['tpot_p50'] > 0 else "N/A"
    tpot_p95_str = f"{r['tpot_p95']:.2f}ms" if r['tpot_p95'] > 0 else "N/A"
    ttft_p50_str = f"{r['ttft_p50']:.1f}ms" if r['ttft_p50'] > 0 else "N/A"
    ttft_p95_str = f"{r['ttft_p95']:.1f}ms" if r['ttft_p95'] > 0 else "N/A"
    e2e_p50_str = f"{r['e2e_p50']:.1f}ms" if r['e2e_p50'] > 0 else "N/A"

    line = f"{r['instance_type']:<22} {r['tp']:>3} {r['region']:<12} {r['benchmark']:<10} {tpot_p50_str:>10} {tpot_p95_str:>10} {ttft_p50_str:>10} {ttft_p95_str:>10} {e2e_p50_str:>12} {pass_str:>6}"
    print(line)

# =============================================================================
# 性价比排名（TPOT / 小时成本）
# =============================================================================
print()
print("=" * 80)
print(" 性价比排名 (越低越好: TPOT_P50 * 小时成本)")
print("=" * 80)
print()

# 只对有有效 TPOT 数据的记录排名
ranked = []
for r in all_results:
    if r["tpot_p50"] > 0:
        cost = SPOT_COSTS.get(r["instance_type"], 50.0)  # 默认 $50/hr
        # 性价比指标：TPOT * 成本，越低越好
        score = r["tpot_p50"] * cost
        ranked.append({**r, "cost_per_hr": cost, "score": score})

ranked.sort(key=lambda x: x["score"])

if ranked:
    print(f"{'排名':>4} {'硬件':<22} {'TP':>3} {'测试类型':<10} {'TPOT P50':>10} {'Spot $/hr':>10} {'得分':>10} {'达标':>6}")
    print("-" * 80)
    for i, r in enumerate(ranked, 1):
        pass_str = "PASS" if r["pass"] else "FAIL"
        print(f"{i:>4} {r['instance_type']:<22} {r['tp']:>3} {r['benchmark']:<10} {r['tpot_p50']:>8.2f}ms ${r['cost_per_hr']:>8.2f} {r['score']:>10.2f} {pass_str:>6}")
    print()
    print("得分 = TPOT_P50(ms) x Spot成本($/hr)，值越低性价比越高")
else:
    print("没有可用的 TPOT 数据进行性价比排名")

print()
PYEOF
