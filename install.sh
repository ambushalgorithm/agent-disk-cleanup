#!/usr/bin/env bash
set -euo pipefail

# agent-disk-cleanup installer.
# Run as the target (non-root) user; it uses sudo for privileged steps.
#
#   ./install.sh [--dry-run] [--uninstall] [--purge]
#
# --dry-run    show what would be done, change nothing
# --uninstall  disable and remove the scheduler entries (keeps scripts)
# --purge      with --uninstall, also remove installed scripts and env file
#
# Supports systemd (Linux), launchd (macOS), and cron (other Unix).

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$REPO_DIR/bin/platform.sh"

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
  TARGET_HOME="$(resolve_home "$TARGET_USER")"
  SUDO=""
else
  TARGET_USER="$USER"
  TARGET_HOME="$HOME"
  SUDO="sudo"
fi
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GROUP="$(id -gn "$TARGET_USER")"

# ---- config ----------------------------------------------------------------
SCRIPT_DIR="$TARGET_HOME/bin"
RETENTION_DAYS=2
KEEP_RECENT_SESSIONS=3
CPU_TICKS_MAX=150
SCHEDULE="Mon,Wed,Fri,Sun 04:00"
HOST_SCHEDULE="Mon,Wed,Fri,Sun 04:20"
RANDOMIZED_DELAY=600
CONVERT_DIR=""
OPENCODE_DB=""
ENABLE_DOCKER_PRUNE=1
ENABLE_JOURNALD=1
JOURNAL_MAX_USE="500M"
ENABLE_APT_CLEAN=1
ENABLE_MACOS_CLEANUP=0
CONVERT=0

if [ -f "$REPO_DIR/cleanup.conf" ]; then
  # shellcheck source=/dev/null
  source "$REPO_DIR/cleanup.conf"
fi

UNIT_DIR="/etc/systemd/system"
ENV_FILE="/etc/agent-disk-cleanup.conf"
HOST_LIB_DIR="/usr/local/lib/agent-disk-cleanup"
LAUNCH_AGENTS_DIR="$TARGET_HOME/Library/LaunchAgents"
LAUNCH_DAEMONS_DIR="/Library/LaunchDaemons"
LOG_DIR="$TARGET_HOME/.local/state/agent-disk-cleanup"
HOST_LOG_DIR="/var/log/agent-disk-cleanup"
AGENT_LABEL="com.agent-disk-cleanup.opencode"
DAEMON_LABEL="com.agent-disk-cleanup.host"
BASH_BIN="$(command -v bash 2>/dev/null || echo /bin/bash)"
SERVICE_MGR="${ADC_SCHEDULER:-$(service_manager)}"

log() { printf '[install] %s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: $*"
  else
    "$@"
  fi
}

# env_lines -> KEY=VALUE for the runtime environment (systemd + launchd + cron).
env_lines() {
  printf 'PATH=%s\n' "$SERVICE_PATH"
  printf 'RETENTION_DAYS=%s\n' "$RETENTION_DAYS"
  printf 'KEEP_RECENT_SESSIONS=%s\n' "$KEEP_RECENT_SESSIONS"
  printf 'CPU_TICKS_MAX=%s\n' "$CPU_TICKS_MAX"
  printf 'CONVERT_DIR=%s\n' "$CONVERT_DIR"
  printf 'OPENCODE_DB=%s\n' "$OPENCODE_DB"
  printf 'ENABLE_DOCKER_PRUNE=%s\n' "$ENABLE_DOCKER_PRUNE"
  printf 'ENABLE_JOURNALD=%s\n' "$ENABLE_JOURNALD"
  printf 'JOURNAL_MAX_USE=%s\n' "$JOURNAL_MAX_USE"
  printf 'ENABLE_APT_CLEAN=%s\n' "$ENABLE_APT_CLEAN"
  printf 'ENABLE_MACOS_CLEANUP=%s\n' "$ENABLE_MACOS_CLEANUP"
  printf 'CONVERT=%s\n' "$CONVERT"
}

env_dict() {
  local k v
  env_lines | while IFS='=' read -r k v; do
    printf '\t\t<key>%s</key>\n\t\t<string>%s</string>\n' "$k" "$(xml_escape "$v")"
  done
}

render_plist() { # template out label script log_name schedule log_dir
  local tpl="$1" out="$2" label="$3" script="$4" logname="$5" sched="$6" logdir="$7"
  local tmp t1 t2
  tmp="$(mktemp -d)"
  env_dict > "$tmp/env"
  launchd_intervals "$sched" > "$tmp/cal"
  t1="$tmp/step1"
  t2="$tmp/step2"
  subst_file "@ENV_DICT@" "$tmp/env" "$tpl" > "$t1"
  subst_file "@CALENDAR_INTERVALS@" "$tmp/cal" "$t1" > "$t2"
  sed -e "s|@LABEL@|$label|g" \
      -e "s|@BASH@|$BASH_BIN|g" \
      -e "s|@SCRIPT@|$script|g" \
      -e "s|@LOG_DIR@|$logdir|g" \
      -e "s|@LOG_NAME@|$logname|g" "$t2" > "$out"
  rm -rf "$tmp"
}

