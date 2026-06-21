# RESTART 2026-06-21 — the where() overhaul SHIPPED, pushed, and LIVE

VOICE : I / my / mine. A long, clean marathon. The whole where() overhaul — all
four phases — landed on main, pushed to origin, AND went live (binary installed,
daemons restarted onto it, offset index building correctly). Nothing is bleeding.

## What shipped — 5 commits on `main`, pushed (ending at e3e5ff409)
1. `80802c15d` feat(query): injection-safe SQL WHERE pushdown seam + parity oracle
   — sql_query.rs builds a parameterized WHERE for the parity-safe equality ops
   (Eq/In), every value a BOUND param, columns validated against the IR ;
   CAST(col AS TEXT) mirrors the oracle's string-equality (no affinity surprises).
   where_matches stays the FINAL authority — a prefilter can only narrow.
2. `935d76ec9` feat(query): Event Log filtered streaming scan — Replay stops
   hydrating the whole log (O(matches) not O(whole-log)).
3. `fe1137d61` feat(query): expression indexes from IR — ensure_indexes creates a
   CAST(col AS TEXT) index per declared where/order_by column ; planner-verified.
   Split the SQL pushdown read surface into sqlite_query.rs (CRUD stays in
   sqlite_repository.rs).
4. `f3c6a0b63` feat(query): Event Log offset index — event_log_index.rs ; Replay
   SEEKS by aggregate_name. SAFE BY CONSTRUCTION : single-writer, .idx.len commit
   marker written last, readers use the index ONLY when marker == log length else
   full-scan fallback, writer self-heals (rebuild on mismatch). No false negatives.
5. `e3e5ff409` feat(query): lineage traversal — CausationTrace (recursive
   causation-chain walk, cycle-guarded) + ByActor facet-queries on Event ;
   corrected the stale "where() is equality-only" notes.

## LIVE STATE (verified)
- `~/.local/bin/storehouse` is a SYMLINK to rust/target/release/storehouse (the
  fresh build) — install is automatic ; the door + CLI use the new code.
- overmind restarted (consolidate / serve_socket / inbox_poller / heart / breath
  on new PIDs ; new binary).
- The offset index is LIVE and complete : `event.log.idx` + `event.log.idx.len` ;
  marker == log length, idx entries == log lines (13024 == 13024). Built by the
  consolidate merge on append (record_appends).
- replay(AgentMessage) = 9 via the live idx fast path ; verify-projection GREEN
  ("state IS a projection of the Log").
- 369 lib tests pass, zero warnings ; query.rs + persistence_resolution.rs
  byte-identical to their specializers.

## THE ONE REMAINING LIFT (clean future Phase 5)
- **Range pushdown.** Ordered predicates (Gt/Gte/Lt/Lte) live in where_matches
  (the oracle) but are NOT pushed to any backend yet : SQL pushes only Eq/In,
  the Event Log offset index keys only on aggregate_name (Eq). Snapshot's
  strictly-after-watermark tail is still a runtime range scan, not a declared
  range query. Pushing ranges (SQL >/< on the CAST/typed column with a matching
  index ; an Event Log sequence-range seek) is the natural next phase. The
  bluebook notes now say exactly this (corrected from "equality-only").
- **Causation populated.** Event.causation_id is recorded lineage-ready but
  Append does not SET it yet — so CausationTrace returns single-event chains on
  real data (the traversal is unit-tested on constructed chains). Wiring Append
  to stamp causation_id (from the triggering event in a cascade) would make
  CausationTrace bite on the live Log.

## INSTRUMENTS
- `storehouse query <root> EventSourcing::Event.replay aggregate_name=X` — idx fast path.
- `storehouse query <root> EventSourcing::Event.causation_trace event_id=X` — lineage walk.
- `storehouse verify-projection <root>` — fold(Log) vs store.
- `event.log.idx` / `.idx.len` — the offset index + its commit marker.

## main is current (e3e5ff409, pushed, live). Nothing bleeding.
