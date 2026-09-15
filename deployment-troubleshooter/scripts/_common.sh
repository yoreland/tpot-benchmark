#!/usr/bin/env bash
# _common.sh - shared read-only helpers for the tpot deployment-troubleshooter
# skill. Sourced by the other scripts. Contains no write operations.
set -euo pipefail

# Resolve the directory this file lives in, then source config.env next to it.
_TPOT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.env
source "${_TPOT_SCRIPT_DIR}/config.env"

# Print an error to stderr and exit.
tpot_die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Ensure AWS credentials are present in the environment (never stored by us).
tpot_require_aws_creds() {
  if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    tpot_die "AWS credentials not found. Export AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (and AWS_SESSION_TOKEN if temporary) before running."
  fi
}

# Build the booking API Basic Auth header value from the TPOT_API_AUTH env var.
# The password is read from the environment, never from a file.
tpot_api_auth_header() {
  local var="${TPOT_API_AUTH_ENV:-TPOT_API_AUTH}"
  local val="${!var:-}"
  if [[ -z "${val}" ]]; then
    tpot_die "Booking API auth not found. Export ${var}='username:password' before running."
  fi
  printf 'Authorization: Basic %s' "$(printf '%s' "${val}" | base64 | tr -d '\n')"
}

# Pick a JSON pretty-printer: jq if available, else python3, else cat.
tpot_json_pp() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool
  else
    cat
  fi
}
