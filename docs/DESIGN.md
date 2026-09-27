# Design notes

## Why cleanup can consume disk

opencode uses SQLite in WAL mode. Deleting rows (old sessions and their events)
does not release disk space to the operating system: SQLite moves the affected
pages onto a **freelist** and reuses them for later writes. The database file
therefore stays the same size.

To actually shrink the file, SQLite provides:

- `VACUUM` (and `VACUUM INTO`) — rebuilds the database into a temporary file and
  then replaces/copies it back. The SQLite documentation states it can require
  **"as much as twice the size of the original database file"** in free disk
  space. On a nearly-full disk this turns a cleanup into an outage.
- `PRAGMA incremental_vacuum` — removes freelist pages and truncates the file
  **in place**, with **no temporary copy**. It only works when the database is in
  `auto_vacuum=INCREMENTAL` mode.

## Strategy

1. **Convert once, off-root.** `PRAGMA auto_vacuum=INCREMENTAL` only takes effect
   after a `VACUUM`. We run that one-time rebuild with `VACUUM INTO` pointed at a
   directory on a **different filesystem** (`CONVERT_DIR`). The database
   filesystem is only read during the build, so it never grows. The swap then
   deletes the old file *before* copying the new one into place, so usage only
   decreases. The result is verified (`PRAGMA integrity_check`, `auto_vacuum=2`)
   before and after the swap.

2. **Reclaim after each run.** Each scheduled run deletes sessions older than
   `RETENTION_DAYS`, then reclaims freed pages. The method is chosen by freelist
   size, because `PRAGMA incremental_vacuum` (no argument) frees the *entire*
   freelist as a single transaction: for a freelist that is most of the file that
   transaction is enormous, cannot checkpoint, and balloons the WAL. Instead:

   - **Small freelist** → `PRAGMA incremental_vacuum(VACUUM_PAGES_PER_RUN)` (bounded,
     so the WAL stays small), then `PRAGMA wal_checkpoint(TRUNCATE)`.
   - **Large freelist** (more than `REBUILD_FREELIST_PAGES`, or more than
     `REBUILD_FREELIST_PCT`% of the file) → an off-root rebuild
     (`opencode-db-convert.sh`), which compacts the live data quickly.

   A retention floor applies: the `KEEP_RECENT_SESSIONS` (default 5) most recent
   top-level sessions (`parent_id IS NULL`) **per directory**, plus any sub-session
   whose parent is one of them, are excluded from deletion even if they are older
   than the retention window. This guarantees each directory keeps its own recent
   work, not just the globally most recent sessions.

## Idle gating

Pruning requires exclusive-ish access and must not interrupt active work. Before
touching the database, `stop_opencode` checks:

- the most recent `session.time_updated` timestamp (idle for `IDLE_MINUTES`), and
- CPU ticks consumed by `opencode` processes over a short sample.

If either indicates activity, the run skips and leaves opencode running. Only
when idle does it send `SIGTERM`, wait, fall back to `SIGKILL`, and verify no
process still holds the database (via `pgrep` and `lsof`).

## Sidecar cleanups

- `docker builder prune -af` runs first, gated by `ENABLE_DOCKER_PRUNE`.
- `host-cleanup.sh` runs as root: on Linux it caps `journald`
  (`SystemMaxUse`) and runs `journalctl --vacuum-size`, plus `apt-get clean`;
  on macOS it can run `periodic` (`ENABLE_MACOS_CLEANUP`). Each action is
  skipped when its tools are unavailable.

## Portability

The scripts target Linux, macOS, and the BSDs under bash 3.2+.

- `bin/platform.sh` centralizes every place the platforms differ. Each helper
  tries the GNU form first and falls back to the POSIX/BSD equivalent:
  `df -B1 --output=avail` → `df -Pk`; `stat -c` → `stat -f`; `date -d @` →
  `date -r`; `sed -i` → `sed -i ''`.
- CPU idle detection reads `/proc/<pid>/stat` on Linux and parses
  `ps -o time=` elsewhere, normalized to centiseconds so `CPU_TICKS_MAX`
  keeps the same meaning across platforms. The default is `150` centiseconds
  over a 5s sample (idle opencode sits around 20, so a lower value caused every
  run to skip as "busy").
- Scheduling is selected at install time: systemd units, launchd plists, or a
  marked `crontab` block. The `SCHEDULE` string (`DOW-list HH:MM`) is consumed
  directly by systemd's `OnCalendar`, and parsed into
  `StartCalendarInterval` / cron fields for the others.
- The one-time conversion prefers a secondary filesystem but degrades to
  same-filesystem building when none exists, with an explicit warning.

## Safety properties

- **No growth on the database filesystem**: conversion builds off-root and swaps
  by delete-then-copy; recurring prunes use `incremental_vacuum`.
- **Bounded**: pre-flight free-space checks abort before any work if space is
  insufficient.
- **Recoverable**: the conversion uses a trap that removes the build file, and
  restores the database from it if interrupted during the swap.
- **Idempotent**: safe to run repeatedly; skips when there is nothing to do.

## Operational notes

- Timers use `Persistent=true`, so a missed run (host off) executes on next boot.
- `RandomizedDelaySec` spreads load and avoids collisions with other jobs.
- Inspect results with `journalctl -u opencode-cleanup -u host-cleanup`.
