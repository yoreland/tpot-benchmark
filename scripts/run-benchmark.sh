#!/usr/bin/env bash
# =============================================================================
# SGLang 推理性能自动化 Benchmark 脚本
# 用途：在 EKS 集群上部署 SGLang 推理服务并运行性能基准测试
# =============================================================================
set -euo pipefail

# =============================================================================
# 可配置参数（默认值）
# =============================================================================
CLUSTER_NAME="${CLUSTER_NAME:-sglang-benchmark}"
REGION="${REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-p6-b300.48xlarge}"
MODEL_NAME="${MODEL_NAME:-deepseek-ai/DeepSeek-V4-Flash}"

# 测试负载参数
INPUT_TOKENS="${INPUT_TOKENS:-40000}"
OUTPUT_TOKENS="${OUTPUT_TOKENS:-1500}"
NUM_PROMPTS="${NUM_PROMPTS:-50}"
MAX_CONCURRENCY="${MAX_CONCURRENCY:-1}"

# SGLang 容器镜像
SGLANG_IMAGE="${SGLANG_IMAGE:-lmsysorg/sglang:v0.5.12.post1-cu130}"

# EAGLE 推测解码配置
NUM_STEPS="${NUM_STEPS:-3}"
EAGLE_TOPK="${EAGLE_TOPK:-1}"
DRAFT_TOKENS="${DRAFT_TOKENS:-4}"

# 张量并行 / 数据并行配置
# DP-attention 默认关闭：上游 cookbook 的 Hopper 注记说明原始 FP4 checkpoint 走
# W4A16 Marlin 路径时是 TP-only，DP-attention / DeepEP 都用不了。以前这里默认
# --dp 8 --enable-dp-attention 和 --tp 8 一起发出去，对 H200 目标是自相矛盾的
# 配置。要用 DP 就显式 --dp N 并把 ENABLE_DP_ATTENTION=true 打开（仅限
# sgl-project/DeepSeek-V4-Flash-FP8 这类重打包 FP8 权重）。
TP_SIZE="${TP_SIZE:-8}"
DP_SIZE="${DP_SIZE:-}"
ENABLE_DP_ATTENTION="${ENABLE_DP_ATTENTION:-false}"

# 本地 NVMe 在宿主机上的路径（hostPath）。README 9.1 记录了三种环境不一样：
#   自建 EKS RAID0 : /mnt/k8s-disks/0/   （本脚本默认）
#   HyperPod       : /opt/dlami/nvme/
#   裸 EC2         : /mnt/nvme/          （见 scripts/bootstrap/bench-bootstrap.sh）
# 写错的后果就是权重落到小根盘上，这正是 2026-08-07 那次 $353 的直接原因。
NVME_HOST_PATH="${NVME_HOST_PATH:-/mnt/k8s-disks/0}"

# 内部常量
DEPLOY_NAME="sglang-benchmark"
NAMESPACE="default"
LOCAL_PORT=30000
POD_READY_TIMEOUT=2400  # 40 分钟（冷启动约 30 分钟）
RESULTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 验收标准阈值
TPOT_THRESHOLD_MS=4.5
TTFT_THRESHOLD_MS=1700

# =============================================================================
# 命令行参数解析
# =============================================================================
usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  --cluster-name NAME       EKS 集群名称 (默认: $CLUSTER_NAME)
  --region REGION           AWS Region (默认: $REGION)
  --instance-type TYPE      实例类型 (默认: $INSTANCE_TYPE)
  --model MODEL             模型名称 (默认: $MODEL_NAME)
  --tp SIZE                 张量并行度 (默认: $TP_SIZE)
  --dp SIZE                 数据并行度 (默认: 不启用；只有重打包 FP8 权重才该开)
  --nvme-host-path PATH     宿主机本地 NVMe 路径 (默认: $NVME_HOST_PATH,
                            HyperPod 用 /opt/dlami/nvme)
  --input-tokens N          输入 token 数 (默认: $INPUT_TOKENS)
  --output-tokens N         输出 token 数 (默认: $OUTPUT_TOKENS)
  --num-prompts N           请求数量 (默认: $NUM_PROMPTS)
  --max-concurrency N       最大并发数 (默认: $MAX_CONCURRENCY)
  --help                    显示帮助信息

