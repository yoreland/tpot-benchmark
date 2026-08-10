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
# FEAT-004 的公共夹具：总结闸门相关用例都用这几个 helper
# =============================================================================
STAGED="$REPO_ROOT/scripts/run-staged.sh"
SUMMARIZER="$REPO_ROOT/scripts/summarize-run.sh"
FIXTURE_RUN_ID="20260807-150955-a1b2"
LOWACCEPT_RUN_ID="20260807-171500-l0wa"

# 造一份阶段台账。第二个参数决定那条 h200 成功记录有没有写过总结；
# 第三个参数给 pending 时再塞两条「跑完了但 phase 还没回填」的记录
# （一条 full、一条 plumbing），用来验证回填只认 GPU stage。
seed_ledger() {
    local path="$1" summary_done="$2" pending="${3:-no}"
    SEED_PATH="$path" SEED_DONE="$summary_done" SEED_PENDING="$pending" \
    SEED_RUN_ID="$FIXTURE_RUN_ID" python3 - <<'PYEOF'
import json
import os

entries = [{
    "stage": "full",
    "run_id": os.environ["SEED_RUN_ID"],
    "instance_type": "p5en.48xlarge",
    "instance_id": "i-0000000000fixture",
    "started_at": "2026-08-07T15:09:55Z",
    "ended_at": "2026-08-07T16:30:15Z",
    "exit_status": 0,
    "s3_prefix": "s3://tpot-bench-results-077090643075-us-east-2/runs/%s/"
                 % os.environ["SEED_RUN_ID"],
    "recipe": "scripts/recipes/h200-tp4-fp4-eagle.env",
    "mode": "real",
    "note": "测试用种子记录（没有启动过任何实例）",
    "gpu_family": "h200",
    "gpu_success": True,
    "final_phase": "completed",
    "spot_price_usd_per_hour": 26.6617,
    "summary_required": True,
    "summary_done": os.environ["SEED_DONE"] == "true",
    "summary_path": None,
    "summary_ack": False,
}]
if os.environ["SEED_PENDING"] == "yes":
    # 这两条刻意不带 final_phase / gpu_success：模拟「不带 --wait 启动，
    # 退出那一刻 status.json 还没上传」的情形，闸门应当只回填 GPU stage 那条。
    entries = [{
        "stage": "plumbing", "run_id": "20260808-010101-plmb",
        "instance_type": "c5d.large", "instance_id": "i-0stub00000000000",
        "started_at": "2026-08-08T01:01:01Z", "ended_at": "2026-08-08T01:21:01Z",
        "exit_status": 0, "s3_prefix": "s3://bkt/runs/20260808-010101-plmb/",
        "recipe": "", "mode": "real", "note": "c5d.large 管路验证成功（无 GPU）",
    }, {
        "stage": "full", "run_id": "20260808-020202-h200",
        "instance_type": "p5en.48xlarge", "instance_id": "i-0stub00000000000",
        "started_at": "2026-08-08T02:02:02Z", "ended_at": "2026-08-08T02:05:02Z",
        "exit_status": 0, "s3_prefix": "s3://bkt/runs/20260808-020202-h200/",
        "recipe": "scripts/recipes/h200-tp4-fp4-eagle.env", "mode": "real",
        "note": "不带 --wait 启动，退出时 phase 未知",
    }]
with open(os.environ["SEED_PATH"], "w", encoding="utf-8") as fh:
    json.dump({"schema": "tpot-bench-stage-ledger/2", "entries": entries},
              fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PYEOF
}

# 跑一次 run-staged.sh：stub 永远在 PATH 最前，台账写在用例目录里。
# 第 4 个参数控制要不要给 CONFIRM_SPEND=yes —— 验收标准明确要求证明
# 「补上 CONFIRM_SPEND 也绕不过总结闸门」，所以这里必须真的传一次。
# 传的时候 aws 一律是 tests/stubs/aws，绝不会碰到真实 AWS。
run_staged_gate() {
    local bin="$1" ledger="$2" out="$3" confirm="$4"; shift 4
    if [[ "$confirm" == "yes" ]]; then
        timeout "$CASE_TIMEOUT" env \
            PATH="$bin:$PATH" STUB_LOG="$STUB_LOG" CONFIRM_SPEND=yes \
            LEDGER="$ledger" LEDGER_REFRESH="${GATE_REFRESH:-false}" \
            STUB_SPOT_PRICE=26.661700 \
            bash "$STAGED" "$@" >"$out" 2>&1
    else
        timeout "$CASE_TIMEOUT" env -u CONFIRM_SPEND \
            PATH="$bin:$PATH" STUB_LOG="$STUB_LOG" \
            LEDGER="$ledger" LEDGER_REFRESH="${GATE_REFRESH:-false}" \
            STUB_SPOT_PRICE=26.661700 \
            bash "$STAGED" "$@" >"$out" 2>&1
    fi
    LAST_EXIT=$?
}

ledger_field() {
    # ledger_field <台账> <run_id> <字段>
    LF_PATH="$1" LF_RUN="$2" LF_KEY="$3" python3 - <<'PYEOF'
import json
import os

try:
    with open(os.environ["LF_PATH"], encoding="utf-8") as fh:
        entries = json.load(fh).get("entries") or []
except (json.JSONDecodeError, OSError):
    entries = []
value = "<无记录>"
for entry in entries:
    if entry.get("run_id") == os.environ["LF_RUN"]:
        value = entry.get(os.environ["LF_KEY"], "<无此字段>")
print(json.dumps(value, ensure_ascii=False))
PYEOF
}

# =============================================================================
# 用例 16) 总结闸门：有一次 GPU 成功但没写总结时，付费 GPU stage 必须被拦住，
# 而且**补上 CONFIRM_SPEND=yes 也一样被拦**。后半句才是关键：如果这个闸门排在
# 花费闸门后面，无人值守的会话只要照常带着 CONFIRM_SPEND=yes 就能继续烧钱。
# =============================================================================
begin_case 16 "跑成功未总结时 gpu-smoke/full 以 3 退出，CONFIRM_SPEND 也绕不过"
BIN="$(make_case_bin)"
GATE_LEDGER="$CASE_DIR/stage-ledger.json"
seed_ledger "$GATE_LEDGER" false
run_staged_gate "$BIN" "$GATE_LEDGER" "$CASE_DIR/gate-full.log" no --stage full
assert_exit 3 "$LAST_EXIT" "无 CONFIRM_SPEND + 有未总结的成功运行 -> 退出码 3（不是 2）"
assert_file_contains "$CASE_DIR/gate-full.log" "$FIXTURE_RUN_ID" \
    "拒绝信息里点名了等待总结的 RUN_ID"
assert_file_contains "$CASE_DIR/gate-full.log" "scripts/summarize-run.sh" \
    "拒绝信息里给出了清闸门的命令"
assert_file_contains "$CASE_DIR/gate-full.log" "--ack-summary" "说明了怎么显式跳过"
assert_file_not_contains "$CASE_DIR/gate-full.log" "渲染 user-data" \
    "闸门在 run-staged 自己这里就拦住了，没有把 launcher 叫起来"
run_staged_gate "$BIN" "$GATE_LEDGER" "$CASE_DIR/gate-full-confirm.log" yes --stage full
assert_exit 3 "$LAST_EXIT" "带 CONFIRM_SPEND=yes 仍然是 3（总结闸门排在花费闸门之前）"
assert_file_not_contains "$CASE_DIR/gate-full-confirm.log" "渲染 user-data" \
    "带 CONFIRM_SPEND=yes 也没有把 launcher 叫起来"
run_staged_gate "$BIN" "$GATE_LEDGER" "$CASE_DIR/gate-smoke.log" no --stage gpu-smoke
assert_exit 3 "$LAST_EXIT" "gpu-smoke 同样被总结闸门拦住"
assert_file_not_contains "$STUB_LOG" "run-instances" "三次尝试都没有发起任何 run-instances"
assert_file_not_contains "$STUB_LOG" "terminate-instances" "更没有动过任何实例"
end_case

# =============================================================================
# 用例 17) --ack-summary：能跳过，但跳过之后紧接着还得过花费闸门（退出码 2），
# 而且台账里必须留下「用过 override」的痕迹 —— 可跳过但绝不静默。
# =============================================================================
begin_case 17 "--ack-summary 放行总结闸门后仍被花费闸门拦住，且台账留痕"
BIN="$(make_case_bin)"
ACK_LEDGER="$CASE_DIR/stage-ledger.json"
seed_ledger "$ACK_LEDGER" false
run_staged_gate "$BIN" "$ACK_LEDGER" "$CASE_DIR/ack.log" no --stage full --ack-summary
assert_exit 2 "$LAST_EXIT" "总结闸门被放行，改由花费闸门以 2 拒绝（两个闸门相互独立）"
assert_file_contains "$CASE_DIR/ack.log" "已用 --ack-summary 跳过总结闸门" "override 在输出里大声留痕"
assert_file_contains "$CASE_DIR/ack.log" "p5en.48xlarge" "继续走到了花费画像"
assert_file_contains "$CASE_DIR/ack.log" "106.65" "打印了最坏花费"
assert_contains_token "$(ledger_field "$ACK_LEDGER" "-" summary_ack)" "true" \
    "台账里那条拒绝记录标了 summary_ack=true"
assert_file_not_contains "$STUB_LOG" "run-instances" "override 也没有真的启动实例"
end_case

# =============================================================================
# 用例 18) 总结写完（summary_done=true）之后闸门必须放行，
# 否则总结就变成了一道永久的墙。
# =============================================================================
begin_case 18 "summary_done=true 时闸门放行，退回普通的花费拒绝"
BIN="$(make_case_bin)"
DONE_LEDGER="$CASE_DIR/stage-ledger.json"
seed_ledger "$DONE_LEDGER" true
run_staged_gate "$BIN" "$DONE_LEDGER" "$CASE_DIR/done.log" no --stage full
assert_exit 2 "$LAST_EXIT" "已有总结时不再触发 3，退回花费闸门的 2"
assert_file_contains "$CASE_DIR/done.log" "台账里没有「已成功但未总结」的运行" "明确说明闸门放行"
assert_file_not_contains "$CASE_DIR/done.log" "已经有一次 GPU 运行成功了" "不再打印停顿拒绝信息"
end_case

# =============================================================================
# 用例 19) phase 回填只认 GPU stage：c5d.large 的管路成功永远不算 GPU 成功，
# 所以它不可能触发总结闸门。同时验证「不带 --wait 启动」的自愈路径：
# 下一次执行时闸门会用只读方式把 full 那条的 phase 补成真值并拦住。
# =============================================================================
begin_case 19 "c5d.large 管路成功不算 GPU 成功；full 的 phase 会被只读回填"
BIN="$(make_case_bin)"
# 让这个用例的 aws 在 s3 cp status.json 时返回 phase=completed，
# 其余子命令仍交给公共 stub（照样只写调用日志，不碰真实 AWS）。
# 注意必须先 rm 掉那个符号链接：直接 `cat >` 会顺着链接把 tests/stubs/aws
# 本身覆盖掉（第一版就踩了这个坑，后面所有用例一起挂）。
rm -f "$BIN/aws"
cat >"$BIN/aws" <<EOF
#!/usr/bin/env bash
set -uo pipefail
printf 'aws %s\n' "\$*" >>"\${STUB_LOG:-/dev/null}"
if [[ "\$*" == *"s3 cp"*"status.json"* ]]; then
    # 形状照抄 bench-bootstrap.sh 真正写出的 status.json
    echo '{"run_id": "20260808-020202-h200", "stage": "full", "phase": "completed", "exit_code": 0}'
    exit 0
fi
exec "$STUB_DIR/aws" "\$@"
EOF
chmod +x "$BIN/aws"
REFILL_LEDGER="$CASE_DIR/stage-ledger.json"
seed_ledger "$REFILL_LEDGER" false yes
GATE_REFRESH=true run_staged_gate "$BIN" "$REFILL_LEDGER" "$CASE_DIR/refill.log" no --stage full
assert_exit 3 "$LAST_EXIT" "回填后发现 full 那次其实成功了，于是被总结闸门拦住"
assert_file_contains "$CASE_DIR/refill.log" "回补台账: RUN_ID 20260808-020202-h200" \
    "只读回填了 full 那条记录的 phase"
assert_file_not_contains "$CASE_DIR/refill.log" "回补台账: RUN_ID 20260808-010101-plmb" \
    "plumbing 那条根本不参与回填（它没有 GPU）"
assert_contains_token "$(ledger_field "$REFILL_LEDGER" 20260808-020202-h200 gpu_success)" \
    "true" "full 那条被标成 gpu_success=true"
assert_contains_token "$(ledger_field "$REFILL_LEDGER" 20260808-010101-plmb gpu_success)" \
    "<无此字段>" "plumbing 那条始终没有 gpu_success 字段（c5d.large 无 GPU）"
assert_file_contains "$CASE_DIR/refill.log" "20260808-020202-h200" "拒绝信息点名的是 H200 那次运行"
# 顺带确认 plumbing 自己写台账时也不会给自己发 GPU 身份
PLUMB_LEDGER="$CASE_DIR/plumbing-ledger.json"
timeout "$CASE_TIMEOUT" env -u CONFIRM_SPEND PATH="$BIN:$PATH" STUB_LOG="$STUB_LOG" \
    LEDGER="$PLUMB_LEDGER" LEDGER_REFRESH=false STUB_SPOT_PRICE=0.029500 \
    bash "$STAGED" --stage plumbing >"$CASE_DIR/plumbing.log" 2>&1
LAST_EXIT=$?
assert_exit 2 "$LAST_EXIT" "plumbing 仍然被花费闸门拦住"
assert_file_contains "$PLUMB_LEDGER" '"gpu_family": "none"' "c5d.large 的台账记录 gpu_family=none"
assert_file_contains "$PLUMB_LEDGER" '"summary_required": false' "因此永远不会要求写总结"
assert_file_not_contains "$STUB_LOG" "run-instances" "整个用例没有发起任何 run-instances"
end_case

# =============================================================================
# 用例 20) summarize-run.sh --fixture：总结里必须有真数字、有基线对比、有 A1-A9
# 判定表，并且把台账翻成 summary_done=true（这才是闸门的放行条件）。
# =============================================================================
begin_case 20 "summarize-run 夹具产出完整总结并放行闸门"
SUM_LEDGER="$CASE_DIR/stage-ledger.json"
SUM_OUT="$CASE_DIR/summaries"
seed_ledger "$SUM_LEDGER" false
timeout "$CASE_TIMEOUT" bash "$SUMMARIZER" --fixture "$REPO_ROOT/tests/fixtures" \
    --out "$SUM_OUT" --ledger "$SUM_LEDGER" >"$CASE_DIR/stdout.log" 2>&1
LAST_EXIT=$?
assert_exit 0 "$LAST_EXIT" "夹具总结生成成功（不碰 AWS，零花费）"
SUM_MD="$SUM_OUT/$FIXTURE_RUN_ID-summary.md"
assert_file_exists "$SUM_MD" "总结文件名是 <RUN_ID>-summary.md"
assert_file_contains "$SUM_MD" "4.21 ms" "总结里有 TPOT P50 实测值"
assert_file_contains "$SUM_MD" "4.88 ms" "总结里有 TPOT P95 实测值"
assert_file_contains "$SUM_MD" "1.512 s" "总结里有 TTFT P50 实测值"
assert_file_contains "$SUM_MD" "1.603 s" "总结里有 TTFT P95 实测值"
assert_file_contains "$SUM_MD" "6.428 s" "总结里有 E2E P50 实测值"
assert_file_contains "$SUM_MD" "3.76" "与 README 12.2 的 ~3.76 ms 基线做了对比"
assert_file_contains "$SUM_MD" "266" "并且对比了 ~266 tok/s 的 decode 吞吐"
assert_file_contains "$SUM_MD" "accept length" "有 accept length 这一项"
assert_file_contains "$SUM_MD" "2.71" "写出了实测 accept_length"
assert_file_contains "$SUM_MD" "≥ 2" "accept_length 对的是 A7 的 2.0 门槛"
for cid in A1 A2 A3 A4 A5 A6 A7 A8 A9; do
    assert_file_contains "$SUM_MD" "**$cid**" "判定表里有 README 12.9 的 $cid"
done
assert_file_contains "$SUM_MD" "未评估" "拿不到判据的条目标成未评估而不是 PASS"
assert_file_contains "$SUM_MD" "118770 MiB" "GPU 显存峰值来自 gpu.csv"
assert_file_contains "$SUM_MD" "91% / 94.5% / 98%" "每张卡的利用率 min/mean/max 都在"
assert_file_contains "$SUM_MD" "4820 s / 3600" "花费按 status.json/元数据的耗时算出来"
assert_file_contains "$SUM_MD" "12.12.1" "给出了 README 12.12.1 该填哪一行"
assert_file_contains "$SUM_MD" "合成夹具" "夹具产出的总结显著标注了不是真实测量"
# A6/A8/A9 必须是未评估而不是 PASS：这三条产物里确实没有判据
for spec in "A6" "A8" "A9"; do
    A_LINE="$(grep -F "**$spec**" "$SUM_MD" | head -n1)"
    assert_contains_token "$A_LINE" "未评估" "$spec 标成未评估（并写了原因）"
    assert_not_contains_token "$A_LINE" "PASS" "$spec 没有被悄悄算成 PASS"
done
assert_contains_token "$(ledger_field "$SUM_LEDGER" "$FIXTURE_RUN_ID" summary_done)" \
    "true" "台账里那条记录被翻成 summary_done=true"
assert_contains_token "$(ledger_field "$SUM_LEDGER" "$FIXTURE_RUN_ID" summary_path)" \
    "$FIXTURE_RUN_ID-summary.md" "台账里记下了总结路径"
# 幂等：再跑一次不该把台账写坏、也不该追加记录
timeout "$CASE_TIMEOUT" bash "$SUMMARIZER" --fixture "$REPO_ROOT/tests/fixtures" \
    --out "$SUM_OUT" --ledger "$SUM_LEDGER" >"$CASE_DIR/stdout2.log" 2>&1
LAST_EXIT=$?
assert_exit 0 "$LAST_EXIT" "重复生成同一份总结仍以 0 退出（幂等）"
IDEMPOTENT="$(python3 - "$SUM_LEDGER" <<'PYEOF'
import json
import sys

ledger = json.load(open(sys.argv[1], encoding="utf-8"))
print("%s %d" % (ledger.get("schema"), len(ledger.get("entries") or [])))
PYEOF
)"
assert_contains_token "$IDEMPOTENT" "tpot-bench-stage-ledger/2 1" \
    "台账仍是合法 JSON、schema 为 /2、条数没有被追加"
