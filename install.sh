#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENABLE=0
INSTALL_DEPS=0
ROTATE_READER_TOKEN=0
DISABLE_LEGACY=0

usage() {
  cat <<'USAGE'
Usage: ./install.sh [options]

Options:
  --install-deps         Install jq, rclone and smartmontools with apt.
  --rotate-reader-token  Replace the dedicated local audit token.
  --disable-legacy       Disable the old independent PBS mirror/GC/report timers.
  --enable               Enable timers after a successful full configuration check.
  -h, --help             Show this help.

The installer never overwrites real configuration files in /etc/pbs-protection.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-deps) INSTALL_DEPS=1; shift ;;
    --rotate-reader-token) ROTATE_READER_TOKEN=1; shift ;;
    --disable-legacy) DISABLE_LEGACY=1; shift ;;
    --enable) ENABLE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'ERROR: run as root' >&2; exit 1; }
command -v proxmox-backup-manager >/dev/null 2>&1 \
  || { echo 'ERROR: this does not appear to be a Proxmox Backup Server' >&2; exit 1; }

if [[ "$INSTALL_DEPS" == "1" ]]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y jq rclone smartmontools openssl
fi

for cmd in jq rclone smartctl openssl; do
  command -v "$cmd" >/dev/null 2>&1 \
    || { echo "ERROR: missing dependency: $cmd (rerun with --install-deps)" >&2; exit 1; }
done

install -d -o root -g root -m 0755 /usr/local/lib/pbs-protection
install -d -o root -g root -m 0700 /etc/pbs-protection
install -d -o root -g root -m 0700 /var/lib/pbs-protection
install -d -o root -g root -m 0750 /var/log/pbs-protection

install -o root -g root -m 0640 \
  "$ROOT_DIR/scripts/lib/common.sh" \
  /usr/local/lib/pbs-protection/common.sh

install -o root -g root -m 0750 \
  "$ROOT_DIR/scripts/pbs-protection-cycle.sh" \
  /usr/local/sbin/pbs-protection-cycle
install -o root -g root -m 0750 \
  "$ROOT_DIR/scripts/pbs-protection-discover.sh" \
  /usr/local/sbin/pbs-protection-discover
install -o root -g root -m 0750 \
  "$ROOT_DIR/scripts/pbs-protection-monthly-verify.sh" \
  /usr/local/sbin/pbs-protection-monthly-verify
install -o root -g root -m 0750 \
  "$ROOT_DIR/scripts/pbs-protection-status.sh" \
  /usr/local/sbin/pbs-protection-status
install -o root -g root -m 0750 \
  "$ROOT_DIR/scripts/pbs-protection-config-archive.sh" \
  /usr/local/sbin/pbs-protection-config-archive

for unit in "$ROOT_DIR"/systemd/*.service "$ROOT_DIR"/systemd/*.timer; do
  install -o root -g root -m 0644 "$unit" "/etc/systemd/system/$(basename "$unit")"
done

if [[ ! -e /etc/pbs-protection/pbs-protection.env ]]; then
  install -o root -g root -m 0600 \
    "$ROOT_DIR/config/pbs-protection.env.example" \
    /etc/pbs-protection/pbs-protection.env
  echo 'Created /etc/pbs-protection/pbs-protection.env from the example.'
else
  echo 'Preserved existing /etc/pbs-protection/pbs-protection.env.'
fi

if [[ ! -e /etc/pbs-protection/expected-backups.json ]]; then
  install -o root -g root -m 0600 \
    "$ROOT_DIR/config/expected-backups.json.example" \
    /etc/pbs-protection/expected-backups.json
  echo 'Created review-required /etc/pbs-protection/expected-backups.json.'
else
  echo 'Preserved existing /etc/pbs-protection/expected-backups.json.'
fi

# shellcheck disable=SC1091
source /etc/pbs-protection/pbs-protection.env
: "${PBS_DATASTORE:=pbs-sas}"
: "${PROMOTION_VERIFY_JOB:=pbs-sas-promotion}"
: "${MONTHLY_VERIFY_JOB:=pbs-sas-monthly-full}"
: "${PBS_PASSWORD_FILE:=/etc/pbs-protection/reader-token.secret}"

READER_USER='pbs-protection@pbs'
READER_TOKEN_NAME='reader'
READER_AUTH_ID="${READER_USER}!${READER_TOKEN_NAME}"

generate_reader_token() {
  local raw json secret
  raw="$(proxmox-backup-manager user generate-token \
    "$READER_USER" "$READER_TOKEN_NAME" \
    --comment 'Local read-only token for PBS protection gates')"

  json="$(printf '%s\n' "$raw" | sed -n '/Result:/,$p' | sed '1s/^[^{]*//')"
  if ! jq -e . >/dev/null 2>&1 <<<"$json"; then
    echo 'ERROR: token was created, but its one-time secret could not be parsed.' >&2
    echo 'Delete/rotate the token before retrying:' >&2
    echo "  proxmox-backup-manager user delete-token '$READER_USER' '$READER_TOKEN_NAME'" >&2
    exit 1
  fi

  secret="$(jq -r '.value // empty' <<<"$json")"
  [[ -n "$secret" ]] || { echo 'ERROR: generated token JSON contained no value field' >&2; exit 1; }
  printf '%s\n' "$secret" >"$PBS_PASSWORD_FILE"
  chown root:root "$PBS_PASSWORD_FILE"
  chmod 0600 "$PBS_PASSWORD_FILE"
}