示例:
  # 在 B300 上运行
  ./scripts/run-benchmark.sh --instance-type p6-b300.48xlarge --tp 8 --region us-east-1

  # 在 H200 上运行
  ./scripts/run-benchmark.sh --instance-type p5en.48xlarge --tp 4 --region us-west-2

  # 在 B200 上运行
  ./scripts/run-benchmark.sh --instance-type p6-b200.48xlarge --tp 8 --region us-east-2
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --model) MODEL_NAME="$2"; shift 2 ;;
        --tp) TP_SIZE="$2"; shift 2 ;;
        --dp) DP_SIZE="$2"; ENABLE_DP_ATTENTION=true; shift 2 ;;
        --nvme-host-path) NVME_HOST_PATH="$2"; shift 2 ;;
        --input-tokens) INPUT_TOKENS="$2"; shift 2 ;;
        --output-tokens) OUTPUT_TOKENS="$2"; shift 2 ;;
        --num-prompts) NUM_PROMPTS="$2"; shift 2 ;;
        --max-concurrency) MAX_CONCURRENCY="$2"; shift 2 ;;
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

cleanup() {
    log "清理资源..."
    # 关闭 port-forward
    if [[ -n "${PF_PID:-}" ]] && kill -0 "$PF_PID" 2>/dev/null; then
        kill "$PF_PID" 2>/dev/null || true
        log "已关闭 port-forward (PID: $PF_PID)"
    fi
    # 删除部署
    kubectl delete deployment "$DEPLOY_NAME" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    kubectl delete service "${DEPLOY_NAME}-svc" -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
    log "清理完成"
}

# 注册退出时的清理函数
trap cleanup EXIT

# =============================================================================
# Step a) 检查工具依赖
# =============================================================================
log "检查工具依赖..."
for cmd in kubectl aws python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "错误: 未找到命令 '$cmd'，请先安装" >&2
        exit 1
    fi
done
log "工具依赖检查通过: kubectl, aws, python3"

# =============================================================================
# Step b) 连接到 EKS 集群
# =============================================================================
log "连接到 EKS 集群: $CLUSTER_NAME (Region: $REGION)..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
log "已更新 kubeconfig"

# 验证集群连接
kubectl cluster-info || { echo "错误: 无法连接到集群" >&2; exit 1; }

# =============================================================================
# Step c) 等待 GPU 节点 Ready
# =============================================================================
log "等待 GPU 节点就绪 (实例类型: $INSTANCE_TYPE)..."
NODE_READY=false
for i in $(seq 1 60); do
    # 查找匹配实例类型的节点
    READY_NODES=$(kubectl get nodes -l "node.kubernetes.io/instance-type=$INSTANCE_TYPE" \
        --no-headers 2>/dev/null | grep -c " Ready" || true)
    if [[ "$READY_NODES" -gt 0 ]]; then
        NODE_READY=true
        log "GPU 节点已就绪 ($READY_NODES 个节点)"
        break
    fi
    log "等待 GPU 节点... ($i/60)"
    sleep 30
done

if [[ "$NODE_READY" != "true" ]]; then
    echo "错误: 等待 GPU 节点超时 (30 分钟)" >&2
    exit 1
fi

# =============================================================================
# Step d) 部署 SGLang 推理服务
# =============================================================================
log "部署 SGLang 推理服务..."

