#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/opencode-db-lib.sh"

DB="${OPENCODE_DB:-$(default_db_path)}"
DAYS="${RETENTION_DAYS:-2}"
BATCH="${BATCH:-50}"
CONVERT="${CONVERT:-0}"

IDLE_MINUTES="${IDLE_MINUTES:-15}"
CPU_SAMPLE="${CPU_SAMPLE:-5}"
CPU_TICKS_MAX="${CPU_TICKS_MAX:-20}"
STOP_WAIT="${STOP_WAIT:-30}"
STOP_RECHECK="${STOP_RECHECK:-10}"

if [ ! -f "$DB" ]; then
  log "database not found: $DB"
  exit 1
fi

set +e
stop_opencode "$IDLE_MINUTES" "$CPU_SAMPLE" "$CPU_TICKS_MAX" "$STOP_WAIT" "$STOP_RECHECK"
rc=$?
set -e
case "$rc" in
  0) ;;
  10) exit 0 ;;
  *) exit "$rc" ;;
esac

prune_sessions "$DAYS"

log "final wal checkpoint"
sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null

AV=$(sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA auto_vacuum;" 2>/dev/null || echo 0)
log "auto_vacuum=$AV"

if [ "$AV" = "2" ]; then
  FREELIST=$(sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA freelist_count;")
  log "freelist pages: $FREELIST; reclaiming with incremental_vacuum (no temp copy)"
  if [ "$FREELIST" -gt 0 ]; then
    sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA incremental_vacuum;" >/dev/null
    sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
  fi
  log "done:"
  ls -lh "$DB"
  df -h "$(dirname "$DB")" | tail -1
else
  if [ "$CONVERT" = "1" ]; then
    log "auto_vacuum=$AV (not incremental); running one-time off-root conversion"
    "$DIR/opencode-db-convert.sh"
  else
    log "auto_vacuum=$AV is not incremental; skipping vacuum."
    log "run with CONVERT=1 to perform the one-time off-root conversion."
  fi
fi