if ! proxmox-backup-manager user list --output-format json \
    | jq -e --arg user "$READER_USER" '.[] | select((.userid // .user) == $user)' >/dev/null; then
  proxmox-backup-manager user create "$READER_USER" \
    --comment 'Local audit user for PBS protection gates'
fi

token_exists=0
if proxmox-backup-manager user list-tokens "$READER_USER" --output-format json \
    | jq -e --arg token "$READER_AUTH_ID" '.[] | select((.tokenid // .id) == $token)' >/dev/null; then
  token_exists=1
fi

if [[ "$ROTATE_READER_TOKEN" == "1" && "$token_exists" == "1" ]]; then
  proxmox-backup-manager user delete-token "$READER_USER" "$READER_TOKEN_NAME"
  token_exists=0
  rm -f "$PBS_PASSWORD_FILE"
fi

if [[ "$token_exists" == "0" ]]; then
  generate_reader_token
elif [[ ! -s "$PBS_PASSWORD_FILE" ]]; then
  echo "ERROR: token $READER_AUTH_ID exists, but $PBS_PASSWORD_FILE is missing." >&2
  echo 'Rerun with --rotate-reader-token to create and save a new secret.' >&2
  exit 1
else
  echo "Preserved existing reader token and $PBS_PASSWORD_FILE."
fi

proxmox-backup-manager acl update "/datastore/${PBS_DATASTORE}" DatastoreAudit \
  --auth-id "$READER_USER"
proxmox-backup-manager acl update "/datastore/${PBS_DATASTORE}" DatastoreAudit \
  --auth-id "$READER_AUTH_ID"

ensure_verify_job() {
  local id="$1" ignore="$2" outdated="$3" comment="$4"
  if proxmox-backup-manager verify-job show "$id" >/dev/null 2>&1; then
    echo "Preserved existing verification job: $id"
  else
    proxmox-backup-manager verify-job create "$id" \
      --store "$PBS_DATASTORE" \
      --ignore-verified "$ignore" \
      --outdated-after "$outdated" \
      --max-depth 7 \
      --comment "$comment"
  fi
}

ensure_verify_job "$PROMOTION_VERIFY_JOB" true 30 \
  'Promotion gate: new backups and verification older than 30 days'
ensure_verify_job "$MONTHLY_VERIFY_JOB" false 30 \
  'Monthly full datastore verification'

systemctl daemon-reload

if [[ "$DISABLE_LEGACY" == "1" ]]; then
  legacy_units=(
    pbs-to-nas.timer pbs-to-s3.timer pbs-gc-guarded.timer
    pbs-drift-check.timer pbs-daily-report.timer
  )
  systemctl disable --now "${legacy_units[@]}" 2>/dev/null || true
  echo 'Disabled legacy independent PBS timers where present.'
fi

# Produce a discovery file for review, but never activate it automatically.
if /usr/local/sbin/pbs-protection-discover \
    --output /etc/pbs-protection/expected-backups.discovered.json; then
  echo 'Created /etc/pbs-protection/expected-backups.discovered.json for review.'
else
  echo 'WARNING: group discovery failed; inspect credentials/configuration.' >&2
fi

if [[ "$ENABLE" == "1" ]]; then
  /usr/local/sbin/pbs-protection-cycle --check
  systemctl enable --now pbs-protection-cycle.timer
  systemctl enable --now pbs-protection-monthly-verify.timer
  echo 'Enabled PBS protection timers.'
else
  echo
  echo 'Installed but left timers disabled.'
  echo 'Next steps:'
  echo '  1. Review /etc/pbs-protection/pbs-protection.env'
  echo '  2. Review expected-backups.discovered.json and install it as expected-backups.json'
  echo '  3. Set reviewed=true'
  echo '  4. Run: pbs-protection-cycle --check'
  echo '  5. Run: systemctl start pbs-protection-cycle.service'
  echo '  6. Enable timers after the first successful promotion'
fi