# 构建 SGLang 启动参数
SGLANG_ARGS="python3 -m sglang.launch_server"
SGLANG_ARGS+=" --model-path $MODEL_NAME"
SGLANG_ARGS+=" --tp $TP_SIZE"
# DP 相关参数改为「按需加」：不给 --dp 就一个字节都不发
if [[ -n "$DP_SIZE" ]]; then
    SGLANG_ARGS+=" --dp-size $DP_SIZE"
fi
if [[ "$ENABLE_DP_ATTENTION" == "true" ]]; then
    SGLANG_ARGS+=" --enable-dp-attention"
fi
# 正确拼写是 --speculative-algorithm（上游 server_arguments 文档与 cookbook 一致）；
# 以前写的「--speculative-algo」少了 rithm，根本不是有效 flag，启动时会直接失败
SGLANG_ARGS+=" --speculative-algorithm EAGLE"
SGLANG_ARGS+=" --speculative-num-steps $NUM_STEPS"
SGLANG_ARGS+=" --speculative-eagle-topk $EAGLE_TOPK"
SGLANG_ARGS+=" --speculative-num-draft-tokens $DRAFT_TOKENS"
SGLANG_ARGS+=" --trust-remote-code"
SGLANG_ARGS+=" --mem-fraction-static 0.85"
SGLANG_ARGS+=" --cuda-graph-max-bs 64"
SGLANG_ARGS+=" --enable-metrics"
SGLANG_ARGS+=" --host 0.0.0.0"
SGLANG_ARGS+=" --port 30000"

# 生成临时 Kubernetes manifest
MANIFEST_FILE=$(mktemp /tmp/sglang-manifest-XXXXXX.yaml)
cat > "$MANIFEST_FILE" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY_NAME
  template:
    metadata:
      labels:
        app: $DEPLOY_NAME
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node.kubernetes.io/instance-type
                operator: In
                values:
                - "$INSTANCE_TYPE"
      containers:
      - name: sglang
        image: $SGLANG_IMAGE
        command: ["bash", "-c"]
        args:
        - |
          $SGLANG_ARGS
        ports:
        - containerPort: 30000
          name: http
        resources:
          limits:
            nvidia.com/gpu: "8"
          requests:
            nvidia.com/gpu: "8"
        volumeMounts:
        - name: shm
          mountPath: /dev/shm
        - name: nvme-hf
          mountPath: /root/.cache/huggingface
        - name: nvme-tmp
          mountPath: /tmp
        env:
        - name: HF_HOME
          value: /root/.cache/huggingface
        - name: TMPDIR
          value: /tmp
      volumes:
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: 64Gi
      - name: nvme-hf
        hostPath:
          path: $NVME_HOST_PATH/hf-cache
          type: DirectoryOrCreate
      - name: nvme-tmp
        hostPath:
          path: $NVME_HOST_PATH/tmp
          type: DirectoryOrCreate
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
---
apiVersion: v1
kind: Service
metadata:
  name: ${DEPLOY_NAME}-svc
  namespace: $NAMESPACE
spec:
  selector:
    app: $DEPLOY_NAME
  ports:
  - port: 30000
    targetPort: 30000
    protocol: TCP
  type: ClusterIP
EOF

log "应用 Kubernetes manifest..."
kubectl apply -f "$MANIFEST_FILE"
rm -f "$MANIFEST_FILE"
log "部署已创建"

# =============================================================================
# Step e) 等待 Pod Ready（超时 40 分钟）
# =============================================================================
log "等待 SGLang Pod 就绪 (超时: ${POD_READY_TIMEOUT}s / ~40 分钟)..."
kubectl rollout status deployment/"$DEPLOY_NAME" -n "$NAMESPACE" --timeout="${POD_READY_TIMEOUT}s"
log "SGLang Pod 已就绪"

# 额外等待服务启动完成（模型加载）
log "等待模型加载完成..."
POD_NAME=$(kubectl get pods -l app="$DEPLOY_NAME" -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 120); do
    if kubectl logs "$POD_NAME" -n "$NAMESPACE" 2>/dev/null | grep -q "The server is fired up"; then
        log "SGLang 服务已启动"
        break
    fi
    if [[ $i -eq 120 ]]; then
        echo "错误: 模型加载超时" >&2
        exit 1
    fi
    sleep 15
