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
for cmd in jq timeout df findmnt smartctl systemctl proxmox-backup-manager proxmox-backup-client rclone openssl; do
  require_cmd "$cmd"
done
pbs_client_env

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
NOW="$(epoch_now)"
REPORT_DIR="${DAILY_REPORT_DIR:-${STATE_DIR}/reports}"
REPORT_FILE="${REPORT_DIR}/daily-${RUN_ID}.txt"
LATEST_REPORT="${REPORT_DIR}/latest.txt"
REPORT_KEEP_DAYS="${DAILY_REPORT_KEEP_DAYS:-90}"
WARN_AGE_HOURS="${DAILY_REPORT_WARN_AGE_HOURS:-26}"
FAIL_AGE_HOURS="${DAILY_REPORT_FAIL_AGE_HOURS:-36}"
PROMOTION_WARN_HOURS="${DAILY_REPORT_PROMOTION_WARN_HOURS:-26}"
PROMOTION_FAIL_HOURS="${DAILY_REPORT_PROMOTION_FAIL_HOURS:-36}"
RCLONE_SIZE_TIMEOUT_SEC="${DAILY_REPORT_RCLONE_TIMEOUT_SEC:-1800}"

install -d -o root -g root -m 0700 "$REPORT_DIR"

OVERALL="HEALTHY"
declare -a WARNINGS=()
declare -a FAILURES=()
declare -a GROUP_LINES=()

mark_warning() {
  [[ "$OVERALL" == "FAILED" ]] || OVERALL="WARNING"
  WARNINGS+=("$*")
}

mark_failure() {
  OVERALL="FAILED"
  FAILURES+=("$*")
}

age_text() {
  local hours="${1:-0}"
  if (( hours < 24 )); then
    printf '%sh' "$hours"
  else
    printf '%sd%sh' "$((hours / 24))" "$((hours % 24))"
  fi
}

local_time_from_epoch() {
  local epoch="${1:-0}"
  if [[ "$epoch" =~ ^[0-9]+$ && "$epoch" -gt 0 ]]; then
    date -d "@${epoch}" '+%F %T %Z'
  else
    printf 'unknown'
  fi
}

snapshot_json() {
  local ns="$1" group="$2"
  proxmox-backup-client snapshot list "$group" \
    --repository "$PBS_REPOSITORY" \
    --ns "$ns" \
    --output-format json
}

PROMOTION_SUMMARY="missing"
if [[ -r "${STATE_DIR}/last-success.json" ]]; then
  PROMOTION_EPOCH="$(jq -r '.completed_epoch // 0' "${STATE_DIR}/last-success.json")"
  PROMOTION_CYCLE="$(jq -r '.cycle // "unknown"' "${STATE_DIR}/last-success.json")"
  if [[ "$PROMOTION_EPOCH" =~ ^[0-9]+$ && "$PROMOTION_EPOCH" -gt 0 ]]; then
    PROMOTION_AGE_HOURS=$(( (NOW - PROMOTION_EPOCH) / 3600 ))
    PROMOTION_SUMMARY="cycle=${PROMOTION_CYCLE}, age=$(age_text "$PROMOTION_AGE_HOURS"), completed=$(local_time_from_epoch "$PROMOTION_EPOCH")"
    if (( PROMOTION_AGE_HOURS > PROMOTION_FAIL_HOURS )); then
      mark_failure "last successful promotion is $(age_text "$PROMOTION_AGE_HOURS") old"
    elif (( PROMOTION_AGE_HOURS > PROMOTION_WARN_HOURS )); then
      mark_warning "last successful promotion is $(age_text "$PROMOTION_AGE_HOURS") old"
    fi
  else
    mark_failure "last-success.json has no valid completion time"
  fi
else
  mark_failure "no successful promotion marker exists"
fi

