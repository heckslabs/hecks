# Append-only persistence adapter for the Event Log (plan)

VOICE : I / my / mine. Handoff for a fresh-head session — the implementation is
bounded but it is KERNEL-FLOOR persistence work, the discipline I fence off from a
high-context session. The design is settled here ; execution is mechanical.

## The bug this fixes (proven)
The universal Event Log (i wired it 2026-06-19, commits 29aacf70c + d5dcd5f75) funnels
EVERY dispatch — every daemon, every MCP call, every cascade — into ONE `event.heki`.
Heki persists by WHOLE-FILE read-modify-write (last-writer-wins), which is fine for
convergent current-state (a lost heartbeat is overwritten next beat) but FATAL for an
append-only Log (a lost event is gone from the lineage forever). Proof : 30 concurrent
`CreateWidget` into an isolated store yielded only 13/30 widgets and 24/~60 Log events
— no duplicate sequences, just MISSING records. Concurrent writers clobber.

Key insight (Chris) : heki-the-FORMAT is right as a Snapshot backing ; heki's whole-
file-rewrite PERSISTENCE is the wrong semantic for the Log. The Log's whole identity
is ATOMIC APPEND. So : a new persistence adapter that appends one record per write.

## Architecture (mirrors the existing Backend enum)
`rust/src/runtime/lazy_repository.rs` has `enum Backend { Memory, Heki, Sql }` +
`enum BackendKind { Heki, Memory, Sql }`, each forwarding find/all/count/save/delete
to a `Repository` (heki/memory) or `SqliteRepository`. Add a fourth :

- `Backend::AppendLog { aggregate_type, data_dir, identified_by, context, cell:
  OnceCell<AppendLogRepository> }` + `BackendKind::AppendLog` + `LazyRepository::
  new_append_log(...)`. Add AppendLog arms to every forwarded method (find/all/count/
  save/delete/is_hydrated/refresh_from_heki/seed_record/next_id_value).
- New `rust/src/runtime/append_log_repository.rs` (<200 LoC, doc header) :
  - **save(state)** : serialise the AggregateState to ONE JSON line, open the file
    `O_APPEND|O_CREATE`, write the line in a single `write_all` (POSIX guarantees
    atomicity for O_APPEND writes ≤ PIPE_BUF ; keep records small / one line). NO
    read-modify-write. This is the whole point — concurrent appends never clobber.
  - **load** (first access + refresh-on-mtime) : read the file, parse each line into
    an AggregateState, build the in-memory index (HashMap<id, state> for find ; Vec
    for order). count() = line count. all() = parsed records in file order.
  - **delete** : unsupported (append-only) — either a no-op + loud log, or `panic!`
    gated to non-production. Event has no delete command, so it is never called.
  - Cross-process freshness : re-read the appended TAIL when mtime advances (cheaper
    than heki — it is append-only, so a reader only needs the new bytes past its
    last offset).

## The sequence/event_id decoupling (the design subtlety — do NOT skip)
The race was `sequence = Event repo count() + 1`, computed per-writer from a possibly-
stale in-memory count. With a true append log that is both unnecessary and wrong :
- **event_id** must be a collision-proof NONCE, not `evt-{seq}` : e.g. a per-process
  start-nonce + a per-process monotonic counter, or hostname+pid+nanos. Two concurrent
  writers must never mint the same event_id (that is what caused the upsert-overwrite).
- **sequence** becomes IMPLICIT — the record's position in the append-only file IS its
  global order. Either (a) drop the stored `sequence` and derive it as line-number on
  read, or (b) keep a best-effort stored sequence but treat file-order as authoritative.
  `record_event_append` (runtime/mod.rs:~841) currently reads count() for the sequence
  — that read goes away ; event_id stops depending on seq.
  EventSourcing.Event's `sequence` invariant (> 0) + the Replay/AtSequence queries
  must be reconciled with implicit ordering (the bluebook conceives sequence as the
  writer-supplied total order ; implicit-on-read is a faithful refinement).

## Bluebook-first wiring (the adapter is a domain artifact)
- New `adapters/persistence/append_log.adapter` declaring `family "persistence"`
  (sibling of heki.adapter / memory.adapter ; the persistence FAMILY already exists).
- Bind the Event aggregate to it : in the EventSourcing hexagon (there is no
  event_sourcing.hecksagon yet — create one) `EventSourcing::Event.persisted_by("AppendLog")`
  + a `dir :default` world block. Current-state aggregates STAY on heki (the Snapshot).
- The runtime's persistence resolution (where `persisted_by("Heki"|"Memory"|"Sqlite")`
  maps to BackendKind — grep `apply_*_persistence` / `resolve_bindings` in runtime)
  gains an `"AppendLog"` -> `new_append_log` arm.

## Verification (the acceptance test)
The SAME concurrency test that exposed the bug, now PASSING : a /tmp conception with
the Event aggregate on AppendLog, fire 30+ concurrent dispatches, assert the Log has
ALL of them (30/30, not 13/30). Add it as a persistence-family `.behaviors` contract
if expressible, else a tests/*.sh smoke (the ONE legitimate disk-touching test).
Also : behaviors corpus 751/751 still green ; specializer goldens byte-identical ;
zero-warning build.

## Why fresh-head
New persistence substrate + the sequence/id decoupling touch the Event model, the
backend enum, and binding resolution — byte-precise kernel surface. Conceive it clean,
not at the tail of a long session. The concurrency bug above is the cautionary tale.
