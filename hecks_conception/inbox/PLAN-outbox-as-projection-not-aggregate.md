# PLAN — The outbox is a PROJECTION over the event log, not an aggregate

**Decided with Chris, 2026-07-19**, superseding PLAN-outbox-as-middleware-not-
injection.md (which kept a materialized OutboundEvent aggregate, runtime-owned).
Chris : "I don't know why we need a special aggregate — can't it deal with
events too like everything else? It can be a bluebook — we can turn on event
sourcing through hecksagons."

## The insight
The outbox does not need to be a materialized write-model aggregate. Everything
in the system already emits Events, and the event-sourcing substrate already
records them. So the outbox is a READ MODEL (projection) of undelivered events,
exactly as event_sourcing.bluebook's vision already flagged ("OutboundEvent
becomes a read model of undelivered events … none are rewritten in this phase,
only flagged"). This card executes that deferred migration.

## What already exists (do NOT rebuild)
- `event_sourcing.bluebook` (framework realm) : Event (immutable atom + the
  append-only Log), Projection (a fold that DERIVES a view), Snapshot (a cached
  fold = today's heki current-state).
- `record_event_append` (runtime/mod.rs:1318) already appends ONE Event per
  state delta to an append-only JSONL Log (`event.log`, event_log.rs /
  event_log_query.rs / event_log_index.rs). The Log is real and populated on
  every dispatch.
- The delivery host (run_host/mod.rs) and in-process drain
  (drain_outbound_to_quiescence) are name-based consumers — they read a source
  and dispatch lifecycle by name.

## The target (three pieces)
1. **Outbox = a Projection over the Log.** `UndeliveredEffects` folds the Log :
   select each Event whose name matches an EFFECT binding (a hecksagon bind
   carrying `on:`), keyed by (event, adapter) ; remove it when a delivery fact
   for that (event, adapter) appears. Defined as a framework Projection, not a
   per-domain aggregate. No injection into user domains — the symptom
   (ToolShed's page showing OutboundEvent) disappears because there is no
   OutboundEvent aggregate to show.
2. **Delivery = Events, like everything else.** Claiming / delivering / failing
   append delivery facts to the Log (Claimed / Delivered / Failed) rather than
   mutating a materialized OutboundEvent record's lifecycle. "Undelivered" is
   emits minus deliveries — derived, not stored.
3. **Event sourcing toggled through the hecksagon.** Event sourcing is a
   PERSISTENCE STRATEGY, so it belongs in the hexagon exactly like
   `persisted_by`. An aggregate whose persistence is event-sourced serves its
   state as a fold of its Log (snapshots are cached folds).

## THE API DECISION — LOCKED (Chris, 2026-07-19)
Event sourcing is NOT a peer persistence adapter (not `persisted_by(
"EventSourced")`) — it is ITS OWN DIRECTIVE, layered ON TOP of persistence :
"persistence+". The directive is just `event_sourced` :

    Pizzas::Order.persisted_by("Heki")   # snapshot base
    Pizzas::Order.event_sourced          # + the Log on top (persistence+)

This resolves the tension that heki cannot be REPLACED by "EventSourced" —
heki IS the snapshot the Log folds onto. Persistence is the base ; event
sourcing is the `+`.

## THE BLOCKER — the Log writer is gated off as lossy (found 2026-07-19)
The whole outbox-as-projection depends on the event Log being WRITTEN.
`record_event_append` (mod.rs) is gated OFF by default (`HECKS_EVENT_SOURCING`)
because the OLD event.heki whole-file RMW clobbered under concurrent writers
(Chris, 2026-06-20 : "Until the out-of-process single-writer lands, event
sourcing is gated OFF so no lossy Log runs"). BUT the CURRENT record_event_
append writes per-process `shards/` (event_shard::reserve) folded by a merge —
which looks like the safe single-writer-per-shard design the gate awaited.
DECISION (Chris) : VERIFY the shard/merge writer is single-writer-safe and
that reads see merged data BEFORE turning anything on.

### VERIFIED SAFE — the gate is stale (2026-07-19)
- SHARD WRITE : single-writer-per-shard, lossless append at any size (each
  process owns its `.shard`, O_APPEND, no interleave). 7/7 event_shard tests.
- MERGE (event_merge.rs) : sole writer to the global Log, byte-offset
  checkpoint, idempotent on crash (dedup by event_id), GC only dead+fully-
  folded shards. PROVEN lossless : `thirty_concurrent_writers_lose_nothing`
  = 1500 events / 30 writers / 0 lost (old whole-file repo lost 13/30). 7/7
  event_merge tests.
- WIRED : `run_consolidate_if` fires the merge on
  `EventSourcing::Consolidation.Consolidate`, which `storehouse drive` fires
  on an interval (the retired merge daemon, reborn as a bluebook Driver).
  Reads are eventually-consistent — a shard is visible within one
  consolidation tick, which is exactly right for an outbox.
- The ONLY thing still off is `record_event_append`'s `HECKS_EVENT_SOURCING`
  early-return. Its rationale (lossy whole-file RMW) NO LONGER HOLDS — the
  shards+merge topology superseded it. Moving that gate from the global env
  var to the per-aggregate `event_sourced` directive is safe.

## NEXT BUILD STEP (unblocked)
1. The `event_sourced` hecksagon directive (persistence+) : parse it (Ruby +
   Rust), and make `record_event_append` fire for an aggregate carrying it
   (regardless of the env var). Keep the env var as a global override.
2. The `UndeliveredEffects` projection over the Log + delivery-as-events.
3. Delete the OutboundEvent injection ; the served page is clean because the
   outbox is a projection, not an aggregate.
Each a green, gated commit.

HEKI COMPOSES, it is NOT replaced. Two senses :
  1. `persisted_by("Heki")` (or default) stays as snapshot-only persistence
     for aggregates that don't need the Log — a per-aggregate choice.
  2. Under `EventSourced`, HEKI IS THE SNAPSHOT LAYER : the aggregate appends
     to the Log (truth) AND caches its folded current-state in heki (the
     Snapshot event_sourcing.bluebook already defines as "today's heki
     current-state store, reinterpreted, with on-read fall-forward to
     replay"). Reads hit the heki snapshot + replay only newer events.

STILL OPEN (smaller) : is a delivery fact a raw Log Event, or a tiny
event-sourced `Delivery` aggregate whose Claimed/Delivered/Failed commands
append to the Log? Lean : a small event-sourced Delivery aggregate, so the
same persisted_by("EventSourced") machinery carries it and the projection
joins effect-emits against Delivery events by (event, adapter).

## Gates (kernel-floor, fresh head)
- Full `cargo test --workspace` (effect/outbox/host tests must pass against the
  projection, not the aggregate : run_host, drain_outbound, dispatch_cascade,
  effect_outbound_record).
- Parity (dump.rs / canonical_ir.rb) — the projection + any event-sourced
  binding must round-trip Ruby<->Rust.
- Behaviors corpus.
- Live : boot an effect example (pizzas / bin-buddy), dispatch an emitting
  command, confirm delivery works via the projection + delivery events AND no
  OutboundEvent aggregate appears in any served domain.

## Superseded
The runtime-owned-aggregate slice (merge_framework_outbox + user_aggregates UI
filter) was BUILT and green (108 test binaries) but REVERTED : it kept the
materialized aggregate this card dissolves. Two ideas from it survive as
by-products of the projection model : (a) no framework substrate is grafted
into a user domain, (b) framework substrate never renders on the served
surface — both fall out naturally once the outbox is a projection.