# 闸门此刻必须放行
BIN="$(make_case_bin)"
run_staged_gate "$BIN" "$SUM_LEDGER" "$CASE_DIR/after.log" no --stage full
assert_exit 2 "$LAST_EXIT" "总结落地后闸门放行，退回花费闸门的 2"
end_case

# =============================================================================
# 用例 21) accept_length < 2.0 的夹具必须判 A7 FAIL —— 这条守的是「推测解码
# 没生效也能混过验收」这个最容易被放过去的失败模式。
# =============================================================================
begin_case 21 "accept_length 低于 2.0 时 A7 判 FAIL"
LOW_OUT="$CASE_DIR/summaries"
timeout "$CASE_TIMEOUT" bash "$SUMMARIZER" \
    --fixture "$REPO_ROOT/tests/fixtures/variant-low-accept" \
    --out "$LOW_OUT" --ledger "$CASE_DIR/no-such-ledger.json" \
    >"$CASE_DIR/stdout.log" 2>&1
LAST_EXIT=$?
assert_exit 0 "$LAST_EXIT" "未达标的运行照样产出总结（未达标是结论，不是脚本失败）"
LOW_MD="$LOW_OUT/$LOWACCEPT_RUN_ID-summary.md"
assert_file_exists "$LOW_MD" "生成了低 accept 变体的总结"
A7_LINE="$(grep -F "**A7**" "$LOW_MD" | head -n1)"
assert_contains_token "$A7_LINE" "1.12" "A7 行里是实测的 accept_length 1.12"
assert_contains_token "$A7_LINE" "FAIL" "A7 判 FAIL"
assert_not_contains_token "$A7_LINE" "PASS" "A7 绝不是 PASS"
A1_LINE="$(grep -F "**A1**" "$LOW_MD" | head -n1)"
assert_contains_token "$A1_LINE" "FAIL" "TPOT 5.60 ms 同时让 A1 判 FAIL"
assert_file_contains "$LOW_MD" "没有复现博客数字" "吞吐远低于基线时明确说没复现"
assert_file_contains "$LOW_MD" "台账" "总结里说明了 recipe 等信息的来源"
end_case