done

# =============================================================================
# Step f) Port-forward 到本地 30000 端口
# =============================================================================
log "建立 port-forward (localhost:$LOCAL_PORT -> Pod:30000)..."
kubectl port-forward "pod/$POD_NAME" "$LOCAL_PORT:30000" -n "$NAMESPACE" &
PF_PID=$!
sleep 5

# 验证 port-forward 可用
if ! curl -s "http://localhost:$LOCAL_PORT/health" | grep -q "ok"; then
    echo "错误: port-forward 不可用" >&2
    exit 1
fi
log "Port-forward 建立成功"

# =============================================================================
# Step g) 运行 bench_serving（自定义参数）
# =============================================================================
log "运行 bench_serving (input=$INPUT_TOKENS, output=$OUTPUT_TOKENS, prompts=$NUM_PROMPTS, concurrency=$MAX_CONCURRENCY)..."

BENCH_OUTPUT="/tmp/bench_result_${TIMESTAMP}.json"
python3 -m sglang.bench_serving --backend sglang \
    --dataset-name random \
    --random-input "$INPUT_TOKENS" \
    --random-output "$OUTPUT_TOKENS" \
    --num-prompts "$NUM_PROMPTS" \
    --max-concurrency "$MAX_CONCURRENCY" \
    --output-file "$BENCH_OUTPUT"

log "基准测试完成，结果保存到: $BENCH_OUTPUT"

# =============================================================================
# Step h) 运行官方对标命令（30K input / 4096 output）
# =============================================================================
log "运行官方对标测试 (input=30000, output=4096)..."

BENCH_OFFICIAL="/tmp/bench_official_${TIMESTAMP}.json"
python3 -m sglang.bench_serving --backend sglang \
    --dataset-name random \
    --random-input 30000 \
    --random-output 4096 \
    --num-prompts "$NUM_PROMPTS" \
    --max-concurrency "$MAX_CONCURRENCY" \
    --output-file "$BENCH_OFFICIAL"

log "官方对标测试完成，结果保存到: $BENCH_OFFICIAL"

# =============================================================================
# Step i) 解析结果，输出 Pass/Fail 判断
# =============================================================================
log "解析测试结果..."

parse_and_judge() {
    local result_file="$1"
    local label="$2"

    python3 <<PYEOF
import json
import sys


def load_bench(path):
    """bench_serving --output-file 是「追加一行 JSON」的 JSONL，json.load 读不了。

    先试整体解析（兼容手工造的单对象文件），失败再逐行解析并取最后一条记录。
    """
    with open(path) as fh:
        raw = fh.read().strip()
    if not raw:
        return {}
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return obj
    except json.JSONDecodeError:
        pass
    last = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(rec, dict):
            last = rec
    return last


def pick(data, *keys):
    for key in keys:
        value = data.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return float(value)
    return 0


data = load_bench("$result_file")

# 提取关键指标。当前 sglang.benchmark.serving 写的是 median_* / p95_* 这一套，
# median_* 就是 P50；后面几个候选是历史/别名写法，保留兼容。
tpot_p50 = pick(data, "median_tpot_ms", "tpot_p50_ms", "inter_token_latency_p50_ms", "median_itl_ms")
tpot_p95 = pick(data, "p95_tpot_ms", "tpot_p95_ms", "inter_token_latency_p95_ms", "p95_itl_ms")
ttft_p50 = pick(data, "median_ttft_ms", "ttft_p50_ms", "time_to_first_token_p50_ms")
ttft_p95 = pick(data, "p95_ttft_ms", "ttft_p95_ms", "time_to_first_token_p95_ms")
e2e_p50 = pick(data, "median_e2e_latency_ms", "e2e_latency_p50_ms", "request_latency_p50_ms")
throughput = pick(data, "output_throughput", "output_throughput_tok_per_s", "output_token_throughput")

# 验收标准判断
tpot_pass = tpot_p50 <= $TPOT_THRESHOLD_MS if tpot_p50 > 0 else False
ttft_pass = ttft_p50 <= $TTFT_THRESHOLD_MS if ttft_p50 > 0 else False
overall = "PASS" if (tpot_pass and ttft_pass) else "FAIL"

print(f"\n{'='*60}")
print(f" [$label] 测试结果")
print(f"{'='*60}")
print(f"  TPOT P50:   {tpot_p50:.2f} ms  (阈值: <= {$TPOT_THRESHOLD_MS} ms) {'PASS' if tpot_pass else 'FAIL'}")
print(f"  TPOT P95:   {tpot_p95:.2f} ms")
print(f"  TTFT P50:   {ttft_p50:.2f} ms  (阈值: <= {$TTFT_THRESHOLD_MS} ms) {'PASS' if ttft_pass else 'FAIL'}")
print(f"  TTFT P95:   {ttft_p95:.2f} ms")
print(f"  E2E P50:    {e2e_p50:.2f} ms")
print(f"  Throughput: {throughput:.1f} tok/s")
print(f"  综合判定:   {overall}")
print(f"{'='*60}\n")

sys.exit(0 if overall == "PASS" else 1)
PYEOF
}

