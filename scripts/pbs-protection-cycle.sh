#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="/usr/local/lib/pbs-protection/common.sh"
[[ -r "$COMMON_LIB" ]] || COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/common.sh
source "$COMMON_LIB"

CHECK_ONLY=0
DRY_RUN=0
FORCE_GC=0
CYCLE_ID="$(date -u +%Y%m%dT%H%M%SZ)"
START_EPOCH="$(epoch_now)"
SUCCESS_MARKER_WRITTEN=0

usage() {
  cat <<'USAGE'
Usage: pbs-protection-cycle [--check] [--dry-run] [--force-gc]

  --check       Validate configuration, storage, credentials and expected backups.
  --dry-run     Run gates and verification, but do not sync NAS/S3 or prune/GC.
  --force-gc    Run garbage collection after a successful promotion regardless of weekday.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force-gc) FORCE_GC=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

load_config
ensure_runtime_dirs
CURRENT_LOG="${LOG_DIR}/cycle-${CYCLE_ID}.log"
touch "$CURRENT_LOG"
chmod 0600 "$CURRENT_LOG"

on_exit() {
  local rc=$?
  clear_datastore_maintenance

  if [[ "$rc" -ne 0 ]]; then
    local failed_json="${STATE_DIR}/last-attempt.json"
    jq -n \
      --arg cycle "$CYCLE_ID" \
      --arg stage "$CURRENT_STAGE" \
      --arg completed "$(utc_now)" \
      --arg log "$CURRENT_LOG" \
      --argjson rc "$rc" \
      --argjson promotion_completed "$SUCCESS_MARKER_WRITTEN" \
      '{cycle:$cycle,status:"failed",stage:$stage,rc:$rc,completed:$completed,log:$log,promotion_completed:($promotion_completed==1)}' \
      | json_write_atomic "$failed_json"

    notify "❌ <b>PBS protection cycle failed</b>

Cycle: <code>$(html_escape "$CYCLE_ID")</code>
Stage: <b>$(html_escape "$CURRENT_STAGE")</b>
RC: <b>${rc}</b>
Promotion completed: <b>$([[ "$SUCCESS_MARKER_WRITTEN" -eq 1 ]] && echo yes || echo no)</b>
Log: <code>$(html_escape "$CURRENT_LOG")</code>"
  fi
}
trap on_exit EXIT

validate_config() {
  CURRENT_STAGE="config"
  local required=(
    PBS_DATASTORE PBS_DATASTORE_PATH PBS_REPOSITORY PBS_PASSWORD_FILE
    EXPECTED_BACKUPS_FILE PBS_NAMESPACES SMART_DEVICE
    NAS_MOUNT NAS_DEST RCLONE_CONF S3_DEST PROMOTION_VERIFY_JOB
  )
  local name
  for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || die "required setting is empty: $name"
  done

  [[ -r "$EXPECTED_BACKUPS_FILE" ]] || die "expected-backups policy missing: $EXPECTED_BACKUPS_FILE"
  jq -e '.reviewed == true and (.namespaces | type == "object")' "$EXPECTED_BACKUPS_FILE" >/dev/null \
    || die "expected-backups policy has not been reviewed (set reviewed=true after review)"

  [[ -r "$RCLONE_CONF" ]] || die "rclone configuration is unreadable: $RCLONE_CONF"
  [[ -r "$PBS_PASSWORD_FILE" ]] || die "PBS token/password file is unreadable: $PBS_PASSWORD_FILE"

  pbs_client_env
}

check_datastore_mount() {
  CURRENT_STAGE="datastore-mount"
  [[ -d "$PBS_DATASTORE_PATH" ]] || die "datastore path does not exist: $PBS_DATASTORE_PATH"
  mountpoint -q "$PBS_DATASTORE_PATH" || die "datastore path is not a mountpoint: $PBS_DATASTORE_PATH"

  local ds_path
  ds_path="$(proxmox-backup-manager datastore show "$PBS_DATASTORE" --output-format json | jq -r '.path // empty')"
  [[ "$ds_path" == "$PBS_DATASTORE_PATH" ]] \
    || die "PBS datastore path mismatch: configured=${ds_path:-unknown}, expected=$PBS_DATASTORE_PATH"

  if [[ -n "${PBS_DATASTORE_UUID:-}" ]]; then
    local mounted_uuid
    mounted_uuid="$(findmnt -rn -M "$PBS_DATASTORE_PATH" -o UUID 2>/dev/null | head -n1)"
    [[ "$mounted_uuid" == "$PBS_DATASTORE_UUID" ]] \
      || die "datastore UUID mismatch: mounted=${mounted_uuid:-unknown}, expected=$PBS_DATASTORE_UUID"
  fi

  log "datastore mount and PBS configuration are correct"
}

