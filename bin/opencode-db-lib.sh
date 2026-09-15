#!/usr/bin/env bash
# Shared helpers for agent disk-cleanup scripts.
# Intended to be sourced, not executed.

ADC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$ADC_LIB_DIR/platform.sh"

log() { printf '[%s] %s\n' "$(now_iso)" "$*"; }

# Backwards-compatible alias.
df_bytes() { df_avail_bytes "$1"; }

# Print the default opencode database path. Honors `opencode db path` when the
# CLI is available, otherwise falls back to the XDG data directory.
default_db_path() {
  local p
  if have opencode; then
    p=$(opencode db path 2>/dev/null | head -1 || true)
    if [ -n "${p:-}" ]; then
      echo "$p"
      return 0
    fi
  fi
  echo "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"
}

opencode_running() {
  local pids
  pids=$(list_opencode_pids)
  [ -n "$pids" ]
}

show_opencode() {
  local pids
  pids=$(list_opencode_pids | tr '\n' ' ')
  [ -n "$pids" ] || return 0
  ps -o pid=,command= -p $pids 2>/dev/null || true
}

# Sum cumulative CPU time (centiseconds) across opencode processes.
opencode_cpu_centis() {
  local s=0 p t
  for p in $(list_opencode_pids 2>/dev/null); do
    t=$(proc_cpu_centis "$p" 2>/dev/null || echo 0)
    s=$(( s + ${t:-0} ))
  done
  echo "$s"
}

# stop_opencode [idle_minutes] [cpu_sample] [cpu_centis_max] [stop_wait] [recheck]
# Reads: STOP_OPENCODE, DB
# Returns: 0 = safe to proceed (stopped or not running)
#          10 = skipped because opencode is active
#          1  = error
stop_opencode() {
  local idle_minutes="${1:-15}" cpu_sample="${2:-5}" cpu_centis_max="${3:-150}"
  local stop_wait="${4:-30}" recheck="${5:-10}"
  local last_ms now_ms a b i

  opencode_running || return 0

  if [ "${STOP_OPENCODE:-1}" != "1" ]; then
    log "opencode running and STOP_OPENCODE!=1; aborting:"
    show_opencode
    return 1
  fi

  last_ms=$(sqlite3 -cmd ".timeout 5000" "$DB" "SELECT COALESCE(max(time_updated),0) FROM session;" 2>/dev/null || echo 0)
  now_ms=$(( $(date +%s) * 1000 ))
  if [ "$last_ms" -gt 0 ] && [ $(( now_ms - last_ms )) -lt $(( idle_minutes * 60000 )) ]; then
    log "session activity within ${idle_minutes}m; skipping (opencode left running)"
    return 10
  fi

  a=$(opencode_cpu_centis)
  sleep "$cpu_sample"
  b=$(opencode_cpu_centis)
  if [ $(( b - a )) -gt "$cpu_centis_max" ]; then
    log "opencode busy (${b}-${a} centis / ${cpu_sample}s); skipping (opencode left running)"
    return 10
  fi

  log "opencode idle; stopping (TERM, then KILL after ${stop_wait}s):"
  show_opencode
  for i in $(list_opencode_pids 2>/dev/null); do
    kill -TERM "$i" 2>/dev/null || true
  done
  for i in $(seq 1 "$stop_wait"); do
    opencode_running || break
    sleep 1
  done
  if opencode_running; then
    log "still running; sending KILL"
    for i in $(list_opencode_pids 2>/dev/null); do
      kill -KILL "$i" 2>/dev/null || true
    done
    sleep 2
  fi
  if opencode_running; then
    log "ERROR: could not stop opencode:"
    show_opencode
    return 1
  fi
  for i in $(seq 1 "$recheck"); do
    if opencode_running; then
      log "opencode reappeared; aborting:"
      show_opencode
      return 1
    fi
    sleep 1
  done
  log "opencode stopped and stayed stable"
  return 0
}

# prune_sessions <days>
# Reads: DB, BATCH, KEEP_RECENT_SESSIONS
prune_sessions() {
  local days="$1" cut total ids_file keep
  keep="${KEEP_RECENT_SESSIONS:-3}"
  cut=$(( ( $(date +%s) - days*86400 ) * 1000 ))
  log "Retention ${days}d; pruning sessions updated before $(epoch_to_human $((cut/1000)) '%Y-%m-%d %H:%M')"
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

  local batch_size="${BATCH:-50}" batch=() id
  log "deleting in batches of ${batch_size} ..."
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    batch+=("$id")
    if [ "${#batch[@]}" -ge "$batch_size" ]; then
      prune_batch "${batch[@]}"
      batch=()
    fi
  done < "$ids_file"
  if [ "${#batch[@]}" -gt 0 ]; then
    prune_batch "${batch[@]}"
  fi
  rm -f "$ids_file"
}

# needs_rebuild <freelist_pages> <page_count>
# Returns 0 when a full off-root rebuild is preferable to incremental_vacuum:
# the freelist is huge in absolute terms or represents a large fraction of the
# file. Freeing millions of pages with incremental_vacuum runs as one giant
# transaction (huge WAL, very slow), so rebuild instead in that case.
needs_rebuild() {
  local freelist="$1" total="$2"
  case "${freelist:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${total:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$freelist" -gt 0 ] || return 1
  [ "$total" -gt 0 ] || return 1
  [ "$freelist" -gt "${REBUILD_FREELIST_PAGES:-100000}" ] && return 0
  [ $(( freelist * 100 / total )) -gt "${REBUILD_FREELIST_PCT:-25}" ] && return 0
  return 1
}
