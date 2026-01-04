#!/usr/bin/env bash
set -euo pipefail

# Deploy local add-on folder to HAOS "local add-ons" share (/addons/<slug>)
# BusyBox-safe, avoids symlinks (rsync -aL).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST=""
SSH_USER="root"
SSH_PORT="22"

ADDON_DIR="$ROOT/op25_haos_experiment"
SLUG="op25_haos_experiment"
REMOTE_BASE="/addons"

DO_RELOAD=0
DO_RESTART_SUPERVISOR=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/haos.sh deploy --host <ip> [options]

Options:
  --host <ip>                 HAOS host IP (required)
  --ssh-user <user>           SSH user (default: root)
  --ssh-port <port>           SSH port (default: 22)
  --addon-dir <path>          Local add-on dir (default: ./op25_haos_experiment)
  --slug <slug>               Add-on slug/folder (default: op25_haos_experiment)
  --remote-base <path>        Remote base dir (default: /addons)   (do NOT use /addons/local)
  --reload                    Reload add-on store
  --restart-supervisor        Restart supervisor (forces rescan)

Example:
  ./scripts/haos.sh deploy --host 192.168.1.222 --reload --restart-supervisor
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

ssh_cmd() {
  ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" "$@"
}

main() {
  [[ $# -ge 1 ]] || { usage; exit 2; }
  local cmd="$1"; shift

  case "$cmd" in
    deploy)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --host) HOST="${2:-}"; shift 2 ;;
          --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
          --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
          --addon-dir) ADDON_DIR="${2:-}"; shift 2 ;;
          --slug) SLUG="${2:-}"; shift 2 ;;
          --remote-base) REMOTE_BASE="${2:-}"; shift 2 ;;
          --reload) DO_RELOAD=1; shift ;;
          --restart-supervisor) DO_RESTART_SUPERVISOR=1; shift ;;
          -h|--help) usage; exit 0 ;;
          *) die "Unknown arg: $1" ;;
        esac
      done

      [[ -n "$HOST" ]] || die "--host is required"
      [[ -d "$ADDON_DIR" ]] || die "Missing local add-on dir: $ADDON_DIR"
      [[ -f "$ADDON_DIR/config.yaml" ]] || die "Missing $ADDON_DIR/config.yaml"
      command -v rsync >/dev/null 2>&1 || die "rsync is required locally"

      local dest="${REMOTE_BASE%/}/${SLUG}"

      echo "[1/3] Preparing remote folder: ${dest}"
      ssh_cmd "mkdir -p '$dest'"

      echo "[2/3] Syncing add-on (dereference symlinks: rsync -aL --delete)"
      rsync -aL --delete \
        -e "ssh -p $SSH_PORT -o StrictHostKeyChecking=accept-new" \
        "$ADDON_DIR/" "${SSH_USER}@${HOST}:${dest}/"

      echo "[3/3] Optional supervisor actions"
      if [[ "$DO_RELOAD" -eq 1 ]]; then
        ssh_cmd "ha addons reload >/dev/null 2>&1 || ha supervisor reload >/dev/null 2>&1 || true"
      fi
      if [[ "$DO_RESTART_SUPERVISOR" -eq 1 ]]; then
        ssh_cmd "ha supervisor restart"
      fi

      echo "Done."
      echo "Try install:"
      echo "  ssh ${SSH_USER}@${HOST} \"ha addons install local_${SLUG} || ha addons install ${SLUG}\""
      ;;
    *)
      usage; exit 2 ;;
  esac
}

main "$@"
