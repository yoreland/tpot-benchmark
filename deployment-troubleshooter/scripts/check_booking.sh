#!/usr/bin/env bash
# check_booking.sh - READ-ONLY. List recent bookings, or show one booking.
#
# Usage:
#   ./check_booking.sh                 # list the most recent bookings
#   ./check_booking.sh <bookingId>     # show a single booking's key fields
#
# Reads the booking REST API through CloudFront using HTTP Basic Auth taken
# from the TPOT_API_AUTH environment variable. Performs only HTTP GET requests.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

command -v curl >/dev/null 2>&1 || tpot_die "curl is required."

AUTH_HEADER="$(tpot_api_auth_header)"
BOOKING_ID="${1:-}"

if [[ -z "${BOOKING_ID}" ]]; then
  echo "== Listing recent bookings from ${TPOT_API_BASE} ==" >&2
  RESP="$(curl -fsS -H "${AUTH_HEADER}" "${TPOT_API_BASE}")"
  # Show a compact table of the key fields when jq is available.
  if command -v jq >/dev/null 2>&1; then
    echo "${RESP}" | jq -r '
      (if type=="array" then . elif has("bookings") then .bookings elif has("items") then .items else [.] end)
      | .[]
      | [.bookingId, .status, (.instanceId // "-"), (.ssmCommandId // "-"), (.deploymentPlan // "-")]
      | @tsv
    ' | awk 'BEGIN{printf "%-20s %-12s %-22s %-40s %s\n","BOOKING_ID","STATUS","INSTANCE_ID","SSM_COMMAND_ID","PLAN"}
             {printf "%-20s %-12s %-22s %-40s %s\n",$1,$2,$3,$4,$5}'
  else
    echo "${RESP}" | tpot_json_pp
  fi
else
  echo "== Booking ${BOOKING_ID} from ${TPOT_API_BASE} ==" >&2
  RESP="$(curl -fsS -H "${AUTH_HEADER}" "${TPOT_API_BASE}/${BOOKING_ID}")"
  if command -v jq >/dev/null 2>&1; then
    echo "${RESP}" | jq '{bookingId, status, deploymentPlan, instanceId, az, region, ssmCommandId, endpoint}'
  else
    echo "${RESP}" | tpot_json_pp
  fi
fi
