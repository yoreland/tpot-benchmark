#!/bin/bash
set -e
echo "[$(date -u)] Phase 5 Benchmark: 3P1D PD vs tp8 baseline loads"

RESULTS=/opt/dlami/nvme/bench-results
mkdir -p $RESULTS

echo "=== 1. Customer load: 40K input / 1.5K output (c=1) ==="
docker exec sglang-p0 python3 -m sglang.bench_serving --backend sglang \
  --base-url http://127.0.0.1:30080 \
  --dataset-name random --num-prompts 50 --max-concurrency 1 \
  --random-input 40000 --random-output 1500 \
  --output-file /opt/dlami/nvme/bench-results/pd_3p1d_custom_40k.jsonl 2>&1 | tail -30
echo "Custom 40K done. $(date -u)"

echo "=== 2. Official load: 30K input / 4096 output (c=1) ==="
docker exec sglang-p0 python3 -m sglang.bench_serving --backend sglang \
  --base-url http://127.0.0.1:30080 \
  --dataset-name random --num-prompts 50 --max-concurrency 1 \
  --random-input 30000 --random-output 4096 \
  --output-file /opt/dlami/nvme/bench-results/pd_3p1d_official_30k.jsonl 2>&1 | tail -30
echo "Official 30K done. $(date -u)"

echo "=== 3. Concurrency sweep (8K input / 1.5K output) ==="
for c in 1 2 4 8 16 32; do
  echo "--- concurrency=$c ---"
  N=$((c * 8))
  docker exec sglang-p0 python3 -m sglang.bench_serving --backend sglang \
    --base-url http://127.0.0.1:30080 \
    --dataset-name random --num-prompts $N --max-concurrency $c \
    --random-input 8000 --random-output 1500 \
    --output-file /opt/dlami/nvme/bench-results/pd_3p1d_sweep_c${c}.jsonl 2>&1 | tail -5
done
echo "Sweep done. $(date -u)"

echo "=== 4. Upload results to S3 ==="
aws s3 cp $RESULTS/ s3://tpot-bench-results-077090643075-us-west-2/runs/b300-pd-3p1d/ \
  --recursive --include "pd_*" --region us-west-2 2>&1 | tail -5

echo "=== 5. Quick summary ==="
for f in $RESULTS/pd_3p1d_custom_40k.jsonl $RESULTS/pd_3p1d_official_30k.jsonl; do
  echo "--- $(basename $f) ---"
  tail -1 "$f" | python3 -c "
import sys, json
d = json.loads(sys.stdin.readline())
print(f'  TPOT P50: {d.get(\"median_tpot_ms\",0):.3f} ms')
print(f'  TPOT P95: {d.get(\"p95_tpot_ms\",0):.3f} ms')
print(f'  TTFT P50: {d.get(\"median_ttft_ms\",0):.3f} ms')
print(f'  TTFT P95: {d.get(\"p95_ttft_ms\",0):.3f} ms')
print(f'  Output throughput: {d.get(\"output_throughput\",0):.1f} tok/s')
print(f'  Completed: {d.get(\"completed\",0)}/{d.get(\"total\",0)}')
" 2>/dev/null || echo "  (parse error)"
done

echo "[$(date -u)] Phase 5 Benchmark COMPLETE"
