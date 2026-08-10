#!/usr/bin/env bash
# =============================================================================
# Deploy the tpot-bench-capacity-poller Lambda + EventBridge schedule + SNS
#
# Creates:
#   1. SNS topic: tpot-bench-capacity-alerts
#   2. IAM role: tpot-bench-poller-lambda-role (with inline policy)
#   3. Lambda function: tpot-bench-capacity-poller (Python 3.12, 256MB, 60s)
#   4. EventBridge rule: tpot-bench-poll-capacity (rate 3 minutes)
#   5. Lambda permission for EventBridge invocation
#   6. EventBridge target -> Lambda
#
# Idempotent: re-running updates the Lambda code and configuration.
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-077090643075}"

FUNCTION_NAME="tpot-bench-capacity-poller"
ROLE_NAME="tpot-bench-poller-lambda-role"
POLICY_NAME="tpot-bench-poller-policy"
TOPIC_NAME="tpot-bench-capacity-alerts"
RULE_NAME="tpot-bench-poll-capacity"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LAMBDA_SRC="$SCRIPT_DIR/lambda/capacity_poller"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# =============================================================================
# Step 1: SNS Topic
# =============================================================================
log "Step 1: Creating SNS topic '$TOPIC_NAME'..."
SNS_TOPIC_ARN=$(aws sns create-topic \
    --region "$REGION" \
    --name "$TOPIC_NAME" \
    --query 'TopicArn' --output text)
log "  SNS Topic ARN: $SNS_TOPIC_ARN"

# =============================================================================
# Step 2: IAM Role
# =============================================================================
log "Step 2: Creating IAM role '$ROLE_NAME'..."

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}'

ROLE_ARN=""
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
        --query 'Role.Arn' --output text)
    log "  Role already exists: $ROLE_ARN"
    # Update trust policy in case it changed
    aws iam update-assume-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-document "$TRUST_POLICY"
else
    ROLE_ARN=$(aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --query 'Role.Arn' --output text)
    log "  Created role: $ROLE_ARN"
    # Wait for role to propagate
    log "  Waiting 10s for IAM role propagation..."
    sleep 10
fi

