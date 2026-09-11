#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/opencode-db-lib.sh"

DB="${OPENCODE_DB:-$(default_db_path)}"
MARGIN="${SPACE_MARGIN_BYTES:-$(( 3 * 1024 * 1024 * 1024 ))}"
ALLOW_SAME_FS="${ALLOW_SAME_FS:-0}"

IDLE_MINUTES="${IDLE_MINUTES:-15}"
CPU_SAMPLE="${CPU_SAMPLE:-5}"
CPU_TICKS_MAX="${CPU_TICKS_MAX:-20}"
STOP_WAIT="${STOP_WAIT:-30}"
STOP_RECHECK="${STOP_RECHECK:-10}"

if [ ! -f "$DB" ]; then
  log "database not found: $DB"
  exit 1
fi

# Resolve the build directory. Prefer an explicit CONVERT_DIR, then an
# auto-detected secondary filesystem, then fall back to the local temp dir with
# same-filesystem building allowed (safe when free space is ample).
if [ -z "${CONVERT_DIR:-}" ]; then
  if CONVERT_DIR=$(find_secondary_fs "$(dirname "$DB")" "$MARGIN"); then
    log "auto-detected off-root CONVERT_DIR=$CONVERT_DIR"
  else
    CONVERT_DIR="${TMPDIR:-/var/tmp}/agent-disk-cleanup-convert"
    ALLOW_SAME_FS=1
    log "WARNING: no secondary filesystem found; building on the database filesystem."
    log "WARNING: this temporarily needs ~2x the live database in free space."
  fi
fi
BUILD_DIR="$CONVERT_DIR"

set +e
stop_opencode "$IDLE_MINUTES" "$CPU_SAMPLE" "$CPU_TICKS_MAX" "$STOP_WAIT" "$STOP_RECHECK"
rc=$?
set -e
case "$rc" in
  0) ;;
  10) log "opencode active; conversion skipped"; exit 0 ;;
  *) exit "$rc" ;;
esac

mkdir -p "$BUILD_DIR" || { log "cannot create build dir: $BUILD_DIR"; exit 1; }

# The conversion rebuilds a full second copy. To guarantee the DB filesystem
# never grows, that copy should live on a different filesystem.
DB_DEV=$(fs_device "$(dirname "$DB")" 2>/dev/null || echo "")
BUILD_DEV=$(fs_device "$BUILD_DIR" 2>/dev/null || echo "")
if [ -n "$DB_DEV" ] && [ "$DB_DEV" = "$BUILD_DEV" ] && [ "$ALLOW_SAME_FS" != "1" ]; then
  log "ERROR: build dir ($BUILD_DIR) is on the same filesystem as the database."
  log "Set CONVERT_DIR to a directory on another filesystem, or ALLOW_SAME_FS=1 to override."
  exit 1
fi

PAGE_SIZE=$(sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA page_size;")
PAGE_COUNT=$(sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA page_count;")
FREELIST=$(sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA freelist_count;")
LIVE=$(( (PAGE_COUNT - FREELIST) * PAGE_SIZE ))
REQUIRED=$(( LIVE + MARGIN ))
AVAIL=$(df_avail_bytes "$BUILD_DIR")

log "live=${LIVE} bytes; build-dir free=${AVAIL}; required=${REQUIRED}"
if [ "$AVAIL" -lt "$REQUIRED" ]; then
  log "ERROR: not enough free space in $BUILD_DIR to build safely; aborting (nothing changed)"
  exit 1
fi

BUILD="$BUILD_DIR/opencode.db.build.$$"
KEEP_BUILD=0
DELETED_OLD=0
COPY_DONE=0
cleanup() {
  # If the old DB was removed but the copy never completed, restore from the build.
  if [ "$DELETED_OLD" = "1" ] && [ "$COPY_DONE" != "1" ] && [ -f "$BUILD" ]; then
    log "interrupted during swap; restoring database from $BUILD"
    cp "$BUILD" "$DB" || true
  fi
  if [ "$KEEP_BUILD" != "1" ]; then
    rm -f "$BUILD"
  fi
}
trap cleanup EXIT INT TERM

rm -f "$BUILD"
log "building compacted incremental DB at $BUILD ..."
sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA auto_vacuum=INCREMENTAL; VACUUM INTO '$BUILD';" >/dev/null

log "verifying build ..."
CHECK=$(sqlite3 -cmd ".timeout 5000" "$BUILD" "PRAGMA integrity_check;")
if [ "$CHECK" != "ok" ]; then
  log "ERROR: build integrity check failed: $CHECK"
  exit 1
fi
AV=$(sqlite3 -cmd ".timeout 5000" "$BUILD" "PRAGMA auto_vacuum;")
if [ "$AV" != "2" ]; then
  log "ERROR: build auto_vacuum=$AV (expected 2)"
  exit 1
fi
log "build verified (integrity ok, auto_vacuum=2, size=$(file_size "$BUILD") bytes)"
KEEP_BUILD=1

log "swapping: removing old root DB, then copying new one into place ..."
rm -f "$DB" "$DB-wal" "$DB-shm"
DELETED_OLD=1
cp "$BUILD" "$DB"
COPY_DONE=1

CHECK=$(sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA integrity_check;")
if [ "$CHECK" != "ok" ]; then
  log "ERROR: copied DB integrity check failed: $CHECK"
  log "recovery copy preserved at: $BUILD"
  exit 1
fi
AV=$(sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA auto_vacuum;")
if [ "$AV" != "2" ]; then
  log "ERROR: copied DB auto_vacuum=$AV (expected 2); recovery copy at: $BUILD"
  exit 1
fi

rm -f "$BUILD"
KEEP_BUILD=0
log "conversion complete"
ls -lh "$DB"
df -h "$(dirname "$DB")" | tail -1
df -h "$BUILD_DIR" | tail -1
