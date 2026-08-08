#!/usr/bin/env bash
# =============================================================================
# TPOT Benchmark 引导/启动脚本测试套件（纯 bash，无需 bats）
# 用途：在没有 GPU、没有本地 NVMe、不接触真实 AWS 的沙箱里，真实执行
#       scripts/bootstrap/bench-bootstrap.sh 与 scripts/launch-bench-ec2.sh 的控制流。
#
# 做法：tests/stubs/ 里的假二进制（aws / docker / nvidia-smi / lsblk / nvme /
#       mdadm / mkfs.xfs / mount / df / curl / shutdown）前置到 PATH，每次调用都
#       追加到「调用日志」；被测脚本以 DRY_RUN=1 运行，不可逆操作（mdadm --create /
#       mkfs / docker data-root 迁移 / terminate-instances / shutdown）不执行，只把
#       命令行记录到同一份调用日志（DRY_RUN_LOG=$STUB_LOG）。因此断言针对的是
#       「脚本真的算出并决定执行了什么」，而不是某段静态字符串。
#
# 注意：这里刻意不用 set -e —— 单个用例失败必须继续跑完其余用例并给出汇总。
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB_DIR="$REPO_ROOT/tests/stubs"
BOOTSTRAP="$REPO_ROOT/scripts/bootstrap/bench-bootstrap.sh"
LAUNCHER="$REPO_ROOT/scripts/launch-bench-ec2.sh"
TMP_ROOT="$(mktemp -d)"
CASE_TIMEOUT="${CASE_TIMEOUT:-120}"
TEST_BUCKET="tpot-bench-results-077090643075-us-east-2"
TEST_CKPT_URI="s3://$TEST_BUCKET/checkpoints/test"
DISKS_1="nvme0n1 200G Amazon Elastic Block Store\nnvme1n1 3.5T Amazon EC2 NVMe Instance Storage"
DISKS_4="nvme0n1 200G Amazon Elastic Block Store\nnvme1n1 3.5T Amazon EC2 NVMe Instance Storage\nnvme2n1 3.5T Amazon EC2 NVMe Instance Storage\nnvme3n1 3.5T Amazon EC2 NVMe Instance Storage\nnvme4n1 3.5T Amazon EC2 NVMe Instance Storage"

CASES_RUN=0
CASES_FAILED=0
ASSERTS_RUN=0
ASSERTS_FAILED=0
FAILED_CASES=()
CASE_ID=""
CASE_NAME=""
CASE_DIR=""
CASE_HAS_FAILURE=0
STUB_LOG=""
LOG_DIR=""
NVME_MOUNT=""
RUN_ID=""
LAST_EXIT=0

# =============================================================================
# 工具函数
# =============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# shellcheck disable=SC2329  # 由下面的 trap cleanup EXIT 间接调用
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

begin_case() {
    CASE_ID="$1"
    CASE_NAME="$2"
    CASE_HAS_FAILURE=0
    CASES_RUN=$((CASES_RUN + 1))
    echo ""
    echo "=============================================================================="
    echo " 用例 $CASE_ID) $CASE_NAME"
    echo "=============================================================================="
    CASE_DIR="$TMP_ROOT/case-$CASE_ID"
    LOG_DIR="$CASE_DIR/log"
    NVME_MOUNT="$CASE_DIR/nvme"
    STUB_LOG="$CASE_DIR/invocations.log"
    RUN_ID="test-$CASE_ID"
    mkdir -p "$LOG_DIR" "$NVME_MOUNT"
    : >"$STUB_LOG"
    LAST_EXIT=0
}

end_case() {
    if [[ "$CASE_HAS_FAILURE" == "1" ]]; then
        CASES_FAILED=$((CASES_FAILED + 1))
        FAILED_CASES+=("$CASE_ID) $CASE_NAME")
        echo " -> 用例 $CASE_ID 结果: FAIL"
    else
        echo " -> 用例 $CASE_ID 结果: PASS"
    fi
}

pass_assert() {
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    echo "   [ok]   $1"
}

fail_assert() {
    ASSERTS_RUN=$((ASSERTS_RUN + 1))
    ASSERTS_FAILED=$((ASSERTS_FAILED + 1))
    CASE_HAS_FAILURE=1
    echo "   [FAIL] $1"
    if [[ -n "${2:-}" ]]; then
        echo "          $2"
    fi
}

assert_exit() {
    if [[ "$2" == "$1" ]]; then
        pass_assert "$3（退出码 $2）"
    else
        fail_assert "$3" "期望退出码 $1，实际 $2"
    fi
}

assert_exit_nonzero() {
    if [[ "$1" != "0" ]]; then
        pass_assert "$2（退出码 $1）"
    else
        fail_assert "$2" "期望非零退出码，实际 0"
    fi
}

assert_file_contains() {
    if [[ -f "$1" ]] && grep -qF -- "$2" "$1"; then
        pass_assert "$3"
    else
        fail_assert "$3" "在 $1 中找不到: $2"
    fi
}

assert_file_not_contains() {
    if [[ ! -f "$1" ]] || ! grep -qF -- "$2" "$1"; then
        pass_assert "$3"
    else
        fail_assert "$3" "$1 中不应出现: $2"
    fi
}

