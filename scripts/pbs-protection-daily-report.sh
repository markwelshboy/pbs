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
for cmd in jq timeout df smartctl systemctl proxmox-backup-manager proxmox-backup-client rclone openssl; do
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
PROMOTION_FAIL_HOURS="${DAILY_REPORT_PROMOTION_FAIL_AGE_HOURS:-${DAILY_REPORT_PROMOTION_FAIL_HOURS:-36}}"
RCLONE_SIZE_TIMEOUT_SEC="${DAILY_REPORT_RCLONE_TIMEOUT_SEC:-1800}"

install -d -o root -g root -m 0700 "$REPORT_DIR"

OVERALL="HEALTHY"
declare -a WARNINGS=()
declare -a FAILURES=()
declare -a GROUP_LINES=()
declare -a WORKLOAD_HOSTS=()
declare -a HOSTCFG_HOSTS=()
declare -A WORKLOAD_HOST_SEEN=()
declare -A HOSTCFG_HOST_SEEN=()
declare -A MATRIX_EXPECTED=()
declare -A MATRIX_FOUND=()
declare -A MATRIX_VERIFIED=()

DAY_DATES=(
  "$(date +%F)"
  "$(date -d '1 day ago' +%F)"
  "$(date -d '2 days ago' +%F)"
)

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

short_host() {
  local host="${1%-pve}"
  printf '%.9s' "$host"
}

snapshot_json() {
  local ns="$1" group="$2"
  proxmox-backup-client snapshot list "$group" \
    --repository "$PBS_REPOSITORY" \
    --ns "$ns" \
    --output-format json
}

matrix_cell() {
  local category="$1" ns="$2" offset="$3"
  local expected found verified icon
  expected="${MATRIX_EXPECTED["${category}|${ns}"]:-0}"
  found="${MATRIX_FOUND["${category}|${ns}|${offset}"]:-0}"
  verified="${MATRIX_VERIFIED["${category}|${ns}|${offset}"]:-0}"

  if (( expected == 0 )); then
    printf -- '-'
    return 0
  fi

  if (( found == expected && verified == expected )); then
    icon='✅'
  elif (( found == 0 )); then
    icon='❌'
  else
    icon='⚠️'
  fi

  printf '%d/%d%s' "$found" "$expected" "$icon"
}

build_matrix() {
  local category="$1"
  shift
  local ns

  printf '%-9s %-7s %-7s %-7s\n' 'host' 'today' '-1d' '-2d'
  for ns in "$@"; do
    printf '%-9s %-7s %-7s %-7s\n' \
      "$(short_host "$ns")" \
      "$(matrix_cell "$category" "$ns" 0)" \
      "$(matrix_cell "$category" "$ns" 1)" \
      "$(matrix_cell "$category" "$ns" 2)"
  done
}

PROMOTION_SUMMARY="missing"
PROMOTION_SHORT="missing"
PROMOTION_CYCLE="unknown"
PROMOTION_AGE_HOURS=0
PROMOTION_LOG=""
CYCLE_ELAPSED="unknown"
if [[ -r "${STATE_DIR}/last-success.json" ]]; then
  PROMOTION_EPOCH="$(jq -r '.completed_epoch // 0' "${STATE_DIR}/last-success.json")"
  PROMOTION_CYCLE="$(jq -r '.cycle // "unknown"' "${STATE_DIR}/last-success.json")"
  PROMOTION_LOG="$(jq -r '.log // empty' "${STATE_DIR}/last-success.json")"
  if [[ "$PROMOTION_EPOCH" =~ ^[0-9]+$ && "$PROMOTION_EPOCH" -gt 0 ]]; then
    PROMOTION_AGE_HOURS=$(( (NOW - PROMOTION_EPOCH) / 3600 ))
    PROMOTION_SUMMARY="cycle=${PROMOTION_CYCLE}, age=$(age_text "$PROMOTION_AGE_HOURS"), completed=$(local_time_from_epoch "$PROMOTION_EPOCH")"
    PROMOTION_SHORT="$(date -d "@${PROMOTION_EPOCH}" '+%H:%M') ($(age_text "$PROMOTION_AGE_HOURS") old)"
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

