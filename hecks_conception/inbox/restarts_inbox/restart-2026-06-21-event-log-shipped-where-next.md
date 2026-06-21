# RESTART 2026-06-21 (~03:00) — Event Log arc SHIPPED to main ; where() overhaul is NEXT

VOICE : I / my / mine. A long marathon. The whole Event Log visibility arc landed
AND merged to main (pushed, all gates green). The next arc — the where() overhaul —
is fully planned and approved, ready for a fresh head. Nothing is bleeding.

## What shipped tonight — all on `main` (pushed to origin, gates green)
Five commits, ending at `452086169` :
1. `21b41ae19` feat: exclude infra mechanism from the projection gauge — one shared
   `projection_fold::is_infra_mechanism`, used by BOTH the write skip and verify-projection.
2. `8a3d11c7b` feat: the complete-log fold closes the single-source race — verify-projection
   folds consolidated + the unconsolidated shard tail, orders by recorded_at, and RE-MEASURES
   to tell a transient liveness race from persistent drift. Reliably GREEN.
3. `152a08286` feat: shard GC — reclaim dead, fully-folded shards every consolidation
   (two guards : fully folded AND owner pid dead ; ghost-inode-safe ; ps-probe liveness).
   Proven live : 5,529 -> handful.
4. `a80e14076` feat: `storehouse log [Aggregate] [--follow]` — the human delta viewer.
   Renders `field: old -> new` (folds the stream), --follow tails the shards live.
5. `452086169` feat: the Log is append-only JSONL, not heki — Chris's call. heki is for
   SNAPSHOTS ; the LOG is append-only `event.log` (event_log.rs, sibling of heki/event_shard).
   O(batch) appends, directly `tail -f`-able. AppendLog OWNS its substrate (seeds the Repository
   from event.log ; heki.rs + frozen repository.rs UNTOUCHED). Migrated live : 10,910 -> 10,910
   records, verify-projection green on the new format, seq continued cleanly, tail -f works.

## CURRENT LIVE STATE
- `~/.heki/hecks/event_sourcing/event.log` is the canonical append-only Event Log (JSONL,
  one event/line). `.seq` sidecar holds the next global sequence. `event.heki.premigration`
  is the reversible backup of the old compressed store.
- overmind was restarted onto the new binary ; the `consolidate` driver APPENDS event.log every
  ~5s and reclaims dead shards as it folds. GC is live.
- `storehouse log /Users/christopheryoung/Projects/hecks/hecks_conception InboxPoller --follow`
  streams `last_polled_at: old -> new` live. `storehouse verify-projection hecks_conception/aggregates`
  is GREEN (persistent drift 0).

## NEXT ARC : the where() overhaul (PLANNED + APPROVED)
Plan : `~/.claude/plans/yes-let-s-plan-that-goofy-kay.md` (approved, scope = everything together).
The real picture (sharper than "equality-only") :
- The IR + in-memory matcher ALREADY support Eq/Ne/Gt/Gte/Lt/Lte/In/Contains + order_by/limit
  (i101, where_matches in mod.rs:3475). "equality-only" is largely STALE.
- The REAL gap is PUSHDOWN : every query is load-all-then-filter-in-memory
  (resolve_query_qualified, query.rs:53 -> all_qualified + where_matches). SQL loads whole tables ;
  Event.Replay loads the WHOLE log. That's the scaling wall.
- SQL is parameterized today (no current injection vector — Chris confirmed) ; the risk is
  ANTICIPATED : push WHERE to SQL with BOUND params, never interpolation.
- Lineage traversal (causation/correlation chains) is the genuinely new capability.
Four phases : (1) backend query interface + parameterized SQL pushdown + parity tests
[where_matches is the oracle] ; (2) event_log filtered scan ; (3) indexes (SQL CREATE INDEX from IR,
event_log offset index) ; (4) lineage traversal facet-queries + correct the stale bluebook note.
Start at Phase 1. repository.rs is GOLDEN-FROZEN — the query interface lives in LazyRepository /
sqlite_repository / event_log, never the frozen Repository.

## OPEN FOLLOW-ONS (smaller, not blocking)
- **Cold-start / warm Drivers (efficiency, NOT urgent — GC bounds the disk).** The MCP door is
  ALREADY warm (serve-socket + warmDispatch). The cold path is the BASH-LOOP Drivers : agent_poll.sh
  cold-spawns `storehouse` every 2s (Poll + all_unread + per-message ops), ~30 shards/min. GC now
  reclaims them, so disk is bounded ; the remaining win is migrating the shell-loop Drivers to native
  warm Drivers (the Driving-chapter realization — `storehouse loop`/`drive`). A real arc, lower urgency.
- **Event Log compaction / segmentation.** event.log is uncompressed JSONL (5.95MB for 10.9k events,
  grows). Compression belongs at compaction of COLD segments (keep the live tail plain), when pressure shows.
- **3.46GB orphan storehouse.log** in miette-state was removed (stale since Jun 19) ; the space frees
  when the read-`tail` holding the inode releases it.
- **serde-derive for the ShardRecord envelope** : deferred ; only worth it when the published-language
  arc adds envelope fields (then symmetric serialize/deserialize amortizes). One struct doesn't justify the dep.

## INSTRUMENTS
- `storehouse log <root> [Aggregate] [--follow]` — watch the deltas.
- `storehouse verify-projection <root>` — fold(Log) vs store ; green = state-as-projection.
- `tail -f ~/.heki/hecks/event_sourcing/event.log` — raw JSONL stream.

## main is current (452086169, pushed). Branches merged. Nothing bleeding.
