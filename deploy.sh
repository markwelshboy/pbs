#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${PBS_DEPLOY_TARGET:-pbs-mini-direct}"
declare -a INSTALL_ARGS=()

usage() {
  cat <<'USAGE'
Usage: ./deploy.sh [target] [installer options]

Examples:
  ./deploy.sh pbs-mini-direct
  ./deploy.sh pbs-mini-direct --install-deps
  ./deploy.sh pbs-mini-direct --disable-legacy --enable

The local working tree is streamed to /tmp on the target, then install.sh runs
there. Private configuration and credentials are never copied from the repo.
USAGE
}

if [[ $# -gt 0 && "$1" != --* ]]; then
  TARGET="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-deps|--rotate-reader-token|--disable-legacy|--enable)
      INSTALL_ARGS+=("$1")
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

REMOTE_DIR="/tmp/pbs-protection-deploy.$(date +%s)"
printf 'Deploying to %s\n' "$TARGET"

tar \
  --exclude='.git' \
  --exclude='*.secret' \
  -C "$ROOT_DIR" -czf - . \
| ssh -o BatchMode=yes "$TARGET" \
    "install -d -m 0700 '$REMOTE_DIR' && tar -xzf - -C '$REMOTE_DIR'"

quoted_args=""
for arg in "${INSTALL_ARGS[@]}"; do
  printf -v quoted_args '%s %q' "$quoted_args" "$arg"
done

ssh -t "$TARGET" \
  "cd '$REMOTE_DIR' && ./install.sh${quoted_args}; rc=\$?; rm -rf '$REMOTE_DIR'; exit \$rc"
