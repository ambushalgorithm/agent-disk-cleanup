# agent-disk-cleanup

Portable cleanup automation for machines that run [opencode](https://opencode.ai).
It prunes old opencode session data and reclaims the space **without ever
temporarily consuming more disk space**, and optionally trims Docker build
cache, `journald`, and the `apt` cache.

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

- Only runs when the opencode database is idle (no recent session activity and
  near-zero CPU); otherwise it skips and leaves opencode running.
- Graceful `SIGTERM`, then `SIGKILL` after a timeout, then verifies the database
  is no longer open.
- `VACUUM`/conversion is refused unless enough free space exists; aborts leave
  the database untouched.
- A trap removes temporary files (and restores the database if interrupted
  mid-swap).
- Idempotent; re-running is safe.

## Contents

| Path | Purpose |
| --- | --- |
| `bin/opencode-db-lib.sh` | Shared helpers (logging, idle detection, prune) |
| `bin/opencode-db-compact.sh` | Recurring prune + `incremental_vacuum` |
| `bin/opencode-db-convert.sh` | One-time off-root conversion to incremental |
| `bin/opencode-cleanup.sh` | Docker builder prune, then the DB prune |
| `bin/host-cleanup.sh` | journald cap/vacuum and `apt` cache (root) |
| `systemd/*.in` | Unit templates rendered by the installer |
| `install.sh` | Idempotent installer / uninstaller |
| `cleanup.conf.example` | Configuration reference |
| `docs/DESIGN.md` | Design notes and rationale |

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

- checks for `bash`, `sqlite3`, and `systemd` (docker/opencode optional);
- copies the user scripts to `$SCRIPT_DIR` (default `$HOME/bin`);
- installs the root helper under `/usr/local/lib/agent-disk-cleanup/`;
- writes `/etc/agent-disk-cleanup.conf` and the systemd units;
- enables `opencode-cleanup.timer` and `host-cleanup.timer`.

Preview changes without touching anything:

```bash
./install.sh --dry-run
```

### Uninstall

```bash
./install.sh --uninstall          # disable/remove units, keep scripts
./install.sh --uninstall --purge  # also remove installed scripts/env file
```

## Configuration

`cleanup.conf` (or environment variables):

| Variable | Default | Meaning |
| --- | --- | --- |
| `SCRIPT_DIR` | `$HOME/bin` | Where user scripts are installed |
| `RETENTION_DAYS` | `2` | opencode sessions older than this are pruned |
| `SCHEDULE` | `Mon,Wed,Fri,Sun 04:00` | opencode/Docker timer |
| `HOST_SCHEDULE` | `Mon,Wed,Fri,Sun 04:20` | host cleanup timer |
| `RANDOMIZED_DELAY` | `600` | systemd jitter in seconds |
| `CONVERT_DIR` | auto-detected | Off-root build dir for the one-time conversion |
| `OPENCODE_DB` | auto-detected | Database path (`opencode db path` / XDG) |
| `ENABLE_DOCKER_PRUNE` | `1` | Run `docker builder prune -af` |
| `ENABLE_JOURNALD` | `1` | Cap + vacuum `journald` |
| `JOURNAL_MAX_USE` | `500M` | `SystemMaxUse` for `journald` |
| `ENABLE_APT_CLEAN` | `1` | Run `apt-get clean` |

## One-time conversion

If the database is not yet in `auto_vacuum=incremental` mode, the recurring job
only deletes rows (so it never grows) but cannot shrink the file. Convert once:

```bash
# quit all opencode instances first
CONVERT=1 "$HOME/bin/opencode-db-compact.sh"
```

Requirements:

- `CONVERT_DIR` must be on a **different filesystem** with free space roughly
  equal to the live database size. The script refuses otherwise (override with
  `ALLOW_SAME_FS=1` only if you accept a temporary increase).
- The database filesystem only ever decreases in usage during the swap.

After conversion, every scheduled run reclaims space in place.

## Troubleshooting

- **"opencode active; skipping"** — the job intentionally skips when opencode is
  busy or recently active. It retries on the next schedule.
- **"not incremental; skipping vacuum"** — run the one-time conversion (above);
  no growth occurs until then.
- **Docker prune**: set `ENABLE_DOCKER_PRUNE=0` to disable.
- **Logs**: `journalctl -u opencode-cleanup -u host-cleanup`.

## License

MIT — see [LICENSE](LICENSE).
