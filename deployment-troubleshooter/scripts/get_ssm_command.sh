#!/usr/bin/env bash
# get_ssm_command.sh - READ-ONLY. Inspect the SSM RunCommand that ran the deploy.
#
# Usage:
#   ./get_ssm_command.sh <commandId> [instanceId]
#
# Shows the top-level invocation result (usually "exit status 1" - the real
# error lives in /var/log/tpot-bench/deploy.log on the instance) AND the raw
# shell script that was sent to the instance.
#
# Uses only read-only AWS SSM APIs: get-command-invocation and list-commands.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

tpot_require_aws_creds

COMMAND_ID="${1:-}"
INSTANCE_ID="${2:-}"
[[ -n "${COMMAND_ID}" ]] || tpot_die "Usage: $0 <commandId> [instanceId]"

echo "== SSM command ${COMMAND_ID} (region ${TPOT_REGION}) ==" >&2

if [[ -n "${INSTANCE_ID}" ]]; then
  echo "-- get-command-invocation (instance ${INSTANCE_ID}) --" >&2
  aws ssm get-command-invocation \
    --region "${TPOT_REGION}" \
    --command-id "${COMMAND_ID}" \
    --instance-id "${INSTANCE_ID}" \
    --query '{Status:Status, ResponseCode:ResponseCode, StandardOutputContent:StandardOutputContent, StandardErrorContent:StandardErrorContent}' \
    --output json | tpot_json_pp || true
fi

echo "-- list-commands: status + the raw script that was sent --" >&2
# The Parameters.commands array holds the deploy script that was dispatched.
aws ssm list-commands \
  --region "${TPOT_REGION}" \
  --command-id "${COMMAND_ID}" \
  --query 'Commands[0].{Status:Status, DocumentName:DocumentName, RequestedDateTime:RequestedDateTime, Targets:Targets, Commands:Parameters.commands}' \
  --output json | tpot_json_pp