if [[ -r "${STATE_DIR}/last-attempt.json" ]]; then
  ATTEMPT_STATUS="$(jq -r '.status // "unknown"' "${STATE_DIR}/last-attempt.json")"
  ATTEMPT_STAGE="$(jq -r '.stage // "unknown"' "${STATE_DIR}/last-attempt.json")"
  ATTEMPT_COMPLETED="$(jq -r '.completed // "unknown"' "${STATE_DIR}/last-attempt.json")"
  mark_warning "last recorded attempt status=${ATTEMPT_STATUS}, stage=${ATTEMPT_STAGE}, completed=${ATTEMPT_COMPLETED}"
fi

DEFAULT_AGE="$(jq -r '.default_max_age_hours // 36' "$EXPECTED_BACKUPS_FILE")"
while IFS=$'\t' read -r ns group policy_age; do
  [[ -n "$ns" && -n "$group" ]] || continue
  policy_age="${policy_age:-$DEFAULT_AGE}"

  if ! JS="$(snapshot_json "$ns" "$group" 2>/dev/null)"; then
    GROUP_LINES+=("FAIL  [$ns] $group — cannot list snapshots")
    mark_failure "cannot list [$ns]:$group"
    continue
  fi

  LATEST="$(jq '[.[] | (."backup-time" // .backup_time // 0)] | max // 0' <<<"$JS")"
  if [[ "$LATEST" -eq 0 ]]; then
    GROUP_LINES+=("FAIL  [$ns] $group — no snapshots")
    mark_failure "no snapshots for [$ns]:$group"
    continue
  fi

  AGE_HOURS=$(( (NOW - LATEST) / 3600 ))
  VERIFICATION="$(jq -r --argjson latest "$LATEST" '
    [.[] | select((."backup-time" // .backup_time // 0) == $latest)][0]
    | (.verification.state // .verification_state // "missing")
    | ascii_downcase' <<<"$JS")"

  LINE_STATE="OK"
  if (( AGE_HOURS > FAIL_AGE_HOURS || AGE_HOURS > policy_age )); then
    LINE_STATE="FAIL"
    mark_failure "stale backup [$ns]:$group age=$(age_text "$AGE_HOURS")"
  elif (( AGE_HOURS > WARN_AGE_HOURS )); then
    LINE_STATE="WARN"
    mark_warning "aging backup [$ns]:$group age=$(age_text "$AGE_HOURS")"
  fi

  if [[ "$VERIFICATION" != "ok" ]]; then
    LINE_STATE="FAIL"
    mark_failure "latest snapshot not verified OK [$ns]:$group state=${VERIFICATION}"
  fi

  GROUP_LINES+=("$(printf '%-5s [%s] %-30s age=%-6s verified=%s' "$LINE_STATE" "$ns" "$group" "$(age_text "$AGE_HOURS")" "$VERIFICATION")")
done < <(
  jq -r --argjson default_age "$DEFAULT_AGE" '
    .namespaces | to_entries[]
    | .key as $ns
    | (.value.max_age_hours // $default_age) as $ns_age
    | .value.required_groups[]
    | if type == "string"
      then [$ns, ., $ns_age]
      else [$ns, .group, (.max_age_hours // $ns_age)]
      end
    | @tsv' "$EXPECTED_BACKUPS_FILE"
)

DATASTORE_JSON="$(proxmox-backup-manager datastore show "$PBS_DATASTORE" --output-format json 2>/dev/null || echo '{}')"
MAINTENANCE_MODE="$(jq -r '.["maintenance-mode"] // .maintenance_mode // "clear"' <<<"$DATASTORE_JSON")"
if [[ "$MAINTENANCE_MODE" != "clear" && "$MAINTENANCE_MODE" != "null" && -n "$MAINTENANCE_MODE" ]]; then
  mark_failure "datastore maintenance mode is active: $MAINTENANCE_MODE"
fi

CYCLE_SERVICE_STATE="$(systemctl is-active pbs-protection-cycle.service 2>/dev/null || true)"
[[ -n "$CYCLE_SERVICE_STATE" ]] || CYCLE_SERVICE_STATE="unknown"
if [[ "$CYCLE_SERVICE_STATE" == "failed" ]]; then
  mark_failure "pbs-protection-cycle.service is failed"
elif [[ "$CYCLE_SERVICE_STATE" == "active" ]]; then
  mark_warning "promotion cycle is still active at report time"
fi

for timer in pbs-protection-cycle.timer pbs-protection-monthly-verify.timer pbs-protection-daily-report.timer; do
  TIMER_ENABLED="$(systemctl is-enabled "$timer" 2>/dev/null || true)"
  TIMER_ACTIVE="$(systemctl is-active "$timer" 2>/dev/null || true)"
  if [[ "$TIMER_ENABLED" != "enabled" || "$TIMER_ACTIVE" != "active" ]]; then
    mark_failure "$timer state enabled=${TIMER_ENABLED:-unknown}, active=${TIMER_ACTIVE:-unknown}"
  fi
done

DF_LINE="$(df -B1 --output=size,used,avail,pcent "$PBS_DATASTORE_PATH" 2>/dev/null | tail -n1 | xargs)"
read -r FS_SIZE FS_USED FS_AVAIL FS_PCT <<<"$DF_LINE"
FS_SIZE="${FS_SIZE:-0}"; FS_USED="${FS_USED:-0}"; FS_AVAIL="${FS_AVAIL:-0}"; FS_PCT="${FS_PCT:-unknown}"

SMART_OUTPUT="$(smartctl -a "$SMART_DEVICE" 2>/dev/null || true)"
SMART_HEALTH="$(awk -F: '/SMART Health Status|SMART overall-health/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' <<<"$SMART_OUTPUT")"
SMART_TEMP="$(awk -F: '/Current Drive Temperature/ {gsub(/[^0-9]/,"",$2); print $2; exit}' <<<"$SMART_OUTPUT")"
SMART_GROWN="$(awk -F: '/Elements in grown defect list/ {gsub(/ /,"",$2); print $2; exit}' <<<"$SMART_OUTPUT")"
SMART_NONMEDIUM="$(awk -F: '/Non-medium error count/ {gsub(/ /,"",$2); print $2; exit}' <<<"$SMART_OUTPUT")"
SMART_UNCORRECTED="$(awk '/^(read:|write:|verify:)/ {sum += $NF} END {print sum+0}' <<<"$SMART_OUTPUT")"

[[ "$SMART_HEALTH" =~ (OK|PASSED) ]] || mark_failure "SMART health is ${SMART_HEALTH:-unknown}"
[[ "${SMART_GROWN:-0}" =~ ^[0-9]+$ && "${SMART_GROWN:-0}" -le "${SMART_MAX_GROWN_DEFECTS:-0}" ]] || mark_failure "SMART grown defects=${SMART_GROWN:-unknown}"
[[ "${SMART_NONMEDIUM:-0}" =~ ^[0-9]+$ && "${SMART_NONMEDIUM:-0}" -le "${SMART_MAX_NON_MEDIUM_ERRORS:-0}" ]] || mark_failure "SMART non-medium errors=${SMART_NONMEDIUM:-unknown}"
[[ "${SMART_UNCORRECTED:-0}" =~ ^[0-9]+$ && "${SMART_UNCORRECTED:-0}" -le "${SMART_MAX_UNCORRECTED_ERRORS:-0}" ]] || mark_failure "SMART uncorrected errors=${SMART_UNCORRECTED:-unknown}"
if [[ "${SMART_TEMP:-}" =~ ^[0-9]+$ ]]; then
  if (( SMART_TEMP >= ${SMART_FAIL_TEMP_C:-55} )); then
    mark_failure "drive temperature ${SMART_TEMP}C exceeds fail threshold"
  elif (( SMART_TEMP >= ${SMART_WARN_TEMP_C:-48} )); then
    mark_warning "drive temperature ${SMART_TEMP}C exceeds warning threshold"
  fi
fi

if NAS_SIZE_JSON="$(timeout "$RCLONE_SIZE_TIMEOUT_SEC" rclone size "$NAS_DEST" --json 2>/dev/null)"; then
  NAS_COUNT="$(jq -r '.count // 0' <<<"$NAS_SIZE_JSON")"
  NAS_BYTES="$(jq -r '.bytes // 0' <<<"$NAS_SIZE_JSON")"
else
  NAS_COUNT="unknown"; NAS_BYTES="unknown"
  mark_failure "could not size NAS mirror within timeout"
fi

if S3_SIZE_JSON="$(timeout "$RCLONE_SIZE_TIMEOUT_SEC" rclone --config "$RCLONE_CONF" size "$S3_DEST" --json 2>/dev/null)"; then
  S3_COUNT="$(jq -r '.count // 0' <<<"$S3_SIZE_JSON")"
  S3_BYTES="$(jq -r '.bytes // 0' <<<"$S3_SIZE_JSON")"
else
  S3_COUNT="unknown"; S3_BYTES="unknown"
  mark_failure "could not size S3 mirror within timeout"
fi

if [[ "$NAS_COUNT" != "unknown" && "$S3_COUNT" != "unknown" ]]; then
  if [[ "$NAS_COUNT" != "$S3_COUNT" || "$NAS_BYTES" != "$S3_BYTES" ]]; then
    mark_failure "NAS/S3 parity mismatch NAS=${NAS_COUNT}:${NAS_BYTES} S3=${S3_COUNT}:${S3_BYTES}"
  fi
fi

TASKS_JSON="$(proxmox-backup-manager task list --all true --limit 100 --output-format json 2>/dev/null || echo '[]')"
RECENT_FAILED_TASKS="$(jq --argjson cutoff "$((NOW - 36 * 3600))" '[.[] | select(
  ((.endtime // ."end-time" // 0) >= $cutoff)
  and ((.status // "") != "OK")
  and ((.status // "") != "unknown")
)] | length' <<<"$TASKS_JSON" 2>/dev/null || echo 0)"
if [[ "$RECENT_FAILED_TASKS" =~ ^[0-9]+$ && "$RECENT_FAILED_TASKS" -gt 0 ]]; then
  mark_warning "$RECENT_FAILED_TASKS failed PBS task(s) in the last 36 hours"
fi

GC_JSON="$(proxmox-backup-manager garbage-collection status "$PBS_DATASTORE" --output-format json 2>/dev/null || echo '{}')"
GC_SUMMARY="$(jq -c '.' <<<"$GC_JSON")"
PRUNE_JSON="$(proxmox-backup-manager prune-job list --output-format json 2>/dev/null || echo '[]')"

NEXT_TIMERS="$(systemctl list-timers --all --no-pager \
  pbs-protection-cycle.timer \
  pbs-protection-monthly-verify.timer \
  pbs-protection-daily-report.timer 2>/dev/null || true)"

{
  printf 'PBS DAILY HEALTH REPORT — %s\n' "$OVERALL"
  printf 'Generated: %s\n' "$(date '+%F %T %Z')"
  printf 'Host:      %s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf '\n'
  printf 'PROMOTION\n'
  printf '  %s\n' "$PROMOTION_SUMMARY"
  printf '  cycle service: %s\n' "$CYCLE_SERVICE_STATE"
  printf '\n'
  printf 'EXPECTED BACKUPS\n'
  printf '  %s\n' "${GROUP_LINES[@]}"
  printf '\n'
  printf 'MIRRORS\n'
  printf '  NAS: objects=%s bytes=%s (%s)\n' "$NAS_COUNT" "$NAS_BYTES" "$([[ "$NAS_BYTES" =~ ^[0-9]+$ ]] && human_bytes "$NAS_BYTES" || printf unknown)"
  printf '  S3:  objects=%s bytes=%s (%s)\n' "$S3_COUNT" "$S3_BYTES" "$([[ "$S3_BYTES" =~ ^[0-9]+$ ]] && human_bytes "$S3_BYTES" || printf unknown)"
  printf '  parity: %s\n' "$([[ "$NAS_COUNT" != unknown && "$NAS_COUNT" == "$S3_COUNT" && "$NAS_BYTES" == "$S3_BYTES" ]] && printf OK || printf FAILED)"
  printf '\n'
  printf 'DATASTORE\n'
  printf '  path: %s\n' "$PBS_DATASTORE_PATH"
  printf '  capacity: %s, used: %s, available: %s, utilization: %s\n' \
    "$(human_bytes "$FS_SIZE")" "$(human_bytes "$FS_USED")" "$(human_bytes "$FS_AVAIL")" "$FS_PCT"
  printf '  maintenance: %s\n' "$MAINTENANCE_MODE"
  printf '\n'
  printf 'SMART\n'
  printf '  health=%s temp=%sC grown=%s non-medium=%s uncorrected=%s\n' \
    "${SMART_HEALTH:-unknown}" "${SMART_TEMP:-unknown}" "${SMART_GROWN:-unknown}" \
    "${SMART_NONMEDIUM:-unknown}" "${SMART_UNCORRECTED:-unknown}"
  printf '\n'
  printf 'MAINTENANCE\n'
  printf '  recent failed PBS tasks (36h): %s\n' "$RECENT_FAILED_TASKS"
  printf '  GC status: %s\n' "$GC_SUMMARY"
  printf '  prune jobs: %s\n' "$(jq -c '.' <<<"$PRUNE_JSON")"
  printf '\n'
  printf 'TIMERS\n%s\n' "$NEXT_TIMERS"

  if ((${#FAILURES[@]})); then
    printf '\nFAILURES\n'
    printf '  - %s\n' "${FAILURES[@]}"
  fi
  if ((${#WARNINGS[@]})); then
    printf '\nWARNINGS\n'
    printf '  - %s\n' "${WARNINGS[@]}"
  fi
} >"$REPORT_FILE"

chmod 0600 "$REPORT_FILE"
cp -f "$REPORT_FILE" "$LATEST_REPORT"
chmod 0600 "$LATEST_REPORT"
find "$REPORT_DIR" -maxdepth 1 -type f -name 'daily-*.txt' -mtime "+$REPORT_KEEP_DAYS" -delete

cat "$REPORT_FILE"

TELEGRAM_GROUPS="$(printf '%s\n' "${GROUP_LINES[@]}" | sed -E 's/ +/ /g' | head -n 20)"
TELEGRAM_MESSAGE="$(cat <<MSG
$([[ "$OVERALL" == HEALTHY ]] && printf '✅' || { [[ "$OVERALL" == WARNING ]] && printf '⚠️' || printf '❌'; }) <b>PBS daily report: $(html_escape "$OVERALL")</b>

Promotion: <code>$(html_escape "$PROMOTION_SUMMARY")</code>
NAS/S3: <b>$(html_escape "$NAS_COUNT") objects / $(html_escape "$NAS_BYTES") bytes</b>
Disk: <b>$(html_escape "${SMART_HEALTH:-unknown}")</b>, temp <b>$(html_escape "${SMART_TEMP:-unknown}")C</b>, use <b>$(html_escape "$FS_PCT")</b>
Failed tasks (36h): <b>$(html_escape "$RECENT_FAILED_TASKS")</b>

<pre>$(html_escape "$TELEGRAM_GROUPS")</pre>
Report: <code>$(html_escape "$REPORT_FILE")</code>
MSG
)"
notify "$TELEGRAM_MESSAGE"

[[ "$OVERALL" != "FAILED" ]]
