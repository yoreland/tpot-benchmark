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
