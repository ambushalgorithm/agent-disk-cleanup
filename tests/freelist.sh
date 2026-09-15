#!/usr/bin/env bash
# Unit test for the needs_rebuild() freelist decision.
# Run: bash tests/freelist.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/bin/opencode-db-lib.sh"

pass=0; fail=0
ok() { pass=$(( pass + 1 )); printf 'ok   - %s\n' "$1"; }
no() { fail=$(( fail + 1 )); printf 'FAIL - %s\n' "$1"; }

# expect <want 0|1> <desc> <freelist> <page_count>
# 0 = needs rebuild, 1 = incremental_vacuum is fine
expect() {
  local want="$1" desc="$2" freelist="$3" total="$4" got=1
  if needs_rebuild "$freelist" "$total"; then got=0; fi
  if [ "$got" = "$want" ]; then ok "$desc"; else no "$desc (got $got want $want)"; fi
}

# defaults: REBUILD_FREELIST_PAGES=100000, REBUILD_FREELIST_PCT=25
expect 1 "empty freelist -> incremental" 0 1000000
expect 1 "small freelist -> incremental" 10 1000000
expect 1 "20% below absolute -> incremental" 50000 250000
expect 0 "over absolute threshold -> rebuild" 200000 1000000
expect 0 "over 25% but below absolute -> rebuild" 90000 300000
expect 0 "over 25% -> rebuild" 300000 1000000
expect 0 "freelist larger than file -> rebuild" 900000 1000000
expect 1 "garbage input -> incremental" abc 1000000
expect 1 "zero pages -> incremental" 10 0

REBUILD_FREELIST_PAGES=1000
expect 0 "custom absolute threshold" 5000 1000000
expect 1 "below custom absolute threshold" 500 1000000
unset REBUILD_FREELIST_PAGES

REBUILD_FREELIST_PCT=5
expect 0 "custom pct threshold" 60000 1000000
expect 1 "below custom pct threshold" 40000 1000000
unset REBUILD_FREELIST_PCT

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
