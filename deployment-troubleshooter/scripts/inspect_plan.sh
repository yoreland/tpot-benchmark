#!/usr/bin/env bash
# inspect_plan.sh - READ-ONLY. Compare plan.modelName vs compose --model-path.
#
# Usage:
#   ./inspect_plan.sh <planId>                # read plan + compose from S3
#   ./inspect_plan.sh <planId> <instanceId>   # read compose from the live instance
#
# Diagnoses failure pattern (a) "model mismatch": the plan's modelName does not
# match the directory the compose file's --model-path points at, so SGLang can't
# find the model dir and the container exits (1).
#
# Reads:
#   - DynamoDB TpotDeploymentPlanTable record (get-item, read-only)
#   - the compose file, either from the S3 COMPOSE_BUCKET (s3 cp, read-only) or,
#     if an instanceId is given, from the live instance via a read-only SSM
#     command (cat of the on-instance compose file).
#
# Issues NO write/mutating operations.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

tpot_require_aws_creds
command -v jq >/dev/null 2>&1 || tpot_die "jq is required for inspect_plan.sh."

PLAN_ID="${1:-}"
INSTANCE_ID="${2:-}"
[[ -n "${PLAN_ID}" ]] || tpot_die "Usage: $0 <planId> [instanceId]"

echo "== Plan ${PLAN_ID} from DynamoDB ${TPOT_PLAN_TABLE} (region ${TPOT_REGION}) ==" >&2
PLAN_JSON="$(aws dynamodb get-item \
  --region "${TPOT_REGION}" \
  --table-name "${TPOT_PLAN_TABLE}" \
  --key "{\"planId\":{\"S\":\"${PLAN_ID}\"}}" \
  --output json)"

ITEM="$(printf '%s' "${PLAN_JSON}" | jq -r '.Item // empty')"
[[ -n "${ITEM}" ]] || tpot_die "No plan found for planId=${PLAN_ID} in ${TPOT_PLAN_TABLE}."

# Flatten the DynamoDB-typed attributes to plain strings.
MODEL_NAME="$(printf '%s' "${PLAN_JSON}" | jq -r '.Item.modelName.S // "-"')"
COMPOSE_FILE="$(printf '%s' "${PLAN_JSON}" | jq -r '.Item.composeFile.S // "-"')"
INSTANCE_TYPE="$(printf '%s' "${PLAN_JSON}" | jq -r '.Item.instanceType.S // "-"')"
RECIPE="$(printf '%s' "${PLAN_JSON}" | jq -r '.Item.recipe.S // "-"')"

echo "  modelName    : ${MODEL_NAME}"
echo "  composeFile  : ${COMPOSE_FILE}"
echo "  instanceType : ${INSTANCE_TYPE}"
echo "  recipe       : ${RECIPE}"

[[ "${COMPOSE_FILE}" != "-" && -n "${COMPOSE_FILE}" ]] || tpot_die "Plan has no composeFile; cannot compare model paths."

# Fetch the compose file contents (read-only).
COMPOSE_CONTENT=""
if [[ -n "${INSTANCE_ID}" ]]; then
  echo "== Reading compose from live instance ${INSTANCE_ID}: ${TPOT_SCRIPTS_DIR}/${COMPOSE_FILE} ==" >&2
  REMOTE_CMD="cat ${TPOT_SCRIPTS_DIR}/${COMPOSE_FILE} 2>/dev/null || echo '(compose file not found on instance)'"
  CMD_ID="$(aws ssm send-command \
    --region "${TPOT_REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --comment "tpot-troubleshooter read-only cat compose" \
    --parameters "commands=[$(printf '%s' "${REMOTE_CMD}" | jq -Rs .)]" \
    --query 'Command.CommandId' --output text)"
  for _ in $(seq 1 40); do
    STATUS="$(aws ssm get-command-invocation \
      --region "${TPOT_REGION}" --command-id "${CMD_ID}" --instance-id "${INSTANCE_ID}" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")"
    case "${STATUS}" in Success|Failed|Cancelled|TimedOut) break ;; *) sleep 3 ;; esac
  done
  COMPOSE_CONTENT="$(aws ssm get-command-invocation \
    --region "${TPOT_REGION}" --command-id "${CMD_ID}" --instance-id "${INSTANCE_ID}" \
    --query 'StandardOutputContent' --output text || true)"
else
  echo "== Reading compose from S3 s3://${TPOT_COMPOSE_BUCKET}/${COMPOSE_FILE} ==" >&2
  COMPOSE_CONTENT="$(aws s3 cp "s3://${TPOT_COMPOSE_BUCKET}/${COMPOSE_FILE}" - --region "${TPOT_REGION}" 2>/dev/null || true)"
  if [[ -z "${COMPOSE_CONTENT}" ]]; then
    tpot_die "Could not read s3://${TPOT_COMPOSE_BUCKET}/${COMPOSE_FILE}. Fix TPOT_COMPOSE_BUCKET in config.env, or pass an instanceId to read from the live instance."
  fi
fi

# Extract every --model-path value from the compose content.
MODEL_PATHS="$(printf '%s' "${COMPOSE_CONTENT}" \
  | grep -oE -- '--model-path[= ]+[^"'"'"' ]+' \
  | sed -E 's/^--model-path[= ]+//' \
  | sort -u || true)"

echo "" >&2
echo "== Compose --model-path value(s) ==" >&2
if [[ -z "${MODEL_PATHS}" ]]; then
  echo "  (no --model-path found in ${COMPOSE_FILE})"
else
  printf '  %s\n' ${MODEL_PATHS}
fi

# The on-disk model dir the platform derives from modelName: "/" -> "__".
DERIVED_DIR="$(printf '%s' "${MODEL_NAME}" | sed 's#/#__#g')"
echo "" >&2
echo "== Comparison ==" >&2
echo "  plan.modelName            : ${MODEL_NAME}"
echo "  derived on-disk dir name  : ${DERIVED_DIR}"

MISMATCH=1
while IFS= read -r mp; do
  [[ -n "${mp}" ]] || continue
  base="$(basename "${mp}")"
  if [[ "${mp}" == *"${MODEL_NAME}"* || "${base}" == "${DERIVED_DIR}" || "${mp}" == *"${DERIVED_DIR}"* ]]; then
    MISMATCH=0
  fi
done <<< "${MODEL_PATHS}"

if [[ -z "${MODEL_PATHS}" ]]; then
  echo "  RESULT: could not extract --model-path; inspect the compose file manually." >&2
elif [[ "${MISMATCH}" -eq 0 ]]; then
  echo "  RESULT: OK - modelName is consistent with the compose --model-path." >&2
else
  echo "  RESULT: *** MISMATCH *** plan.modelName does NOT match any compose --model-path." >&2
  echo "          This is failure pattern (a) (includes DSpark preview draft-head case (e))." >&2
  echo "          Report to the operator; do NOT edit the plan or compose here." >&2
fi
