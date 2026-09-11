#!/usr/bin/env bash
# Shared helpers for agent disk-cleanup scripts.
# Intended to be sourced, not executed.

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }

df_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -1 | tr -d '[:space:]'; }

# Print the default opencode database path. Honors `opencode db path` when the
# CLI is available, otherwise falls back to the XDG data directory.
default_db_path() {
  local p
  if command -v opencode >/dev/null 2>&1; then
    p=$(opencode db path 2>/dev/null | head -1 || true)
    if [ -n "${p:-}" ]; then
      echo "$p"
      return 0
    fi
  fi
  echo "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"
}

opencode_running() { pgrep -x opencode >/dev/null 2>&1; }

opencode_cpu_ticks() {
  local s=0 p t
  for p in $(pgrep -x opencode 2>/dev/null); do
    t=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null || true)
    s=$(( s + ${t:-0} ))
  done
  echo "$s"
}

# stop_opencode [idle_minutes] [cpu_sample] [cpu_ticks_max] [stop_wait] [recheck]
# Reads: STOP_OPENCODE, DB
# Returns: 0 = safe to proceed (stopped or not running)
#          10 = skipped because opencode is active
#          1  = error
stop_opencode() {
  local idle_minutes="${1:-15}" cpu_sample="${2:-5}" cpu_ticks_max="${3:-20}"
  local stop_wait="${4:-30}" recheck="${5:-10}"
  local last_ms now_ms a b i

  opencode_running || return 0

  if [ "${STOP_OPENCODE:-1}" != "1" ]; then
    log "opencode running and STOP_OPENCODE!=1; aborting:"
    pgrep -ax opencode || true
    return 1
  fi

  last_ms=$(sqlite3 -cmd ".timeout 5000" "$DB" "SELECT COALESCE(max(time_updated),0) FROM session;" 2>/dev/null || echo 0)
  now_ms=$(( $(date +%s) * 1000 ))
  if [ "$last_ms" -gt 0 ] && [ $(( now_ms - last_ms )) -lt $(( idle_minutes * 60000 )) ]; then
    log "session activity within ${idle_minutes}m; skipping (opencode left running)"
    return 10
  fi

  a=$(opencode_cpu_ticks)
  sleep "$cpu_sample"
  b=$(opencode_cpu_ticks)
  if [ $(( b - a )) -gt "$cpu_ticks_max" ]; then
    log "opencode busy (${b}-${a} ticks / ${cpu_sample}s); skipping (opencode left running)"
    return 10
  fi

  log "opencode idle; stopping (TERM, then KILL after ${stop_wait}s):"
  pgrep -ax opencode || true
  pkill -TERM -x opencode 2>/dev/null || true
  for i in $(seq 1 "$stop_wait"); do
    opencode_running || break
    sleep 1
  done
  if opencode_running; then
    log "still running; sending KILL"
    pkill -KILL -x opencode 2>/dev/null || true
    sleep 2
  fi
  if opencode_running; then
    log "ERROR: could not stop opencode:"
    pgrep -ax opencode || true
    return 1
  fi
  for i in $(seq 1 "$recheck"); do
    if opencode_running; then
      log "opencode reappeared; aborting:"
      pgrep -ax opencode || true
      return 1
    fi
    sleep 1
  done
  log "opencode stopped and stayed stopped"
  return 0
}

# prune_sessions <days>
# Reads: DB, BATCH, KEEP_RECENT_SESSIONS
prune_sessions() {
  local days="$1" cut total ids_file keep
  keep="${KEEP_RECENT_SESSIONS:-3}"
  cut=$(( ( $(date +%s) - days*86400 ) * 1000 ))
  log "Retention ${days}d; pruning sessions updated before $(date -d "@$((cut/1000))" '+%Y-%m-%d %H:%M')"
  log "keeping the ${keep} most recent top-level session(s) (+ their sub-sessions)"

  # Protected set: the N most recent top-level sessions, plus any sub-session
  # whose parent is one of them, so a preserved parent is never left with a
  # pruned child.
  local keep_cte="WITH keep AS (
      SELECT id FROM session WHERE parent_id IS NULL ORDER BY time_updated DESC, id DESC LIMIT ${keep}
    ),
    protected AS (
      SELECT id FROM keep
      UNION
      SELECT id FROM session WHERE parent_id IN (SELECT id FROM keep)
    )"

  total=$(sqlite3 -cmd ".timeout 5000" "$DB" "$keep_cte SELECT count(*) FROM session WHERE time_updated < $cut AND id NOT IN (SELECT id FROM protected);")
  log "sessions to prune: $total"
  [ "$total" -gt 0 ] || return 0

  ids_file="$(mktemp)"
  sqlite3 "$DB" "$keep_cte SELECT id FROM session WHERE time_updated < $cut AND id NOT IN (SELECT id FROM protected);" > "$ids_file"

  prune_batch() {
    local ids="" id
    for id in "$@"; do ids+="'${id//\'/\'\'}',"; done
    ids="${ids%,}"
    [ -n "$ids" ] || return 0
    sqlite3 -cmd ".timeout 5000" "$DB" "PRAGMA foreign_keys=ON;
      BEGIN IMMEDIATE;
      DELETE FROM event          WHERE aggregate_id IN ($ids);
      DELETE FROM event_sequence WHERE aggregate_id IN ($ids);
      DELETE FROM session        WHERE id IN ($ids);
      COMMIT;
      PRAGMA wal_checkpoint(PASSIVE);" >/dev/null
  }
  export -f prune_batch
  export DB

  log "deleting in batches of ${BATCH:-50} ..."
  xargs -a "$ids_file" -n "${BATCH:-50}" bash -c 'prune_batch "$@"' _
  rm -f "$ids_file"
}
