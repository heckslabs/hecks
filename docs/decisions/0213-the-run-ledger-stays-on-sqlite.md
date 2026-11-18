# The run ledger stays on SQLite until locks recur after the purge

**Status:** Accepted. Date: 2026-11-17. Asked for by the Work item
`spike-would-the-run-ledger-run-on-postgres-and-stop-the-lock-errors`. A spike: nothing in persistence
changed, and no live ledger was written.

## Context

On 2026-11-16 a landing (9f70d8d9) lost its status write to `database is locked`. About 38 processes
hold `~/.claude/hecks-dev/agent_run.db` open, SQLite allows one writer for the whole file, and the
write-ahead file had grown to 1.5 GB, the size of the database, and was never checkpointed. The question
was whether Postgres, which allows many writers and keeps no such file, would stop the errors.

The brief asked for the cheap fixes to be judged first: checkpoint the log, and trim delivered outbox rows.

**Measured 2026-11-17, read-only, on the owner's machine** (these are readings, not invariants):

| What | Reading |
| --- | --- |
| `agent_run.db` | 1.33 GB (323,836 pages of 4 KB) |
| `agent_run.db-wal` | 832 KB (was 1.5 GB) |
| `hecks_outbox` | 164,872 rows by page count, 644 MB of the file |
| outbox by status | 228,892 delivered (508 MB of event text), 6,774 refused, 479 failed, 4 claimed |
| `agent_run_entries` | 424 MB; `events` 84 MB |
| `database is locked` in `board.log` | 1 line (the `cannot open Hecks` refusal) |
| Processes holding the file | about 40 Ruby processes, 54 MB resident each on average |
| Memory | 36 GB machine, 945 MB swap free of 2 GB, 38 GB disk free |
| Scratch Postgres 16, idle | 3 processes, 25 MB resident in total (default `shared_buffers` 128 MB) |

## Decision

1. **The log is already bounded, so the first fix is done.** `Sqlite::ConnectionPragmas`
   (`lib/hecks/adapters/driven/sqlite/connection_pragmas.rb`, commit `f367a57fa`) sets
   `journal_size_limit` to 64 MB and `wal_autocheckpoint` to 200 pages, and checkpoints on every open of a
   WAL store. The log now stands at 832 KB. A 10 second busy wait and an open that retries a held file
   (`97c238d86`) cover the rest of the window the failure came from.
2. **Do not move the run ledger to Postgres now.** One lock line since the fix does not pay for the
   move, and the move has real costs (below). Close the spike as not needed.
3. **The outbox purge is the second fix and is not part of this spike.** `LedgerKeeping::OutboxPurge`
   (`lib/hecks/hecks/adapters/ledger_keeping/outbox_purge.rb`) deletes delivered rows settled before a
   cutoff. 228,892 delivered rows hold 508 MB of the 1.33 GB file. A purge shortens every scan and every
   vacuum, so it is the next thing to run, by the beat that already owns it.

### What Postgres would take, for whoever revisits it

4. **Domains.** The Postgres adapter (`lib/hecks/adapters/driven/postgres.rb`) declares `atomic_put`,
   `optimistic_concurrency` and `dispatch_claims`, and has its own outbox, journal, events and sagas
   files, so AgentRun, Delivery, Tickets and Agents would bind through a local hecksagon
   (`persisted_by`, ADR 0136) without a change to their bluebooks. The SQLite-only code is the ledger
   upkeep: `LedgerKeeping::Database` (compaction count, vacuum, lock-bounded checks), the outbox purge,
   the `sqlite_status` readings and the resident stores read SQLite files directly. Each needs a Postgres
   twin, or a refusal by name, before the move.
5. **Memory.** An idle server is small (25 MB), but each of the roughly 40 processes would open its own
   backend, 5 to 15 MB each, so a few hundred MB at busy times against about 150 MB free. A pooler
   (pgbouncer) or a single writer process would be needed, and either is a new process to keep alive.
6. **The move.** The 1.33 GB is not copied as a file: it is replayed through the journal
   (`agent_run_entries`, `events`) into era tables, with outbox rows and claims carried or purged first.
   Every process switches at once, because the binding is read at boot from `hecks.local.hecksagon` and
   `hecks.local.world`; it needs a quiet window of the kind `qa_quiesce.hold!` gives, a fresh boot of
   every long-running process, and a backup of the file first (`~/.claude/hecks-dev/backups`).
7. **Only the run ledger would move.** `tickets.db` (54 MB), `agents.db` (21 MB), `pipeline.db` (2 MB)
   and `catcher.db` stay on SQLite: they are small and their writers are few. A split ledger is one
   more thing to be down, so it is the whole of the Postgres cost, taken only if locks return.

## Revisit if

- `database is locked` recurs in `board.log` or a landing log after the outbox purge has run, or
- the file grows past 2 GB with the log bounded, or
- a second ledger shows the same errors.

Then the work items are: (a) Postgres twins of the ledger upkeep commands, (b) a pooler or single-writer
decision with a measured memory figure, (c) a replay-and-switch command for the run ledger only, run in a
quiet window with the backup taken first.