CUSTOM_PASS=true
parse_and_judge "$BENCH_OUTPUT" "自定义参数 (${INPUT_TOKENS}in/${OUTPUT_TOKENS}out)" || CUSTOM_PASS=false

OFFICIAL_PASS=true
parse_and_judge "$BENCH_OFFICIAL" "官方对标 (30Kin/4096out)" || OFFICIAL_PASS=false

# =============================================================================
# Step j) 保存结果到 results/ 目录
# =============================================================================
mkdir -p "$RESULTS_DIR"

# 生成结果文件名
RESULT_PREFIX="${INSTANCE_TYPE//\./-}_tp${TP_SIZE}_${TIMESTAMP}"
RESULT_JSON="$RESULTS_DIR/${RESULT_PREFIX}.json"
RESULT_SUMMARY="$RESULTS_DIR/${RESULT_PREFIX}_summary.txt"

# 合并结果为 JSON
python3 <<PYEOF
import json
from datetime import datetime


def load_bench(path):
    """同上：bench_serving 的 --output-file 是 JSONL，取最后一条记录。"""
    try:
        with open(path) as fh:
            raw = fh.read().strip()
    except OSError:
        return {}
    if not raw:
        return {}
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return obj
    except json.JSONDecodeError:
        pass
    last = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(rec, dict):
            last = rec
    return last


def pick(data, *keys):
    for key in keys:
        value = data.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return float(value)
    return 0


def normalize(raw):
    """补上 compare-results.sh 读的键名，同时保留 bench_serving 的原始键。"""
    if not raw:
        return {}
    out = dict(raw)
    out["tpot_p50_ms"] = pick(raw, "median_tpot_ms", "tpot_p50_ms", "inter_token_latency_p50_ms", "median_itl_ms")
    out["tpot_p95_ms"] = pick(raw, "p95_tpot_ms", "tpot_p95_ms", "inter_token_latency_p95_ms", "p95_itl_ms")
    out["ttft_p50_ms"] = pick(raw, "median_ttft_ms", "ttft_p50_ms", "time_to_first_token_p50_ms")
    out["ttft_p95_ms"] = pick(raw, "p95_ttft_ms", "ttft_p95_ms", "time_to_first_token_p95_ms")
    out["e2e_latency_p50_ms"] = pick(raw, "median_e2e_latency_ms", "e2e_latency_p50_ms", "request_latency_p50_ms")
    out["output_throughput_tok_per_s"] = pick(raw, "output_throughput", "output_throughput_tok_per_s", "output_token_throughput")
    return out