assert_file_exists() {
    if [[ -f "$1" ]]; then
        pass_assert "$2"
    else
        fail_assert "$2" "文件不存在: $1"
    fi
}

count_in_log() {
    if [[ -f "$1" ]]; then
        grep -cF -- "$2" "$1" 2>/dev/null || true
    else
        echo 0
    fi
}

assert_count() {
    local actual
    actual="$(count_in_log "$1" "$2")"
    if [[ "$actual" == "$3" ]]; then
        pass_assert "$4（命中 $actual 次）"
    else
        fail_assert "$4" "期望 '$2' 出现 $3 次，实际 $actual 次"
    fi
}

assert_min_count() {
    local actual
    actual="$(count_in_log "$1" "$2")"
    if (( actual >= $3 )); then
        pass_assert "$4（命中 $actual 次 >= $3）"
    else
        fail_assert "$4" "期望 '$2' 至少出现 $3 次，实际 $actual 次"
    fi
}

assert_contains_token() {
    # assert_contains_token <字符串> <子串> <说明>
    if [[ "$1" == *"$2"* ]]; then
        pass_assert "$3"
    else
        fail_assert "$3" "实际内容: $1"
    fi
}

assert_not_contains_token() {
    if [[ "$1" != *"$2"* ]]; then
        pass_assert "$3"
    else
        fail_assert "$3" "实际内容: $1"
    fi
}

grep_line() {
    grep -F -- "$2" "$1" 2>/dev/null | head -n1
}

status_phase() {
    sed -n 's/.*"phase": "\([^"]*\)".*/\1/p' "$LOG_DIR/status.json" 2>/dev/null | head -n1
}

assert_phase() {
    local actual
    actual="$(status_phase)"
    if [[ "$actual" == "$1" ]]; then
        pass_assert "status.json 的 phase = $1"
    else
        fail_assert "status.json 的 phase 应为 $1" "实际为 '${actual:-<无>}'"
    fi
}

