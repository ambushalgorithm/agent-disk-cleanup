#!/usr/bin/env bash
# Portable platform helpers for agent-disk-cleanup.
# Intended to be sourced, not executed. Targets bash 3.2+ (macOS system bash)
# through 5.x, on Linux, macOS, and the BSDs.
#
# Every helper avoids GNU-only flags by preferring a GNU form and falling back
# to the POSIX/BSD equivalent.

ADC_OS=""

# detect_os -> linux | macos | freebsd | openbsd | netbsd | other
detect_os() {
  if [ -z "$ADC_OS" ]; then
    case "$(uname -s 2>/dev/null || echo unknown)" in
      Linux*)   ADC_OS=linux ;;
      Darwin*)  ADC_OS=macos ;;
      FreeBSD*) ADC_OS=freebsd ;;
      OpenBSD*) ADC_OS=openbsd ;;
      NetBSD*)  ADC_OS=netbsd ;;
      *)        ADC_OS=other ;;
    esac
  fi
  printf '%s\n' "$ADC_OS"
}

have() { command -v "$1" >/dev/null 2>&1; }

# now_iso -> local time in ISO-8601. Avoids `date -Is` (GNU/newer-BSD only).
now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# df_avail_bytes <path> -> free bytes on the filesystem holding <path>.
# GNU: df -B1 --output=avail. POSIX fallback: df -Pk column 4 (1K blocks).
df_avail_bytes() {
  local p="$1" v
  v=$(df -B1 --output=avail "$p" 2>/dev/null | tail -n 1 | tr -d '[:space:]')
  case "$v" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$v"; return 0 ;;
  esac
  v=$(df -Pk "$p" 2>/dev/null | awk 'NR==2 {print $4 * 1024; exit}')
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$v"; return 0 ;;
  esac
}

# fs_device <path> -> filesystem device id. GNU stat -c %d, BSD stat -f %d.
fs_device() {
  local p="$1" v
  v=$(stat -c %d "$p" 2>/dev/null) || v=""
  case "$v" in
    ''|*[!0-9]*) v=$(stat -f %d "$p" 2>/dev/null) ;;
  esac
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$v"; return 0 ;;
  esac
}

# fs_type <path> -> filesystem type name (e.g. ext4, tmpfs, fuse), or empty.
# Linux: findmnt, then `df -P -T`. Elsewhere: best effort (often empty).
fs_type() {
  local p="$1" v=""
  if have findmnt; then
    v=$(findmnt -no FSTYPE --target "$p" 2>/dev/null) || v=""
  fi
  if [ -z "$v" ]; then
    v=$(df -P -T "$p" 2>/dev/null | awk 'NR==2 {print $2}') || v=""
    case "$v" in ''|Type|Filesystem) v="" ;; esac
  fi
  printf '%s\n' "$v"
}

# file_size <path> -> size in bytes. GNU stat -c %s, BSD stat -f %z.
file_size() {
  local p="$1" v
  v=$(stat -c %s "$p" 2>/dev/null) || v=""
  case "$v" in
    ''|*[!0-9]*) v=$(stat -f %z "$p" 2>/dev/null) ;;
  esac
  case "$v" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$v"; return 0 ;;
  esac
}

# epoch_to_human <epoch_seconds> [strftime_fmt] -> formatted local time.
# GNU date -d @x, BSD date -r x.
epoch_to_human() {
  local e="$1" fmt="${2:-%Y-%m-%d %H:%M}" v
  v=$(date -d "@$e" "+$fmt" 2>/dev/null) || v=""
  if [ -z "$v" ]; then
    v=$(date -r "$e" "+$fmt" 2>/dev/null) || v=""
  fi
  printf '%s\n' "$v"
}

# sed_inplace <sed_expression> <file>
sed_inplace() {
  local expr="$1" file="$2"
  if sed --version >/dev/null 2>&1; then
    sed -i -e "$expr" "$file"
  else
    sed -i '' -e "$expr" "$file"
  fi
}

