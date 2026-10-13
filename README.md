# agent-disk-cleanup

Portable cleanup automation for machines that run [opencode](https://opencode.ai).
It prunes old opencode session data and reclaims the space **without ever
temporarily consuming more disk space**, and optionally trims Docker build
cache, `journald`, the `apt` cache, or macOS maintenance scripts.

Runs on **Linux** (systemd), **macOS** (launchd), and other Unix systems
(cron). The shell code avoids GNU-only flags and falls back to BSD/POSIX
equivalents.

## The problem

opencode keeps an append-only SQLite database (`opencode.db`) whose `event` table
grows without bound. Deleting old sessions does **not** shrink the file: SQLite
moves freed pages to a *freelist* and reuses them. Reclaiming the space normally
requires `VACUUM`, which writes a full second copy first — up to **2× the
database size** in temporary space. On a nearly-full disk that makes a "cleanup"
fill the disk instead.

## How this fixes it

1. **One-time conversion** (`opencode-db-convert.sh`): rebuilds the database in
   `auto_vacuum=INCREMENTAL` mode. The second copy is built on a **different
   filesystem**, and the old file is deleted before the new one is copied back,
   so the database's filesystem usage only ever goes **down**.
2. **Recurring prune** (`opencode-db-compact.sh`): deletes sessions older than
   the retention window and runs `PRAGMA incremental_vacuum`, which truncates
   freelist pages **in place with no temporary copy**. Zero I/O amplification.

Safety rails in every script:

- **Never terminates opencode.** Cleanup sends no signals. Anything a running
  opencode process references — a session id on its command line, or its
  working directory — is **never** pruned, so open or frozen sessions survive.
- Pruning runs concurrently with opencode. Only the one-time off-root
  conversion needs it closed, and that is deferred until it is.
- `VACUUM`/conversion is refused unless enough free space exists; aborts leave
  the database untouched.
- A trap removes temporary files (and restores the database if interrupted
  mid-swap).
- **Per-directory policies** (`policies.conf`) decide retention. By default the
  `KEEP_RECENT_SESSIONS` (default 10) most recent top-level sessions **per
  directory** (and their sub-sessions) are kept; rules can keep nothing in
  disposable directories (e.g. agent working dirs) once they have been idle.
- Idempotent; re-running is safe.

## Contents

| Path | Purpose |
| --- | --- |
| `bin/platform.sh` | Portable helpers (OS detection, `df`/`stat`/`date`/CPU fallbacks, scheduling) |
| `bin/opencode-db-lib.sh` | Shared helpers (logging, live-session protection, per-directory policies, prune) |
| `bin/opencode-db-compact.sh` | Recurring prune + `incremental_vacuum` |
| `bin/opencode-db-list.sh` | List directories with their session counts and policy |
| `bin/opencode-db-convert.sh` | One-time off-root conversion to incremental |
| `bin/opencode-cleanup.sh` | Docker builder prune, then the DB prune |
| `bin/host-cleanup.sh` | journald/apt (Linux) or `periodic` (macOS) |
| `run-cleanup.sh` | One-shot runner: backup + prune + optional one-time conversion |
| `systemd/*.in` | Unit templates rendered by the installer |
| `launchd/*.plist.in` | launchd agent/daemon templates rendered by the installer |
| `install.sh` | Idempotent installer / uninstaller (systemd/launchd/cron) |
| `cleanup.conf.example` | Configuration reference |
| `policies.conf.example` | Per-directory retention policy reference |
| `tests/` | Cross-platform helper, prune, policy, and protection tests |
| `docs/DESIGN.md` | Design notes and rationale |

## Platform support

| Platform | Scheduler | Host cleanup |
| --- | --- | --- |
| Linux | systemd timers | `journald` cap/vacuum, `apt-get clean` |
| macOS | launchd agents/daemons | `periodic` (opt-in via `ENABLE_MACOS_CLEANUP=1`) |
| Other Unix/BSD | cron (`crontab`) | journald/apt where available |

The installer picks the scheduler automatically. A user-level agent runs the
opencode/Docker cleanup; a root-level daemon/service runs host cleanup.


## Installation

Run as the user whose home directory hosts opencode (the installer calls `sudo`
for the systemd units):

```bash
git clone git@github.com:ambushalgorithm/agent-disk-cleanup.git
cd agent-disk-cleanup
cp cleanup.conf.example cleanup.conf   # optional; edit as needed
./install.sh
```

The installer:

- checks for `bash` and `sqlite3`, and for a scheduler
  (`systemctl`, `launchctl`, or `crontab`); docker/opencode are optional;
- copies the user scripts to `$SCRIPT_DIR` (default `$HOME/bin`);
- installs the root helper under `/usr/local/lib/agent-disk-cleanup/`;
- writes `/etc/agent-disk-cleanup.conf` and the scheduler entries;
- enables the opencode/Docker job and the host-cleanup job.

Preview changes without touching anything:

```bash
./install.sh --dry-run
```

### Uninstall

```bash
./install.sh --uninstall          # disable/remove units, keep scripts
./install.sh --uninstall --purge  # also remove installed scripts/env file
```

## Quick cleanup (no install)

`run-cleanup.sh` runs everything in place, with no installer or sudo. It takes a
consistent backup, prunes, and performs the one-time conversion:

```bash
./run-cleanup.sh                  # backup + prune + convert
./run-cleanup.sh --dry-run        # show what would be pruned, change nothing
./run-cleanup.sh --list           # list directories and their policy
./run-cleanup.sh --list --sizes   # ...with estimated database MB per directory
RETENTION_DAYS=7 ./run-cleanup.sh # change the default retention for this run
```

Pruning is safe while opencode is running: it protects anything a live opencode
process references and never sends signals. The one-time conversion still needs
opencode closed and is deferred until it is. The backup is removed automatically
after a successful run; set `KEEP_BACKUP=1` to retain it, or `BACKUP=0` to skip
the backup entirely. On failure the backup is always kept.

## Configuration

`cleanup.conf` (or environment variables):

| Variable | Default | Meaning |
| --- | --- | --- |
| `SCRIPT_DIR` | `$HOME/bin` | Where user scripts are installed |
| `RETENTION_DAYS` | `0` | default age cutoff in days (`0` = count-only, no time floor) |
| `KEEP_RECENT_SESSIONS` | `10` | default: always keep this many recent top-level sessions **per directory** (and their sub-sessions) |
| `INACTIVE_MINUTES` | `0` | default idle grace before a session becomes eligible |
| `POLICIES_FILE` | auto | per-directory policy table (see `policies.conf.example`) |
| `CPU_TICKS_MAX` | `150` | CPU sample threshold used when gating exclusive operations |
| `REBUILD_FREELIST_PAGES` | `100000` | Rebuild off-root when the freelist exceeds this many pages |
| `REBUILD_FREELIST_PCT` | `25` | …or when the freelist is more than this % of the file |
| `VACUUM_PAGES_PER_RUN` | `50000` | Pages freed per run via bounded `incremental_vacuum` |
| `SCHEDULE` | `Mon,Wed,Fri,Sun 04:00` | opencode/Docker job schedule (`DOW-list HH:MM`) |
| `HOST_SCHEDULE` | `Mon,Wed,Fri,Sun 04:20` | host cleanup schedule |
| `RANDOMIZED_DELAY` | `600` | systemd jitter in seconds |
| `CONVERT_DIR` | auto-detected | Off-root build dir for the one-time conversion (empty = auto) |
| `OPENCODE_DB` | auto-detected | Database path (`opencode db path` / XDG) |
| `CONVERT` | `0` | Let the scheduled job run the one-time conversion |
| `ENABLE_DOCKER_PRUNE` | `1` | Run `docker builder prune -af` and `docker image prune -af` |
| `ENABLE_JOURNALD` | `1` | Cap + vacuum `journald` |
| `JOURNAL_MAX_USE` | `500M` | `SystemMaxUse` for `journald` |
| `ENABLE_APT_CLEAN` | `1` | Run `apt-get clean` |
| `ENABLE_MACOS_CLEANUP` | `0` | Run macOS `periodic` maintenance |

## One-time conversion

If the database is not yet in `auto_vacuum=incremental` mode, the recurring job
only deletes rows (so it never grows) but cannot shrink the file. Convert once:

```bash
# quit all opencode instances first
CONVERT=1 "$HOME/bin/opencode-db-compact.sh"
```

Or set `CONVERT=1` in `cleanup.conf` before installing to have the scheduled job
perform it on the first run where opencode is closed. The scheduled job never
stops opencode, so the conversion is simply deferred until then.

Requirements:

- If a secondary filesystem is available, `CONVERT_DIR` is auto-detected and
  used, so the database filesystem only ever decreases in usage during the
  swap. If none is available, the conversion builds on the database filesystem
  and temporarily needs ~2× the live database in free space (set
  `ALLOW_SAME_FS=1` to acknowledge this, or point `CONVERT_DIR` at another
  filesystem).

After conversion, every scheduled run reclaims space in place.

## Testing

```bash
bash tests/portability.sh   # helper + syntax smoke tests
bash tests/prune.sh         # prune/cascade/retention-floor functional test
bash tests/policies.sh      # per-directory policies + live-session protection
./install.sh --dry-run      # preview scheduler changes
```

## Troubleshooting

- **"opencode running; deferred rebuild/conversion"** — routine pruning already
  ran; the exclusive rebuild/conversion waits until opencode is closed.
- **"not incremental; skipping vacuum"** — run the one-time conversion (above);
  no growth occurs until then.
- **Docker prune**: set `ENABLE_DOCKER_PRUNE=0` to disable.
- **Logs (Linux)**: `journalctl -u opencode-cleanup -u host-cleanup`.
- **Logs (macOS)**: `~/.local/state/agent-disk-cleanup/opencode-cleanup.log`
  and `/var/log/agent-disk-cleanup/host-cleanup.log`.
- **macOS job didn't run**: check `launchctl list | grep agent-disk-cleanup`
  and confirm the agent is loaded (`launchctl print gui/$(id -u)/com.agent-disk-cleanup.opencode`).
- **cron fallback**: inspect with `crontab -l` (user) and `sudo crontab -l` (root).

## License

MIT — see [LICENSE](LICENSE).
