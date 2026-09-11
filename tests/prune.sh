#!/usr/bin/env bash
# Functional test for prune_sessions against a synthetic opencode-like schema.
# Run: bash tests/prune.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/bin/opencode-db-lib.sh"

DB="$(mktemp -u).db"
trap 'rm -f "$DB" "$DB-wal" "$DB-shm"' EXIT

sqlite3 "$DB" <<'SQL'
CREATE TABLE session(id TEXT PRIMARY KEY, parent_id TEXT, time_updated INTEGER);
CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT REFERENCES session(id) ON DELETE CASCADE);
CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT REFERENCES message(id) ON DELETE CASCADE);
CREATE TABLE event_sequence(aggregate_id TEXT PRIMARY KEY);
CREATE TABLE event(id TEXT PRIMARY KEY, aggregate_id TEXT REFERENCES event_sequence(aggregate_id) ON DELETE CASCADE);
SQL

now=$(date +%s)
ms() { echo $(( ($1) * 1000 )); }
a=$(ms $(( now - 10*86400 )))
b=$(ms $(( now - 8*86400 )))
c=$(ms $(( now - 6*86400 )))
d=$(ms $(( now - 4*86400 )))

for s in "A $a" "B $b" "C $c" "D $d"; do
  id="${s%% *}"; t="${s##* }"
  sqlite3 "$DB" "INSERT INTO session VALUES('$id',NULL,$t);
    INSERT INTO message VALUES('m_$id','$id');
    INSERT INTO part VALUES('p_$id','m_$id');
    INSERT INTO event_sequence VALUES('$id');
    INSERT INTO event VALUES('e_$id','$id');"
done
sqlite3 "$DB" "INSERT INTO session VALUES('D1','D',$d);
  INSERT INTO message VALUES('m_D1','D1');
  INSERT INTO part VALUES('p_D1','m_D1');
  INSERT INTO event_sequence VALUES('D1');
  INSERT INTO event VALUES('e_D1','D1');"

KEEP_RECENT_SESSIONS=1 BATCH=2 prune_sessions 2 >/dev/null

pass=0; fail=0
ok() { pass=$(( pass + 1 )); printf 'ok   - %s\n' "$1"; }
no() { fail=$(( fail + 1 )); printf 'FAIL - %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got [$2] want [$3])"; fi; }

eq "sessions kept" "$(sqlite3 "$DB" "SELECT group_concat(id,',') FROM (SELECT id FROM session ORDER BY id);")" "D,D1"
eq "messages kept" "$(sqlite3 "$DB" "SELECT group_concat(id,',') FROM (SELECT id FROM message ORDER BY id);")" "m_D,m_D1"
eq "parts kept" "$(sqlite3 "$DB" "SELECT group_concat(id,',') FROM (SELECT id FROM part ORDER BY id);")" "p_D,p_D1"
eq "events kept" "$(sqlite3 "$DB" "SELECT group_concat(id,',') FROM (SELECT id FROM event ORDER BY id);")" "e_D,e_D1"
eq "event_sequence kept" "$(sqlite3 "$DB" "SELECT group_concat(aggregate_id,',') FROM (SELECT aggregate_id FROM event_sequence ORDER BY aggregate_id);")" "D,D1"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
