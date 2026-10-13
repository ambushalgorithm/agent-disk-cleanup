#!/usr/bin/env bash
# Functional test for per-directory policies and live-session protection.
# Run: bash tests/policies.sh
#
# Exercises:
# - policy_for_dir glob matching (first match wins)
# - a keep=0 rule deletes everything in a directory
# - the default keep floor retains the most recent N per directory
# - a per-directory inactive_min guard protects recently-touched sessions
# - sessions in a directory a live opencode process sits in are never pruned
# - sessions referenced by a live process id in argv are never pruned
# - sub-sessions of a protected parent are kept
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/bin/opencode-db-lib.sh"

pass=0; fail=0
ok() { pass=$(( pass + 1 )); printf 'ok   - %s\n' "$1"; }
no() { fail=$(( fail + 1 )); printf 'FAIL - %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got [$2] want [$3])"; fi; }

DB="$(mktemp -u).db"
POL="$(mktemp)"
trap 'rm -f "$DB" "$DB-wal" "$DB-shm" "$POL"' EXIT

sqlite3 "$DB" <<'SQL'
CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT, time_updated INTEGER);
CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT REFERENCES session(id) ON DELETE CASCADE);
CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT REFERENCES message(id) ON DELETE CASCADE);
CREATE TABLE event_sequence(aggregate_id TEXT PRIMARY KEY);
CREATE TABLE event(id TEXT PRIMARY KEY, aggregate_id TEXT REFERENCES event_sequence(aggregate_id) ON DELETE CASCADE);
SQL

now=$(date +%s)
ms() { echo $(( ($1) * 1000 )); }
old=$(( now - 10*86400 ))
recent=$(( now - 300 ))     # 5 minutes
mid=$(( now - 20*3600 ))    # 20 hours

add() { # id parent dir updated_secs
  local id="$1" parent="$2" dir="$3" t="$4"
  local p
  case "$parent" in -|NULL) p="NULL" ;; *) p="'$parent'" ;; esac
  sqlite3 "$DB" "INSERT INTO session VALUES('$id',$p,'$dir',$(ms "$t"));
    INSERT INTO event_sequence VALUES('$id');
    INSERT INTO event VALUES('e_$id','$id');"
}

# default-keep dir: 3 sessions, newest retained by the default keep=1
add K1 NULL /keep "$old"
add K2 NULL /keep "$old"
add K3 NULL /keep "$old"        # newest of /keep
add KC K3   /keep "$old"        # sub of the kept parent -> must survive

# slot dir: keep=0 -> all pruned
add S1 NULL /slot-1 "$old"
add S2 NULL /slot-1 "$old"

# idle dir: keep=0 but inactive_min=600 (10h) -> recent survives, 20h-old pruned
add I1 NULL /idle-1 "$mid"
add I2 NULL /idle-1 "$recent"

# live dir: keep=0, but a live process sits in it -> all survive
add L1 NULL /live-1 "$old"
add L2 NULL /live-1 "$old"

# argv-protected session in a default dir (P0 is newer, so keep=1 would prune P1)
add P0 NULL /argv-1 "$mid"
add P1 NULL /argv-1 "$old"

cat > "$POL" <<'EOF'
# first match wins
*/slot-*    0   0    0
*/idle-*    0   600  0
*/live-*    0   0    0
*           1   0    0
EOF

# Simulate live opencode references.
list_live_session_ids() { printf '%s\n' "P1"; }
list_live_dirs() { printf '%s\n' "/live-1"; }
pending_input_session_ids() { :; }

POLICIES_FILE="$POL" KEEP_RECENT_SESSIONS=1 INACTIVE_MINUTES=0 BATCH=2 prune_sessions 0 2>/dev/null

survivors="$(sqlite3 "$DB" "SELECT group_concat(id,',') FROM (SELECT id FROM session ORDER BY id);")"
eq "kept (keep floor + live + inactive + subsession)" "$survivors" "I2,K3,KC,L1,L2,P0,P1"

events="$(sqlite3 "$DB" "SELECT group_concat(id,',') FROM (SELECT id FROM event ORDER BY id);")"
eq "events cascade with sessions" "$events" "e_I2,e_K3,e_KC,e_L1,e_L2,e_P0,e_P1"

# policy_for_dir ordering (specific before catch-all)
POLICIES_FILE="$POL"
load_policies 9 0 0
eq "slot rule wins"   "$(policy_for_dir /x/slot-1/app)" "0 0 0"
eq "idle rule wins"   "$(policy_for_dir /x/idle-1)"     "0 600 0"
eq "catch-all applies" "$(policy_for_dir /x/other)"     "1 0 0"

# with no policies file, the passed defaults apply
unset POLICIES_FILE
load_policies 9 0 0
eq "defaults with no file" "$(policy_for_dir /x/other)" "9 0 0"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
