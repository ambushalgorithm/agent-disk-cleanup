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

# stop_opencode [idle_minutes] [cpu_sample] [cpu_centis_max]
# This NEVER signals opencode. It only reports whether the database is quiet
# enough for an exclusive operation (e.g. the one-time off-root conversion).
# Recurring pruning runs concurrently with opencode and protects anything a
# live process references, so it never needs opencode stopped.
# Reads: DB
# Returns: 0 = opencode not running (safe)
#          10 = skipped because opencode is running/active
stop_opencode() {
  local idle_minutes="${1:-15}" cpu_sample="${2:-5}" cpu_centis_max="${3:-150}"
  local last_ms now_ms a b

  opencode_running || return 0

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

  log "opencode is running; refusing to stop it (cleanup never terminates opencode)"
  return 10
}

# ---------------------------------------------------------------------------
# Live opencode references
#
# opencode persists no "this session is open" flag, and session.time_updated is
# only written on prompt submit / metadata changes (not on open, navigation, or
# streaming). The only reliable signal is process state: a running opencode
# process carries its session id in argv (`opencode -s ses_...`) and/or its
# working directory equals session.directory. We protect everything a live
# process references so an open (or frozen) session is never pruned.
# ---------------------------------------------------------------------------

# Session ids mentioned on any process command line.
list_live_session_ids() {
  ps -Ao args= 2>/dev/null | grep -oE 'ses_[A-Za-z0-9]+' 2>/dev/null | sort -u || true
}

# Working directories of running opencode processes (== session.directory).
list_live_dirs() {
  local p c
  for p in $(list_opencode_pids 2>/dev/null); do
    c=$(proc_cwd "$p" 2>/dev/null || true)
    [ -n "$c" ] && printf '%s\n' "$c"
  done | sort -u || true
}

# Session ids with an admitted-but-not-promoted prompt (a turn in flight).
pending_input_session_ids() {
  sqlite3 -cmd ".timeout 5000" "$DB" \
    "SELECT session_id FROM session_input WHERE promoted_seq IS NULL;" 2>/dev/null || true
}