# proc_cpu_centis <pid> -> cumulative CPU time in centiseconds (1/100 s).
# Linux reads /proc/<pid>/stat (fields 14+15, in clock ticks); macOS/BSD parse
# `ps -o time=`. Centiseconds keep the meaning of CPU_TICKS_MAX consistent
# across platforms.
proc_cpu_centis() {
  local pid="$1" v clk
  if [ -r "/proc/$pid/stat" ]; then
    clk=$(getconf CLK_TCK 2>/dev/null || echo 100)
    v=$(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    printf '%s\n' "$(( v * 100 / clk ))"
    return 0
  fi
  v=$(ps -o time= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$v" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$v" | awk '
    {
      t = $0
      days = 0
      if (index(t, "-") > 0) { split(t, d, "-"); days = d[1] + 0; t = d[2] }
      n = split(t, p, ":")
      secs = 0
      for (i = 1; i <= n; i++) secs = secs * 60 + p[i]
      printf "%d\n", (days * 86400 + secs) * 100 + 0.5
    }'
}

# list_opencode_pids -> one PID per line for processes named "opencode".
list_opencode_pids() {
  if have pgrep; then
    pgrep -x opencode 2>/dev/null
    return 0
  fi
  ps -Ao pid=,comm= 2>/dev/null | awk '{ n = split($2, a, "/"); if (a[n] == "opencode") print $1 }'
}

# resolve_home <user> -> home directory.
resolve_home() {
  local u="$1"
  if have getent; then
    getent passwd "$u" 2>/dev/null | cut -d: -f6
    return 0
  fi
  if have dscl; then
    dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
    return 0
  fi
  eval echo "~$u"
}

# service_manager -> systemd | launchd | cron | none
service_manager() {
  if have systemctl; then printf 'systemd\n'; return 0; fi
  if have launchctl; then printf 'launchd\n'; return 0; fi
  if have crontab; then printf 'cron\n'; return 0; fi
  printf 'none\n'
}

xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# subst_file <placeholder_line> <replacement_file> <template_file>
# Prints <template_file> with lines exactly equal to <placeholder_line> replaced
# by the contents of <replacement_file>. Used to inject multi-line blocks.
subst_file() {
  awk -v ph="$1" -v rf="$2" '
    $0 == ph { while ((getline line < rf) > 0) print line; close(rf); next }
    { print }
  ' "$3"
}

# schedule_entries "<DOW,..> HH:MM" -> "DOW H M" lines (DOW '*' = daily).
# Accepts systemd-style weekday names (Sun..Sat) or numbers (0-7).
schedule_entries() {
  local spec="$1" days time dow hh mm oldifs
  days="${spec%% *}"
  time="${spec##* }"
  case "$time" in
    *:*) ;;
    *) time="04:00" ;;
  esac
  hh="${time%%:*}"
  mm="${time##*:}"
  hh="${hh#0}"
  mm="${mm#0}"
  [ -n "$hh" ] || hh=0
  [ -n "$mm" ] || mm=0
  case "$days" in
    ''|'*'|daily|'*-*-*') printf '* %s %s\n' "$hh" "$mm"; return 0 ;;
  esac
  oldifs="$IFS"
  IFS=,
  for dow in $days; do
    case "$dow" in
      Sun|sun|0|7) printf '0 %s %s\n' "$hh" "$mm" ;;
      Mon|mon|1)   printf '1 %s %s\n' "$hh" "$mm" ;;
      Tue|tue|2)   printf '2 %s %s\n' "$hh" "$mm" ;;
      Wed|wed|3)   printf '3 %s %s\n' "$hh" "$mm" ;;
      Thu|thu|4)   printf '4 %s %s\n' "$hh" "$mm" ;;
      Fri|fri|5)   printf '5 %s %s\n' "$hh" "$mm" ;;
      Sat|sat|6)   printf '6 %s %s\n' "$hh" "$mm" ;;
    esac
  done
  IFS="$oldifs"
}

# launchd_intervals "<DOW,..> HH:MM" -> StartCalendarInterval <dict> XML.
launchd_intervals() {
  local dow h m
  schedule_entries "$1" | while read -r dow h m; do
    printf '\t\t<dict>\n'
    if [ "$dow" != "*" ]; then
      printf '\t\t\t<key>Weekday</key>\n\t\t\t<integer>%s</integer>\n' "$dow"
    fi
    printf '\t\t\t<key>Hour</key>\n\t\t\t<integer>%s</integer>\n' "$h"
    printf '\t\t\t<key>Minute</key>\n\t\t\t<integer>%s</integer>\n' "$m"
    printf '\t\t</dict>\n'
  done
}

# cron_expr "<DOW,..> HH:MM" -> "M H * * DOW"
cron_expr() {
  local dow h m hh="" mm="" dows="" first=1
  while read -r dow h m; do
    if [ "$first" = "1" ]; then hh="$h"; mm="$m"; first=0; fi
    if [ "$dow" = "*" ]; then
      dows="*"
    elif [ "$dows" = "*" ]; then
      :
    elif [ -z "$dows" ]; then
      dows="$dow"
    else
      dows="$dows,$dow"
    fi
  done < <(schedule_entries "$1")
  printf '%s %s * * %s\n' "${mm:-0}" "${hh:-4}" "${dows:-*}"
}

# cron_block_merge <begin> <end> <install|remove> <line> <in> <out>
# Rewrites a crontab-style file, replacing/removing the marked block.
cron_block_merge() {
  local begin="$1" end="$2" action="$3" line="$4" infile="$5" outfile="$6"
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip = 1 }
    skip != 1 { print }
    $0 == e { skip = 0 }' "$infile" > "$outfile"
  if [ "$action" = "install" ]; then
    {
      printf '%s\n' "$begin"
      printf '%s\n' "$line"
      printf '%s\n' "$end"
    } >> "$outfile"
  fi
}

# find_secondary_fs <db_dir> [min_free_bytes]
# Prints a writable base directory on a filesystem different from <db_dir>'s,
# with at least <min_free_bytes> free, or returns 1 if none is available.
find_secondary_fs() {
  local db_dir="$1" min_free="${2:-$(( 2 * 1024 * 1024 * 1024 ))}"
  local db_dev mnt dev base avail fst
  db_dev=$(fs_device "$db_dir" 2>/dev/null) || return 1
  while IFS= read -r mnt; do
    case "$mnt" in
      /|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*|/System/Volumes/*) continue ;;
    esac
    fst=$(fs_type "$mnt")
    case "$fst" in
      tmpfs|devtmpfs|ramfs|overlay|squashfs|nfs*|cifs|smb*|fuse*|9p|sshfs|afs|autofs) continue ;;
    esac
    dev=$(fs_device "$mnt" 2>/dev/null) || continue
    [ "$dev" = "$db_dev" ] && continue
    if [ -w "$mnt" ]; then
      base="$mnt"
    elif [ -n "${USER:-}" ] && [ -d "$mnt/$USER" ] && [ -w "$mnt/$USER" ]; then
      base="$mnt/$USER"
    else
      continue
    fi
    avail=$(df_avail_bytes "$base" 2>/dev/null) || continue
    [ "${avail:-0}" -ge "$min_free" ] || continue
    printf '%s\n' "$base/agent-disk-cleanup-convert"
    return 0
  done < <(df -P 2>/dev/null | awk 'NR > 1 {print $NF}')
  return 1
}