# =============================================================================
# 用例 22) 测量值缺失时必须报错退出，绝不产出一份填着占位符的总结。
# 一份写着「N/A」的总结会被当成「已经总结过了」，闸门就此放行 —— 那比没有总结更糟。
# =============================================================================
begin_case 22 "缺少必需测量值时 summarize-run 报错退出且不产出总结"
BROKEN_RUN="$CASE_DIR/fixture/run-$FIXTURE_RUN_ID"
mkdir -p "$BROKEN_RUN/results" "$BROKEN_RUN/logs"
# 只留运行元数据与 status.json，两份 bench 输出故意缺席
# （模拟服务起来了但 bench 没写出结果就收尾的情形）
cp "$REPO_ROOT/tests/fixtures/run-$FIXTURE_RUN_ID/results/run_$FIXTURE_RUN_ID.json" \
    "$BROKEN_RUN/results/"
cp "$REPO_ROOT/tests/fixtures/run-$FIXTURE_RUN_ID/logs/status.json" "$BROKEN_RUN/logs/"
BROKEN_OUT="$CASE_DIR/summaries"
BROKEN_LEDGER="$CASE_DIR/stage-ledger.json"
seed_ledger "$BROKEN_LEDGER" false
timeout "$CASE_TIMEOUT" bash "$SUMMARIZER" --fixture "$CASE_DIR/fixture" \
    --out "$BROKEN_OUT" --ledger "$BROKEN_LEDGER" >"$CASE_DIR/stdout.log" 2>&1