## Consequences

No persistence code, bluebook or hecksagon changes. The ledger stays on SQLite in WAL mode with a bounded
log. The next step is to run the outbox purge and watch the logs.

## Follow-up (readings of 2026-11-18T03Z): the purge worked; the retention was the size

Asked for by the Work item `the-outbox-purge-leaves-200k-delivered-rows-and-ledger-locks-recur`.

**Cause.** The purge was not broken. Delivered rows spanned exactly the world's `outbox_hours: 24`
(oldest settled 2026-11-17T03:23Z at a reading of 2026-11-18T03:23Z), the delete covers every aggregate
(`agent_run` alone held 206k of 218k delivered rows), and `OutboxPurged` recurred. The outbox takes
10,000 to 30,000 delivered rows an hour, so a 24 hour retention holds about 200,000 rows at all times.

**Change.** `outbox_hours` is 1 in `lib/hecks/hecks/tickets.world`, and the default in
`LedgerKeeping::Ledger::OUTBOX_HOURS` matches it. A beat deletes the delivered rows settled more than an
hour ago, so the outbox holds about one hour of inflow (10k to 30k rows). Only delivered rows are read by
the purge; the one reader of delivered rows, the outbox fuzz property, reads its own run. The batch size
is unchanged: no reading shows the batch length as the cause of a lock.

| Reading (read-only) | Before the change, 2026-11-18T03:29Z | Still on the 24 hour train copy, 2026-11-18T03:41Z | After one beat, 2026-11-18T05:13Z | After one day |
| --- | --- | --- | --- | --- |
| `hecks_outbox` delivered rows | 218,391 | 220,865 | 29,972 (oldest settled 04:07:28Z) | to be read |
| `agent_run.db` bytes | 1.38 GB (1,384,271,872 bytes) | 1.40 GB (1,398,099,968 bytes) | 827 MB (827,498,496 bytes) | to be read |
| `database is locked` lines that day | 3 on 2026-11-17 | not recounted | 1 in `board.log` (see below) | to be read |

**What the after reading shows.** Delivered rows now span about one hour, so the one hour retention is
what deleted them. The file fell by about 570 MB because the purge's `OutboxPurged` reaction is followed
by `LedgerFile.Reclaim` (the `ReclaimAfterThePurge` policy in `ledger_care.bluebook`): deleting rows frees
pages and the vacuum gives them back, so the purge and the vacuum together account for the drop. The
failed (563) and refused (8,328) rows stay by design; only delivered rows are purged.

**Which copy purged.** `grep outbox_hours ~/.claude/hecks-train/lib/hecks/hecks/tickets.world` still
prints `outbox_hours: 24` at the 05:13Z reading, so the purge that produced the one hour span did not run
from the train copy; it ran from a checkout that carries the change. The train copy takes the change at
its next boarding and refresh. Until then a beat from the train copy would keep 24 hours again, so the
one day reading counts only once that grep prints `outbox_hours: 1`.

**The lock line.** `board.log` holds one `cannot open Hecks: database is locked` line (line 44657 of
73,968). It carries no timestamp, so it cannot be placed before or after the first one hour beat, and it
may be one of the three of 2026-11-17 already counted. It is not counted as a lock after the purge. The
lock count over the day after the train copy runs with `outbox_hours: 1` is the one reading still to be
taken; the Work item stays open for it so that the revisit condition below can fire.

**Revisit.** If `database is locked` recurs once the outbox stands near 20,000 rows, that meets this
ADR's own revisit condition and the work items (a), (b) and (c) above become due. Locks seen while the
outbox held 200,000 rows do not by themselves meet it.

### Reading of 2026-11-18T10:37Z (read-only): the train copy still keeps 24 hours

| Reading | 2026-11-18T10:37Z |
| --- | --- |
| `hecks_outbox` delivered rows | 61,007 (oldest settled 07:40:40Z, about 3 hours); 36,787 of them settled more than an hour before the reading |
| `agent_run.db` bytes | 468 MB (467,574,784 bytes); the write-ahead file is 0 bytes |
| Train copy `tickets.world` | still `outbox_hours: 24`; it has not been boarded with the change |
| `database is locked` in `board.log` | the same one line, 44657 (the file grew from 73,968 to 74,072 lines); not a second lock |
| `database is locked` in `integration-listener.log` | 1, line 5981 of 22,929 (`cannot open Hecks`, no timestamp); first counted here |

The 3 hour span does not confirm the one hour retention: 36,787 delivered rows are older than an hour, so
the beat that purges now is not the one hour copy. The 05:13Z span of one hour came from a checkout that
carries the change; the train copy purges at 24 hours, and that retention is bounded by the train's last
purge, not by this change. The file's fall from 827 MB to 468 MB while the outbox grew is not explained by
a reading taken here (no vacuum event was read); it is left unexplained. The one day reading still waits
for the train copy to print `outbox_hours: 1`, and the Work item stays open for it.