# sql_quote <value> -> single-quoted SQL literal.
sql_quote() { printf "'%s'" "$(printf '%s' "${1:-}" | sed "s/'/''/g")"; }

# ---------------------------------------------------------------------------
# Per-directory policies
#
# POLICIES_FILE is a line-based table, first match wins:
#     <glob>  <keep>  <inactive_min>  <days>
# - keep:         the N most recent top-level sessions per directory are kept
#                 (0 = keep none). Their sub-sessions are kept too.
# - inactive_min: never prune a session idle for fewer than this many minutes.
# - days:         age cutoff in days (0 = count-only, no time floor).
# Directories with no matching rule use the defaults (KEEP_RECENT_SESSIONS,
# INACTIVE_MINUTES, RETENTION_DAYS).
# ---------------------------------------------------------------------------

# load_policies <default_keep> <default_inactive_min> <default_days>
load_policies() {
  POL_PATTERN=(); POL_KEEP=(); POL_INACTIVE=(); POL_DAYS=()
  POL_DEF_KEEP="${1:-0}"; POL_DEF_INACTIVE="${2:-0}"; POL_DEF_DAYS="${3:-0}"
  local f="${POLICIES_FILE:-}"
  if [ -z "$f" ]; then
    # Auto-detect a policies.conf next to the repo/install tree.
    local cand
    for cand in "$ADC_LIB_DIR/../policies.conf" "$ADC_LIB_DIR/policies.conf"; do
      if [ -f "$cand" ]; then f="$cand"; break; fi
    done
  fi
  [ -n "$f" ] && [ -f "$f" ] || return 0
  local pat k ina d
  while read -r pat k ina d; do
    [ -n "${pat:-}" ] || continue
    POL_PATTERN[${#POL_PATTERN[@]}]="$pat"
    POL_KEEP[${#POL_KEEP[@]}]="${k:-$POL_DEF_KEEP}"
    POL_INACTIVE[${#POL_INACTIVE[@]}]="${ina:-$POL_DEF_INACTIVE}"
    POL_DAYS[${#POL_DAYS[@]}]="${d:-$POL_DEF_DAYS}"
  done < <(awk '
    { sub(/#.*/, "", $0); if (NF == 0) next; print $1, $2, $3, $4 }' "$f")
}

# policy_for_dir <directory> -> "<keep> <inactive_min> <days>"
policy_for_dir() {
  local dir="$1" i=0 n
  n=${#POL_PATTERN[@]}
  while [ "$i" -lt "$n" ]; do
    # shellcheck disable=SC2254  # the pattern is intentional glob syntax
    case "$dir" in
      ${POL_PATTERN[$i]})
        printf '%s %s %s\n' "${POL_KEEP[$i]}" "${POL_INACTIVE[$i]}" "${POL_DAYS[$i]}"
        return 0 ;;
    esac
    i=$(( i + 1 ))
  done
  printf '%s %s %s\n' "$POL_DEF_KEEP" "$POL_DEF_INACTIVE" "$POL_DEF_DAYS"
}

# prune_sessions [default_days]
# Reads: DB, BATCH, KEEP_RECENT_SESSIONS, RETENTION_DAYS, INACTIVE_MINUTES,
#        POLICIES_FILE, DRY_RUN.
# Deletes sessions not protected by any policy or live reference, in batches.
prune_sessions() {
  local days_default="${1:-${RETENTION_DAYS:-0}}"
  local def_keep="${KEEP_RECENT_SESSIONS:-10}"
  local def_inactive="${INACTIVE_MINUTES:-0}"
  local dry="${DRY_RUN:-0}"
  local now_ms tmpdir sql out
  now_ms=$(( $(date +%s) * 1000 ))
  tmpdir="$(mktemp -d)"

  load_policies "$def_keep" "$def_inactive" "$days_default"

  # ---- per-directory policy table ------------------------------------------
  local dirs d pol k ina dd
  dirs=$(sqlite3 -readonly "$DB" "SELECT DISTINCT directory FROM session;" 2>/dev/null || true)

  sql="PRAGMA foreign_keys=ON;
CREATE TEMP TABLE dir_policy(directory TEXT PRIMARY KEY, keep INTEGER NOT NULL, inactive_ms INTEGER NOT NULL, days INTEGER NOT NULL);"

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    pol="$(policy_for_dir "$d")"
    k="${pol%% *}"; pol="${pol#* }"
    ina="${pol%% *}"; dd="${pol#* }"
    sql="$sql
INSERT OR REPLACE INTO dir_policy VALUES($(sql_quote "$d"), ${k:-0}, $(( ${ina:-0} * 60000 )), ${dd:-0});"
  done <<EOF
$dirs
EOF

  # ---- protected set: never prune anything a live process references -------
  sql="$sql
CREATE TEMP TABLE protect(id TEXT PRIMARY KEY);"

  # explicit session ids (argv) + turns in flight
  { list_live_session_ids; pending_input_session_ids; } | sed '/^[[:space:]]*$/d' | sort -u > "$tmpdir/ids" || true
  if [ -s "$tmpdir/ids" ]; then
    local vals="" id
    while IFS= read -r id; do
      [ -n "$id" ] && vals="$vals,($(sql_quote "$id"))"
    done < "$tmpdir/ids"
    sql="$sql
INSERT OR IGNORE INTO protect(id) VALUES ${vals#,};"
  fi

  # every session in a directory a running opencode process currently sits in
  list_live_dirs | sed '/^[[:space:]]*$/d' | sort -u > "$tmpdir/dirs" || true
  if [ -s "$tmpdir/dirs" ]; then
    local dlist="" ld
    while IFS= read -r ld; do
      [ -n "$ld" ] && dlist="$dlist,$(sql_quote "$ld")"
    done < "$tmpdir/dirs"
    sql="$sql
INSERT OR IGNORE INTO protect(id) SELECT id FROM session WHERE directory IN (${dlist#,});"
  fi

  # policy floor: keep the most recent N top-level sessions per directory
  sql="$sql
INSERT OR IGNORE INTO protect(id)
  SELECT id FROM (
    SELECT s.id AS id,
           row_number() OVER (PARTITION BY s.directory ORDER BY s.time_updated DESC, s.id DESC) rn,
           (SELECT keep FROM dir_policy dp WHERE dp.directory = s.directory) keep
    FROM session s WHERE s.parent_id IS NULL
  ) WHERE keep IS NOT NULL AND keep > 0 AND rn <= keep;
INSERT OR IGNORE INTO protect(id) SELECT id FROM session WHERE parent_id IN (SELECT id FROM protect);"

  # ---- candidates ----------------------------------------------------------
  sql="$sql
CREATE TEMP TABLE victims(id TEXT PRIMARY KEY);
INSERT INTO victims(id)
  SELECT s.id FROM session s JOIN dir_policy dp ON dp.directory = s.directory
  WHERE s.time_updated < ($now_ms - dp.days * 86400000)
    AND s.time_updated < ($now_ms - dp.inactive_ms)
    AND s.id NOT IN (SELECT id FROM protect);
DELETE FROM victims WHERE id IN (SELECT parent_id FROM session WHERE id IN (SELECT id FROM protect));
SELECT 'COPYCAT_PROTECTED=' || (SELECT count(*) FROM protect);
SELECT 'COPYCAT_VICTIMS=' || (SELECT count(*) FROM victims);
SELECT id FROM victims;"

  out="$(sqlite3 -cmd ".timeout 30000" "$DB" "$sql")" || { log "prune query failed"; rm -rf "$tmpdir"; return 1; }

  local protected_count victims_count
  protected_count=$(printf '%s\n' "$out" | sed -n 's/^COPYCAT_PROTECTED=//p')
  victims_count=$(printf '%s\n' "$out" | sed -n 's/^COPYCAT_VICTIMS=//p')
  printf '%s\n' "$out" | sed -n '/^COPYCAT_/d; /^[[:space:]]*$/d; p' > "$tmpdir/victims"

  log "protected ${protected_count:-0} session(s) (live + top-keep); candidates to prune: ${victims_count:-0}"
  if [ "${victims_count:-0}" -le 0 ]; then
    log "nothing to prune"
    rm -rf "$tmpdir"
    return 0
  fi

  if [ "$dry" = "1" ]; then
    log "DRY_RUN: would prune ${victims_count} session(s):"
    while IFS= read -r id; do
      [ -n "$id" ] && log "  - $id"
    done < "$tmpdir/victims"
    rm -rf "$tmpdir"
    return 0
  fi

  prune_batch() {
    local ids="" id
    for id in "$@"; do ids+="'${id//\'/\'\'}',"; done
    ids="${ids%,}"
    [ -n "$ids" ] || return 0
    sqlite3 -cmd ".timeout 30000" "$DB" "PRAGMA foreign_keys=ON;
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
  done < "$tmpdir/victims"
  if [ "${#batch[@]}" -gt 0 ]; then
    prune_batch "${batch[@]}"
  fi

  rm -rf "$tmpdir"
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