check_nas_mount() {
  CURRENT_STAGE="nas-preflight"
  [[ -d "$NAS_MOUNT" ]] || die "NAS mount directory does not exist: $NAS_MOUNT"
  ls -la "$NAS_MOUNT" >/dev/null

  local mount_info fstype
  mount_info="$(findmnt -rn -T "$NAS_MOUNT" -o SOURCE,TARGET,FSTYPE 2>/dev/null | head -n1)"
  [[ -n "$mount_info" ]] || die "NAS path is not backed by a mounted filesystem: $NAS_MOUNT"
  fstype="$(awk '{print $3}' <<<"$mount_info")"

  if [[ -n "${NAS_EXPECTED_FSTYPE_REGEX:-}" ]]; then
    [[ "$fstype" =~ $NAS_EXPECTED_FSTYPE_REGEX ]] \
      || die "NAS filesystem type '$fstype' does not match '$NAS_EXPECTED_FSTYPE_REGEX'"
  fi

  local probe="${NAS_MOUNT}/.pbs-protection-write-test.$$"
  : >"$probe" || die "NAS mount is not writable: $NAS_MOUNT"
  rm -f "$probe"
  log "NAS mount ready: $mount_info"
}

check_smart() {
  CURRENT_STAGE="smart"
  [[ -e "$SMART_DEVICE" ]] || die "SMART device does not exist: $SMART_DEVICE"

  local output health grown nonmedium uncorrected temp
  output="$(smartctl -a "$SMART_DEVICE")"
  health="$(awk -F: '/SMART Health Status|SMART overall-health/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' <<<"$output")"
  [[ "$health" =~ (OK|PASSED) ]] || die "SMART health is not OK: ${health:-unknown}"

  grown="$(awk -F: '/Elements in grown defect list/ {gsub(/ /,"",$2); print $2; exit}' <<<"$output")"
  nonmedium="$(awk -F: '/Non-medium error count/ {gsub(/ /,"",$2); print $2; exit}' <<<"$output")"
  uncorrected="$(awk '/^(read:|write:|verify:)/ {sum += $NF} END {print sum+0}' <<<"$output")"
  temp="$(awk -F: '/Current Drive Temperature/ {gsub(/[^0-9]/,"",$2); print $2; exit}' <<<"$output")"

  [[ "${grown:-0}" =~ ^[0-9]+$ && "${grown:-0}" -le "${SMART_MAX_GROWN_DEFECTS:-0}" ]] \
    || die "SMART grown defect count is ${grown:-unknown}"
  [[ "${nonmedium:-0}" =~ ^[0-9]+$ && "${nonmedium:-0}" -le "${SMART_MAX_NON_MEDIUM_ERRORS:-0}" ]] \
    || die "SMART non-medium error count is ${nonmedium:-unknown}"
  [[ "$uncorrected" -le "${SMART_MAX_UNCORRECTED_ERRORS:-0}" ]] \
    || die "SMART uncorrected error count is $uncorrected"

  if [[ -n "${temp:-}" && "$temp" -ge "${SMART_FAIL_TEMP_C:-55}" ]]; then
    die "drive temperature ${temp}C exceeds fail threshold ${SMART_FAIL_TEMP_C:-55}C"
  elif [[ -n "${temp:-}" && "$temp" -ge "${SMART_WARN_TEMP_C:-48}" ]]; then
    warn "drive temperature is ${temp}C"
  fi

  log "SMART OK: health=${health}, temp=${temp:-unknown}C, grown=${grown:-0}, non-medium=${nonmedium:-0}, uncorrected=${uncorrected}"
}

check_kernel_storage_errors() {
  CURRENT_STAGE="kernel-errors"
  local since_epoch pattern matches
  since_epoch="$(jq -r '.completed_epoch // empty' "${STATE_DIR}/last-success.json" 2>/dev/null || true)"
  [[ "$since_epoch" =~ ^[0-9]+$ ]] || since_epoch="$(( $(epoch_now) - ${KERNEL_ERROR_LOOKBACK_HOURS:-36} * 3600 ))"

  pattern='I/O error|Buffer I/O|blk_update_request|EXT4-fs error|medium error|uncorrected|mpt[23]sas.*(reset|fault|timeout)|scsi.*(abort|timeout|offline)|sas.*timeout'
  matches="$(journalctl -k --since "@${since_epoch}" --no-pager 2>/dev/null | grep -Eai "$pattern" || true)"
  if [[ -n "$matches" ]]; then
    printf '%s\n' "$matches" >>"$CURRENT_LOG"
    die "kernel storage-error patterns were found since the previous successful promotion"
  fi
  log "no kernel storage-error patterns found"
}

snapshot_json() {
  local ns="$1" group="$2"
  proxmox-backup-client snapshot list "$group" \
    --repository "$PBS_REPOSITORY" \
    --ns "$ns" \
    --output-format json
}

