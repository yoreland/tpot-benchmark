#!/bin/bash
# =============================================================================
# Capacity Poller: H200 (p5en.48xlarge) + B300 (p6-b300.48xlarge)
# Scans spot capacity every 3 minutes across multiple regions/AZs.
# When capacity is found, launches the benchmark via launch-bench-ec2.sh.
#
# NO B200 -- SGLang has a triton MoE "Hidden size mismatch" bug on B200.
#
# Usage:
#   bash scripts/poll-b300-h200.sh                    # foreground
#   nohup bash scripts/poll-b300-h200.sh &            # background
#   (launched by automation with run_in_background)
# =============================================================================

# Deliberately omit set -u / set -o pipefail to avoid dying on unset vars or
# broken pipes (SIGPIPE). This script must survive long background runs.

REPO="/projects/sandbox/tpot-benchmark"
LOG="$REPO/results/capacity-poll.log"
LAUNCHER="$REPO/scripts/launch-bench-ec2.sh"
POLL_INTERVAL=180  # seconds between rounds

# Ensure results dir exists
mkdir -p "$REPO/results"

# --- Subnet mapping (verified) ---
declare -A SUBNET_MAP
SUBNET_MAP["us-east-1a"]="subnet-0ae36a5845b616649"
SUBNET_MAP["us-east-1c"]="subnet-0519fb0c779ad92c7"
SUBNET_MAP["us-east-2a"]="subnet-09bfc4e5573173d64"
SUBNET_MAP["us-east-2b"]="subnet-0c900c1611bf34e49"
SUBNET_MAP["us-east-2c"]="subnet-087bce7226890195e"
SUBNET_MAP["us-west-2a"]="subnet-0570e1b3d4cabf650"
SUBNET_MAP["us-west-2c"]="subnet-08a022641b49f4630"
SUBNET_MAP["us-west-2d"]="subnet-03f3fa89ad241fbbb"

# --- Target definitions ---
# Format: "instance_type region az max_price recipe_file"
declare -a TARGETS=(
    # H200 targets (p5en.48xlarge) - max $35
    "p5en.48xlarge us-east-1 us-east-1a 35 scripts/recipes/h200-tp4-fp4-eagle.env"
    "p5en.48xlarge us-east-1 us-east-1c 35 scripts/recipes/h200-tp4-fp4-eagle.env"
    "p5en.48xlarge us-east-2 us-east-2a 35 scripts/recipes/h200-tp4-fp4-eagle.env"
    "p5en.48xlarge us-east-2 us-east-2b 35 scripts/recipes/h200-tp4-fp4-eagle.env"
    "p5en.48xlarge us-east-2 us-east-2c 35 scripts/recipes/h200-tp4-fp4-eagle.env"
    "p5en.48xlarge us-west-2 us-west-2a 35 scripts/recipes/h200-tp4-fp4-eagle.env"
    "p5en.48xlarge us-west-2 us-west-2c 35 scripts/recipes/h200-tp4-fp4-eagle.env"
    "p5en.48xlarge us-west-2 us-west-2d 35 scripts/recipes/h200-tp4-fp4-eagle.env"
    # B300 targets (p6-b300.48xlarge) - max $60
    "p6-b300.48xlarge us-east-1 us-east-1a 60 scripts/recipes/b300-tp2-dp2-fp4-megamoe.env"
    "p6-b300.48xlarge us-east-1 us-east-1c 60 scripts/recipes/b300-tp2-dp2-fp4-megamoe.env"
    "p6-b300.48xlarge us-east-2 us-east-2a 60 scripts/recipes/b300-tp2-dp2-fp4-megamoe.env"
    "p6-b300.48xlarge us-east-2 us-east-2b 60 scripts/recipes/b300-tp2-dp2-fp4-megamoe.env"
    "p6-b300.48xlarge us-east-2 us-east-2c 60 scripts/recipes/b300-tp2-dp2-fp4-megamoe.env"
    "p6-b300.48xlarge us-west-2 us-west-2a 60 scripts/recipes/b300-tp2-dp2-fp4-megamoe.env"
    "p6-b300.48xlarge us-west-2 us-west-2c 60 scripts/recipes/b300-tp2-dp2-fp4-megamoe.env"
    "p6-b300.48xlarge us-west-2 us-west-2d 60 scripts/recipes/b300-tp2-dp2-fp4-megamoe.env"
)

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# Check if capacity exists by doing a dry-run spot request
# Returns 0 if capacity available, 1 otherwise
check_capacity() {
    local itype="$1" region="$2" az="$3" max_price="$4"

    # Get latest DL AMI for the region
    local ami
    ami=$(aws ssm get-parameter --region "$region" \
        --name "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id" \
        --query 'Parameter.Value' --output text 2>/dev/null)
    if [[ -z "$ami" || "$ami" == "None" ]]; then
        return 1
    fi

    local subnet="${SUBNET_MAP[$az]}"
    if [[ -z "$subnet" ]]; then
        log "WARN: no subnet for $az, skipping"
        return 1
    fi

    # Probe: request a spot instance to test capacity
    local sg
    sg=$(aws ec2 describe-security-groups --region "$region" \
        --filters "Name=group-name,Values=tpot-bench-noingress-sg" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
    if [[ -z "$sg" || "$sg" == "None" ]]; then
        sg=$(aws ec2 describe-security-groups --region "$region" \
            --filters "Name=group-name,Values=default" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
    fi
    if [[ -z "$sg" || "$sg" == "None" ]]; then
        log "WARN: no security group for $region, skipping"
        return 1
    fi

    local result
    result=$(aws ec2 run-instances --region "$region" \
        --image-id "$ami" --instance-type "$itype" --count 1 \
        --subnet-id "$subnet" \
        --security-group-ids "$sg" \
        --iam-instance-profile Name=tpot-bench-ec2-profile \
        --instance-market-options "MarketType=spot,SpotOptions={MaxPrice=${max_price},SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}" \
        --instance-initiated-shutdown-behavior terminate \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=capacity-probe-poll},{Key=Project,Value=tpot-benchmark}]" 2>&1)

    if echo "$result" | grep -q "InstanceId"; then
        local iid
        iid=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['Instances'][0]['InstanceId'])" 2>/dev/null)
        log "PROBE SUCCESS: $itype @ $az ($region) -> $iid"
        # Immediately terminate the probe instance
        aws ec2 terminate-instances --region "$region" --instance-ids "$iid" >> /dev/null 2>&1
        return 0
    else
        # Extract error for logging (only on verbose rounds)
        return 1
    fi
}