# 组装一个只包含指定 stub 的 PATH 目录（用于「缺少 nvidia-smi」这类用例）
make_case_bin() {
    local bin="$CASE_DIR/bin" f name e skip
    mkdir -p "$bin"
    for f in "$STUB_DIR"/*; do
        name="$(basename "$f")"
        skip=0
        for e in "$@"; do
            [[ "$name" == "$e" ]] && skip=1
        done
        [[ "$skip" == "1" ]] && continue
        ln -sf "$f" "$bin/$name"
    done
    printf '%s' "$bin"
}

# 跑一次 bench-bootstrap.sh：stub 在 PATH 最前，DRY_RUN=1，
# DRY_RUN_LOG 与 STUB_LOG 指向同一份调用日志
run_bootstrap() {
    local bin="$1"; shift
    timeout "$CASE_TIMEOUT" env \
        PATH="$bin:$PATH" \
        STUB_LOG="$STUB_LOG" \
        DRY_RUN=1 \
        DRY_RUN_LOG="$STUB_LOG" \
        LOG_DIR="$LOG_DIR" \
        NVME_MOUNT="$NVME_MOUNT" \
        REGION=us-east-2 \
        RESULTS_BUCKET="$TEST_BUCKET" \
        RUN_ID="$RUN_ID" \
        "$@" \
        bash "$BOOTSTRAP" >"$CASE_DIR/stdout.log" 2>&1
    LAST_EXIT=$?
    if [[ "$LAST_EXIT" == "124" ]]; then
        echo "   [注意] 用例被 timeout ${CASE_TIMEOUT}s 强杀"
    fi
}

run_launcher() {
    local bin="$1"; shift
    timeout "$CASE_TIMEOUT" env -u CONFIRM_SPEND \
        PATH="$bin:$PATH" STUB_LOG="$STUB_LOG" \
        bash "$@" >"$CASE_DIR/stdout.log" 2>&1
    LAST_EXIT=$?
}

log "测试根目录: $TMP_ROOT"
log "被测: $BOOTSTRAP"
log "      $LAUNCHER"

# =============================================================================
# 用例 1) 只有一块本地盘时直接使用，不组 RAID0
# =============================================================================
begin_case 1 "单块实例存储盘直接使用，不调用 mdadm"
BIN="$(make_case_bin)"
run_bootstrap "$BIN" \
    STUB_LSBLK="$DISKS_1" \
    STUB_DF_AVAIL_KB=3000000000 \
    CHECKPOINT_GB=160 STORAGE_MARGIN_GB=80 \
    FETCH_CHECKPOINT=false RUN_SERVER=false \
    MAX_RUNTIME_MINUTES=5 STREAM_INTERVAL_SECONDS=1
assert_exit 0 "$LAST_EXIT" "单盘场景正常结束"
assert_file_contains "$STUB_LOG" "mkfs.xfs -f /dev/nvme1n1" "对唯一的实例存储盘直接 mkfs"
assert_file_contains "$STUB_LOG" "mount /dev/nvme1n1 $NVME_MOUNT" "直接挂载该盘"
assert_file_not_contains "$STUB_LOG" "mdadm" "单盘场景绝不调用 mdadm"
assert_file_contains "$CASE_DIR/stdout.log" "只有 1 块本地盘" "日志说明走了单盘分支"
assert_file_contains "$CASE_DIR/stdout.log" "跳过 nvme0n1（EBS 根设备）" "EBS 根设备被显式排除"
end_case

# =============================================================================
# 用例 2) 多块本地盘组 RAID0，且绝不把 EBS 根盘拉进阵列
# =============================================================================
begin_case 2 "多块实例存储盘组 RAID0，排除 EBS 根盘"
BIN="$(make_case_bin)"
run_bootstrap "$BIN" \
    STUB_LSBLK="$DISKS_4" \
    STUB_DF_AVAIL_KB=30000000000 \
    CHECKPOINT_GB=160 STORAGE_MARGIN_GB=80 \
    FETCH_CHECKPOINT=false RUN_SERVER=false \
    MAX_RUNTIME_MINUTES=5 STREAM_INTERVAL_SECONDS=1
assert_exit 0 "$LAST_EXIT" "多盘场景正常结束"
assert_file_contains "$STUB_LOG" "mdadm --create /dev/md0 --level=0 --raid-devices=4" \
    "组 RAID0：--level=0 且 --raid-devices 等于实例存储盘数(4)"
MDADM_LINE="$(grep_line "$STUB_LOG" "mdadm --create")"
for dev in /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 /dev/nvme4n1; do
    assert_contains_token "$MDADM_LINE" "$dev" "RAID0 成员包含 $dev"
done
assert_not_contains_token "$MDADM_LINE" "/dev/nvme0n1" "RAID0 成员不包含 EBS 根设备 /dev/nvme0n1"
assert_file_contains "$STUB_LOG" "mkfs.xfs -f /dev/md0" "对 /dev/md0 而不是单盘做 mkfs"
end_case

# =============================================================================
# 用例 3) 容量护栏：可用空间小于权重体积时，在任何下载/容器之前就失败
# =============================================================================
begin_case 3 "容量不足时在下载与容器之前失败"
BIN="$(make_case_bin)"
run_bootstrap "$BIN" \
    STUB_LSBLK="$DISKS_1" \
    STUB_DF_AVAIL_KB=10485760 \
    CHECKPOINT_GB=160 STORAGE_MARGIN_GB=80 \
    CHECKPOINT_S3_URI="$TEST_CKPT_URI" \
    FETCH_CHECKPOINT=true RUN_SERVER=true \
    MAX_RUNTIME_MINUTES=5 STREAM_INTERVAL_SECONDS=1
assert_exit_nonzero "$LAST_EXIT" "容量不足时非零退出"
assert_file_contains "$CASE_DIR/stdout.log" "容量不足" "打印了明确的容量不足原因"
assert_file_not_contains "$STUB_LOG" "s3 sync" "护栏在任何 s3 sync 之前就拦住了（权重下载与 streamer 都没起）"
assert_file_not_contains "$STUB_LOG" "docker run" "护栏在任何 docker run 之前就拦住了"
assert_file_contains "$STUB_LOG" "s3 cp" "仍用单次 s3 cp 把故障报告送出盘外"
assert_phase failed
end_case

# =============================================================================
# 用例 4) streamer 周期性把日志目录与结果目录同步到 s3://bucket/runs/RUN_ID/...
# =============================================================================
begin_case 4 "streamer 周期同步日志与结果到 S3"
BIN="$(make_case_bin)"
run_bootstrap "$BIN" \
    STUB_LSBLK="$DISKS_1" \
    STUB_DF_AVAIL_KB=3000000000 \
    STUB_CHECKPOINT_SLEEP=5 \
    CHECKPOINT_GB=160 STORAGE_MARGIN_GB=80 \
    CHECKPOINT_S3_URI="$TEST_CKPT_URI" \
    FETCH_CHECKPOINT=true RUN_SERVER=false \
    MAX_RUNTIME_MINUTES=5 STREAM_INTERVAL_SECONDS=1 GPU_SAMPLE_INTERVAL_SECONDS=1
assert_exit 0 "$LAST_EXIT" "同步场景正常结束"
assert_min_count "$STUB_LOG" "s3 sync $LOG_DIR/ s3://$TEST_BUCKET/runs/$RUN_ID/logs/" 3 \
    "streamer 在 5s 下载期间反复同步日志目录（不是只在收尾同步一次）"
assert_min_count "$STUB_LOG" "s3 sync $NVME_MOUNT/results/ s3://$TEST_BUCKET/runs/$RUN_ID/results/" 3 \
    "streamer 同样反复同步结果目录"
assert_min_count "$CASE_DIR/stdout.log" "[streamer] 第" 3 "streamer 的周期痕迹至少出现 3 轮"
assert_file_contains "$STUB_LOG" "cloudwatch put-metric-data --region us-east-2 --namespace TpotBench --metric-name Heartbeat --value 1 --dimensions RunId=$RUN_ID" \
    "发布 CloudWatch 心跳指标（维度带 RunId）"
assert_file_contains "$STUB_LOG" "--metric-name PhaseCode" "发布阶段编码指标"
end_case

# =============================================================================
# 用例 5) Spot 中断：收到通知后做最终同步并把 phase 置为 spot_interrupted
# =============================================================================
begin_case 5 "Spot 中断通知触发最终同步并置 phase"
BIN="$(make_case_bin)"
run_bootstrap "$BIN" \
    STUB_LSBLK="$DISKS_1" \
    STUB_DF_AVAIL_KB=3000000000 \
    STUB_CHECKPOINT_SLEEP=8 \
    STUB_SPOT_ACTION='{"action":"terminate","time":"2026-08-08T04:24:00Z"}' \
    CHECKPOINT_GB=160 STORAGE_MARGIN_GB=80 \
    CHECKPOINT_S3_URI="$TEST_CKPT_URI" \
    FETCH_CHECKPOINT=true RUN_SERVER=false \
    MAX_RUNTIME_MINUTES=5 STREAM_INTERVAL_SECONDS=60 SPOT_POLL_INTERVAL_SECONDS=1
assert_exit 0 "$LAST_EXIT" "Spot 中断按干净退出处理"
assert_phase spot_interrupted
assert_file_contains "$CASE_DIR/stdout.log" "[Spot] 收到中断通知" "记录了中断通知内容"
assert_file_contains "$CASE_DIR/stdout.log" "[Spot] 开始中断前最终同步" "中断后立刻做最终同步"
assert_file_contains "$CASE_DIR/stdout.log" "[Spot] 最终同步完成" "最终同步完成后才通知主流程退出"
assert_min_count "$STUB_LOG" "s3 sync $LOG_DIR/ s3://$TEST_BUCKET/runs/$RUN_ID/logs/" 1 \
    "中断路径确实把日志同步出去了"
end_case

# =============================================================================
# 用例 6) 墙上时钟看门狗：独立于主流程，到点必须终止实例
# =============================================================================
begin_case 6 "看门狗到点终止实例"
BIN="$(make_case_bin)"
run_bootstrap "$BIN" \
    STUB_LSBLK="$DISKS_1" \
    STUB_DF_AVAIL_KB=3000000000 \
    STUB_CHECKPOINT_SLEEP=15 \
    CHECKPOINT_GB=160 STORAGE_MARGIN_GB=80 \
    CHECKPOINT_S3_URI="$TEST_CKPT_URI" \
    FETCH_CHECKPOINT=true RUN_SERVER=false \
    MAX_RUNTIME_MINUTES=0.05 STREAM_INTERVAL_SECONDS=60 SPOT_POLL_INTERVAL_SECONDS=60
assert_exit 0 "$LAST_EXIT" "看门狗收尾后退出"
assert_phase deadline_exceeded
assert_file_contains "$CASE_DIR/stdout.log" "已到 0.05 分钟硬性上限" "看门狗在主流程仍在下载时就触发"
assert_count "$STUB_LOG" "ec2 terminate-instances" 1 "看门狗调用了 terminate-instances，且收尾不会重复调用"
assert_file_contains "$STUB_LOG" "aws ec2 terminate-instances --region us-east-2 --instance-ids i-0stub00000000000" \
    "终止的是自己的 instance-id（来自 IMDSv2）"
end_case

# =============================================================================
# 用例 7) 正常完成：跑完两条 bench_serving，只终止一次
# =============================================================================
begin_case 7 "正常完成且只终止一次"
BIN="$(make_case_bin)"
run_bootstrap "$BIN" \
    STUB_LSBLK="$DISKS_4" \
    STUB_DF_AVAIL_KB=30000000000 \
    STUB_GPU_COUNT=8 STUB_HEALTH_OK=1 \
    CHECKPOINT_GB=160 STORAGE_MARGIN_GB=80 \
    CHECKPOINT_S3_URI="$TEST_CKPT_URI" \
    FETCH_CHECKPOINT=true RUN_SERVER=true \
    TP_SIZE=8 SGLANG_EXTRA_ARGS="--speculative-algorithm EAGLE --speculative-num-steps 3" \
    MAX_RUNTIME_MINUTES=5 STREAM_INTERVAL_SECONDS=1 GPU_SAMPLE_INTERVAL_SECONDS=1
assert_exit 0 "$LAST_EXIT" "完整流程正常结束"
assert_phase completed
assert_count "$STUB_LOG" "ec2 terminate-instances" 1 "正常完成只调用一次 terminate-instances"
assert_file_contains "$STUB_LOG" "docker run -d --name sglang-server --gpus all --ipc=host" "带 GPU 与 ipc=host 启动容器"
assert_file_contains "$STUB_LOG" "--ulimit memlock=-1" "设置 memlock ulimit"
assert_file_contains "$STUB_LOG" "--speculative-algorithm EAGLE" "recipe 里的推测解码参数被透传给 SGLang"
assert_file_contains "$STUB_LOG" "bench_serving --backend sglang --dataset-name random --random-input 40000 --random-output 1500 --num-prompts 50 --max-concurrency 1" \
    "第一条 bench 用 README 6.1 的客户负载参数"
assert_file_contains "$STUB_LOG" "bench_serving --backend sglang --dataset-name random --random-input 30000 --random-output 4096 --num-prompts 50 --max-concurrency 1" \
    "第二条 bench 用 README 6.1 的官方对标参数"
assert_file_exists "$NVME_MOUNT/results/bench_custom_$RUN_ID.json" "写出了客户负载 bench 结果文件"
assert_file_exists "$NVME_MOUNT/results/bench_official_$RUN_ID.json" "写出了官方对标 bench 结果文件"
assert_file_exists "$NVME_MOUNT/results/run_$RUN_ID.json" "写出了运行元数据供 FEAT-003 收集器消费"
assert_file_exists "$LOG_DIR/gpu.csv" "GPU 采样写出了 gpu.csv"
assert_file_contains "$LOG_DIR/gpu.csv" ",87," "gpu.csv 里有真实采样行（利用率 87）"
assert_file_contains "$STUB_LOG" "--metric-name GpuUtilization" "GPU 利用率被推到 CloudWatch"
assert_file_contains "$STUB_LOG" "docker-data-root-relocate" "在 docker pull 之前决定迁移 data-root 到 NVMe"
end_case

# =============================================================================
# 用例 8) 没有 nvidia-smi 时只告警不中断（plumbing 阶段的 c5d.large 无 GPU）
# =============================================================================
begin_case 8 "缺少 nvidia-smi 只告警不中断"
BIN="$(make_case_bin nvidia-smi)"
if [[ -e "$BIN/nvidia-smi" ]]; then
    fail_assert "用例 bin 目录不应包含 nvidia-smi" "$BIN/nvidia-smi 仍然存在"
else
    pass_assert "用例 bin 目录里没有 nvidia-smi（模拟无 GPU 机型）"
fi
run_bootstrap "$BIN" \
    STUB_LSBLK="nvme0n1 200G Amazon Elastic Block Store\nnvme1n1 50G Amazon EC2 NVMe Instance Storage" \
    STUB_DF_AVAIL_KB=52428800 \
    CHECKPOINT_GB=1 STORAGE_MARGIN_GB=5 \
    FETCH_CHECKPOINT=false RUN_SERVER=false \
    MAX_RUNTIME_MINUTES=5 STREAM_INTERVAL_SECONDS=1
assert_exit 0 "$LAST_EXIT" "无 GPU 也能跑完管路验证"
assert_phase completed
assert_file_contains "$CASE_DIR/stdout.log" "未找到 nvidia-smi" "打印了缺少 nvidia-smi 的告警"
assert_file_contains "$CASE_DIR/stdout.log" "跳过 GPU 采样" "明确说明跳过 GPU 采样"
if [[ ! -f "$LOG_DIR/gpu.csv" ]]; then
    pass_assert "没有 nvidia-smi 时不生成 gpu.csv"
else
    fail_assert "没有 nvidia-smi 时不应生成 gpu.csv" "$LOG_DIR/gpu.csv 存在"
fi
end_case

# =============================================================================
# 用例 9) launcher 花费闸门：没有 CONFIRM_SPEND 一律拒绝启动
# =============================================================================
begin_case 9 "launcher 无 CONFIRM_SPEND 时拒绝启动"
BIN="$(make_case_bin)"
run_launcher "$BIN" "$LAUNCHER" --stage full
assert_exit_nonzero "$LAST_EXIT" "没有 CONFIRM_SPEND=yes 时拒绝启动"
assert_file_contains "$CASE_DIR/stdout.log" "拒绝启动" "明确输出拒绝启动"
assert_file_contains "$CASE_DIR/stdout.log" "p5en.48xlarge" "打印了实例类型"
assert_file_contains "$CASE_DIR/stdout.log" "26.661700" "打印了 Spot 现价（每小时预估）"
assert_file_contains "$CASE_DIR/stdout.log" "35.00" "打印了 Spot 出价上限"
assert_file_contains "$CASE_DIR/stdout.log" "240 分钟" "打印了 MAX_RUNTIME_MINUTES"
assert_file_contains "$CASE_DIR/stdout.log" "106.65" "打印了最坏总花费（26.6617 x 240/60）"
assert_file_not_contains "$STUB_LOG" "run-instances" "完全没有发起 run-instances 调用"
end_case

# =============================================================================
# 用例 10) launcher --dry-run：run-instances 参数必须齐全
# 自终止依赖 Project 标签，SSM 依赖实例配置文件，Spot 依赖 MaxPrice
# =============================================================================
begin_case 10 "launcher --dry-run 参数完整"
BIN="$(make_case_bin)"
run_launcher "$BIN" "$LAUNCHER" --stage full --dry-run
assert_exit 0 "$LAST_EXIT" "dry-run 以 0 退出"
assert_file_contains "$CASE_DIR/stdout.log" "DryRunOperation" "把 DryRunOperation 当作成功"
RUN_LINE="$(grep_line "$STUB_LOG" "ec2 run-instances")"
for token in "--dry-run" "--iam-instance-profile Name=tpot-bench-ec2-profile" \
             "HttpTokens=required" "Key=Project,Value=tpot-benchmark" \
             "MaxPrice=35.00" "SpotInstanceType=one-time" "ResourceType=volume" \
             "--user-data file://" "--instance-type p5en.48xlarge"; do
    assert_contains_token "$RUN_LINE" "$token" "run-instances 参数包含 $token"
done
assert_file_contains "$CASE_DIR/stdout.log" "bash -n 校验通过" "下单前对渲染结果做了 bash -n 校验"
end_case

# =============================================================================
# 用例 11) 渲染结果语法错误时，launcher 必须在任何 AWS 调用之前拒绝
# =============================================================================
begin_case 11 "user-data 语法错误时拒绝启动且不调用 AWS"
BIN="$(make_case_bin)"
BROKEN_DIR="$CASE_DIR/scripts"
mkdir -p "$BROKEN_DIR/bootstrap"
cp "$LAUNCHER" "$BROKEN_DIR/launch-bench-ec2.sh"
{
    cat "$BOOTSTRAP"
    echo 'if [[ 1 == 1 ]]; then'   # 故意留一个未闭合的 if
} >"$BROKEN_DIR/bootstrap/bench-bootstrap.sh"
run_launcher "$BIN" "$BROKEN_DIR/launch-bench-ec2.sh" --stage full --dry-run
assert_exit_nonzero "$LAST_EXIT" "引导脚本语法错误时拒绝启动"
assert_file_contains "$CASE_DIR/stdout.log" "语法校验失败" "打印了语法校验失败原因"
assert_file_not_contains "$STUB_LOG" "aws " "语法校验先于任何 AWS 调用（调用日志里没有 aws）"
end_case

# =============================================================================
# 用例 12) 新脚本里不得出现全网 CIDR 字面量与写死的沙箱出口 IP
# =============================================================================
begin_case 12 "新脚本无全网 CIDR 字面量与写死出口 IP"
WORLD_CIDR_LITERAL="$(printf '%s/%d' '0.0.0.0' 0)"
OLD_EGRESS_IP="$(printf '54.236.%d.%d' 10 181)"
for f in "$BOOTSTRAP" "$LAUNCHER" "$REPO_ROOT/tests/run-tests.sh"; do
    if grep -qF -- "$WORLD_CIDR_LITERAL" "$f"; then
        fail_assert "$(basename "$f") 不应包含全网 CIDR 字面量" "$f"
    else
        pass_assert "$(basename "$f") 不含全网 CIDR 字面量"
    fi
    if grep -qF -- "$OLD_EGRESS_IP" "$f"; then
        fail_assert "$(basename "$f") 不应写死沙箱出口 IP" "$f"
    else
        pass_assert "$(basename "$f") 不含写死的沙箱出口 IP"
    fi
done
end_case

# =============================================================================
# 用例 13) collect-results.sh 必须产出 compare-results.sh 真能读的 schema
# 这条用例守的是一个很容易悄悄坏掉的契约：实例写的是 bench_serving 原始输出
# (JSONL + median_* 键名)，而 compare-results.sh 读的是 .results.tpot_p50_ms。
# 中间那层一坏，对比表全是 N/A，而且不会报错。
# =============================================================================
begin_case 13 "collect-results 夹具 -> compare-results 表格有真实数字"
COLLECTOR="$REPO_ROOT/scripts/collect-results.sh"
COMPARER="$REPO_ROOT/scripts/compare-results.sh"
FIXTURES="$REPO_ROOT/tests/fixtures"
OUT_DIR="$CASE_DIR/collected"
timeout "$CASE_TIMEOUT" bash "$COLLECTOR" --fixture "$FIXTURES" --out "$OUT_DIR" \
    >"$CASE_DIR/stdout.log" 2>&1
LAST_EXIT=$?
assert_exit 0 "$LAST_EXIT" "collect-results 处理夹具后以 0 退出"
COLLECTED_JSON="$OUT_DIR/p5en-48xlarge_tp4_20260807_150955.json"
assert_file_exists "$COLLECTED_JSON" "文件名沿用 run-benchmark.sh 的 <类型>_tp<N>_<时间戳>.json"
assert_file_exists "$OUT_DIR/p5en-48xlarge_tp4_20260807_150955_summary.txt" "同时产出人类可读 summary"
assert_file_contains "$CASE_DIR/stdout.log" "JSONL，共 2 条，取最后一条" \
    "识别出 bench_serving 的 JSONL 形态并取最后一条记录"

# 直接读 JSON，断言 compare-results.sh 依赖的每一个字段都在且是真数字
SCHEMA_REPORT="$(python3 - "$COLLECTED_JSON" <<'PYEOF'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
meta = data["metadata"]
problems = []
for key in ("instance_type", "tp_size", "region", "timestamp"):
    if not meta.get(key):
        problems.append("metadata.%s 缺失" % key)
for name, expect_in, expect_out in (("custom_benchmark", 40000, 1500),
                                    ("official_benchmark", 30000, 4096)):
    bench = data.get(name) or {}
    cfg = bench.get("config") or {}
    res = bench.get("results") or {}
    if cfg.get("input_tokens") != expect_in or cfg.get("output_tokens") != expect_out:
        problems.append("%s.config 与 README 6.1 不一致: %s" % (name, cfg))
    if cfg.get("num_prompts") != 50 or cfg.get("max_concurrency") != 1:
        problems.append("%s.config 的 prompts/并发与 README 6.1 不一致" % name)
    for key in ("tpot_p50_ms", "tpot_p95_ms", "ttft_p50_ms", "ttft_p95_ms"):
        if not isinstance(res.get(key), (int, float)) or res.get(key) <= 0:
            problems.append("%s.results.%s 不是正数" % (name, key))
    if "pass" not in bench:
        problems.append("%s.pass 缺失" % name)
print("OK" if not problems else "; ".join(problems))
print(data["custom_benchmark"]["results"]["tpot_p50_ms"])
print(data["official_benchmark"]["results"]["tpot_p50_ms"])
PYEOF
)"
assert_contains_token "$(echo "$SCHEMA_REPORT" | sed -n 1p)" "OK" \
    "产出的 JSON 含 compare-results.sh 需要的全部字段"
assert_contains_token "$(echo "$SCHEMA_REPORT" | sed -n 2p)" "4.21" \
    "自定义负载取到的是 JSONL 最后一条 (median_tpot_ms=4.21，不是第一条的 9.99)"
assert_contains_token "$(echo "$SCHEMA_REPORT" | sed -n 3p)" "3.76" \
    "官方对标取到 median_tpot_ms=3.76"

# 再真的跑一遍 compare-results.sh，断言表格里是数字而不是 N/A
timeout "$CASE_TIMEOUT" bash "$COMPARER" "$OUT_DIR" >"$CASE_DIR/compare.log" 2>&1
LAST_EXIT=$?
assert_exit 0 "$LAST_EXIT" "compare-results.sh 读取收集结果后以 0 退出"
assert_file_contains "$CASE_DIR/compare.log" "4.21ms" "对比表里 TPOT P50 是真实数字"
assert_file_contains "$CASE_DIR/compare.log" "1512.4ms" "对比表里 TTFT P50 是真实数字"
assert_file_contains "$CASE_DIR/compare.log" "PASS" "对比表给出了达标判定"
assert_file_not_contains "$CASE_DIR/compare.log" "没有可用的测试结果" \
    "compare-results.sh 真的看到了传入目录（不是静默回退到默认 results/）"
if grep -qE '^p5en\.48xlarge .*N/A' "$CASE_DIR/compare.log"; then
    fail_assert "TPOT P50 列不得出现 N/A" "$(grep -E '^p5en' "$CASE_DIR/compare.log")"
else
    pass_assert "对比表里没有 N/A"
fi
end_case

# =============================================================================
# 用例 14) recipe 文件与推测解码 flag 拼写
# =============================================================================
begin_case 14 "三个 recipe 齐备、语法正确、DSpark 不带 EAGLE 专属参数"
RECIPE_DIR="$REPO_ROOT/scripts/recipes"
for r in h200-tp4-fp4-eagle.env h200-tp4-fp8-eagle.env h200-tp4-dspark-0731.env; do
    if [[ -f "$RECIPE_DIR/$r" ]]; then
        pass_assert "recipe 存在: $r"
    else
        fail_assert "recipe 缺失: $r"
        continue
    fi
    if bash -n "$RECIPE_DIR/$r" 2>/dev/null; then
        pass_assert "$r 能被 bash 解析（launcher 会把它拼进 user-data）"
    else
        fail_assert "$r 语法错误"
    fi
    if grep -qE '^#.*[0-9]{9,} 字节' "$RECIPE_DIR/$r"; then
        pass_assert "$r 头部写明了 checkpoint 精确字节数"
    else
        fail_assert "$r 头部缺少 checkpoint 精确字节数"
    fi
    assert_file_contains "$RECIPE_DIR/$r" "--speculative-algorithm" "$r 用的是 --speculative-algorithm"
done
# 断言只针对「真正生效的行」：注释里会成段引用上游原文，包含这些 flag 名字是
# 应该的，被引用不等于被传给服务端。
effective_lines() {
    local src="$1" dst="$2"
    grep -vE '^[[:space:]]*(#|$)' "$src" >"$dst" || true
    printf '%s' "$dst"
}
DSPARK_EFF="$(effective_lines "$RECIPE_DIR/h200-tp4-dspark-0731.env" "$CASE_DIR/dspark.eff")"
FP4_EFF="$(effective_lines "$RECIPE_DIR/h200-tp4-fp4-eagle.env" "$CASE_DIR/fp4.eff")"
FP8_EFF="$(effective_lines "$RECIPE_DIR/h200-tp4-fp8-eagle.env" "$CASE_DIR/fp8.eff")"
assert_file_contains "$DSPARK_EFF" "--speculative-algorithm DSPARK" "DSpark recipe 指定了 DSPARK"
for forbidden in "--speculative-num-steps" "--speculative-eagle-topk" \
                 "--speculative-num-draft-tokens" "--speculative-draft-model-path"; do
    assert_file_not_contains "$DSPARK_EFF" "$forbidden" \
        "DSpark recipe 生效行里没有 $forbidden（上游明确要求省略）"
done
assert_file_not_contains "$FP4_EFF" "--enable-dp-attention" \
    "FP4/Marlin recipe 生效行里不开 DP-attention（Hopper 上不支持）"
assert_file_not_contains "$FP4_EFF" "--dp-size" "FP4/Marlin recipe 生效行里不传 DP 并行度"
assert_file_contains "$FP8_EFF" "--enable-dp-attention" \
    "FP8 重打包 recipe 才开 DP-attention"
assert_file_contains "$FP4_EFF" "--moe-runner-backend marlin" \
    "FP4 recipe 走 Hopper 的 W4A16 Marlin MoE runner"
BAD_SPELLING="$(printf -- '--speculative-algo%s' ' ')"
if grep -rqF -- "$BAD_SPELLING" "$REPO_ROOT/scripts/"; then
    fail_assert "scripts/ 下仍存在错误拼写的 speculative flag" \
        "$(grep -rnF -- "$BAD_SPELLING" "$REPO_ROOT/scripts/")"
else
    pass_assert "scripts/ 下没有错误拼写的 speculative flag"
fi
end_case

# =============================================================================
# 用例 15) run-staged.sh：preflight 之后的每一级都必须被花费闸门拦住
# =============================================================================
begin_case 15 "run-staged 三级付费 stage 在无 CONFIRM_SPEND 时全部拒绝"
STAGED="$REPO_ROOT/scripts/run-staged.sh"
BIN="$(make_case_bin)"
STAGE_LEDGER="$CASE_DIR/stage-ledger.json"
run_staged() {
    # stub 在 PATH 最前，台账写到用例目录，绝不写真实 results/
    timeout "$CASE_TIMEOUT" env -u CONFIRM_SPEND \
        PATH="$BIN:$PATH" STUB_LOG="$STUB_LOG" \
        STUB_SPOT_PRICE="$2" LEDGER="$STAGE_LEDGER" \
        bash "$STAGED" --stage "$1" >"$CASE_DIR/staged-$1.log" 2>&1
    LAST_EXIT=$?
}
for spec in "plumbing c5d.large 0.029500 0.01" \
            "gpu-smoke g6e.xlarge 1.200000 1.20" \
            "full p5en.48xlarge 26.661700 106.65"; do
    # shellcheck disable=SC2086  # 故意按空格拆成四个字段
    set -- $spec
    stage="$1"; itype="$2"; price="$3"; worst="$4"
    run_staged "$stage" "$price"
    assert_exit 2 "$LAST_EXIT" "stage $stage 无 CONFIRM_SPEND 时以 2 退出"
    assert_file_contains "$CASE_DIR/staged-$stage.log" "$itype" "stage $stage 打印了自己的实例类型 $itype"
    assert_file_contains "$CASE_DIR/staged-$stage.log" "$worst" "stage $stage 打印了最坏花费 \$$worst"
    assert_file_contains "$CASE_DIR/staged-$stage.log" "CONFIRM_SPEND=yes" "stage $stage 说明了如何显式授权"
    # 必须是 run-staged 自己在闸门处拦住，而不是靠 launcher 兜底：
    # 被拦住时 launcher 根本不该被调用，所以它的渲染步骤不会出现在输出里。
    assert_file_not_contains "$CASE_DIR/staged-$stage.log" "渲染 user-data" \
        "stage $stage 在自己的闸门处就拒绝了，没有把 launcher 叫起来"
done
assert_file_not_contains "$STUB_LOG" "run-instances" "三级 stage 都没有发起 run-instances"
assert_file_exists "$STAGE_LEDGER" "阶段台账已生成（迭代状态落在文件里）"
LEDGER_REPORT="$(python3 - "$STAGE_LEDGER" <<'PYEOF'
import json
import sys

entries = json.load(open(sys.argv[1], encoding="utf-8"))["entries"]
stages = [e["stage"] for e in entries]
statuses = {e["stage"]: e["exit_status"] for e in entries}
required = {"plumbing", "gpu-smoke", "full"}
missing = required - set(stages)
wrong = [s for s in required - missing if statuses[s] != 2]
print("OK" if not missing and not wrong else "missing=%s wrong=%s" % (missing, wrong))
PYEOF
)"
assert_contains_token "$LEDGER_REPORT" "OK" "台账为三级 stage 各记了一条 exit_status=2 的拒绝记录"
end_case

# =============================================================================
# 汇总
# =============================================================================
echo ""
echo "=============================================================================="
echo " 测试汇总"
echo "=============================================================================="
echo " 用例: $CASES_RUN 个，失败 $CASES_FAILED 个"
echo " 断言: $ASSERTS_RUN 条，失败 $ASSERTS_FAILED 条"
if (( CASES_FAILED > 0 )); then
    echo " 失败用例:"
    for c in "${FAILED_CASES[@]}"; do
        echo "   - $c"
    done
    echo "=============================================================================="
    exit 1
fi
echo " 结论: 全部通过（本次测试未接触任何真实 AWS 资源，花费 \$0）"
echo "=============================================================================="
exit 0
