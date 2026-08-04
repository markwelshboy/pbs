#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="/usr/local/lib/pbs-protection/common.sh"
[[ -r "$COMMON_LIB" ]] || COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/common.sh
source "$COMMON_LIB"

load_config
ensure_runtime_dirs
require_root
for cmd in jq flock timeout proxmox-backup-manager; do require_cmd "$cmd"; done
acquire_lock

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
CURRENT_LOG="${LOG_DIR}/monthly-verify-${RUN_ID}.log"
touch "$CURRENT_LOG"
chmod 0600 "$CURRENT_LOG"
CURRENT_STAGE="monthly-verify"

on_exit() {
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    notify "❌ <b>PBS monthly verification failed</b>

Job: <code>$(html_escape "${MONTHLY_VERIFY_JOB:-unset}")</code>
RC: <b>${rc}</b>
Log: <code>$(html_escape "$CURRENT_LOG")</code>"
  fi
}
trap on_exit EXIT

[[ -n "${MONTHLY_VERIFY_JOB:-}" ]] || die "MONTHLY_VERIFY_JOB is not configured"
wait_for_pbs_idle
log "running full monthly verification job: $MONTHLY_VERIFY_JOB"
timeout "${MONTHLY_VERIFY_TIMEOUT_SEC:-259200}" \
  proxmox-backup-manager verify-job run "$MONTHLY_VERIFY_JOB" \
  >>"$CURRENT_LOG" 2>&1
wait_for_pbs_idle
log "monthly verification completed successfully"
notify "✅ <b>PBS monthly verification complete</b>

Job: <code>$(html_escape "$MONTHLY_VERIFY_JOB")</code>
Log: <code>$(html_escape "$CURRENT_LOG")</code>"
