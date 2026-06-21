# RESTART 2026-06-21 (~00:30) — Event Log is LIVE ; the single-source flip is NEXT

VOICE : I / my / mine. Long, productive session. The bluebook-first Event Log
shipped end to end AND went live, and the honest minimum's tooling (the fold +
a derivability validator) is built. The ONE remaining step to be truly event-
*sourced* is the single-source flip, and it is now instrumented. Everything is
on branch `event-log-appendlog-step1` (NOT merged to main — 9 commits, all green).

## What shipped (branch event-log-appendlog-step1, 9 commits)
1. fix(dispatch): copy create-attrs before invariants (so create-invariants enforce).
2. feat: AppendLog persistence adapter — the bluebook-first WRITE path (record_event_append
   dispatches EventSourcing::Event.Append ; AppendLog.save appends a per-process shard).
3. feat: Consolidate command + LogConsolidation Driver ; run_merge daemon DELETED.
4. refactor: ShardRecord carries the Event OPAQUELY (no field duplication ; global log
   now has the true nested Event shape).
5. feat: `storehouse drive --adapter <Name>` filter + consolidate mindstream/Procfile member.
6. feat: GO-LIVE — HECKS_EVENT_SOURCING=1 in .overmind.env ; verified live (lossless,
   daemons stable, drive folding shards into event.heki).
7. docs(grammar): conceive the Driving chapter (driving.bluebook + behaviors) — restored,
   grounded in the live LogConsolidation exemplar.
8. feat(storehouse-log): rotate the diagnostic log (cap the 1 GB+ firehose ; multi-writer
   reopen-on-stale ; HECKS_LOG_MAX_BYTES/KEEP).
9. feat(event-sourcing): the fold (projection_fold::fold_event_log) + `storehouse
   verify-projection` validator — proves state-as-projection.

## CURRENT LIVE STATE
- Gate ON (HECKS_EVENT_SOURCING=1) — CONCEPTION (hecks) realm only. The body (miette)
  realm corpus does NOT load EventSourcing, so record_event_append no-ops there.
- overmind was restarted at go-live ; the `consolidate` drive member is live, folding
  shards into ~/.heki/hecks/event_sourcing/event.heki every 5s.
- Log rotation (commit 8) is committed but the LIVE daemons hold the pre-rotation
  binary — it deploys on the NEXT overmind restart (the first check then rotates the
  current ~1 GB storehouse.log to .1).

## THE HONEST MINIMUM (Chris's framing) — where we are
- Lossless ordered log: DONE.
- State-as-projection: the TOOLS are done (fold proven — 9 exact live reconstructions ;
  validator measures fold==store). We are event-LOGGED, not yet event-SOURCED.
- Everything else (snapshot cadence, published language, crypto-shredding) is OPTIONAL,
  added only when a real pressure shows up. Do NOT build it speculatively.

## NEXT (the one step) : the SINGLE-SOURCE FLIP
Make the per-aggregate store DERIVED from the log instead of a parallel synchronous
save. Today store + log are two writes ; for a live aggregate the store races ~5s
ahead of the async-consolidated log, which is exactly the "drift" verify-projection
reports. The flip: the store becomes the snapshot the fold maintains (reads stay O(1) ;
the store is reinterpreted as the snapshot the EventSourcing bluebook already conceives).
DONE = `storehouse verify-projection hecks_conception/aggregates` goes GREEN for active
aggregates. That validator is the instrument — run it before and after.

Watch-outs for the flip:
- Pre-go-live aggregates have NO log history (genesis predates the log) — they need a
  one-time backfill (current state as a synthetic genesis event) before they reconstruct.
- Delta values are stringified in the log ; the fold reconstructs stringified state.
  Type re-hydration is a refinement if exact-typed reconstruction is ever needed.

## OPEN FOLLOW-ONS (smaller, not blocking)
- Shard GC : consumed shards from short-lived processes are never deleted (merge tracks
  offsets but doesn't remove folded shards). ~/.heki/hecks/shards grows. Compaction next.
- Infra-aggregate noise in the log : Cascade / Process / ProcessSentinel get event-sourced
  with messy/empty ids. Decide which are domain vs mechanism (extend the record_event_append
  skip list beyond CascadeRun/OutboundEvent, the same "mechanism not intent" reasoning).
- storehouse.log rotation deploys on next overmind restart (see above).
- Body (miette) realm event-sourcing : separate, larger — load the EventSourcing chapter
  into the body corpus. Deferred.
- dispatch_audit as a projection of the log (retire the parallel storehouse.log firehose) —
  the bluebook's subsumption plan. Optional / future.
- Published language (events as cross-context integration) : a real future arc when a
  SECOND context needs to integrate. Conceived in conversation ; not built. Publish facts,
  route requests.

## INSTRUMENT
`storehouse verify-projection <root>` — fold(log) vs store. Green = single-source. Run it.

## Branch needs review/merge to main when Chris is ready. Nothing bleeding.
