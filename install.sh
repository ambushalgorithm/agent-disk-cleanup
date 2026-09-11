#!/usr/bin/env bash
set -euo pipefail

# agent-disk-cleanup installer.
# Run as the target (non-root) user; it uses sudo for privileged steps.
#
#   ./install.sh [--dry-run] [--uninstall] [--purge]
#
# --dry-run    show what would be done, change nothing
# --uninstall  disable and remove the systemd units (keeps scripts)
# --purge      with --uninstall, also remove installed scripts and env file

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=0
UNINSTALL=0
PURGE=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge) PURGE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# ---- resolve target user / privilege helper --------------------------------
if [ "$(id -u)" -eq 0 ]; then
  TARGET_USER="${SUDO_USER:-}"
  if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    echo "ERROR: run this as the target user (it will call sudo), not as root." >&2
    exit 1
  fi
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  SUDO=""
else
  TARGET_USER="$USER"
  TARGET_HOME="$HOME"
  SUDO="sudo"
fi
TARGET_GROUP="$(id -gn "$TARGET_USER")"

# ---- config ----------------------------------------------------------------
SCRIPT_DIR="$TARGET_HOME/bin"
RETENTION_DAYS=2
KEEP_RECENT_SESSIONS=3
SCHEDULE="Mon,Wed,Fri,Sun 04:00"
HOST_SCHEDULE="Mon,Wed,Fri,Sun 04:20"
RANDOMIZED_DELAY=600
CONVERT_DIR=""
OPENCODE_DB=""
ENABLE_DOCKER_PRUNE=1
ENABLE_JOURNALD=1
JOURNAL_MAX_USE="500M"
ENABLE_APT_CLEAN=1

if [ -f "$REPO_DIR/cleanup.conf" ]; then
  # shellcheck source=/dev/null
  source "$REPO_DIR/cleanup.conf"
fi

UNIT_DIR="/etc/systemd/system"
ENV_FILE="/etc/agent-disk-cleanup.conf"
HOST_LIB_DIR="/usr/local/lib/agent-disk-cleanup"

log() { printf '[install] %s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: $*"
  else
    "$@"
  fi
}

df_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d '[:space:]'; }

