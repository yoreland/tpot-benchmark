#!/usr/bin/env bash
# deployer_logs.sh - READ-ONLY. Pull tpot-booking-deployer Lambda history logs.
#
# Usage:
#   ./deployer_logs.sh                        # recent deployer log events
#   ./deployer_logs.sh <bookingId>            # filter events mentioning bookingId
#   ./deployer_logs.sh <bookingId> <since>    # also start from an ISO-8601 time
#   e.g. ./deployer_logs.sh b-1234 2026-09-14T00:00:00Z
#
# Reads CloudWatch Logs for /aws/lambda/tpot-booking-deployer. Use this when the
# instance has been terminated (its local deploy.log is gone) or when you want the
# orchestration side of the story. This is where you see capacity decisions, the
# SSM command dispatch, and the top-level exit status the deployer recorded.
#
# Uses only read-only AWS CloudWatch Logs APIs: filter-log-events.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

tpot_require_aws_creds

BOOKING_ID="${1:-}"
SINCE_ISO="${2:-}"

# Convert an optional ISO-8601 start time to epoch milliseconds for the API.
START_ARGS=()
if [[ -n "${SINCE_ISO}" ]]; then
  if EPOCH="$(date -u -d "${SINCE_ISO}" +%s 2>/dev/null)"; then
    START_ARGS=(--start-time "$(( EPOCH * 1000 ))")
  else
    tpot_die "Could not parse start time '${SINCE_ISO}'. Use ISO-8601, e.g. 2026-09-14T00:00:00Z"
  fi
fi

# Optional server-side filter on the bookingId. filter-log-events matches the
# literal string across event messages.
FILTER_ARGS=()
if [[ -n "${BOOKING_ID}" ]]; then
  FILTER_ARGS=(--filter-pattern "\"${BOOKING_ID}\"")
  echo "== deployer logs (${TPOT_DEPLOYER_LOG_GROUP}) filtered by '${BOOKING_ID}' ==" >&2
else
  echo "== recent deployer logs (${TPOT_DEPLOYER_LOG_GROUP}) ==" >&2
fi

aws logs filter-log-events \
  --region "${TPOT_REGION}" \
  --log-group-name "${TPOT_DEPLOYER_LOG_GROUP}" \
  "${START_ARGS[@]}" \
  "${FILTER_ARGS[@]}" \
  --query 'events[].[timestamp,message]' \
  --output text 2>/dev/null \
| while IFS=$'\t' read -r TS MSG; do
    if [[ -n "${TS}" && "${TS}" != "None" ]]; then
      # Human-readable UTC timestamp; the message is already the log line.
      printf '%s  %s\n' "$(date -u -d "@$(( TS / 1000 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "${TS}")" "${MSG}"
    else
      printf '%s\n' "${MSG}"
    fi
  done

echo "(tip: sibling log groups exist for capacity/api/orphan-cleaner: ${TPOT_DEPLOYER_LOG_GROUP}-capacity-poller etc. Edit TPOT_DEPLOYER_LOG_GROUP in config.env to inspect them.)" >&2