# Inline policy with all required permissions
POLICY_DOC='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Permissions",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeInstances",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSMParameter",
      "Effect": "Allow",
      "Action": "ssm:GetParameter",
      "Resource": "arn:aws:ssm:*:*:parameter/aws/service/deeplearning/*"
    },
    {
      "Sid": "S3Upload",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::tpot-bench-results-*/*"
    },
    {
      "Sid": "SNSPublish",
      "Effect": "Allow",
      "Action": "sns:Publish",
      "Resource": "arn:aws:sns:*:'"$ACCOUNT_ID"':'"$TOPIC_NAME"'"
    },
    {
      "Sid": "EventBridge",
      "Effect": "Allow",
      "Action": [
        "events:DisableRule",
        "events:DescribeRule"
      ],
      "Resource": "arn:aws:events:*:'"$ACCOUNT_ID"':rule/'"$RULE_NAME"'"
    },
    {
      "Sid": "IAMPassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::'"$ACCOUNT_ID"':role/tpot-bench-ec2-role"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:'"$ACCOUNT_ID"':*"
    }
  ]
}'

aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$POLICY_NAME" \
    --policy-document "$POLICY_DOC"
log "  Attached inline policy: $POLICY_NAME"

# =============================================================================
# Step 3: Package Lambda zip
# =============================================================================
log "Step 3: Packaging Lambda zip..."

ZIP_FILE="$WORK_DIR/capacity-poller.zip"

# Copy handler
cp "$LAMBDA_SRC/handler.py" "$WORK_DIR/handler.py"

# Copy co-packaged files into the zip structure
mkdir -p "$WORK_DIR/recipes"
cp "$REPO_ROOT/scripts/bootstrap/bench-bootstrap.sh" "$WORK_DIR/bench-bootstrap.sh"
cp "$REPO_ROOT/scripts/recipes/h200-tp4-fp4-eagle.env" "$WORK_DIR/recipes/h200-tp4-fp4-eagle.env"
cp "$REPO_ROOT/scripts/recipes/b300-tp2-dp2-fp4-megamoe.env" "$WORK_DIR/recipes/b300-tp2-dp2-fp4-megamoe.env"

# Create zip
(cd "$WORK_DIR" && zip -r "$ZIP_FILE" \
    handler.py \
    bench-bootstrap.sh \
    recipes/h200-tp4-fp4-eagle.env \
    recipes/b300-tp2-dp2-fp4-megamoe.env)

ZIP_SIZE=$(wc -c < "$ZIP_FILE" | tr -d ' ')
log "  Lambda zip: $ZIP_FILE ($ZIP_SIZE bytes)"

# =============================================================================
# Step 4: Create or Update Lambda Function
# =============================================================================
log "Step 4: Creating/updating Lambda function '$FUNCTION_NAME'..."

if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
    # Update existing function
    aws lambda update-function-code \
        --region "$REGION" \
        --function-name "$FUNCTION_NAME" \
        --zip-file "fileb://$ZIP_FILE" \
        --query 'FunctionArn' --output text >/dev/null
    log "  Updated function code"

    # Wait for update to complete
    aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null || true

    aws lambda update-function-configuration \
        --region "$REGION" \
        --function-name "$FUNCTION_NAME" \
        --timeout 120 \
        --memory-size 256 \
        --environment "Variables={SNS_TOPIC_ARN=$SNS_TOPIC_ARN,EVENTBRIDGE_RULE_NAME=$RULE_NAME}" \
        --query 'FunctionArn' --output text >/dev/null
    log "  Updated function configuration"
    FUNCTION_ARN=$(aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" \
        --query 'Configuration.FunctionArn' --output text)
else
    # Create new function
    FUNCTION_ARN=$(aws lambda create-function \
        --region "$REGION" \
        --function-name "$FUNCTION_NAME" \
        --runtime "python3.12" \
        --role "$ROLE_ARN" \
        --handler "handler.lambda_handler" \
        --timeout 120 \
        --memory-size 256 \
        --zip-file "fileb://$ZIP_FILE" \
        --environment "Variables={SNS_TOPIC_ARN=$SNS_TOPIC_ARN,EVENTBRIDGE_RULE_NAME=$RULE_NAME}" \
        --query 'FunctionArn' --output text)
    log "  Created function: $FUNCTION_ARN"

    # Wait for function to be active
    aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME" --region "$REGION" 2>/dev/null || true
fi

log "  Function ARN: $FUNCTION_ARN"

# =============================================================================
# Step 5: EventBridge Rule
# =============================================================================
log "Step 5: Creating EventBridge rule '$RULE_NAME'..."

RULE_ARN=$(aws events put-rule \
    --region "$REGION" \
    --name "$RULE_NAME" \
    --schedule-expression "rate(3 minutes)" \
    --state ENABLED \
    --description "Poll spot capacity for tpot-bench H200/B300 every 3 minutes" \
    --query 'RuleArn' --output text)
log "  Rule ARN: $RULE_ARN"

# =============================================================================
# Step 6: Lambda Permission for EventBridge
# =============================================================================
log "Step 6: Adding Lambda permission for EventBridge..."

# Remove existing permission (ignore error if not found)
aws lambda remove-permission \
    --region "$REGION" \
    --function-name "$FUNCTION_NAME" \
    --statement-id "eventbridge-invoke" 2>/dev/null || true

aws lambda add-permission \
    --region "$REGION" \
    --function-name "$FUNCTION_NAME" \
    --statement-id "eventbridge-invoke" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "$RULE_ARN" >/dev/null
log "  Permission granted"

# =============================================================================
# Step 7: EventBridge Target
# =============================================================================
log "Step 7: Adding EventBridge target..."

aws events put-targets \
    --region "$REGION" \
    --rule "$RULE_NAME" \
    --targets "Id=capacity-poller-target,Arn=$FUNCTION_ARN" >/dev/null
log "  Target added: $FUNCTION_ARN"

# =============================================================================
# Done
# =============================================================================
echo ""
echo "=============================================================================="
echo " Deployment Complete"
echo "=============================================================================="
echo " Lambda Function : $FUNCTION_NAME ($FUNCTION_ARN)"
echo " EventBridge Rule: $RULE_NAME (rate: 3 minutes, ENABLED)"
echo " SNS Topic       : $SNS_TOPIC_ARN"
echo " IAM Role        : $ROLE_NAME ($ROLE_ARN)"
echo ""
echo " Monitor logs:"
echo "   aws logs tail /aws/lambda/$FUNCTION_NAME --region $REGION --follow"
echo ""
echo " Test invocation:"
echo "   aws lambda invoke --function-name $FUNCTION_NAME --region $REGION /dev/stdout"
echo ""
echo " Teardown:"
echo "   bash infra/teardown-poller.sh"
echo "=============================================================================="
