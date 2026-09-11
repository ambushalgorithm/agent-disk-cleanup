#!/usr/bin/env bash
# Tests for run-cleanup.sh: DB discovery via `opencode db path`, backup
# handling (removed on success, kept on failure/KEEP_BACKUP=1), and exit codes.
# Run: bash tests/run-cleanup.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOXES=""
trap 'for d in $SANDBOXES; do rm -rf "$d"; done' EXIT

pass=0; fail=0
ok() { pass=$(( pass + 1 )); printf 'ok   - %s\n' "$1"; }
no() { fail=$(( fail + 1 )); printf 'FAIL - %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got [$2] want [$3])"; fi; }

# make_sandbox <compact_exit_code> -> prints sandbox dir
make_sandbox() {
  local sb
  sb="$(mktemp -d)"
  SANDBOXES="$SANDBOXES $sb"
  mkdir -p "$sb/bin" "$sb/fakebin"
  cp "$ROOT/bin/platform.sh" "$ROOT/bin/opencode-db-lib.sh" "$sb/bin/"
  cp "$ROOT/run-cleanup.sh" "$sb/run-cleanup.sh"
  chmod +x "$sb/run-cleanup.sh"
  printf '#!/usr/bin/env bash\necho "compact DB=$OPENCODE_DB"\nexit %s\n' "$1" \
    > "$sb/bin/opencode-db-compact.sh"
  chmod +x "$sb/bin/opencode-db-compact.sh"
  sqlite3 "$sb/opencode.db" "CREATE TABLE session(id TEXT, time_updated INTEGER);
    INSERT INTO session VALUES('a',1);"
  cat > "$sb/fakebin/opencode" <<EOF
#!/bin/sh
[ "\$1" = "db" ] && [ "\$2" = "path" ] && { echo "$sb/opencode.db"; exit 0; }
exit 1
EOF
  printf '#!/bin/sh\nexit 1\n' > "$sb/fakebin/pgrep"
  chmod +x "$sb/fakebin/opencode" "$sb/fakebin/pgrep"
  printf '%s\n' "$sb"
}

echo "# success (default): backup removed"
sb="$(make_sandbox 0)"
out="$(PATH="$sb/fakebin:$PATH" REPO="$sb" "$sb/run-cleanup.sh" 2>&1)"
rc=$?
eq "exits 0" "$rc" "0"
printf '%s' "$out" | grep -q "$sb/opencode.db" && ok "detected DB via opencode db path" || no "detected DB via opencode db path"
printf '%s' "$out" | grep -q "compact DB=$sb/opencode.db" && ok "passed DB to compact" || no "passed DB to compact"
if ls "$sb"/opencode.db.bak.* >/dev/null 2>&1; then no "backup removed by default"; else ok "backup removed by default"; fi

echo "# success with KEEP_BACKUP=1: backup retained"
sb="$(make_sandbox 0)"
out="$(PATH="$sb/fakebin:$PATH" REPO="$sb" KEEP_BACKUP=1 "$sb/run-cleanup.sh" 2>&1)"
rc=$?
eq "exits 0" "$rc" "0"
if ls "$sb"/opencode.db.bak.* >/dev/null 2>&1; then ok "backup retained"; else no "backup retained"; fi

echo "# failure: backup retained and rc propagated"
sb="$(make_sandbox 3)"
out="$(PATH="$sb/fakebin:$PATH" REPO="$sb" "$sb/run-cleanup.sh" 2>&1)"
rc=$?
eq "exits with compact code" "$rc" "3"
printf '%s' "$out" | grep -q "Backup kept at" && ok "reports backup kept" || no "reports backup kept"
if ls "$sb"/opencode.db.bak.* >/dev/null 2>&1; then ok "backup retained on failure"; else no "backup retained on failure"; fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
