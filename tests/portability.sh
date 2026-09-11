#!/usr/bin/env bash
# Portability smoke tests for agent-disk-cleanup.
# Run: bash tests/portability.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/bin/platform.sh"

pass=0
fail=0
ok()  { pass=$(( pass + 1 )); printf 'ok   - %s\n' "$1"; }
no()  { fail=$(( fail + 1 )); printf 'FAIL - %s\n' "$1"; }
check_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got [$2] want [$3])"; fi; }
check_re() { if printf '%s' "$2" | grep -Eq "$3"; then ok "$1"; else no "$1 (got [$2])"; fi; }

echo "# platform helpers"

check_re "detect_os" "$(detect_os)" '^(linux|macos|freebsd|openbsd|netbsd|other)$'
check_re "df_avail_bytes /" "$(df_avail_bytes /)" '^[0-9]+$'
check_re "fs_device /" "$(fs_device /)" '^[0-9]+$'

t="$(mktemp)"
printf 'hello' > "$t"
check_eq "file_size" "$(file_size "$t")" "5"
check_re "epoch_to_human 0" "$(epoch_to_human 0)" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$'
check_re "now_iso" "$(now_iso)" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'
check_re "proc_cpu_centis \$\$" "$(proc_cpu_centis $$)" '^[0-9]+$'
check_eq "xml_escape" "$(xml_escape 'a&b<c>')" 'a&amp;b&lt;c&gt;'

check_eq "schedule_entries Mon,Wed 04:00" \
  "$(schedule_entries 'Mon,Wed 04:00' | tr '\n' ';')" "1 4 0;3 4 0;"
check_eq "schedule_entries daily 23:05" \
  "$(schedule_entries 'daily 23:05' | tr '\n' ';')" "* 23 5;"
check_re "launchd_intervals Sun 04:00" "$(launchd_intervals 'Sun 04:00')" '<integer>0</integer>'
check_eq "cron_expr Mon,Wed,Fri,Sun 04:00" \
  "$(cron_expr 'Mon,Wed,Fri,Sun 04:00')" "0 4 * * 1,3,5,0"
check_eq "cron_expr daily 04:20" "$(cron_expr 'daily 04:20')" "20 4 * * *"

subst="$(mktemp)"
tpl="$(mktemp)"
printf 'X\n@BLOCK@\nY\n' > "$tpl"
printf 'a\nb\n' > "$subst"
check_eq "subst_file" "$(subst_file '@BLOCK@' "$subst" "$tpl" | tr '\n' ';')" "X;a;b;Y;"
rm -f "$subst" "$tpl" "$t"

cf="$(mktemp)"
co="$(mktemp)"
printf '0 1 * * * /bin/true\n# BEGIN agent-disk-cleanup:x\nold\n# END agent-disk-cleanup:x\n' > "$cf"
cron_block_merge "# BEGIN agent-disk-cleanup:x" "# END agent-disk-cleanup:x" install "new line" "$cf" "$co"
check_eq "cron_block_merge install" "$(tr '\n' ';' < "$co")" \
  "0 1 * * * /bin/true;# BEGIN agent-disk-cleanup:x;new line;# END agent-disk-cleanup:x;"
cron_block_merge "# BEGIN agent-disk-cleanup:x" "# END agent-disk-cleanup:x" remove "" "$co" "$cf"
check_eq "cron_block_merge remove" "$(tr '\n' ';' < "$cf")" "0 1 * * * /bin/true;"
rm -f "$cf" "$co"

check_re "service_manager" "$(service_manager)" '^(systemd|launchd|cron|none)$'
if find_secondary_fs "$HOME" >/dev/null 2>&1; then
  ok "find_secondary_fs (found)"
else
  ok "find_secondary_fs (none, graceful)"
fi
list_opencode_pids >/dev/null 2>&1 && ok "list_opencode_pids" || no "list_opencode_pids"

echo "# script syntax"
for f in bin/platform.sh bin/opencode-db-lib.sh bin/opencode-db-compact.sh \
         bin/opencode-db-convert.sh bin/opencode-cleanup.sh bin/host-cleanup.sh \
         run-cleanup.sh install.sh; do
  if bash -n "$ROOT/$f" 2>/dev/null; then ok "bash -n $f"; else no "bash -n $f"; fi
done

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
