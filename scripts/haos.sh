#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# HAOS helper for local add-on development (deploy / uninstall / logs / status)
# For rtl-haos and any similar HA add-on repo (reads slug from config.yaml).
# ==============================================================================

# ----------------------------- defaults / env ------------------------------
HA_HOST="${HA_HOST:-homeassistant.local}"
HA_USER="${HA_USER:-root}"
HA_PORT="${HA_PORT:-22}"
HA_KEY="${HA_KEY:-}"                  # optional identity file
HA_REMOTE_BASE="${HA_REMOTE_BASE:-/addons/local}"
HA_REMOTE_SHARE_BASE="${HA_REMOTE_SHARE_BASE:-/share}"
LOCAL_SHARE_DIR="${LOCAL_SHARE_DIR:-}" # optional (relative to repo root or absolute)

USE_MUX=1
DRY_RUN=0
YES=0
NO_HA=0

# ----------------------------- helpers ------------------------------------
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

die() { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }
note() { echo "${YELLOW}$*${NC}"; }
info() { echo "${BLUE}$*${NC}"; }
ok() { echo "${GREEN}$*${NC}"; }

usage() {
  cat <<EOF
Usage:
  ./scripts/haos.sh <command> [options]

Commands:
  deploy        Sync code to HAOS + (optional) rebuild/restart + (optional) show logs
  uninstall     Stop/uninstall add-on + remove remote add-on folder(s) (+ optional /share cleanup)
  clean         Remove remote add-on folder(s) only (no ha CLI)
  logs          Show logs (or -f)
  status        Show detected paths and add-on install status on HAOS

Options:
  --host <h>            HA hostname/IP (default: ${HA_HOST})
  --user <u>            SSH user (default: ${HA_USER})
  --port <p>            SSH port (default: ${HA_PORT})
  --key <path>          SSH identity file (or set HA_KEY)
  --no-mux              Disable SSH multiplexing
  --dry-run             Print actions (and rsync --dry-run)
  --yes                 Skip confirmation prompts (uninstall/clean)

Deploy options:
  --rebuild             If installed: ha addons rebuild
  --restart             Restart after rebuild/install
  --logs                Print logs after start/restart
  --no-ha               Deploy files only; skip ha CLI

Share/data options:
  --share <localdir>    Sync local folder to /share/<slug> (or --share-remote)
  --share-remote <dir>  Remote share path (default: /share/<slug>)
Uninstall options:
  --rm-share            Also remove remote share dir

Env vars supported:
  HA_HOST, HA_USER, HA_PORT, HA_KEY,
  HA_REMOTE_BASE, HA_REMOTE_SHARE_BASE, LOCAL_SHARE_DIR

Examples:
  ./scripts/haos.sh deploy --host 192.168.1.109 --rebuild --restart --logs
  ./scripts/haos.sh uninstall --host 192.168.1.109 --rm-share
  ./scripts/haos.sh status --host 192.168.1.109
EOF
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

confirm() {
  (( YES )) && return 0
  read -r -p "$1 [y/N] " ans
  [[ "${ans:-}" == "y" || "${ans:-}" == "Y" ]]
}

# Find repo root robustly
repo_root() {
  if command -v git >/dev/null 2>&1 && git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
  else
    cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
  fi
}

read_slug() {
  local root="$1"
  local cfg="$root/config.yaml"
  [[ -f "$cfg" ]] || die "config.yaml not found at repo root: $cfg"
  local slug
  slug="$(awk -F': *' '$1=="slug"{print $2}' "$cfg" | tr -d '"' | tr -d "'" | head -n1)"
  [[ -n "$slug" ]] || die "Could not read 'slug:' from $cfg"
  # safety
  [[ "$slug" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Slug '$slug' looks unsafe; refusing."
  echo "$slug"
}

# SSH options (array) + rsync ssh string
build_ssh() {
  local host="$1" user="$2" port="$3" key="$4" use_mux="$5"
  local ctrl="/tmp/haos-${host//./_}-${port}-${user}.sock"

  SSH_TARGET="${user}@${host}"
  SSH_OPTS=( -p "$port" -o StrictHostKeyChecking=accept-new )

  if [[ -n "$key" ]]; then
    SSH_OPTS+=( -i "$key" -o IdentitiesOnly=yes )
  fi

  if (( use_mux )); then
    SSH_OPTS+=( -o ControlMaster=auto -o ControlPersist=120s -o ControlPath="$ctrl" )
    SSH_CTRL_PATH="$ctrl"
  else
    SSH_CTRL_PATH=""
  fi
}

run_ssh() {
  if (( DRY_RUN )); then
    echo "[dry-run] ssh ${SSH_OPTS[*]} ${SSH_TARGET} $*"
    return 0
  fi
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"
}

run_rsync() {
  if (( DRY_RUN )); then
    rsync --dry-run "$@"
  else
    rsync "$@"
  fi
}

close_mux() {
  [[ -n "${SSH_CTRL_PATH:-}" ]] || return 0
  (( DRY_RUN )) && return 0
  ssh -o ControlPath="$SSH_CTRL_PATH" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
}

# ----------------------------- command impl --------------------------------
cmd_deploy() {
  local rebuild="$1" restart="$2" show_logs="$3"
  shift 3

  require_cmd ssh
  require_cmd rsync
  require_cmd awk

  local root slug
  root="$(repo_root)"
  slug="$(read_slug "$root")"

# Generate an untracked build marker so add-on runs can display vX.Y.Z+<sha> automatically.
# This is intentionally not written into config.yaml (Supervisor expects X.Y.Z there).
if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  local sha dirty
  sha="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || true)"
  dirty=""
  if ! git -C "$root" diff --quiet --ignore-submodules --; then
    dirty="-dirty"
  fi
  if [[ -n "$sha" ]]; then
    printf "%s%s" "$sha" "$dirty" > "${root}/build.txt" || true
  fi
fi


  local addon_id_dash="local_${slug}"
  local addon_id_us="local_${slug//-/_}"

  local remote_addon_path="${HA_REMOTE_BASE%/}/${slug}"
  local share_remote_default="${HA_REMOTE_SHARE_BASE%/}/${slug}"
  local share_remote="${SHARE_REMOTE:-$share_remote_default}"
  local share_local="${SHARE_LOCAL:-$LOCAL_SHARE_DIR}"

  info "[1/4] Preparing Remote Directories..."
  run_ssh "mkdir -p '$remote_addon_path'"

  if [[ -n "${share_local}" ]]; then
    local share_local_abs="$share_local"
    [[ "$share_local_abs" = /* ]] || share_local_abs="${root}/${share_local}"
    if [[ -d "$share_local_abs" ]]; then
      run_ssh "mkdir -p '$share_remote'"
    else
      note "Share sync requested but not found: $share_local_abs (skipping)"
      share_local_abs=""
    fi
  fi

  info "[2/4] Syncing Add-on Code..."
  local rsync_exclude_gitignore=()
  [[ -f "${root}/.gitignore" ]] && rsync_exclude_gitignore+=( --exclude-from="${root}/.gitignore" )

  run_rsync -avz --delete \
    -e "ssh ${SSH_OPTS[*]}" \
    "${rsync_exclude_gitignore[@]}" \
    --exclude='.git' \
    --exclude='.github' \
    --exclude='.venv' \
    --exclude='venv' \
    --exclude='__pycache__' \
    --exclude='.pytest_cache' \
    --exclude='.mypy_cache' \
    --exclude='.ruff_cache' \
    --exclude='deploy.sh' \
    --exclude='deploy.example.sh' \
    --exclude='scripts/haos.sh' \
    --exclude='scripts/deploy_haos.sh' \
    --exclude='scripts/uninstall_haos.sh' \
    "${root}/" "$SSH_TARGET:${remote_addon_path}/"

  info "[3/4] Syncing Data..."
  if [[ -n "${share_local:-}" ]]; then
    local share_local_abs="$share_local"
    [[ "$share_local_abs" = /* ]] || share_local_abs="${root}/${share_local}"
    if [[ -d "$share_local_abs" ]]; then
      run_rsync -avz --delete -e "ssh ${SSH_OPTS[*]}" \
        "${share_local_abs}/" "$SSH_TARGET:${share_remote}/"
      ok "Data sync complete."
    else
      note "Data sync skipped (local share dir missing)."
    fi
  else
    note "Data sync skipped (no --share / LOCAL_SHARE_DIR)."
  fi

  info "[4/4] Managing Home Assistant Add-on..."
  if (( NO_HA )); then
    note "Skipping ha CLI steps (--no-ha). Files deployed to: ${remote_addon_path}"
    close_mux
    return 0
  fi

  # Run remote management; pass args cleanly
  run_ssh "bash -s" -- "$addon_id_us" "$addon_id_dash" "$rebuild" "$restart" "$show_logs" <<'REMOTE'
set -e
A1="$1"; A2="$2"; REBUILD="$3"; RESTART="$4"; SHOW_LOGS="$5"

if ! command -v ha >/dev/null 2>&1; then
  echo "NOTE: 'ha' CLI not found in this SSH environment."
  echo "      Deploy succeeded, but manage steps must be done in UI."
  exit 0
fi

echo "... Refreshing Add-on Store"
ha store reload >/dev/null 2>&1 || true
ha addons reload >/dev/null 2>&1 || true

FOUND=""
for S in "$A1" "$A2"; do
  if ha addons info "$S" >/dev/null 2>&1; then
    FOUND="$S"
    break
  fi
done

if [[ -n "$FOUND" ]]; then
  echo "... Add-on found ($FOUND)."
  if [[ "$REBUILD" == "1" ]]; then
    echo "... Rebuilding"
    ha addons rebuild "$FOUND"
  fi
  if [[ "$RESTART" == "1" ]]; then
    echo "... Restarting"
    ha addons restart "$FOUND" >/dev/null 2>&1 || ha addons start "$FOUND"
  fi
else
  echo "... Add-on not installed. Attempting install..."
  if ha addons install "$A1" >/dev/null 2>&1 || ha addons install "$A2" >/dev/null 2>&1; then
    echo "... Install OK."
    if ha addons info "$A1" >/dev/null 2>&1; then FOUND="$A1"; else FOUND="$A2"; fi
    echo "... Starting"
    ha addons start "$FOUND" >/dev/null 2>&1 || true
  else
    echo "ERROR: Add-on not available to install via CLI (yet)."
    echo "UI: Settings → Add-ons → Add-on store → (⋮) Check for updates"
    exit 0
  fi
fi

if [[ "$SHOW_LOGS" == "1" && -n "$FOUND" ]]; then
  echo "... Logs"
  sleep 2
  ha addons logs "$FOUND" || true
fi
REMOTE

  ok "Deployment complete."
  close_mux
}

cmd_uninstall() {
  local rm_share="$1"
  require_cmd ssh
  require_cmd awk

  local root slug
  root="$(repo_root)"
  slug="$(read_slug "$root")"

  local addon_id_dash="local_${slug}"
  local addon_id_us="local_${slug//-/_}"

  local remote_addon_main="${HA_REMOTE_BASE%/}/${slug}"
  local remote_addon_legacy="/addons/${slug}"
  local remote_addon_main_us="${HA_REMOTE_BASE%/}/${slug//-/_}"
  local remote_addon_legacy_us="/addons/${slug//-/_}"

  local share_remote_default="${HA_REMOTE_SHARE_BASE%/}/${slug}"
  local share_remote="${SHARE_REMOTE:-$share_remote_default}"

  confirm "This will uninstall the add-on (if installed) and delete remote folders under /addons. Continue?" || die "Aborted."

  info "[1/3] Stopping/uninstalling (if possible)..."
  run_ssh "bash -s" -- "$addon_id_us" "$addon_id_dash" <<'REMOTE'
set -e
A1="$1"; A2="$2"
if ! command -v ha >/dev/null 2>&1; then
  echo "NOTE: 'ha' CLI not found; skipping stop/uninstall via CLI."
  exit 0
fi

FOUND=""
for S in "$A1" "$A2"; do
  if ha addons info "$S" >/dev/null 2>&1; then FOUND="$S"; break; fi
done

if [[ -n "$FOUND" ]]; then
  ha addons stop "$FOUND" >/dev/null 2>&1 || true
  ha addons uninstall "$FOUND" >/dev/null 2>&1 || true
  ha store reload >/dev/null 2>&1 || true
  ha addons reload >/dev/null 2>&1 || true
  echo "Uninstalled: $FOUND"
else
  echo "Add-on not installed (skipping)."
fi
REMOTE

  info "[2/3] Removing remote add-on folders..."
  run_ssh "rm -rf \
    '$remote_addon_main' '$remote_addon_legacy' \
    '$remote_addon_main_us' '$remote_addon_legacy_us'"

  if (( rm_share )); then
    info "[3/3] Removing remote share folder..."
    run_ssh "rm -rf '$share_remote'"
  else
    note "[3/3] Share removal skipped (use --rm-share)."
  fi

  ok "Uninstall complete. UI: Add-on store → (⋮) Check for updates"
  close_mux
}

cmd_clean() {
  require_cmd ssh
  require_cmd awk

  local root slug
  root="$(repo_root)"
  slug="$(read_slug "$root")"

  local remote_addon_main="${HA_REMOTE_BASE%/}/${slug}"
  local remote_addon_legacy="/addons/${slug}"
  local remote_addon_main_us="${HA_REMOTE_BASE%/}/${slug//-/_}"
  local remote_addon_legacy_us="/addons/${slug//-/_}"

  confirm "This will DELETE remote folders under /addons (no uninstall). Continue?" || die "Aborted."

  info "Removing remote add-on folders..."
  run_ssh "rm -rf \
    '$remote_addon_main' '$remote_addon_legacy' \
    '$remote_addon_main_us' '$remote_addon_legacy_us'"
  ok "Clean complete."
  close_mux
}

cmd_logs() {
  require_cmd ssh
  require_cmd awk

  local follow="${1:-0}"
  local root slug
  root="$(repo_root)"
  slug="$(read_slug "$root")"
  local addon_id_us="local_${slug//-/_}"
  local addon_id_dash="local_${slug}"

  run_ssh "bash -s" -- "$addon_id_us" "$addon_id_dash" "$follow" <<'REMOTE'
set -e
A1="$1"; A2="$2"; FOLLOW="$3"
if ! command -v ha >/dev/null 2>&1; then
  echo "NOTE: 'ha' CLI not found in this SSH environment."
  exit 1
fi
FOUND=""
for S in "$A1" "$A2"; do
  if ha addons info "$S" >/dev/null 2>&1; then FOUND="$S"; break; fi
done
[[ -n "$FOUND" ]] || { echo "Add-on not installed."; exit 1; }
if [[ "$FOLLOW" == "1" ]]; then
  ha addons logs -f "$FOUND"
else
  ha addons logs "$FOUND"
fi
REMOTE
}

cmd_status() {
  require_cmd ssh
  require_cmd awk

  local root slug
  root="$(repo_root)"
  slug="$(read_slug "$root")"

  local addon_id_us="local_${slug//-/_}"
  local addon_id_dash="local_${slug}"

  local remote_addon_main="${HA_REMOTE_BASE%/}/${slug}"
  local remote_addon_legacy="/addons/${slug}"

  info "Local slug: ${slug}"
  echo "SSH: ${HA_USER}@${HA_HOST}:${HA_PORT}"
  echo "Remote add-on (expected): ${remote_addon_main}"
  echo "Remote add-on (legacy):   ${remote_addon_legacy}"
  echo "Add-on IDs:               ${addon_id_us} / ${addon_id_dash}"
  echo

  run_ssh "bash -s" -- "$addon_id_us" "$addon_id_dash" <<'REMOTE'
set -e
A1="$1"; A2="$2"
echo "config.yaml under /addons:"
find /addons -maxdepth 3 -type f -name config.yaml -print 2>/dev/null || true
echo
if command -v ha >/dev/null 2>&1; then
  FOUND=""
  for S in "$A1" "$A2"; do
    if ha addons info "$S" >/dev/null 2>&1; then FOUND="$S"; break; fi
  done
  if [[ -n "$FOUND" ]]; then
    echo "Installed add-on: $FOUND"
    ha addons info "$FOUND" || true
  else
    echo "Add-on not installed."
  fi
else
  echo "NOTE: 'ha' CLI not found in this SSH environment."
fi
REMOTE
}

# ----------------------------- arg parsing ---------------------------------
COMMAND="${1:-}"
shift || true

REBUILD=0
RESTART=0
SHOW_LOGS=0
RM_SHARE=0
FOLLOW=0

SHARE_LOCAL=""
SHARE_REMOTE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HA_HOST="${2:?}"; shift 2 ;;
    --user) HA_USER="${2:?}"; shift 2 ;;
    --port) HA_PORT="${2:?}"; shift 2 ;;
    --key)  HA_KEY="${2:?}"; shift 2 ;;
    --no-mux) USE_MUX=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes) YES=1; shift ;;
    --no-ha) NO_HA=1; shift ;;

    --rebuild) REBUILD=1; shift ;;
    --restart) RESTART=1; shift ;;
    --logs) SHOW_LOGS=1; shift ;;
    --rm-share) RM_SHARE=1; shift ;;
    --follow|-f) FOLLOW=1; shift ;;

    --share) SHARE_LOCAL="${2:?}"; shift 2 ;;
    --share-remote) SHARE_REMOTE="${2:?}"; shift 2 ;;

    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
done

[[ -n "$COMMAND" ]] || { usage; exit 2; }

build_ssh "$HA_HOST" "$HA_USER" "$HA_PORT" "$HA_KEY" "$USE_MUX"

# Warm up mux connection (prompts once if password auth is enabled)
if (( USE_MUX )); then
  run_ssh "true" >/dev/null 2>&1 || true
fi

case "$COMMAND" in
  deploy)   cmd_deploy "$REBUILD" "$RESTART" "$SHOW_LOGS" ;;
  uninstall) cmd_uninstall "$RM_SHARE" ;;
  clean)    cmd_clean ;;
  logs)     cmd_logs "$FOLLOW" ;;
  status)   cmd_status ;;
  *) die "Unknown command: $COMMAND (try --help)" ;;
esac