LAST_EXIT=$?
assert_exit 1 "$LAST_EXIT" "缺少必需测量值时以 1 退出"
assert_file_contains "$CASE_DIR/stdout.log" "拒绝生成一份填着占位符的总结" "说明了为什么不生成"
assert_file_contains "$CASE_DIR/stdout.log" "custom.tpot_p50_ms" "点名了缺哪个值"
if [[ -z "$(find "$BROKEN_OUT" -name '*.md' 2>/dev/null)" ]]; then
    pass_assert "一个 markdown 文件都没有产出"
else
    fail_assert "不应产出任何总结文件" "$(find "$BROKEN_OUT" -name '*.md')"
fi
assert_contains_token "$(ledger_field "$BROKEN_LEDGER" "$FIXTURE_RUN_ID" summary_done)" \
    "false" "台账没有被翻成 summary_done=true（闸门必须继续拦着）"
end_case

# =============================================================================
# scripts/b300-run-config.sh 的用例
# 这个脚本所有动作都发生在一台只能用 SSM 摸到的 B300 上，所以它的 --dry-run 走的是
# 「不发 SSM，把那段机上 shell 文本直接在 stub PATH 上跑一遍」。于是下面断言的是
# 脚本**真的算出来的** docker run / docker exec / aws s3 cp 命令行，而不是静态字符串。
# =============================================================================
B300_RUNNER="$REPO_ROOT/scripts/b300-run-config.sh"
log "被测: $B300_RUNNER"