render() { # systemd template out
  sed -e "s|@USER@|$TARGET_USER|g" \
      -e "s|@GROUP@|$TARGET_GROUP|g" \
      -e "s|@SCRIPT_DIR@|$SCRIPT_DIR|g" \
      -e "s|@HOST_SCRIPT@|$HOST_LIB_DIR/host-cleanup.sh|g" \
      -e "s|@SCHEDULE@|$SCHEDULE|g" \
      -e "s|@HOST_SCHEDULE@|$HOST_SCHEDULE|g" \
      -e "s|@RANDOMIZED_DELAY@|$RANDOMIZED_DELAY|g" \
      "$1" > "$2"
}

# cron_apply <user|root> <tag> <install|remove> [line]
cron_apply() {
  local mode="$1" tag="$2" action="$3" line="${4:-}"
  local begin="# BEGIN agent-disk-cleanup:$tag"
  local end="# END agent-disk-cleanup:$tag"
  local current tmp
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: would ${action} cron block '$tag' in $mode crontab"
    return 0
  fi
  tmp="$(mktemp)"
  if [ "$mode" = "root" ]; then
    current="$($SUDO crontab -l 2>/dev/null || true)"
  else
    current="$(crontab -l 2>/dev/null || true)"
  fi
  printf '%s\n' "$current" > "$tmp"
  cron_block_merge "$begin" "$end" "$action" "$line" "$tmp" "$tmp.merged"
  if [ "$mode" = "root" ]; then
    run $SUDO crontab "$tmp.merged"
  else
    run crontab "$tmp.merged"
  fi
  rm -f "$tmp" "$tmp.merged"
}

cron_line() { # schedule script -> crontab command line
  local sched="$1" script="$2"
  printf '%s /bin/bash -c %s\n' "$(cron_expr "$sched")" "'set -a; . \"$ENV_FILE\"; exec \"$script\"'"
}

# ---- uninstall -------------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  case "$SERVICE_MGR" in
    systemd)
      log "disabling systemd timers"
      run $SUDO systemctl disable --now opencode-cleanup.timer host-cleanup.timer 2>/dev/null || true
      log "removing unit files"
      run $SUDO rm -f "$UNIT_DIR/opencode-cleanup.service" "$UNIT_DIR/opencode-cleanup.timer" \
                      "$UNIT_DIR/host-cleanup.service" "$UNIT_DIR/host-cleanup.timer"
      run $SUDO systemctl daemon-reload
      ;;
    launchd)
      log "unloading launchd agents/daemons"
      launchctl bootout "gui/$TARGET_UID" "$LAUNCH_AGENTS_DIR/$AGENT_LABEL.plist" 2>/dev/null \
        || launchctl unload -w "$LAUNCH_AGENTS_DIR/$AGENT_LABEL.plist" 2>/dev/null || true
      run $SUDO launchctl bootout system "$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist" 2>/dev/null \
        || $SUDO launchctl unload -w "$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist" 2>/dev/null || true
      run rm -f "$LAUNCH_AGENTS_DIR/$AGENT_LABEL.plist"
      run $SUDO rm -f "$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist"
      ;;
    cron)
      log "removing cron entries"
      cron_apply user opencode remove
      cron_apply root host remove
      ;;
  esac
  if [ "$PURGE" = "1" ]; then
    log "removing installed scripts and env file"
    run rm -f "$SCRIPT_DIR/opencode-db-lib.sh" "$SCRIPT_DIR/opencode-db-compact.sh" \
               "$SCRIPT_DIR/opencode-db-convert.sh" "$SCRIPT_DIR/opencode-cleanup.sh" \
               "$SCRIPT_DIR/platform.sh" "$SCRIPT_DIR/run-cleanup.sh"
    run $SUDO rm -rf "$HOST_LIB_DIR" "$ENV_FILE"
  fi
  log "uninstall complete"
  exit 0
fi

# ---- dependency checks -----------------------------------------------------
missing=0
for c in bash sqlite3; do
  if ! have "$c"; then
    log "ERROR: required command not found: $c"
    missing=1
  fi
done
if [ "$SERVICE_MGR" = "none" ]; then
  log "ERROR: no supported scheduler found (need systemctl, launchctl, or crontab)"
  missing=1
fi
[ "$missing" -eq 0 ] || exit 1
have docker >/dev/null 2>&1 || log "note: docker not found; docker prune will be skipped"
have opencode >/dev/null 2>&1 || log "note: opencode not found; set OPENCODE_DB in cleanup.conf"
log "using scheduler: $SERVICE_MGR"

# Build a PATH that includes the tools we rely on.
path_dirs=""
for c in sqlite3 docker opencode; do
  p=$(command -v "$c" 2>/dev/null || true)
  [ -n "$p" ] && path_dirs="$path_dirs:$(dirname "$p")"
