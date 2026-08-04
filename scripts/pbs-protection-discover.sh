#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="/usr/local/lib/pbs-protection/common.sh"
[[ -r "$COMMON_LIB" ]] || COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/common.sh
source "$COMMON_LIB"

OUTPUT="/etc/pbs-protection/expected-backups.discovered.json"
DEFAULT_MAX_AGE_HOURS=""

usage() {
  cat <<'USAGE'
Usage: pbs-protection-discover [--output PATH] [--max-age-hours N]

Discovers all currently visible VM, CT, and host backup groups in each configured
PBS namespace. It writes a review-required expected-backups JSON file; it does
not replace the active policy automatically.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    --max-age-hours) DEFAULT_MAX_AGE_HOURS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

load_config
ensure_runtime_dirs
require_root
require_cmd jq
require_cmd proxmox-backup-client
pbs_client_env

DEFAULT_MAX_AGE_HOURS="${DEFAULT_MAX_AGE_HOURS:-${DEFAULT_MAX_AGE_HOURS_CONFIG:-36}}"
read -r -a namespaces <<<"${PBS_NAMESPACES:-r630 nuc-pve beelink-pve mini-pve}"

CURRENT_STAGE="discover"
log "discovering backup groups from namespaces: ${namespaces[*]}"

result='{"reviewed":false,"default_max_age_hours":'"${DEFAULT_MAX_AGE_HOURS}"',"namespaces":{}}'

for ns in "${namespaces[@]}"; do
  log "reading namespace ${ns}"
  snapshots="$(
    proxmox-backup-client snapshot list \
      --repository "$PBS_REPOSITORY" \
      --ns "$ns" \
      --output-format json
  )"

  groups="$(
    jq '[
      .[]
      | {
          type: (."backup-type" // .backup_type // ""),
          id: (."backup-id" // .backup_id // "")
        }
      | select(.type != "" and .id != "")
      | (.type + "/" + .id)
    ] | unique | sort' <<<"$snapshots"
  )"

  result="$(
    jq --arg ns "$ns" --argjson groups "$groups" \
      '.namespaces[$ns] = {required_groups: $groups}' <<<"$result"
  )"
done

install -d -o root -g root -m 0700 "$(dirname "$OUTPUT")"
printf '%s\n' "$result" | jq . >"$OUTPUT"
chmod 0600 "$OUTPUT"

log "wrote discovery file: $OUTPUT"
log "review it, set reviewed=true, then install it as /etc/pbs-protection/expected-backups.json"