launch_benchmark() {
    local itype="$1" region="$2" az="$3" max_price="$4" recipe="$5"
    local subnet="${SUBNET_MAP[$az]}"
    local bucket="tpot-bench-results-077090643075-${region}"

    log "LAUNCHING: $itype @ $az ($region) recipe=$recipe"
    log "CMD: CONFIRM_SPEND=yes SUBNET_ID=$subnet bash $LAUNCHER --stage full --region $region --az $az --instance-type $itype --max-price $max_price --recipe $REPO/$recipe --bucket $bucket"

    local launch_output
    launch_output=$(cd "$REPO" && CONFIRM_SPEND=yes SUBNET_ID="$subnet" bash "$LAUNCHER" \
        --stage full \
        --region "$region" \
        --az "$az" \
        --instance-type "$itype" \
        --max-price "$max_price" \
        --recipe "$REPO/$recipe" \
        --bucket "$bucket" 2>&1)

    local exit_code=$?
    # Log key lines from output
    echo "$launch_output" | grep -E "RUN_ID|instance|Instance|错误|Error|InsufficientInstance|launched|启动" | head -10 | while IFS= read -r line; do
        log "  LAUNCH> $line"
    done

    if [[ $exit_code -eq 0 ]] && echo "$launch_output" | grep -qiE "instance.*running|实例已启动|launched|InstanceId"; then
        log "BENCHMARK LAUNCHED SUCCESSFULLY for $itype @ $az ($region)"
        return 0
    else
        log "Launch attempt failed (exit=$exit_code), capacity may have been grabbed. Continuing poll..."
        return 1
    fi
}

# =============================================================================
# Main loop
# =============================================================================

# Track which instance types have been successfully launched (avoid double-launch)
declare -A LAUNCHED_TYPES

log "========================================================"
log "=== H200/B300 Capacity Poller STARTED ==="
log "========================================================"
log "Targets: p5en.48xlarge (H200, max \$35) + p6-b300.48xlarge (B300, max \$60)"
log "Regions: us-east-1 (1a,1c), us-east-2 (2a,2b,2c), us-west-2 (2a,2c,2d)"
log "Interval: ${POLL_INTERVAL}s"
log "NO B200 (triton MoE bug)"
log "Recipes: h200-tp4-fp4-eagle.env / b300-tp2-dp2-fp4-megamoe.env"
log "========================================================"

round=0
while true; do
    round=$((round + 1))
    log "--- Round $round ($(date -u '+%H:%M:%S')) ---"

    for target in "${TARGETS[@]}"; do
        read -r itype region az max_price recipe <<< "$target"

        # Skip instance types that have already been successfully launched
        if [[ -n "${LAUNCHED_TYPES[$itype]:-}" ]]; then
            continue
        fi

        if check_capacity "$itype" "$region" "$az" "$max_price"; then
            log "CAPACITY FOUND: $itype @ $az ($region)!"
            if launch_benchmark "$itype" "$region" "$az" "$max_price" "$recipe"; then
                log "SUCCESS: benchmark running for $itype. Will not re-launch this type."
                LAUNCHED_TYPES["$itype"]="$az"
                # If both types have been launched, we're done
                if [[ -n "${LAUNCHED_TYPES["p5en.48xlarge"]:-}" ]] && [[ -n "${LAUNCHED_TYPES["p6-b300.48xlarge"]:-}" ]]; then
                    log "Both H200 and B300 benchmarks launched. Poller complete!"
                    exit 0
                fi
                break  # Skip remaining targets of this type in this round
            fi
        fi
    done

    # Check if all types launched
    if [[ -n "${LAUNCHED_TYPES["p5en.48xlarge"]:-}" ]] && [[ -n "${LAUNCHED_TYPES["p6-b300.48xlarge"]:-}" ]]; then
        log "Both H200 and B300 benchmarks launched. Poller complete!"
        exit 0
    fi

    log "Round $round complete. Sleeping ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
done