run_b300() {
    # run_b300 <bin> [额外 env...] -- <脚本参数...>
    local bin="$1"; shift
    local envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    [[ "${1:-}" == "--" ]] && shift
    timeout "$CASE_TIMEOUT" env \
        PATH="$bin:$PATH" \
        STUB_LOG="$STUB_LOG" \
        DRY_RUN=1 \
        DRY_RUN_LOG="$STUB_LOG" \
        BENCH_ROOT="$CASE_DIR/bench" \
        JIT_CACHE_DIR="$CASE_DIR/jitcache" \
        OUT_DIR="$CASE_DIR/out" \
        POLL_INTERVAL_SEC=1 \
        B300_INSTANCE_ID=i-0stub00000000000 \
        REGION=us-west-2 \
        "${envs[@]}" \
        bash "$B300_RUNNER" "$@" >"$CASE_DIR/stdout.log" 2>&1
    LAST_EXIT=$?
    if [[ "$LAST_EXIT" == "124" ]]; then
        echo "   [注意] 用例被 timeout ${CASE_TIMEOUT}s 强杀"
    fi
}

# =============================================================================
# 用例 23) c1 配置必须逐字算出那条 docker run，并且把两条 bench 的结果归一化进
# matrix-status.json。配置名写错一个字母就等于起了另一台价值 $50/hr 的实验，
# 所以这条断言的是参数本身。
# =============================================================================
begin_case 23 "b300-run-config c1 算出正确的 docker run 并写出 matrix-status"
BIN="$(make_case_bin)"
run_b300 "$BIN" -- --config c1-tp8-eagle-megamoe --dry-run --timeout-sec 5
assert_exit 0 "$LAST_EXIT" "c1 全流程跑通"
DOCKER_RUN_LINE="$(grep_line "$STUB_LOG" "docker run -d --name sglang-server")"
assert_contains_token "$DOCKER_RUN_LINE" "--tp 8" "docker run 里是整机 tp=8"
assert_contains_token "$DOCKER_RUN_LINE" "--moe-a2a-backend megamoe" \
    "MoE 走 megamoe（B300 上唯一验证过的路径，不是 H200 的 marlin）"
