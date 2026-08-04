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
for cmd in tar rclone proxmox-backup-manager; do require_cmd "$cmd"; done

ARCHIVE_ID="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d /var/tmp/pbs-safe-config.XXXXXX)"
ARCHIVE_DIR="${STATE_DIR}/config-archives"
ARCHIVE="${ARCHIVE_DIR}/pbs-mini-safe-config-${ARCHIVE_ID}.tar.gz"
trap 'rm -rf "$WORK"' EXIT

install -d -o root -g root -m 0700 "$ARCHIVE_DIR"
install -d -o root -g root -m 0700 "$WORK/rootfs"

copy_safe() {
  local source="$1"
  [[ -e "$source" ]] || return 0
  local destination="${WORK}/rootfs${source}"
  install -d -m 0700 "$(dirname "$destination")"
  cp -a "$source" "$destination"
}

# PBS configuration without authentication secrets or private keys.
for file in \
  /etc/proxmox-backup/acl.cfg \
  /etc/proxmox-backup/datastore.cfg \
  /etc/proxmox-backup/notifications.cfg \
  /etc/proxmox-backup/notifications-priv.cfg \
  /etc/proxmox-backup/prune.cfg \
  /etc/proxmox-backup/sync.cfg \
  /etc/proxmox-backup/user.cfg \
  /etc/proxmox-backup/verification.cfg \
  /etc/network/interfaces \
  /etc/fstab \
  /etc/pbs-protection/expected-backups.json; do
  # notifications-priv may contain endpoint secrets, so exclude it explicitly.
  [[ "$file" == "/etc/proxmox-backup/notifications-priv.cfg" ]] && continue
  copy_safe "$file"
done

for path in \
  /etc/systemd/system/pbs-protection-cycle.service \
  /etc/systemd/system/pbs-protection-cycle.timer \
  /etc/systemd/system/pbs-protection-monthly-verify.service \
  /etc/systemd/system/pbs-protection-monthly-verify.timer \
  /usr/local/sbin/pbs-protection-cycle \
  /usr/local/sbin/pbs-protection-discover \
  /usr/local/sbin/pbs-protection-monthly-verify \
  /usr/local/sbin/pbs-protection-status \
  /usr/local/sbin/pbs-protection-config-archive \
  /usr/local/lib/pbs-protection; do
  copy_safe "$path"
done

install -d -m 0700 "$WORK/rootfs/var/lib/pbs-protection-metadata"
proxmox-backup-manager versions --verbose \
  >"$WORK/rootfs/var/lib/pbs-protection-metadata/versions.txt" 2>&1 || true
lsblk -a -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINTS,MODEL,SERIAL \
  >"$WORK/rootfs/var/lib/pbs-protection-metadata/lsblk.txt" 2>&1 || true
findmnt -A >"$WORK/rootfs/var/lib/pbs-protection-metadata/findmnt.txt" 2>&1 || true
smartctl -a "${SMART_DEVICE}" \
  >"$WORK/rootfs/var/lib/pbs-protection-metadata/smart.txt" 2>&1 || true

cat >"$WORK/README.txt" <<'NOTE'
PBS safe configuration archive
==============================

This archive intentionally excludes passwords, API-token secrets, rclone
credentials, Telegram credentials, PBS shadow/token files, SSH private keys,
and TLS/private authentication keys.

Restore selectively after a fresh PBS installation. Review network, fstab,
datastore and identity-specific configuration before applying it.
NOTE

tar -C "$WORK" -czf "$ARCHIVE" README.txt rootfs
chmod 0600 "$ARCHIVE"

if [[ -n "${NAS_CONFIG_DEST:-}" ]]; then
  install -d -o root -g root -m 0750 "$NAS_CONFIG_DEST"
  install -o root -g root -m 0640 "$ARCHIVE" "$NAS_CONFIG_DEST/$(basename "$ARCHIVE")"
fi

if [[ -n "${S3_CONFIG_DEST:-}" ]]; then
  rclone copyto "$ARCHIVE" "${S3_CONFIG_DEST%/}/$(basename "$ARCHIVE")" \
    --config "$RCLONE_CONF" --retries "${RCLONE_RETRIES:-5}"
fi

# Local/NAS archives are tiny, but keep the count bounded.
keep="${CONFIG_ARCHIVE_KEEP_LOCAL:-30}"
mapfile -t old_local < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name 'pbs-mini-safe-config-*.tar.gz' -printf '%T@ %p\n' | sort -nr | awk -v keep="$keep" 'NR>keep {$1=""; sub(/^ /,""); print}')
((${#old_local[@]} == 0)) || rm -f -- "${old_local[@]}"

if [[ -n "${NAS_CONFIG_DEST:-}" && -d "$NAS_CONFIG_DEST" ]]; then
  keep="${CONFIG_ARCHIVE_KEEP_NAS:-30}"
  mapfile -t old_nas < <(find "$NAS_CONFIG_DEST" -maxdepth 1 -type f -name 'pbs-mini-safe-config-*.tar.gz' -printf '%T@ %p\n' | sort -nr | awk -v keep="$keep" 'NR>keep {$1=""; sub(/^ /,""); print}')
  ((${#old_nas[@]} == 0)) || rm -f -- "${old_nas[@]}"
fi

printf '%s\n' "$ARCHIVE"
