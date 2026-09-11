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

2. **Prune incrementally forever after.** Each scheduled run deletes sessions
   older than `RETENTION_DAYS`, then calls `PRAGMA incremental_vacuum` followed by
   `PRAGMA wal_checkpoint(TRUNCATE)`. No temporary file, no second copy.

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
- `host-cleanup.sh` runs as root and caps `journald` (`SystemMaxUse`) and runs
  `journalctl --vacuum-size`, plus `apt-get clean`. Both are toggleable.

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
