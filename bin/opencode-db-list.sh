#!/usr/bin/env bash
# opencode-db-list.sh - list opencode session directories with their policy.
#
# Read-only. Shows, per directory: session count, oldest/newest activity, and
# the retention policy that will be applied (keep / inactive_min / days).
#
# Usage:
#   ./bin/opencode-db-list.sh [--sizes]
#
# Env:
#   OPENCODE_DB          database path (default: `opencode db path` / XDG)
#   POLICIES_FILE        per-directory policy table (see docs/DESIGN.md)
#   KEEP_RECENT_SESSIONS default keep (default 10)
#   RETENTION_DAYS       default days (default 0)
#   INACTIVE_MINUTES     default idle grace in minutes (default 0)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/opencode-db-lib.sh"

SIZES=0
for arg in "$@"; do
  case "$arg" in
    --sizes) SIZES=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

DB="${OPENCODE_DB:-$(default_db_path)}"
[ -f "$DB" ] || { printf 'database not found: %s\n' "$DB" >&2; exit 1; }

def_keep="${KEEP_RECENT_SESSIONS:-10}"
def_inactive="${INACTIVE_MINUTES:-0}"
def_days="${RETENTION_DAYS:-0}"
load_policies "$def_keep" "$def_inactive" "$def_days"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

sizes="$tmpdir/sizes"
: > "$sizes"
if [ "$SIZES" = "1" ]; then
  sqlite3 -readonly -separator '	' "$DB" "
    SELECT s.directory, sum(x.bytes) FROM (
      SELECT session_id, length(data) AS bytes FROM part
      UNION ALL
      SELECT session_id, length(data) FROM message
      UNION ALL
      SELECT aggregate_id AS session_id, length(data) FROM event
    ) x JOIN session s ON s.id = x.session_id
    GROUP BY s.directory;" > "$sizes" 2>/dev/null || true
fi

size_for() {
  [ "$SIZES" = "1" ] || { printf '%s\n' "-"; return 0; }
  awk -F'\t' -v d="$1" '$1 == d { printf "%.1f", $2 / 1048576.0; found=1 } END { if (!found) printf "0.0" }' "$sizes"
}

if [ "$SIZES" = "1" ]; then
  printf '%-9s %-11s %-11s %-5s %-8s %-4s %-8s %s\n' \
    SESSIONS OLDEST NEWEST KEEP INACTIVE DAYS MB DIRECTORY
else
  printf '%-9s %-11s %-11s %-5s %-8s %-4s %s\n' \
    SESSIONS OLDEST NEWEST KEEP INACTIVE DAYS DIRECTORY
fi

sqlite3 -readonly -separator '	' "$DB" "
  SELECT directory, count(*), min(time_updated), max(time_updated)
  FROM session GROUP BY directory ORDER BY count(*) DESC;" |
while IFS='	' read -r dir n mn mx; do
  [ -n "$dir" ] || continue
  pol="$(policy_for_dir "$dir")"
  k="${pol%% *}"; pol="${pol#* }"
  ina="${pol%% *}"; dd="${pol#* }"
  oldest=$(epoch_to_human $(( ${mn:-0} / 1000 )) '%Y-%m-%d')
  newest=$(epoch_to_human $(( ${mx:-0} / 1000 )) '%Y-%m-%d')
  if [ "$SIZES" = "1" ]; then
    printf '%-9s %-11s %-11s %-5s %-8s %-4s %-8s %s\n' \
      "$n" "$oldest" "$newest" "$k" "$ina" "$dd" "$(size_for "$dir")" "$dir"
  else
    printf '%-9s %-11s %-11s %-5s %-8s %-4s %s\n' \
      "$n" "$oldest" "$newest" "$k" "$ina" "$dd" "$dir"
  fi
done

printf '\n(policy: default keep=%s inactive=%sm days=%s; POLICIES_FILE=%s)\n' \
  "$def_keep" "$def_inactive" "$def_days" "${POLICIES_FILE:-<auto/no policies.conf>}"