assert_contains_token "$DOCKER_RUN_LINE" "--speculative-algorithm EAGLE" "EAGLE 开着"
assert_contains_token "$DOCKER_RUN_LINE" "--speculative-num-steps 3" "EAGLE steps=3"
assert_contains_token "$DOCKER_RUN_LINE" "--speculative-eagle-topk 1" "EAGLE topk=1"
assert_contains_token "$DOCKER_RUN_LINE" "--speculative-num-draft-tokens 4" "EAGLE draft tokens=4"
assert_contains_token "$DOCKER_RUN_LINE" "SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320" \
    "megamoe 的 per-rank token 上限环境变量被带上"
assert_contains_token "$DOCKER_RUN_LINE" "$CASE_DIR/jitcache:/root/.cache" \
    "JIT 缓存目录被 bind mount 进容器（省掉 10-20 分钟 DeepGEMM 预编译）"
assert_contains_token "$DOCKER_RUN_LINE" "lmsysorg/sglang:v0.5.12.post1-cu130" \
    "镜像 tag 由配置决定（换镜像是绕长上下文内核崩溃的候选手段之一）"
assert_file_contains "$STUB_LOG" "--random-input 40000 --random-output 1500" \
    "自定义负载那条 bench 参数与 README 6.1 一致"
assert_file_contains "$STUB_LOG" "--random-input 30000 --random-output 4096" \
    "官方对标那条 bench 参数与 README 6.1 一致"
assert_file_contains "$STUB_LOG" "--num-prompts 50 --max-concurrency 1" "50 条请求、并发 1"
assert_file_exists "$CASE_DIR/out/matrix-status.json" "matrix-status.json 落盘"
assert_file_contains "$CASE_DIR/out/matrix-status.json" '"status": "completed"' "c1 记成 completed"
assert_file_contains "$CASE_DIR/out/matrix-status.json" '"median_tpot_ms": 3.76' \
    "归一化后的 P50 TPOT 进了状态文件（bench_serving 的键名是 median_*，不是 tpot_p50_*）"
assert_file_contains "$CASE_DIR/out/matrix-status.json" '"p6-b300.48xlarge"' "机型记在状态文件里"
end_case

# =============================================================================
# 用例 24) --skip-launch 的全部意义就是「别动那个已经在跑的服务」。
# 一次多余的 docker rm 等于把 9.5 分钟冷启动和 1.6 GB JIT 缓存一起扔掉。
# =============================================================================
begin_case 24 "--skip-launch 绝不 docker rm / docker run，只跑 bench"
BIN="$(make_case_bin)"
run_b300 "$BIN" -- --config c1-tp8-eagle-megamoe --skip-launch --dry-run --timeout-sec 5
assert_exit 0 "$LAST_EXIT" "--skip-launch 也能跑完 bench"
assert_count "$STUB_LOG" "docker rm" 0 "一次 docker rm 都没有"
assert_count "$STUB_LOG" "docker run" 0 "一次 docker run 都没有"
assert_file_contains "$STUB_LOG" "bench_serving" "还是跑了 bench"
assert_file_contains "$CASE_DIR/stdout.log" "不 docker rm、不 docker run" "日志里说清楚了它跳过了启动"
end_case

# =============================================================================
# 用例 25) 配置名打错必须在**任何** SSM 调用之前就挡住：那台机器 $50/hr，
# 误起一个容器就是十几分钟白烧。
# =============================================================================
begin_case 25 "未知配置名以用法错误退出，且没有发起任何 SSM 调用"
BIN="$(make_case_bin)"
run_b300 "$BIN" -- --config c9-does-not-exist --dry-run
assert_exit 2 "$LAST_EXIT" "未知配置名以退出码 2（用法错误）退出"
assert_count "$STUB_LOG" "ssm send-command" 0 "没有发起任何 SSM 调用"
assert_count "$STUB_LOG" "docker run" 0 "没有起任何容器"
assert_file_contains "$CASE_DIR/stdout.log" "未知配置名" "报错说清楚是配置名的问题"
assert_file_contains "$CASE_DIR/stdout.log" "c1-tp8-eagle-megamoe" "顺手列出了已登记的配置"
end_case