check_expected_backups() {
  local require_verified="${1:-0}"
  CURRENT_STAGE="$([[ "$require_verified" == "1" ]] && echo expected-verified || echo expected-recent)"

  local default_age failures=0 ns group max_age js latest now age verification
  default_age="$(jq -r '.default_max_age_hours // 36' "$EXPECTED_BACKUPS_FILE")"
  now="$(epoch_now)"

  while IFS=$'\t' read -r ns group max_age; do
    [[ -n "$ns" && -n "$group" ]] || continue
    max_age="${max_age:-$default_age}"

    if ! js="$(snapshot_json "$ns" "$group" 2>>"$CURRENT_LOG")"; then
      warn "cannot list expected group [$ns]:$group"
      failures=$((failures + 1))
      continue
    fi

    latest="$(jq '[.[] | (."backup-time" // .backup_time // 0)] | max // 0' <<<"$js")"
    if [[ "$latest" -eq 0 ]]; then
      warn "expected group has no snapshots: [$ns]:$group"
      failures=$((failures + 1))
      continue
    fi

    age=$(( (now - latest) / 3600 ))
    if (( age > max_age )); then
      warn "expected group is stale: [$ns]:$group age=${age}h max=${max_age}h"
      failures=$((failures + 1))
      continue
    fi

    if [[ "$require_verified" == "1" ]]; then
      verification="$(jq -r --argjson latest "$latest" '
        [.[] | select((."backup-time" // .backup_time // 0) == $latest)][0]
        | (.verification.state // .verification_state // "")
        | ascii_downcase' <<<"$js")"
      if [[ "$verification" != "ok" ]]; then
        warn "latest expected snapshot is not verified OK: [$ns]:$group state=${verification:-missing}"
        failures=$((failures + 1))
        continue
      fi
    fi

    log "expected group OK: [$ns]:$group age=${age}h$([[ "$require_verified" == "1" ]] && echo ' verified=ok')"
  done < <(
    jq -r --argjson default_age "$default_age" '
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

  [[ "$failures" -eq 0 ]] || die "$failures expected backup group check(s) failed"
}

run_promotion_verification() {
  CURRENT_STAGE="verify"
  wait_for_pbs_idle
  log "running PBS verification job: $PROMOTION_VERIFY_JOB"
  timeout "${VERIFY_TIMEOUT_SEC:-86400}" \
    proxmox-backup-manager verify-job run "$PROMOTION_VERIFY_JOB" \
    >>"$CURRENT_LOG" 2>&1
  wait_for_pbs_idle
  check_expected_backups 1
  log "promotion verification gate passed"
}

sync_nas() {
  CURRENT_STAGE="nas-sync"
  install -d -o root -g root -m 0750 "$NAS_DEST"
  local -a args
  mapfile -t args < <(rclone_common_args)
  log "syncing verified datastore to NAS: $PBS_DATASTORE_PATH -> $NAS_DEST"
  rclone sync "$PBS_DATASTORE_PATH" "$NAS_DEST" \
    "${args[@]}" --log-file "$CURRENT_LOG" --log-level INFO

  CURRENT_STAGE="nas-check"
  local combined="${STATE_DIR}/nas-check-${CYCLE_ID}.txt"
  local -a check_args
  mapfile -t check_args < <(rclone_check_args "${NAS_CHECK_MODE:-size-only}" "$combined")
  log "checking NAS mirror (${NAS_CHECK_MODE:-size-only})"
  rclone check "$PBS_DATASTORE_PATH" "$NAS_DEST" "${check_args[@]}" \
    --log-file "$CURRENT_LOG" --log-level INFO
}

sync_s3() {
  CURRENT_STAGE="s3-sync"
  local -a args
  mapfile -t args < <(rclone_common_args)
  log "syncing promoted NAS generation to S3: $NAS_DEST -> $S3_DEST"
  rclone sync "$NAS_DEST" "$S3_DEST" \
    "${args[@]}" --log-file "$CURRENT_LOG" --log-level INFO

  if [[ "${S3_CHECK_ENABLED:-1}" == "1" ]]; then
    CURRENT_STAGE="s3-check"
    local combined="${STATE_DIR}/s3-check-${CYCLE_ID}.txt"
    local -a check_args
    mapfile -t check_args < <(rclone_check_args "${S3_CHECK_MODE:-size-only}" "$combined")
    log "checking S3 mirror (${S3_CHECK_MODE:-size-only})"
    rclone check "$NAS_DEST" "$S3_DEST" "${check_args[@]}" \
      --log-file "$CURRENT_LOG" --log-level INFO
  fi
}

archive_safe_config() {
  [[ "${CONFIG_ARCHIVE_ENABLED:-1}" == "1" ]] || {
    log "safe configuration archive disabled"
    return 0
  }
  CURRENT_STAGE="config-archive"
  log "creating safe PBS configuration archive"
  /usr/local/sbin/pbs-protection-config-archive >>"$CURRENT_LOG" 2>&1
}

write_promotion_markers() {
  CURRENT_STAGE="promotion-commit"
  local completed completed_epoch marker local_success nas_marker
  completed="$(utc_now)"
  completed_epoch="$(epoch_now)"
  marker="${STATE_DIR}/promotion-${CYCLE_ID}.json"
  local_success="${STATE_DIR}/last-success.json"

  jq -n \
    --arg cycle "$CYCLE_ID" \
    --arg datastore "$PBS_DATASTORE" \
    --arg completed "$completed" \
    --argjson completed_epoch "$completed_epoch" \
    --arg nas "$NAS_DEST" \
    --arg s3 "$S3_DEST" \
    --arg log "$CURRENT_LOG" \
    '{cycle:$cycle,status:"complete",datastore:$datastore,completed:$completed,completed_epoch:$completed_epoch,verification:"OK",nas_sync:"OK",nas_check:"OK",s3_sync:"OK",nas:$nas,s3:$s3,log:$log}' \
    >"$marker"
  chmod 0600 "$marker"

  nas_marker="${NAS_PROMOTION_MARKER:-$(dirname "$NAS_DEST")/promotion.json}"
  install -D -o root -g root -m 0640 "$marker" "$nas_marker"

  if [[ -n "${S3_PROMOTION_MARKER:-}" ]]; then
    rclone copyto "$marker" "$S3_PROMOTION_MARKER" \
      --config "$RCLONE_CONF" --retries "${RCLONE_RETRIES:-5}" \
      --log-file "$CURRENT_LOG" --log-level INFO
  fi

  cat "$marker" | json_write_atomic "$local_success"
  rm -f "${STATE_DIR}/last-attempt.json"
  SUCCESS_MARKER_WRITTEN=1
  log "promotion committed successfully"
}

run_prune_and_gc() {
  CURRENT_STAGE="post-promotion"
  local job
  if [[ -n "${PRUNE_JOB_IDS:-}" ]]; then
    for job in $PRUNE_JOB_IDS; do
      log "running prune job: $job"
      proxmox-backup-manager prune-job run "$job" >>"$CURRENT_LOG" 2>&1
    done
  else
    log "no prune jobs configured for orchestrated execution"
  fi

  if [[ "${GC_ENABLED:-1}" == "1" ]]; then
    local weekday
    weekday="$(date +%u)"
    if [[ "$FORCE_GC" == "1" || "$weekday" == "${GC_WEEKDAY:-7}" ]]; then
      wait_for_pbs_idle
      log "running garbage collection for $PBS_DATASTORE"
      proxmox-backup-manager garbage-collection start "$PBS_DATASTORE" \
        >>"$CURRENT_LOG" 2>&1
    else
      log "GC deferred: today is weekday ${weekday}; configured weekday is ${GC_WEEKDAY:-7}"
    fi
  fi
}

main() {
  require_root
  for cmd in jq flock mountpoint findmnt journalctl smartctl openssl \
             proxmox-backup-manager proxmox-backup-client rclone timeout; do
    require_cmd "$cmd"
  done
  acquire_lock

  log "starting PBS protection cycle ${CYCLE_ID}"
  validate_config
  check_datastore_mount
  check_nas_mount
  check_smart
  check_kernel_storage_errors
  wait_for_pbs_idle
  check_expected_backups 0

  if [[ "$CHECK_ONLY" == "1" ]]; then
    CURRENT_STAGE="complete"
    log "configuration and preflight checks passed"
    return 0
  fi

  run_promotion_verification

  if [[ "$DRY_RUN" == "1" ]]; then
    CURRENT_STAGE="complete"
    log "dry run complete: verification passed; NAS/S3/prune/GC were skipped"
    return 0
  fi

  wait_for_pbs_idle
  set_datastore_read_only
  sync_nas
  clear_datastore_maintenance
  sync_s3
  archive_safe_config
  write_promotion_markers
  run_prune_and_gc

  CURRENT_STAGE="complete"
  local elapsed=$(( $(epoch_now) - START_EPOCH ))
  log "PBS protection cycle completed in $(hms "$elapsed")"
  notify "✅ <b>PBS protection cycle complete</b>

Cycle: <code>$(html_escape "$CYCLE_ID")</code>
Datastore: <b>$(html_escape "$PBS_DATASTORE")</b>
Elapsed: <b>$(hms "$elapsed")</b>
NAS: <code>$(html_escape "$NAS_DEST")</code>
S3: <code>$(html_escape "$S3_DEST")</code>"
}

main "$@"
