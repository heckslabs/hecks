# Locked design : the clock (worker-liveness TTL), min-viable

> Decision (A) : the clock's first consumer is WORKER LIVENESS, not lease-TTL.
> Same time primitive, but it reuses the SEAM 3 worker-died fan-out to reclaim
> BOTH lease and claim (story becomes re-claimable) instead of half-reclaiming.

## The one runtime primitive

The clock already exists : `heki::now_duration()` + `format_iso8601(secs)`
(storehouse_log.rs) — sortable ISO-8601 UTC, already read at dispatch entry.
The gap is making it reachable as an attr value. Add `{now}` / `{now+N}` /
`{now-N}` (N = seconds) tokens, resolved to `format_iso8601(now ± N)`, in the
TWO dispatch paths that write attrs :
  - `interpolate_event` (driven_adapter_resolver.rs ~269) — hecksagon dispatches.
  - the cadence loop driver dispatch attrs (loop_driver.rs / `storehouse loop`)
    — so `Worker.Heartbeat stale_after={now+N}` updates with real time.
Determinism guard : `HECKS_NOW=<iso>` env consumed inside the now helper
(mirror HECKS_RAND_SEED) so a now-bearing dispatch in a fixture stays
byte-stable for goldens / parity. State this explicitly, not as an afterthought.

ISO-8601 sorts chronologically, WhereOp::Lt + resolve_where_value(:kwarg)
already exist — so `where stale_after: { lt: :now }` works the instant `:now`
is supplied. The where-fan-out query_inputs (`where: { now: "{now}" }`) carry
it via the SAME `{now}` interpolation — no query-path code change.

## Consumer : worker liveness (decision A)

- `Conductor::Worker` gains `stale_after` (ISO timestamp VO). `Register` and
  `Heartbeat` then_set it from a `{now+threshold}` input. (heartbeat-as-liveness
  is the worker model's stated intent ; a crashed autonomous worker stops
  beating, so stale_after stops advancing.)
- Query `Worker.Stale` : `where status: "alive"`, `where stale_after: { lt: :now }`.
- A cadence tick -> an event -> a driven adapter fans out
  `Worker.Stale -> Worker.MarkDead`. (for_each is driven-adapter-only, so the
  cadence dispatches a command that EMITS an event the sweep adapter reacts to ;
  a small Pulse/Sweeper Tick->Ticked is the honest shape. Reuse an existing
  beat event if one fits.)
- MarkDead -> WorkerDied -> the EXISTING worker_died_reclaim.hecksagon fans out
  Lease.Reclaim + Claim.Expire. Nothing new downstream.

## Fill the PENDING_NO_CLOCK sites (3)

volunteer_pull.hecksagon Grant `expires_at: "{now+<TTL>}"` ;
claim_next_on_*_*.hecksagon Acquire `claimed_at: "{now}"`.

## Build order

1. Runtime : `{now}`/`{now+N}`/`{now-N}` in interpolate_event + loop driver +
   HECKS_NOW freeze. (hand-written runtime ; not golden — but confirm.)
2. Worker : stale_after attr + Register/Heartbeat then_set + Worker.Stale query.
3. Sweep : cadence Tick -> event -> driven adapter for_each Worker.Stale ->
   MarkDead. Procfile cadence line.
4. Fill the 3 PENDING_NO_CLOCK sites.
5. Test (HECKS_NOW-frozen) : seed a worker with stale_after in the past + a
   held lease/claim ; fire the sweep ; assert MarkDead -> SEAM 3 reclaimed the
   lease + expired the claim -> story re-claimable. Plus a fresh worker is NOT
   swept. Gate : cargo + golden + 4 parity + behaviors.

## NOT in scope (backstop, later)

Lease-TTL sweep for the alive-but-hung worker (lease TTL elapses while heartbeat
fresh). Decision A covers crashed/stalled-and-silent ; hung-but-beating is the
edge case the lease PastTtl sweep backstops later.
