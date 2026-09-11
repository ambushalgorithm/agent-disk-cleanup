#!/usr/bin/env bash
set -uo pipefail

# Host-level cleanup. Runs as root via the scheduler. Supports DRY_RUN=1.
#
# Linux: caps/vacuums journald and cleans the apt cache.
# macOS: optionally runs the built-in `periodic` maintenance scripts.
# Every action is toggleable and skipped when its tools are unavailable.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
if [ -f "$DIR/opencode-db-lib.sh" ]; then
  . "$DIR/opencode-db-lib.sh"
else
  log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
fi

JOURNAL_CONF="/etc/systemd/journald.conf"
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-500M}"
ENABLE_JOURNALD="${ENABLE_JOURNALD:-1}"
ENABLE_APT_CLEAN="${ENABLE_APT_CLEAN:-1}"
ENABLE_MACOS_CLEANUP="${ENABLE_MACOS_CLEANUP:-0}"
DRY_RUN="${DRY_RUN:-0}"

run() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: $*"
  else
    "$@"
  fi
}

if [ "$ENABLE_JOURNALD" = "1" ] && have journalctl; then
  if [ -f "$JOURNAL_CONF" ]; then
    changed=0
    if grep -qE '^[[:space:]]*SystemMaxUse=' "$JOURNAL_CONF"; then
      current=$(sed -n 's/^[[:space:]]*SystemMaxUse=//p' "$JOURNAL_CONF" | head -1)
      if [ "$current" != "$JOURNAL_MAX_USE" ]; then
        if [ "$DRY_RUN" = "1" ]; then
          log "DRY_RUN: set SystemMaxUse=$JOURNAL_MAX_USE in $JOURNAL_CONF (was $current)"
        else
          sed_inplace "s|^[[:space:]]*SystemMaxUse=.*|SystemMaxUse=${JOURNAL_MAX_USE}|" "$JOURNAL_CONF"
        fi
        changed=1
      fi
    elif grep -q '^\[Journal\]' "$JOURNAL_CONF"; then
      if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN: add SystemMaxUse=$JOURNAL_MAX_USE to $JOURNAL_CONF"
      else
        sed_inplace "/^\[Journal\]/a SystemMaxUse=${JOURNAL_MAX_USE}" "$JOURNAL_CONF"
      fi
      changed=1
    else
      if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN: append [Journal] SystemMaxUse=$JOURNAL_MAX_USE to $JOURNAL_CONF"
      else
        printf '\n[Journal]\nSystemMaxUse=%s\n' "$JOURNAL_MAX_USE" >> "$JOURNAL_CONF"
      fi
      changed=1
    fi
    if [ "$changed" = "1" ]; then
      run systemctl restart systemd-journald
    fi
  fi
  log "vacuuming journald to ${JOURNAL_MAX_USE}"
  run journalctl --vacuum-size="$JOURNAL_MAX_USE"
else
  log "journald cleanup disabled or unavailable"
fi

if [ "$ENABLE_APT_CLEAN" = "1" ] && have apt-get; then
  log "cleaning apt cache"
  run apt-get clean
else
  log "apt cleanup disabled or unavailable"
fi

if [ "$ENABLE_MACOS_CLEANUP" = "1" ] && have periodic; then
  log "running macOS periodic maintenance"
  run periodic daily weekly monthly
else
  log "macOS periodic cleanup disabled or unavailable"
fi