# =============================================================================
# 用例 26) 服务起不来时：必须在超时后以专用退出码退出，并且**无论如何**把
# server.log 传上 S3 —— 机器一被回收，那份日志就是唯一的证据。
# =============================================================================
begin_case 26 "health 一直不是 200 时超时退出，且仍然把 server.log 传上 S3"
BIN="$(make_case_bin)"
run_b300 "$BIN" STUB_HEALTH_OK=0 -- --config c1-tp8-eagle-megamoe --dry-run --timeout-sec 2
assert_exit 3 "$LAST_EXIT" "等就绪超时以退出码 3 退出"
assert_file_contains "$STUB_LOG" "aws s3 cp" "失败路径上仍然发生了 s3 cp"
assert_min_count "$STUB_LOG" "server.log" 1 "上传的对象里包含 server.log"
assert_file_contains "$CASE_DIR/out/matrix-status.json" '"status": "failed"' "状态文件记成 failed"
assert_file_contains "$CASE_DIR/out/matrix-status.json" "等就绪超时" "failure_reason 写明了超时"
assert_count "$STUB_LOG" "bench_serving" 0 "没就绪就绝不开始跑 bench"
end_case

# =============================================================================
# 用例 27) Spot 中断通知：这是一次性 Spot（interruption behavior = terminate），
# 收到通知只剩两分钟。必须先同步产物再退出，而且退出码要和「配置跑挂了」区分开，
# 否则调用方会把「被 AWS 抢走」误判成「这个配置不行」。
# =============================================================================
begin_case 27 "收到 Spot 中断通知时先同步产物再以专用退出码 9 退出"
BIN="$(make_case_bin)"
run_b300 "$BIN" STUB_SPOT_ACTION='{"action":"terminate","time":"2026-08-09T15:30:00Z"}' \
    -- --config c1-tp8-eagle-megamoe --dry-run --timeout-sec 5
assert_exit 9 "$LAST_EXIT" "Spot 中断走专用退出码 9，不和配置失败混在一起"
assert_file_contains "$STUB_LOG" "meta-data/spot/instance-action" "轮询里真的查了 IMDS 的中断通知"
assert_file_contains "$STUB_LOG" "aws s3 cp" "退出之前把产物同步走了"
assert_file_contains "$CASE_DIR/out/matrix-status.json" "spot interruption" \
    "状态文件写明是被抢占，不是配置的问题"
assert_count "$STUB_LOG" "bench_serving" 0 "收到通知后不再开新的 bench"
end_case

# =============================================================================
# 用例 28) 并发扫描：SWEEP_SPEC 逐档执行、文件命名正确、每档单独落 S3
# 守的契约：
#   1) 6 个默认档位落 bench_c<N>.json（与 B300 报告同名，否则没法对照）
#   2) 覆盖了 prompts 的档位落 bench_c<N>_p<P>.json，不会覆盖掉同并发的默认档
#   3) 8000/1500 的负载参数逐字正确
#   4) 扫描发生在两条基线 bench 之后、同一个 server 进程上（不重启容器）
#   5) 每一档跑完立刻 sync，不攒批（spot 被回收时已完成的档位不能丢）
# =============================================================================
begin_case 28 "并发扫描逐档执行、命名正确、同进程、逐档落 S3"
BIN="$(make_case_bin)"
run_bootstrap "$BIN" \
    STUB_LSBLK="$DISKS_4" \
    STUB_DF_AVAIL_KB=30000000000 \
    STUB_GPU_COUNT=8 STUB_HEALTH_OK=1 \
    CHECKPOINT_GB=160 STORAGE_MARGIN_GB=80 \
    CHECKPOINT_S3_URI="$TEST_CKPT_URI" \
    FETCH_CHECKPOINT=true RUN_SERVER=true \
    TP_SIZE=4 \
    SWEEP_SPEC='1 2 4 8 16 32 16:128 32:128' \
    SWEEP_INPUT_TOKENS=8000 SWEEP_OUTPUT_TOKENS=1500 SWEEP_NUM_PROMPTS=32 \
    MAX_RUNTIME_MINUTES=5 STREAM_INTERVAL_SECONDS=60 GPU_SAMPLE_INTERVAL_SECONDS=60
assert_exit 0 "$LAST_EXIT" "带并发扫描的完整流程正常结束"
assert_phase completed
for c in 1 2 4 8 16 32; do
    assert_file_contains "$STUB_LOG" \
        "bench_serving --backend sglang --dataset-name random --random-input 8000 --random-output 1500 --num-prompts 32 --max-concurrency $c" \
        "扫描档位 c=$c 的负载参数与 B300 逐字一致"
    assert_file_exists "$NVME_MOUNT/results/bench_c$c.json" "档位 c=$c 落到 bench_c$c.json"
