# RESTART 2026-06-20 (evening) — Event Log SHIPPED (imperative, proven, gated) ; bluebook-first rewrite is NEXT

VOICE : I / my / mine. Handoff from a long, productive session to my next self.
The out-of-process Event Log is BUILT and PROVEN (30/30 lossless, live) but
IMPERATIVE and GATED OFF. The interval scheduler is BUILT, PROVEN, and LIVE. The
bluebook-first rewrite of the Event Log is CONCEIVED and is the next focused arc.
Everything below is on `main` (head cf9ddf55f). Nothing is bleeding ; nothing is
half-declared. Read this, then pick up at "NEXT".

## What shipped this session (12 commits, all on main)
- d68e3b05d  Event-sourcing GATED OFF (HECKS_EVENT_SOURCING). Stopped the lossy
  in-process Log bleed. Verified both directions ; daemons restarted.
- f89c07519  `driving on interval` wired (Ruby builder + parity fixture). Parity
  194/194. Closed the §3 cron-vs-interval convention.
- bba54aa4d  interval-scheduler design spec + Driver-chapter-retire note.
- a2cf7fc8d  fix : Kitchen.persisted_by missing from pizzas exemplar (latent
  golden failure the pre-push gate caught — fixed at root).
- 29810646f  §2 precondition finding + the shards-plus-merge TOPOLOGY DECISION.
- fd189fe8a  **storehouse drive** — the live interval scheduler. The FIRST daemon
  that fires `driving on` handlers live (cron never did). Single-owner, no
  double-fire. Pure tick-counter core (drive_scheduler.rs, 6 tests). Cadence
  proven LIVE : interval 1s @ poll 500ms -> fires ticks 1,3,5 exactly.
- 3385eaf4c  Event Log SLICE 1 : event_shard.rs — append-only one-JSON-line-per-
  event format + writer + offset-resumable reader. 7 tests.
- b6d90037c  Event Log SLICE 2 : event_merge.rs + `storehouse merge` daemon.
  THE PROOF : 30 concurrent writers x 50 = 1500 recovered, 0 dup (the 30/30 that
  replaces the old 13/30). Crash-safe (idempotent replay). Ordered. 5 tests.
- 3dc5da563  slices 1+2 done note + slice-3 cutover plan.
- f926be79f  Event Log SLICE 3a : rewired record_event_append to write per-
  process SHARDS (not the clobbering shared heki). PROVEN LIVE : 30 concurrent
  gate-on dispatches (each its own process) -> merge -> global count 30.
- 63cf9a83b + cf9ddf55f  bluebook-first CONCEPTION of the refactor + a correction.

## Current state (SAFE)
- The proven Event Log (slices 1-3a) is on main but GATED OFF
  (HECKS_EVENT_SOURCING unset). record_event_append writes shards ONLY when the
  gate is set ; live daemons don't set it, so nothing writes shards yet. Zero
  regression risk. The whole thing is INERT until deliberately gone-live (3b).
- The interval scheduler (storehouse drive) is built + tested but NOT yet a
  Procfile member and nothing in-corpus uses `driving on interval` live — it is
  the mechanism, awaiting adoption.

## NEXT — the bluebook-first rewrite (a focused fresh-head arc, gated worktree)
FULL PLAN : inbox/event-log-bluebook-first-conception.md. The short of it :
the proven slices 1-3a are IMPERATIVE ; the bluebook-first version expresses the
same design as DECLARATION. The honest floor-vs-shadow line (verified) :
  - FLOOR (correctly Rust, sibling of heki.rs — kernel-floor PERSISTENCE IO, NOT
    primitives ; do NOT put them in primitive_registry, that miscategorizes them
    and breaks the dispatcher<->seed macrophage check) : shard byte-IO
    (event_shard.rs), merge fold (event_merge.rs), the run_drive timer loop, the
    ~10-line tick math.
  - SHADOW (build as declaration) : ShardRecord duplicates Event ; run_merge
    should be a `driving on interval` Driver firing a Consolidate command, fired
    by `storehouse drive` (DELETE run_merge) ; record_event_append should
    dispatch Event.Append routed through an AppendLog persistence adapter.
The deep piece : a NEW `Backend::AppendLog` variant in LazyRepository
(persistence_resolution.rs match arm), append-not-upsert save + log-read find.
That bends the persistence family's upsert-shaped reply contract — it is the part
that needs care + a fresh head, NOT a session-end bolt-on. There is NO shallow
first increment (the "register as primitives" idea was wrong — see the correction).
PROJECTION ORDER : (1) Backend::AppendLog + bind Event.persisted_by("AppendLog")
+ revert record_event_append to dispatch Event.Append ; verify 30/30 holds. (2)
Event.Consolidate command + driver + drive-fires-it ; delete run_merge. (3)
ShardRecord -> Event serialization. (4) slice 3b GO-LIVE : gate flip + Procfile
driver members + restart. EACH step COMPLETE + FUNCTIONING before commit (never a
declared-but-ignored bind = written-but-not-functioning).

## Go-live (slice 3b) findings — when the bluebook rewrite is ready to flip on
- NO live readers of event.heki exist yet (Replay/AtSequence conceived in
  event_sourcing.bluebook, NOT implemented). So the cutover's reader-divergence
  risk is LOW — the merge daemon writes the same path a future reader would use.
- MULTI-REALM wrinkle : conception daemons write the hecks realm
  (~/.heki/hecks/shards) ; body daemons write the miette realm. Each realm needs
  its OWN merge daemon (or one multi-dir merge). Shard dir resolved to
  <data-root>/shards (heki_path() returns the realm root, not the per-aggregate
  dir). Account for this when wiring the Procfile merge member(s).
- Un-gate is the LAST act, only after the merge member(s) are live AND a live
  N-process dispatch test shows the global log lossless.

## Pointers (durable)
- inbox/event-log-bluebook-first-conception.md — the refactor plan + floor/shadow.
- inbox/event-log-oop-precondition.md — topology decision + slice-3 cutover plan.
- inbox/interval-scheduler-spec.md — the storehouse drive design + cron-live follow-on.

## Open follow-ons (smaller)
- cron-LIVE : `storehouse drive` fires interval only ; cron handlers still fire in
  no live daemon (test-only). Real 5-field cron matching is the documented next.
- storehouse drive adoption : no Procfile member yet ; nothing live uses
  `driving on interval`. The --every loops COULD migrate to it later.

## No agents running. Daemons are on the gate-OFF binary (event-sourcing inert).
