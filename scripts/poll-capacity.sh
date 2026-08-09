#!/bin/bash
set -o pipefail

LOG=/projects/sandbox/tpot-benchmark/results/capacity-poll.log
REPO=/projects/sandbox/tpot-benchmark

# 按优先级排列：p5en (最便宜，有验证基线) > p6-b200 (性价比) > p6-b300
# 扩展到全球有 spot 价格的 region
# 格式: "instance_type max_price region az subnet_or_auto"
# subnet_or_auto=auto 表示运行时从默认 VPC 解析
declare -a TARGETS=(
    "p5en.48xlarge 35.00 us-east-2 us-east-2a subnet-09bfc4e5573173d64"
    "p5en.48xlarge 35.00 us-east-1 us-east-1a subnet-0ae36a5845b616649"
    "p5en.48xlarge 35.00 us-east-1 us-east-1c subnet-0519fb0c779ad92c7"
    "p5en.48xlarge 35.00 us-west-2 us-west-2c subnet-08a022641b49f4630"
    "p5en.48xlarge 15.00 ap-northeast-2 ap-northeast-2a auto"
    "p5en.48xlarge 30.00 ap-south-1 ap-south-1b auto"
    "p5en.48xlarge 50.00 ap-northeast-1 ap-northeast-1a auto"
    "p6-b200.48xlarge 55.00 us-east-1 us-east-1a subnet-0ae36a5845b616649"
    "p6-b200.48xlarge 55.00 us-east-2 us-east-2a subnet-09bfc4e5573173d64"
    "p6-b200.48xlarge 55.00 us-west-2 us-west-2d subnet-03f3fa89ad241fbbb"
    "p6-b200.48xlarge 60.00 ap-south-1 ap-south-1c auto"
    "p6-b300.48xlarge 60.00 us-east-1 us-east-1a subnet-0ae36a5845b616649"
    "p6-b300.48xlarge 60.00 us-west-2 us-west-2a subnet-0570e1b3d4cabf650"
)

log() { echo "[$(date -u +%Y-%m-%d\ %H:%M:%S)] $*" >> "$LOG"; }

log "=== 容量轮询启动 ==="
log "扫描目标: p5en.48xlarge / p6-b200.48xlarge / p6-b300.48xlarge"
log "Region: us-east-1, us-east-2, us-west-2"
log "间隔: 180s"

attempt=0
while true; do
    attempt=$((attempt + 1))
    log "--- 第 $attempt 轮 ($(date -u +%H:%M)) ---"

    for target in "${TARGETS[@]}"; do
        read -r itype maxprice region az subnet <<< "$target"

        # 自动解析子网（非 US region 没有预配置）
        if [[ "$subnet" == "auto" ]]; then
            subnet=$(aws ec2 describe-subnets --region "$region" \
                --filters "Name=availability-zone,Values=$az" "Name=default-for-az,Values=true" \
                --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
            [[ -z "$subnet" || "$subnet" == "None" ]] && continue
        fi

        ami=$(aws ssm get-parameter --region "$region" \
            --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id \
            --query 'Parameter.Value' --output text 2>/dev/null)
        [[ -z "$ami" || "$ami" == "None" ]] && continue

        # 找到该 region 的安全组（优先用我们的 noingress SG，否则用默认 VPC 的 default SG）
        sg=$(aws ec2 describe-security-groups --region "$region" \
            --filters "Name=group-name,Values=tpot-bench-noingress-sg" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
        if [[ -z "$sg" || "$sg" == "None" ]]; then
            sg=$(aws ec2 describe-security-groups --region "$region" \
                --filters "Name=group-name,Values=default" \
                --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
        fi
        [[ -z "$sg" || "$sg" == "None" ]] && continue

        result=$(aws ec2 run-instances --region "$region" \
            --image-id "$ami" --instance-type "$itype" --count 1 \
            --subnet-id "$subnet" \
            --security-group-ids "$sg" \
            --iam-instance-profile Name=tpot-bench-ec2-profile \
            --instance-market-options "MarketType=spot,SpotOptions={MaxPrice=${maxprice},SpotInstanceType=one-time,InstanceInterruptionBehavior=terminate}" \
            --instance-initiated-shutdown-behavior terminate \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=capacity-probe},{Key=Project,Value=tpot-benchmark}]" 2>&1)

        if echo "$result" | grep -q "InstanceId"; then
            iid=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['Instances'][0]['InstanceId'])")
            log "✅✅✅ 拿到了！$itype @ $az ($region) -> $iid"
            log "立即终止探测实例，用正式流程启动..."
            aws ec2 terminate-instances --region "$region" --instance-ids "$iid" >/dev/null 2>&1

            # 用正式流程启动 benchmark
            log "执行: CONFIRM_SPEND=yes bash $REPO/scripts/run-staged.sh --stage full --region $region --az $az"
            cd "$REPO"
            launch_result=$(CONFIRM_SPEND=yes SUBNET_ID="$subnet" bash scripts/run-staged.sh --stage full --region "$region" --az "$az" 2>&1)
            echo "$launch_result" | grep -E "RUN_ID|实例已启动|错误|InsufficientInstance" | head -5 | while read -r line; do log "$line"; done

            if echo "$launch_result" | grep -q "实例已启动"; then
                log "🎉 BENCHMARK 已启动！轮询结束。"
                echo "$launch_result" >> "$LOG"
                exit 0
            else
                log "探测拿到了但正式启动失败（容量又被抢走），继续轮询..."
            fi
        fi
    done

    log "本轮无容量，等 180s..."
    sleep 180
done
