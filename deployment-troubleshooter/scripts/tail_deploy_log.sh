#!/usr/bin/env bash
# tail_deploy_log.sh - READ-ONLY. Pull live diagnostics off a running instance.
#
# Usage:
#   ./tail_deploy_log.sh <instanceId>
#
# Sends a single SSM RunCommand (AWS-RunShellScript) that executes ONLY
# read-only commands on the instance, then polls for and prints the output:
#   - tail -n 200 /var/log/tpot-bench/deploy.log   (the real deploy error)
#   - docker ps -a                                 (container states)
#   - docker logs --tail for each container         (crash reasons)
#   - ls of the compose dir and the model dir       (missing model dir?)
#   - df -h                                          (full disk / fake RAID)
#   - nvidia-smi                                     (GPU visibility)
#
# NOTE: if the instance has already been terminated, its local deploy.log is
# gone with it. In that case fall back to deployer_logs.sh (Lambda history).
#
# This script issues NO write/mutating commands. send-command is used purely to
# run the read-only shell above.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

tpot_require_aws_creds

INSTANCE_ID="${1:-}"
[[ -n "${INSTANCE_ID}" ]] || tpot_die "Usage: $0 <instanceId>"

# Read-only remote command. Container names follow scripts-*-1 (PD or TP8).
read -r -d '' REMOTE_CMD <<REMOTE || true
set +e
echo '===== deploy.log (tail -n 200) ====='
tail -n 200 ${TPOT_DEPLOY_LOG} 2>/dev/null || echo '(no ${TPOT_DEPLOY_LOG})'
echo '===== docker ps -a ====='
docker ps -a 2>/dev/null || echo '(docker unavailable)'
echo '===== docker logs (tail 80) per container ====='
for c in \$(docker ps -a --format '{{.Names}}' 2>/dev/null); do
  echo "----- \$c -----"
  docker logs --tail 80 "\$c" 2>&1 || true
done
echo '===== ls compose dir ${TPOT_SCRIPTS_DIR} ====='
ls -la ${TPOT_SCRIPTS_DIR} 2>/dev/null || echo '(missing)'
echo '===== ls model dir ${TPOT_MODELS_DIR} ====='
ls -la ${TPOT_MODELS_DIR} 2>/dev/null || echo '(missing)'
echo '===== df -h ====='
df -h 2>/dev/null || true
echo '===== nvidia-smi ====='
nvidia-smi 2>/dev/null || echo '(nvidia-smi unavailable)'
REMOTE

echo "== Sending read-only diagnostic command to ${INSTANCE_ID} (region ${TPOT_REGION}) ==" >&2
CMD_ID="$(aws ssm send-command \
  --region "${TPOT_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --comment "tpot-troubleshooter read-only diagnostics" \
  --parameters "commands=[$(printf '%s' "${REMOTE_CMD}" | jq -Rs .)]" \
  --query 'Command.CommandId' --output text)"

echo "SSM CommandId: ${CMD_ID}" >&2
echo "Waiting for the command to finish..." >&2

for _ in $(seq 1 60); do
  STATUS="$(aws ssm get-command-invocation \
    --region "${TPOT_REGION}" \
    --command-id "${CMD_ID}" \
    --instance-id "${INSTANCE_ID}" \
    --query 'Status' --output text 2>/dev/null || echo "Pending")"
  case "${STATUS}" in
    Success|Failed|Cancelled|TimedOut) break ;;
    *) sleep 3 ;;
  esac
done

echo "== Invocation status: ${STATUS} ==" >&2
aws ssm get-command-invocation \
  --region "${TPOT_REGION}" \
  --command-id "${CMD_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --query 'StandardOutputContent' --output text || true

ERR="$(aws ssm get-command-invocation \
  --region "${TPOT_REGION}" \
  --command-id "${CMD_ID}" \
  --instance-id "${INSTANCE_ID}" \
  --query 'StandardErrorContent' --output text 2>/dev/null || true)"
if [[ -n "${ERR}" && "${ERR}" != "None" ]]; then
  echo "===== stderr =====" >&2
  echo "${ERR}" >&2
fi
