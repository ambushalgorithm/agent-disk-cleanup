#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/opencode-db-lib.sh"

DB="${OPENCODE_DB:-$(default_db_path)}"
DAYS="${RETENTION_DAYS:-0}"
BATCH="${BATCH:-50}"
CONVERT="${CONVERT:-0}"
DRY_RUN="${DRY_RUN:-0}"

if [ ! -f "$DB" ]; then
  log "database not found: $DB"
  exit 1
fi

RUNNING=0
opencode_running && RUNNING=1

# Prune always runs; it protects any session a live opencode process references
# (by session id or working directory), so it is safe to run concurrently.
prune_sessions "$DAYS"

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN: skipping checkpoint/vacuum/conversion"
  exit 0
fi

# Fold the WAL back only as far as readers allow; PASSIVE never blocks them.
sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA wal_checkpoint(PASSIVE);" >/dev/null 2>&1 || true

AV=$(sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA auto_vacuum;" 2>/dev/null || echo 0)
log "auto_vacuum=$AV"

if [ "$RUNNING" = "1" ]; then
  # Reclaim in place while opencode keeps running; defer anything that needs
  # exclusive access (the off-root rebuild/conversion) to a future run.
  if [ "$AV" = "2" ]; then
    FREELIST=$(sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA freelist_count;" 2>/dev/null || echo 0)
    if [ "${FREELIST:-0}" -gt 0 ]; then
      PAGES="${VACUUM_PAGES_PER_RUN:-50000}"
      log "reclaiming up to ${PAGES} pages with bounded incremental_vacuum (opencode running)"
      sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA incremental_vacuum(${PAGES});" >/dev/null
      sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA wal_checkpoint(PASSIVE);" >/dev/null 2>&1 || true
    fi
  fi
  log "opencode running; deferred rebuild/conversion until it is closed"
  log "done:"
  ls -lh "$DB"
  df -h "$(dirname "$DB")" | tail -1
  exit 0
fi

# opencode is not running: safe to do the exclusive work.
sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

if [ "$AV" = "2" ]; then
  FREELIST=$(sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA freelist_count;")
  PAGE_COUNT=$(sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA page_count;")
  log "freelist pages: ${FREELIST} / ${PAGE_COUNT}"
  if [ "${FREELIST:-0}" -gt 0 ]; then
    if needs_rebuild "$FREELIST" "$PAGE_COUNT"; then
      log "freelist is large; rebuilding off-root (fast) instead of incremental_vacuum"
      sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null || true
      "$DIR/opencode-db-convert.sh"
    else
      PAGES="${VACUUM_PAGES_PER_RUN:-50000}"
      log "reclaiming up to ${PAGES} pages with bounded incremental_vacuum"
      sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA incremental_vacuum(${PAGES});" >/dev/null
      sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
    fi
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