done
assert_file_contains "$STUB_LOG" \
    "--random-input 8000 --random-output 1500 --num-prompts 128 --max-concurrency 16" \
    "加样本档 c=16 用 128 条 prompts"
assert_file_contains "$STUB_LOG" \
    "--random-input 8000 --random-output 1500 --num-prompts 128 --max-concurrency 32" \
    "加样本档 c=32 用 128 条 prompts"
assert_file_exists "$NVME_MOUNT/results/bench_c16_p128.json" "加样本档另存 bench_c16_p128.json，不覆盖默认档"
assert_file_exists "$NVME_MOUNT/results/bench_c32_p128.json" "加样本档另存 bench_c32_p128.json，不覆盖默认档"
# 扫描必须在两条基线 bench 之后，且全程只起过一次容器
assert_count "$STUB_LOG" "docker run -d --name sglang-server" 1 \
    "扫描与基线 bench 共用同一个 server 进程，只 docker run 一次"
assert_file_contains "$NVME_MOUNT/results/run_$RUN_ID.json" '"enabled": true' "元数据里标记扫描已启用"
assert_file_contains "$NVME_MOUNT/results/run_$RUN_ID.json" '"max_concurrency": 32, "num_prompts": 128' \
    "元数据逐档记账，含加样本档"
# 8 档扫描 -> 至少 8 次结果同步（再加基线阶段的若干次）
assert_min_count "$STUB_LOG" "s3 sync $NVME_MOUNT/results/" 8 \
    "每档跑完立刻单独同步结果，不攒到最后"
end_case

# =============================================================================
# 用例 29) SWEEP_SPEC 为空时行为与改动前完全一致（不跑任何扫描）
# 这是「新功能默认不改变既有行为」的回归护栏
# =============================================================================
begin_case 29 "SWEEP_SPEC 留空则完全不跑扫描"
BIN="$(make_case_bin)"
run_bootstrap "$BIN" \
    STUB_LSBLK="$DISKS_4" \
    STUB_DF_AVAIL_KB=30000000000 \
    STUB_GPU_COUNT=8 STUB_HEALTH_OK=1 \
    CHECKPOINT_GB=160 STORAGE_MARGIN_GB=80 \
    CHECKPOINT_S3_URI="$TEST_CKPT_URI" \
    FETCH_CHECKPOINT=true RUN_SERVER=true TP_SIZE=4 \
    MAX_RUNTIME_MINUTES=5 STREAM_INTERVAL_SECONDS=60 GPU_SAMPLE_INTERVAL_SECONDS=60
assert_exit 0 "$LAST_EXIT" "不带扫描时流程照旧结束"
assert_count "$STUB_LOG" "bench_serving" 2 "只跑 README 6.1 的两条 bench，一条不多"
assert_file_not_contains "$STUB_LOG" "--random-input 8000" "没有发起任何 8K 扫描负载"
assert_file_contains "$NVME_MOUNT/results/run_$RUN_ID.json" '"enabled": false' "元数据里标记扫描未启用"
assert_file_contains "$NVME_MOUNT/results/run_$RUN_ID.json" '"levels": []' "档位列表为空数组，不是 null"
end_case

# =============================================================================
# 用例 30) 非法 SWEEP_SPEC token 被跳过，合法档位照跑
# 一个手滑的 token 不该让整轮 GPU 时间报废
# =============================================================================
begin_case 30 "非法 SWEEP_SPEC token 只跳过自己，不影响其他档位"
BIN="$(make_case_bin)"
run_bootstrap "$BIN" \
    STUB_LSBLK="$DISKS_4" \
    STUB_DF_AVAIL_KB=30000000000 \
    STUB_GPU_COUNT=8 STUB_HEALTH_OK=1 \
    CHECKPOINT_GB=160 STORAGE_MARGIN_GB=80 \
    CHECKPOINT_S3_URI="$TEST_CKPT_URI" \
    FETCH_CHECKPOINT=true RUN_SERVER=true TP_SIZE=4 \
    SWEEP_SPEC='1 abc 0 4:xyz 8' SWEEP_NUM_PROMPTS=32 \
    MAX_RUNTIME_MINUTES=5 STREAM_INTERVAL_SECONDS=60 GPU_SAMPLE_INTERVAL_SECONDS=60
assert_exit 0 "$LAST_EXIT" "含非法 token 也能正常收尾"
assert_file_exists "$NVME_MOUNT/results/bench_c1.json" "合法档位 c=1 照跑"
assert_file_exists "$NVME_MOUNT/results/bench_c8.json" "合法档位 c=8 照跑"
assert_file_contains "$LOG_DIR/bootstrap.log" "SWEEP_SPEC token 非法" "非法 token 有明确告警"
assert_count "$STUB_LOG" "--random-input 8000" 2 "只跑了 2 个合法档位，非法的没发起请求"
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
