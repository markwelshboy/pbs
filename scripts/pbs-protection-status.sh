#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="/usr/local/lib/pbs-protection/common.sh"
[[ -r "$COMMON_LIB" ]] || COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/common.sh
source "$COMMON_LIB"

load_config
ensure_runtime_dirs

printf 'PBS protection status\n'
printf '=====================\n'
printf 'Datastore:  %s\n' "${PBS_DATASTORE:-unset}"
printf 'Path:       %s\n' "${PBS_DATASTORE_PATH:-unset}"
printf 'NAS mirror: %s\n' "${NAS_DEST:-unset}"
printf 'S3 mirror:  %s\n' "${S3_DEST:-unset}"
printf '\n'

if [[ -r "${STATE_DIR}/last-success.json" ]]; then
  printf 'Last successful promotion:\n'
  jq . "${STATE_DIR}/last-success.json"
else
  printf 'Last successful promotion: none\n'
fi

printf '\n'
if [[ -r "${STATE_DIR}/last-attempt.json" ]]; then
  printf 'Last failed attempt:\n'
  jq . "${STATE_DIR}/last-attempt.json"
fi

printf '\nDatastore filesystem:\n'
df -hT "${PBS_DATASTORE_PATH:-/}" 2>/dev/null || true

if [[ -n "${SMART_DEVICE:-}" && -e "${SMART_DEVICE}" ]]; then
  printf '\nSMART summary:\n'
  smartctl -a "$SMART_DEVICE" 2>/dev/null \
    | grep -E 'SMART Health Status|Current Drive Temperature|Elements in grown defect list|Non-medium error count' \
    || true
fi

printf '\nSystemd timers:\n'
systemctl list-timers --all 'pbs-protection-*' --no-pager 2>/dev/null || true
