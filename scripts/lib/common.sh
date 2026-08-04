#!/usr/bin/env bash
# Shared helpers for PBS protection scripts.

set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

: "${CONFIG_FILE:=/etc/pbs-protection/pbs-protection.env}"
: "${STATE_DIR:=/var/lib/pbs-protection}"
: "${LOG_DIR:=/var/log/pbs-protection}"
: "${LOCK_FILE:=/run/lock/pbs-protection-cycle.lock}"

CURRENT_STAGE="startup"
CURRENT_LOG=""
MAINTENANCE_SET=0

load_config() {
  [[ -r "$CONFIG_FILE" ]] || {
    printf 'ERROR: configuration file is missing or unreadable: %s\n' "$CONFIG_FILE" >&2
    exit 2
  }
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
}

ensure_runtime_dirs() {
  install -d -o root -g root -m 0700 "$STATE_DIR"
  install -d -o root -g root -m 0750 "$LOG_DIR"
  install -d -o root -g root -m 0755 "$(dirname "$LOCK_FILE")"
}

utc_now() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
epoch_now() { date +%s; }

log() {
  local line="[$(date '+%F %T')] [$CURRENT_STAGE] $*"
  printf '%s\n' "$line"
  [[ -n "$CURRENT_LOG" ]] && printf '%s\n' "$line" >>"$CURRENT_LOG"
}

warn() {
  log "WARN: $*" >&2
}

die() {
  log "ERROR: $*" >&2
  return 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

json_write_atomic() {
  local destination="$1"
  local tmp
  tmp="$(mktemp "${destination}.tmp.XXXXXX")"
  cat >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$destination"
}

json_field() {
  local file="$1" expr="$2" default="${3:-}"
  [[ -r "$file" ]] || { printf '%s\n' "$default"; return 0; }
  jq -r "$expr // empty" "$file" 2>/dev/null | awk 'NF { print; exit }' || printf '%s\n' "$default"
}

human_bytes() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " "); i=1;
    while (b >= 1024 && i < 5) { b/=1024; i++ }
    printf "%.2f %s", b, u[i]
  }'
}

hms() {
  local seconds="${1:-0}"
  printf '%02d:%02d:%02d' "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
}

html_escape() {
  local s="${1:-}"
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

notify() {
  local message="$1"
  [[ "${TELEGRAM_ENABLE:-0}" == "1" ]] || return 0
  [[ -x "${TELEGRAM_SEND_BIN:-/usr/bin/telegram-send}" ]] || return 0
  [[ -r "${TELEGRAM_CFG:-/root/.config/telegram-send.conf}" ]] || return 0
  "${TELEGRAM_SEND_BIN:-/usr/bin/telegram-send}" \
    --config "${TELEGRAM_CFG:-/root/.config/telegram-send.conf}" \
    --format html "$message" >/dev/null 2>&1 || true
}

pbs_fingerprint() {
  if [[ -n "${PBS_FINGERPRINT:-}" && "${PBS_FINGERPRINT}" != "auto" ]]; then
    printf '%s\n' "$PBS_FINGERPRINT"
    return 0
  fi

  local cert="${PBS_CERT_FILE:-/etc/proxmox-backup/proxy.pem}"
  [[ -r "$cert" ]] || die "cannot determine PBS fingerprint; certificate missing: $cert"
  openssl x509 -in "$cert" -noout -fingerprint -sha256 \
    | awk -F= '{print tolower($2)}'
}

pbs_client_env() {
  [[ -n "${PBS_REPOSITORY:-}" ]] || die "PBS_REPOSITORY is not configured"
  [[ -n "${PBS_PASSWORD_FILE:-}" ]] || die "PBS_PASSWORD_FILE is not configured"
  [[ -r "$PBS_PASSWORD_FILE" ]] || die "PBS password/token file is unreadable: $PBS_PASSWORD_FILE"
  export PBS_PASSWORD_FILE
  export PBS_FINGERPRINT="$(pbs_fingerprint)"
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another PBS protection operation is already active"
}

set_datastore_read_only() {
  [[ "$MAINTENANCE_SET" -eq 0 ]] || return 0
  log "entering read-only maintenance mode for datastore ${PBS_DATASTORE}"
  proxmox-backup-manager datastore update "$PBS_DATASTORE" \
    --maintenance-mode 'type=read-only,message=PBS protection promotion in progress'
  MAINTENANCE_SET=1
}

clear_datastore_maintenance() {
  [[ "$MAINTENANCE_SET" -eq 1 ]] || return 0
  log "clearing datastore maintenance mode"
  proxmox-backup-manager datastore update "$PBS_DATASTORE" \
    --delete maintenance-mode || true
  MAINTENANCE_SET=0
}

running_relevant_tasks_json() {
  proxmox-backup-manager task list --output-format json 2>/dev/null \
    | jq '[.[] | select(
        ((.["worker-type"] // .worker_type // .type // "") | tostring
          | test("backup|verify|garbage|prune|sync"; "i"))
      )]'
}

wait_for_pbs_idle() {
  local timeout="${PBS_IDLE_TIMEOUT_SEC:-7200}"
  local sleep_sec="${PBS_IDLE_POLL_SEC:-15}"
  local start count
  start="$(epoch_now)"

  while true; do
    count="$(running_relevant_tasks_json | jq 'length')"
    if [[ "$count" -eq 0 ]]; then
      log "PBS has no running backup/verify/prune/GC/sync tasks"
      return 0
    fi

    if (( $(epoch_now) - start >= timeout )); then
      running_relevant_tasks_json | jq . >&2 || true
      die "timed out waiting for PBS to become idle (${count} relevant task(s) remain)"
      return 1
    fi

    log "PBS is busy (${count} relevant task(s)); waiting ${sleep_sec}s"
    sleep "$sleep_sec"
  done
}

rclone_common_args() {
  printf '%s\n' \
    --config "${RCLONE_CONF:-/root/.config/rclone/rclone.conf}" \
    --transfers "${RCLONE_TRANSFERS:-8}" \
    --checkers "${RCLONE_CHECKERS:-16}" \
    --fast-list \
    --delete-after \
    --retries "${RCLONE_RETRIES:-5}" \
    --low-level-retries "${RCLONE_LOW_LEVEL_RETRIES:-10}" \
    --contimeout "${RCLONE_CONTIMEOUT:-30s}" \
    --timeout "${RCLONE_TIMEOUT:-1h}" \
    --stats "${RCLONE_STATS_INTERVAL:-60s}" \
    --stats-one-line \
    --stats-log-level NOTICE
}

rclone_check_args() {
  local mode="${1:-size-only}"
  local -a args=(
    --config "${RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
    --checkers "${RCLONE_CHECKERS:-16}"
    --one-way
    --combined "${2:-/dev/null}"
  )
  [[ "$mode" == "size-only" ]] && args+=(--size-only)
  printf '%s\n' "${args[@]}"
}