done
SERVICE_PATH="${path_dirs#:}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Resolve convert dir. Empty means convert.sh auto-detects at runtime.
if [ -z "$CONVERT_DIR" ]; then
  if CONVERT_DIR=$(find_secondary_fs "$TARGET_HOME"); then
    log "auto-detected CONVERT_DIR=$CONVERT_DIR"
  else
    CONVERT_DIR=""
    log "note: no secondary filesystem detected; conversion will build on the"
    log "note: database filesystem (safe when free space is ample)."
  fi
fi

# ---- install scripts -------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "installing scripts to $SCRIPT_DIR"
run mkdir -p "$SCRIPT_DIR"
for f in platform.sh opencode-db-lib.sh opencode-db-compact.sh opencode-db-convert.sh opencode-cleanup.sh; do
  run install -m 0755 "$REPO_DIR/bin/$f" "$SCRIPT_DIR/$f"
done
run install -m 0755 "$REPO_DIR/run-cleanup.sh" "$SCRIPT_DIR/run-cleanup.sh"

log "installing host-cleanup to $HOST_LIB_DIR"
run $SUDO mkdir -p "$HOST_LIB_DIR"
run $SUDO install -m 0755 "$REPO_DIR/bin/host-cleanup.sh" "$HOST_LIB_DIR/host-cleanup.sh"
run $SUDO install -m 0644 "$REPO_DIR/bin/platform.sh" "$HOST_LIB_DIR/platform.sh"
run $SUDO install -m 0644 "$REPO_DIR/bin/opencode-db-lib.sh" "$HOST_LIB_DIR/opencode-db-lib.sh"

# ---- runtime environment file ----------------------------------------------
env_tmp="$tmp/agent-disk-cleanup.conf"
{
  echo "# Generated by agent-disk-cleanup install.sh. Do not edit by hand."
  env_lines
} > "$env_tmp"
log "writing $ENV_FILE"
run $SUDO install -m 0644 "$env_tmp" "$ENV_FILE"

# ---- install scheduler -----------------------------------------------------
case "$SERVICE_MGR" in
  systemd)
    render "$REPO_DIR/systemd/opencode-cleanup.service.in" "$tmp/opencode-cleanup.service"
    render "$REPO_DIR/systemd/opencode-cleanup.timer.in"   "$tmp/opencode-cleanup.timer"
    render "$REPO_DIR/systemd/host-cleanup.service.in"     "$tmp/host-cleanup.service"
    render "$REPO_DIR/systemd/host-cleanup.timer.in"       "$tmp/host-cleanup.timer"
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
    ;;
  launchd)
    log "installing launchd agents/daemons"
    run mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
    run $SUDO mkdir -p "$LAUNCH_DAEMONS_DIR" "$HOST_LOG_DIR"
    render_plist "$REPO_DIR/launchd/opencode-cleanup.plist.in" "$tmp/opencode-cleanup.plist" \
      "$AGENT_LABEL" "$SCRIPT_DIR/opencode-cleanup.sh" "opencode-cleanup" "$SCHEDULE" "$LOG_DIR"
    render_plist "$REPO_DIR/launchd/host-cleanup.plist.in" "$tmp/host-cleanup.plist" \
      "$DAEMON_LABEL" "$HOST_LIB_DIR/host-cleanup.sh" "host-cleanup" "$HOST_SCHEDULE" "$HOST_LOG_DIR"
    run install -m 0644 "$tmp/opencode-cleanup.plist" "$LAUNCH_AGENTS_DIR/$AGENT_LABEL.plist"
    run $SUDO install -m 0644 "$tmp/host-cleanup.plist" "$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist"
    if [ "$DRY_RUN" != "1" ]; then
      launchctl bootout "gui/$TARGET_UID" "$LAUNCH_AGENTS_DIR/$AGENT_LABEL.plist" 2>/dev/null || true
      launchctl bootstrap "gui/$TARGET_UID" "$LAUNCH_AGENTS_DIR/$AGENT_LABEL.plist" 2>/dev/null \
        || launchctl load -w "$LAUNCH_AGENTS_DIR/$AGENT_LABEL.plist" || true
      $SUDO launchctl bootout system "$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist" 2>/dev/null || true
      $SUDO launchctl bootstrap system "$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist" 2>/dev/null \
        || $SUDO launchctl load -w "$LAUNCH_DAEMONS_DIR/$DAEMON_LABEL.plist" || true
      log "installed. Agents:"
      launchctl list 2>/dev/null | grep -E "$AGENT_LABEL|$DAEMON_LABEL" || true
    fi
    ;;
  cron)
    log "installing cron entries"
    cron_apply user opencode install "$(cron_line "$SCHEDULE" "$SCRIPT_DIR/opencode-cleanup.sh")"
    cron_apply root host install "$(cron_line "$HOST_SCHEDULE" "$HOST_LIB_DIR/host-cleanup.sh")"
    if [ "$DRY_RUN" != "1" ]; then
      log "installed. Crontab:"
      crontab -l 2>/dev/null | grep -A1 "BEGIN agent-disk-cleanup" || true
    fi
    ;;
esac

log "done"