detect_convert_dir() {
  local root_dev target fstype dev avail base
  root_dev=$(stat -c %d / 2>/dev/null || echo "")
  while read -r target; do
    case "$target" in
      /mnt/*|/media/*|/data|/srv) ;;
      *) continue ;;
    esac
    fstype=$(findmnt -no FSTYPE --target "$target" 2>/dev/null || echo "")
    case "$fstype" in
      nfs*|cifs|smb*|fuse*|9p|sshfs|tmpfs|ramfs) continue ;;
    esac
    dev=$(stat -c %d "$target" 2>/dev/null) || continue
    [ -n "$root_dev" ] && [ "$dev" = "$root_dev" ] && continue
    if [ -w "$target" ]; then
      base="$target"
    elif [ -n "${TARGET_USER:-}" ] && [ -d "$target/$TARGET_USER" ] && [ -w "$target/$TARGET_USER" ]; then
      base="$target/$TARGET_USER"
    else
      continue
    fi
    avail=$(df_bytes "$base")
    [ "${avail:-0}" -ge $(( 2 * 1024 * 1024 * 1024 )) ] || continue
    echo "$base/agent-disk-cleanup-convert"
    return 0
  done < <(df -P 2>/dev/null | tail -n +2 | awk '{print $NF}')
  return 1
}

# ---- uninstall -------------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  log "disabling timers"
  run $SUDO systemctl disable --now opencode-cleanup.timer host-cleanup.timer 2>/dev/null || true
  log "removing unit files"
  run $SUDO rm -f "$UNIT_DIR/opencode-cleanup.service" "$UNIT_DIR/opencode-cleanup.timer" \
                  "$UNIT_DIR/host-cleanup.service" "$UNIT_DIR/host-cleanup.timer"
  run $SUDO systemctl daemon-reload
  if [ "$PURGE" = "1" ]; then
    log "removing installed scripts and env file"
    run rm -rf "$SCRIPT_DIR/opencode-db-lib.sh" "$SCRIPT_DIR/opencode-db-compact.sh" \
                "$SCRIPT_DIR/opencode-db-convert.sh" "$SCRIPT_DIR/opencode-cleanup.sh"
    run $SUDO rm -rf "$HOST_LIB_DIR" "$ENV_FILE"
  fi
  log "uninstall complete"
  exit 0
fi

# ---- dependency checks -----------------------------------------------------
missing=0
for c in bash sqlite3 systemctl; do
  if ! command -v "$c" >/dev/null 2>&1; then
    log "ERROR: required command not found: $c"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1
command -v docker >/dev/null 2>&1 || log "note: docker not found; docker prune will be skipped"
command -v opencode >/dev/null 2>&1 || log "note: opencode not found; set OPENCODE_DB in cleanup.conf"

# Build a PATH that includes the tools we rely on.
path_dirs=""
for c in sqlite3 docker opencode; do
  p=$(command -v "$c" 2>/dev/null || true)
  [ -n "$p" ] && path_dirs="$path_dirs:$(dirname "$p")"
done
SERVICE_PATH="${path_dirs#:}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Resolve convert dir.
if [ -z "$CONVERT_DIR" ]; then
  if CONVERT_DIR=$(detect_convert_dir); then
    log "auto-detected CONVERT_DIR=$CONVERT_DIR"
  else
    CONVERT_DIR="${TMPDIR:-/var/tmp}/agent-disk-cleanup-convert"
    log "WARNING: no secondary filesystem detected; CONVERT_DIR=$CONVERT_DIR"
    log "WARNING: the one-time conversion will refuse to run on the same filesystem."
  fi
fi

# ---- render units ----------------------------------------------------------
render() {
  local src="$1" dst="$2"
  sed -e "s|@USER@|$TARGET_USER|g" \
      -e "s|@GROUP@|$TARGET_GROUP|g" \
      -e "s|@SCRIPT_DIR@|$SCRIPT_DIR|g" \
      -e "s|@HOST_SCRIPT@|$HOST_LIB_DIR/host-cleanup.sh|g" \
      -e "s|@SCHEDULE@|$SCHEDULE|g" \
      -e "s|@HOST_SCHEDULE@|$HOST_SCHEDULE|g" \
      -e "s|@RANDOMIZED_DELAY@|$RANDOMIZED_DELAY|g" \
      "$src" > "$dst"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render "$REPO_DIR/systemd/opencode-cleanup.service.in" "$tmp/opencode-cleanup.service"
render "$REPO_DIR/systemd/opencode-cleanup.timer.in"   "$tmp/opencode-cleanup.timer"
render "$REPO_DIR/systemd/host-cleanup.service.in"     "$tmp/host-cleanup.service"
render "$REPO_DIR/systemd/host-cleanup.timer.in"       "$tmp/host-cleanup.timer"

log "installing scripts to $SCRIPT_DIR"
run mkdir -p "$SCRIPT_DIR"
for f in opencode-db-lib.sh opencode-db-compact.sh opencode-db-convert.sh opencode-cleanup.sh; do
  run install -m 0755 "$REPO_DIR/bin/$f" "$SCRIPT_DIR/$f"
done

log "installing host-cleanup to $HOST_LIB_DIR"
run $SUDO mkdir -p "$HOST_LIB_DIR"
run $SUDO install -m 0755 "$REPO_DIR/bin/host-cleanup.sh" "$HOST_LIB_DIR/host-cleanup.sh"
run $SUDO install -m 0644 "$REPO_DIR/bin/opencode-db-lib.sh" "$HOST_LIB_DIR/opencode-db-lib.sh"

# ---- runtime environment file ----------------------------------------------
env_tmp="$tmp/agent-disk-cleanup.conf"
{
  echo "# Generated by agent-disk-cleanup install.sh. Do not edit by hand."
  echo "PATH=$SERVICE_PATH"
  echo "RETENTION_DAYS=$RETENTION_DAYS"
  echo "KEEP_RECENT_SESSIONS=$KEEP_RECENT_SESSIONS"
  echo "CONVERT_DIR=$CONVERT_DIR"
  echo "OPENCODE_DB=$OPENCODE_DB"
  echo "ENABLE_DOCKER_PRUNE=$ENABLE_DOCKER_PRUNE"
  echo "ENABLE_JOURNALD=$ENABLE_JOURNALD"
  echo "JOURNAL_MAX_USE=$JOURNAL_MAX_USE"
  echo "ENABLE_APT_CLEAN=$ENABLE_APT_CLEAN"
} > "$env_tmp"
log "writing $ENV_FILE"
run $SUDO install -m 0644 "$env_tmp" "$ENV_FILE"

# ---- install units and enable ----------------------------------------------
log "installing systemd units"
for u in opencode-cleanup.service opencode-cleanup.timer host-cleanup.service host-cleanup.timer; do
  run $SUDO install -m 0644 "$tmp/$u" "$UNIT_DIR/$u"
done
run $SUDO systemctl daemon-reload
run $SUDO systemctl enable --now opencode-cleanup.timer host-cleanup.timer

if [ "$DRY_RUN" != "1" ]; then
  log "installed. Timers:"
  systemctl list-timers opencode-cleanup.timer host-cleanup.timer --all 2>/dev/null || true
fi
log "done"
