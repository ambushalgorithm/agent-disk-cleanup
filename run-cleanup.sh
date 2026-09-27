#!/usr/bin/env bash
# run-cleanup.sh - one-shot opencode prune + one-time off-root conversion.
#
# Runs the repo's scripts in place (no installer, no sudo). Works on Linux,
# macOS, and the BSDs by reusing bin/platform.sh.
#
# Usage:
#   ./run-cleanup.sh                       # backup, then prune + convert
#   RETENTION_DAYS=7 ./run-cleanup.sh      # keep a week
#   BACKUP=0 ./run-cleanup.sh              # skip backup (not recommended)
#   FORCE=1 ./run-cleanup.sh               # allow stopping a running opencode
#
# Env:
#   REPO                 repo root (default: this script's directory)
#   OPENCODE_DB          database path (default: `opencode db path` / XDG)
#   RETENTION_DAYS       default 2
#   KEEP_RECENT_SESSIONS default 5
#   CONVERT              default 1 (perform the one-time conversion)
#   BACKUP               default 1 (consistent sqlite backup before changes)
#   KEEP_BACKUP          default 0 (backup is deleted after a successful run)
#   FORCE                default 0
#   IDLE_MINUTES         default 15

set -uo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")" && pwd)}"
if [ -f "$REPO/bin/opencode-db-lib.sh" ]; then
  ADC_BIN="$REPO/bin"
elif [ -f "$REPO/opencode-db-lib.sh" ]; then
  ADC_BIN="$REPO"
else
  printf 'ERROR: cannot find opencode-db-lib.sh under %s (set REPO=...)\n' "$REPO" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$ADC_BIN/opencode-db-lib.sh"

COMPACT="$ADC_BIN/opencode-db-compact.sh"
RETENTION_DAYS="${RETENTION_DAYS:-2}"
KEEP_RECENT_SESSIONS="${KEEP_RECENT_SESSIONS:-5}"
CONVERT="${CONVERT:-1}"
BACKUP="${BACKUP:-1}"
KEEP_BACKUP="${KEEP_BACKUP:-0}"
FORCE="${FORCE:-0}"
IDLE_MINUTES="${IDLE_MINUTES:-15}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
human() { ls -lh "$1" 2>/dev/null | awk '{print $5}'; }

[ -x "$COMPACT" ] || die "not found or not executable: $COMPACT (set REPO=/path/to/agent-disk-cleanup)"
have sqlite3 || die "sqlite3 not found"

DB="${OPENCODE_DB:-$(default_db_path)}"
[ -f "$DB" ] || die "database not found: $DB"
export OPENCODE_DB="$DB"

say "Database: $DB"
say "Before: $(human "$DB")  auto_vacuum=$(sqlite3 -readonly "$DB" 'PRAGMA auto_vacuum;' 2>/dev/null || echo '?')"

if [ -n "$(list_opencode_pids)" ]; then
  if [ "$FORCE" = "1" ]; then
    echo "opencode is running; it will be stopped only when the idle gate allows."
  else
    die "opencode is running. Quit it first, or re-run with FORCE=1."
  fi
fi

BAK=""
if [ "$BACKUP" = "1" ]; then
  BAK="${DB}.bak.$(date +%Y%m%d-%H%M%S)"
  say "Backing up to $BAK"
  sqlite3 "$DB" ".backup \"$BAK\"" || die "backup failed"
  say "Backup: $(human "$BAK")"
else
  say "BACKUP=0: skipping backup"
fi

say "Prune + convert (RETENTION_DAYS=$RETENTION_DAYS, KEEP_RECENT_SESSIONS=$KEEP_RECENT_SESSIONS, CONVERT=$CONVERT)"
RETENTION_DAYS="$RETENTION_DAYS" \
KEEP_RECENT_SESSIONS="$KEEP_RECENT_SESSIONS" \
CONVERT="$CONVERT" \
IDLE_MINUTES="$IDLE_MINUTES" \
  "$COMPACT"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "cleanup exited with status $rc"
  [ "$rc" -eq 10 ] && echo "(opencode was active; nothing changed. Quit it and re-run.)"
  [ -n "$BAK" ] && echo "Backup kept at $BAK"
  exit "$rc"
fi

say "After: $(human "$DB")  auto_vacuum=$(sqlite3 -readonly "$DB" 'PRAGMA auto_vacuum;' 2>/dev/null || echo '?')"

if [ -n "$BAK" ]; then
  if [ "$KEEP_BACKUP" = "1" ]; then
    say "Backup kept: $BAK"
  else
    rm -f "$BAK" && say "Removed backup: $BAK (set KEEP_BACKUP=1 to keep)"
  fi
fi

say "Done."
