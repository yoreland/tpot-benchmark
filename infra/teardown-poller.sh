#!/usr/bin/env bash
# =============================================================================
# Teardown the tpot-bench-capacity-poller infrastructure.
#
# Removes (idempotent - handles 'not found' gracefully):
#   1. EventBridge rule targets + rule
#   2. Lambda function
#   3. IAM role policy + role
#   4. SNS topic
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-077090643075}"

FUNCTION_NAME="tpot-bench-capacity-poller"
ROLE_NAME="tpot-bench-poller-lambda-role"
POLICY_NAME="tpot-bench-poller-policy"
TOPIC_NAME="tpot-bench-capacity-alerts"
RULE_NAME="tpot-bench-poll-capacity"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

safe_run() {
    # Execute a command, suppressing "not found" type errors
    "$@" 2>/dev/null || true
}

# =============================================================================
# Step 1: Remove EventBridge targets and rule
# =============================================================================
log "Step 1: Removing EventBridge rule '$RULE_NAME'..."

# Remove all targets from the rule
TARGETS=$(aws events list-targets-by-rule \
    --region "$REGION" \
    --rule "$RULE_NAME" \
    --query 'Targets[].Id' --output text 2>/dev/null || echo "")

if [[ -n "$TARGETS" && "$TARGETS" != "None" ]]; then
    # Convert space-separated IDs to JSON array
    IDS_JSON=$(echo "$TARGETS" | tr '\t' '\n' | while read -r id; do
        [[ -n "$id" ]] && echo "\"$id\""
    done | paste -sd, | sed 's/^/[/;s/$/]/')
    aws events remove-targets \
        --region "$REGION" \
        --rule "$RULE_NAME" \
        --ids "$IDS_JSON" 2>/dev/null || true
    log "  Removed targets: $TARGETS"
else
    log "  No targets found (already removed or rule does not exist)"
fi

# Delete the rule
safe_run aws events delete-rule \
    --region "$REGION" \
    --name "$RULE_NAME"
log "  Rule deleted (or did not exist)"

# =============================================================================
# Step 2: Remove Lambda function
# =============================================================================
log "Step 2: Removing Lambda function '$FUNCTION_NAME'..."
safe_run aws lambda delete-function \
    --region "$REGION" \
    --function-name "$FUNCTION_NAME"
log "  Function deleted (or did not exist)"

# =============================================================================
# Step 3: Remove IAM role and policy
# =============================================================================
log "Step 3: Removing IAM role '$ROLE_NAME'..."

# Delete inline policy
safe_run aws iam delete-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$POLICY_NAME"
log "  Inline policy '$POLICY_NAME' deleted (or did not exist)"

# Delete role
safe_run aws iam delete-role --role-name "$ROLE_NAME"
log "  Role deleted (or did not exist)"

# =============================================================================
# Step 4: Remove SNS topic
# =============================================================================
log "Step 4: Removing SNS topic '$TOPIC_NAME'..."

TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:${TOPIC_NAME}"
safe_run aws sns delete-topic --topic-arn "$TOPIC_ARN" --region "$REGION"
log "  Topic deleted (or did not exist)"

# =============================================================================
# Done
# =============================================================================
echo ""
echo "=============================================================================="
echo " Teardown Complete"
echo "=============================================================================="
echo " Removed: EventBridge rule, Lambda function, IAM role, SNS topic"
echo " All resources cleaned up (idempotent - safe to run multiple times)"
echo "=============================================================================="
