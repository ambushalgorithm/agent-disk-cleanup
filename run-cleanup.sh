#!/usr/bin/env bash
# run-cleanup.sh - one-shot opencode prune (+ optional one-time conversion).
#
# Runs the repo's scripts in place (no installer, no sudo). Works on Linux,
# macOS, and the BSDs by reusing bin/platform.sh.
#
# Cleanup never terminates or stops opencode. Pruning protects any session a
# running opencode process references (by session id or working directory), so
# it is safe to run while opencode is open. The one-time off-root conversion
# still requires opencode to be closed (it is deferred otherwise).
#
# Usage:
#   ./run-cleanup.sh                       # backup, then prune + convert
#   ./run-cleanup.sh --dry-run             # show what would be pruned
#   ./run-cleanup.sh --list [--sizes]      # list directories and their policy
#   RETENTION_DAYS=7 ./run-cleanup.sh      # keep a week
#   BACKUP=0 ./run-cleanup.sh              # skip backup (not recommended)
#
# Env:
#   REPO                 repo root (default: this script's directory)
#   OPENCODE_DB          database path (default: `opencode db path` / XDG)
#   POLICIES_FILE        per-directory policy table (see docs/DESIGN.md)
#   RETENTION_DAYS       default days cutoff (default 0 = count-only)
#   KEEP_RECENT_SESSIONS default keep per directory (default 10)
#   INACTIVE_MINUTES     default idle grace in minutes (default 0)
#   CONVERT              default 1 (perform the one-time conversion)
#   BACKUP               default 1 (consistent sqlite backup before changes)
#   KEEP_BACKUP          default 0 (backup is deleted after a successful run)
#   DRY_RUN              default 0

set -uo pipefail

LIST=0
DRY_RUN="${DRY_RUN:-0}"
for arg in "$@"; do
  case "$arg" in
    --list) LIST=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

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

if [ "$LIST" = "1" ]; then
  exec "$ADC_BIN/opencode-db-list.sh" "$@"
fi

COMPACT="$ADC_BIN/opencode-db-compact.sh"
RETENTION_DAYS="${RETENTION_DAYS:-0}"
KEEP_RECENT_SESSIONS="${KEEP_RECENT_SESSIONS:-10}"
INACTIVE_MINUTES="${INACTIVE_MINUTES:-0}"
CONVERT="${CONVERT:-1}"
BACKUP_SET=0; [ -n "${BACKUP+x}" ] && BACKUP_SET=1
BACKUP="${BACKUP:-1}"
KEEP_BACKUP="${KEEP_BACKUP:-0}"

if [ "$DRY_RUN" = "1" ] && [ "$BACKUP_SET" = "0" ]; then
  # Nothing is written, so a backup is pointless unless explicitly requested.
  BACKUP=0
fi

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
  echo "opencode is running; pruning runs concurrently and never stops it."
  echo "the one-time conversion (if still needed) is deferred until it is closed."
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
INACTIVE_MINUTES="$INACTIVE_MINUTES" \
POLICIES_FILE="${POLICIES_FILE:-}" \
DRY_RUN="$DRY_RUN" \
CONVERT="$CONVERT" \
  "$COMPACT"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "cleanup exited with status $rc"
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