custom = normalize(load_bench("$BENCH_OUTPUT"))
official = normalize(load_bench("$BENCH_OFFICIAL"))

result = {
    "metadata": {
        "timestamp": "$TIMESTAMP",
        "instance_type": "$INSTANCE_TYPE",
        "region": "$REGION",
        "cluster_name": "$CLUSTER_NAME",
        "model": "$MODEL_NAME",
        "tp_size": $TP_SIZE,
        "dp_size": ${DP_SIZE:-0},
        "sglang_image": "$SGLANG_IMAGE",
        "eagle_config": {
            "num_steps": $NUM_STEPS,
            "eagle_topk": $EAGLE_TOPK,
            "draft_tokens": $DRAFT_TOKENS
        }
    },
    "custom_benchmark": {
        "config": {
            "input_tokens": $INPUT_TOKENS,
            "output_tokens": $OUTPUT_TOKENS,
            "num_prompts": $NUM_PROMPTS,
            "max_concurrency": $MAX_CONCURRENCY
        },
        "results": custom,
        "pass": $( [[ "$CUSTOM_PASS" == "true" ]] && echo "true" || echo "false" )
    },
    "official_benchmark": {
        "config": {
            "input_tokens": 30000,
            "output_tokens": 4096,
            "num_prompts": $NUM_PROMPTS,
            "max_concurrency": $MAX_CONCURRENCY
        },
        "results": official,
        "pass": $( [[ "$OFFICIAL_PASS" == "true" ]] && echo "true" || echo "false" )
    },
    "acceptance_criteria": {
        "tpot_threshold_ms": $TPOT_THRESHOLD_MS,
        "ttft_threshold_ms": $TTFT_THRESHOLD_MS
    }
}

with open("$RESULT_JSON", "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

print(f"结果已保存: $RESULT_JSON")
PYEOF

# 生成人类可读 summary
cat > "$RESULT_SUMMARY" <<SUMMARY
==========================================================
SGLang Benchmark 测试报告
==========================================================
时间:         $(date '+%Y-%m-%d %H:%M:%S')
集群:         $CLUSTER_NAME ($REGION)
实例类型:     $INSTANCE_TYPE
模型:         $MODEL_NAME
配置:         TP=$TP_SIZE, DP=${DP_SIZE:-未启用}, EAGLE(steps=$NUM_STEPS, topk=$EAGLE_TOPK, draft=$DRAFT_TOKENS)
镜像:         $SGLANG_IMAGE

----------------------------------------------------------
验收标准:
  TPOT P50 <= ${TPOT_THRESHOLD_MS} ms
  TTFT P50 <= ${TTFT_THRESHOLD_MS} ms

----------------------------------------------------------
自定义测试 (input=$INPUT_TOKENS, output=$OUTPUT_TOKENS, prompts=$NUM_PROMPTS, concurrency=$MAX_CONCURRENCY):
  结果: $( [[ "$CUSTOM_PASS" == "true" ]] && echo "PASS" || echo "FAIL" )

官方对标测试 (input=30000, output=4096, prompts=$NUM_PROMPTS, concurrency=$MAX_CONCURRENCY):
  结果: $( [[ "$OFFICIAL_PASS" == "true" ]] && echo "PASS" || echo "FAIL" )
==========================================================
SUMMARY

log "结果已保存到: $RESULTS_DIR/"
log "  - JSON: ${RESULT_PREFIX}.json"
log "  - Summary: ${RESULT_PREFIX}_summary.txt"

# =============================================================================
# Step k) 清理（在 trap EXIT 中自动执行）
# =============================================================================
log "Benchmark 运行完毕!"
if [[ "$CUSTOM_PASS" == "true" && "$OFFICIAL_PASS" == "true" ]]; then
    log "所有测试 PASS"
    exit 0
else
    log "部分测试 FAIL，请检查结果文件"
    exit 1
fi