if [[ -r "$PROMOTION_LOG" ]]; then
  CYCLE_ELAPSED="$(
    grep -E '\[complete\].*PBS protection cycle completed in [0-9]+:[0-9]+:[0-9]+' "$PROMOTION_LOG" \
      | tail -n 1 \
      | sed -E 's/.*completed in ([0-9]+:[0-9]+:[0-9]+).*/\1/' \
      || true
  )"
  [[ -n "$CYCLE_ELAPSED" ]] || CYCLE_ELAPSED="unknown"
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

  if [[ "$group" == host/* ]]; then
    category="hostcfg"
    if [[ -z "${HOSTCFG_HOST_SEEN[$ns]:-}" ]]; then
      HOSTCFG_HOSTS+=("$ns")
      HOSTCFG_HOST_SEEN["$ns"]=1
    fi
  else
    category="workload"
    if [[ -z "${WORKLOAD_HOST_SEEN[$ns]:-}" ]]; then
      WORKLOAD_HOSTS+=("$ns")
      WORKLOAD_HOST_SEEN["$ns"]=1
    fi
  fi

  expected_key="${category}|${ns}"
  MATRIX_EXPECTED["$expected_key"]=$(( ${MATRIX_EXPECTED["$expected_key"]:-0} + 1 ))

  if ! JS="$(snapshot_json "$ns" "$group" 2>/dev/null)"; then
    GROUP_LINES+=("FAIL  [$ns] $group — cannot list snapshots")
    mark_failure "cannot list [$ns]:$group"
    continue
  fi

  for offset in 0 1 2; do
    DAY_STATE="$(jq -r --arg day "${DAY_DATES[$offset]}" '
      [ .[]
        | {
            epoch: (."backup-time" // .backup_time // 0),
            state: ((.verification.state // .verification_state // "missing") | ascii_downcase)
          }
        | select(.epoch > 0)
        | . + {local_day: (.epoch | strflocaltime("%Y-%m-%d"))}
        | select(.local_day == $day)
      ] as $snapshots
      | if ($snapshots | length) == 0 then "missing"
        elif any($snapshots[]; .state == "ok") then "ok"
        else "unverified"
        end' <<<"$JS")"

    if [[ "$DAY_STATE" != "missing" ]]; then
      found_key="${category}|${ns}|${offset}"
      MATRIX_FOUND["$found_key"]=$(( ${MATRIX_FOUND["$found_key"]:-0} + 1 ))
      if [[ "$DAY_STATE" == "ok" ]]; then
        MATRIX_VERIFIED["$found_key"]=$(( ${MATRIX_VERIFIED["$found_key"]:-0} + 1 ))
      fi
    fi
  done

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

for category in workload hostcfg; do
  if [[ "$category" == "workload" ]]; then
    matrix_hosts=("${WORKLOAD_HOSTS[@]}")
    category_label="workload"
  else
    matrix_hosts=("${HOSTCFG_HOSTS[@]}")
    category_label="host-config"
  fi

  for ns in "${matrix_hosts[@]}"; do
    expected="${MATRIX_EXPECTED["${category}|${ns}"]:-0}"
    for offset in 0 1 2; do
      found="${MATRIX_FOUND["${category}|${ns}|${offset}"]:-0}"
      verified="${MATRIX_VERIFIED["${category}|${ns}|${offset}"]:-0}"
      if (( found < expected )); then
        mark_warning "${category_label} coverage [$ns] ${DAY_DATES[$offset]}=${found}/${expected}"
      elif (( verified < expected )); then
        mark_warning "${category_label} verification [$ns] ${DAY_DATES[$offset]}=${verified}/${expected}"
      fi
    done
  done
done

WORKLOAD_MATRIX="$(build_matrix workload "${WORKLOAD_HOSTS[@]}")"
HOSTCFG_MATRIX="$(build_matrix hostcfg "${HOSTCFG_HOSTS[@]}")"

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

MIRROR_PARITY="FAILED"
if [[ "$NAS_COUNT" != "unknown" && "$S3_COUNT" != "unknown" ]]; then
  if [[ "$NAS_COUNT" == "$S3_COUNT" && "$NAS_BYTES" == "$S3_BYTES" ]]; then
    MIRROR_PARITY="OK"
  else
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
GC_UPID="$(jq -r '.upid // empty' <<<"$GC_JSON")"
GC_REMOVED_BYTES="$(jq -r '.["removed-bytes"] // .removed_bytes // 0' <<<"$GC_JSON")"
GC_REMOVED_CHUNKS="$(jq -r '.["removed-chunks"] // .removed_chunks // 0' <<<"$GC_JSON")"
if [[ -n "$GC_UPID" ]]; then
  GC_SHORT="freed $(human_bytes "$GC_REMOVED_BYTES") / ${GC_REMOVED_CHUNKS} chunks"
else
  GC_SHORT="not run yet (scheduled Sunday)"
fi

PRUNE_JSON="$(proxmox-backup-manager prune-job list --output-format json 2>/dev/null || echo '[]')"
PRUNE_COUNT="$(jq 'length' <<<"$PRUNE_JSON")"

NEXT_TIMERS="$(systemctl list-timers --all --no-pager \
  pbs-protection-cycle.timer \
  pbs-protection-monthly-verify.timer \
  pbs-protection-daily-report.timer 2>/dev/null || true)"

NAS_HUMAN="$([[ "$NAS_BYTES" =~ ^[0-9]+$ ]] && human_bytes "$NAS_BYTES" || printf unknown)"
S3_HUMAN="$([[ "$S3_BYTES" =~ ^[0-9]+$ ]] && human_bytes "$S3_BYTES" || printf unknown)"

{
  printf 'PBS DAILY HEALTH REPORT — %s\n' "$OVERALL"
  printf 'Generated: %s\n' "$(date '+%F %T %Z')"
  printf 'Host:      %s\n' "$(hostname -f 2>/dev/null || hostname)"
  printf 'Store:     %s\n' "$PBS_DATASTORE"
  printf '\n'
  printf 'FIRST GLANCE\n'
  printf '  Overall:    %s\n' "$OVERALL"
  printf '  Promotion:  %s; elapsed=%s\n' "$PROMOTION_SHORT" "$CYCLE_ELAPSED"
  printf '  Mirrors:    %s; %s; %s objects\n' "$MIRROR_PARITY" "$NAS_HUMAN" "$NAS_COUNT"
  printf '  Datastore:  %s used; %s available\n' "$FS_PCT" "$(human_bytes "$FS_AVAIL")"
  printf '  SMART:      %s; %sC\n' "${SMART_HEALTH:-unknown}" "${SMART_TEMP:-unknown}"
  printf '  Tasks:      %s failed in 36h\n' "$RECENT_FAILED_TASKS"
  printf '\n'
  printf 'WORKLOAD BACKUPS — 3 DAY COVERAGE\n%s\n' "$WORKLOAD_MATRIX"
  printf '\n'
  printf 'HOST CONFIG BACKUPS — 3 DAY COVERAGE\n%s\n' "$HOSTCFG_MATRIX"
  printf '\n'
  printf 'LATEST EXPECTED BACKUPS\n'
  printf '  %s\n' "${GROUP_LINES[@]}"
  printf '\n'
  printf 'ENDPOINTS\n'
  printf '  NAS: objects=%s bytes=%s (%s)\n' "$NAS_COUNT" "$NAS_BYTES" "$NAS_HUMAN"
  printf '  S3:  objects=%s bytes=%s (%s)\n' "$S3_COUNT" "$S3_BYTES" "$S3_HUMAN"
  printf '  parity: %s\n' "$MIRROR_PARITY"
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
  printf '  GC: %s\n' "$GC_SHORT"
  printf '  GC raw: %s\n' "$GC_SUMMARY"
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

case "$OVERALL" in
  HEALTHY) STATUS_ICON='✅' ;;
  WARNING) STATUS_ICON='⚠️' ;;
  *) STATUS_ICON='❌' ;;
esac

[[ "$MIRROR_PARITY" == "OK" ]] && MIRROR_ICON='✅' || MIRROR_ICON='❌'
[[ "$SMART_HEALTH" =~ (OK|PASSED) ]] && SMART_ICON='✅' || SMART_ICON='❌'
[[ "$RECENT_FAILED_TASKS" == "0" ]] && TASK_ICON='✅' || TASK_ICON='⚠️'

ISSUE_BLOCK=""
if ((${#FAILURES[@]} || ${#WARNINGS[@]})); then
  ISSUE_LINES="$(
    {
      printf 'FAIL: %s\n' "${FAILURES[@]}"
      printf 'WARN: %s\n' "${WARNINGS[@]}"
    } | sed '/^FAIL: $/d; /^WARN: $/d' | head -n 8
  )"
  ISSUE_BLOCK="
<b>Issues</b>
<pre>$(html_escape "$ISSUE_LINES")</pre>"
fi

TELEGRAM_MESSAGE="$(cat <<MSG
${STATUS_ICON} <b>PBS Daily — $(html_escape "$OVERALL")</b>
🖥 <code>$(html_escape "$(hostname -s)")</code>  🗄 <code>$(html_escape "$PBS_DATASTORE")</code>

<b>At a glance</b>
Promotion: ${STATUS_ICON} <b>$(html_escape "$PROMOTION_SHORT")</b>
Mirrors: ${MIRROR_ICON} <b>$(html_escape "$NAS_HUMAN") / $(html_escape "$NAS_COUNT") objects</b>
Storage: <b>$(html_escape "$FS_PCT") used</b> · $(html_escape "$(human_bytes "$FS_AVAIL")") free
Disk: ${SMART_ICON} <b>$(html_escape "${SMART_HEALTH:-unknown}")</b> · $(html_escape "${SMART_TEMP:-unknown}")C
Tasks: ${TASK_ICON} <b>$(html_escape "$RECENT_FAILED_TASKS") failed</b> · GC $(html_escape "$GC_SHORT")

📦 <b>Workload backups</b>
<pre>$(html_escape "$WORKLOAD_MATRIX")</pre>

🖥 <b>Host config backups</b>
<pre>$(html_escape "$HOSTCFG_MATRIX")</pre>

🔁 <b>Promotion endpoints</b>
NAS: ${MIRROR_ICON} $(html_escape "$NAS_HUMAN")
S3:  ${MIRROR_ICON} $(html_escape "$S3_HUMAN")
Parity: <b>$(html_escape "$MIRROR_PARITY")</b> · elapsed $(html_escape "$CYCLE_ELAPSED")
Prune: <b>$(html_escape "$PRUNE_COUNT") job(s)</b>${ISSUE_BLOCK}

Report: <code>$(html_escape "$REPORT_FILE")</code>
MSG
)"

notify "$TELEGRAM_MESSAGE"

[[ "$OVERALL" != "FAILED" ]]
