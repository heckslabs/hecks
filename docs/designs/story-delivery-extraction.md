# Plan : extract Story's delivery half out of the Planning context

> Review artifact, not a committed doc. "Documentation is the bluebook — no
> separate prose docs." If greenlit, the commitment lands as an **Epic in
> Plan**, not as this markdown file. Read it, decide, then it gets deleted.

**Thesis.** `Plan::Story` speaks two ubiquitous languages — *planning*
(title/tier/sprint/dependencies/use-cases/tasks) and *delivery/CI*
(worktree, the six done-is-done gates, PR-mergeable, main-up-to-date).
The delivery half belongs in the **Conductor** context, where Lease /
MergeQueue / Worker / Claim already live. The runtime now reports the
smell directly (`storehouse dump` : "Plan has 9 aggregates ; 2 concern
clusters"), and — crucially — the extraction is **already ~half done**.

## What already moved (don't redo)

Conductor is mature and tested (Claim 8, Lease 14, Worker 12, MergeQueue
15 behaviours). The seam is live and one-directional (Conductor → Plan) :

- `Conductor::Claim.ClaimAcquired` → `Plan::Story.Start` (volunteer_pull)
- `Conductor::Lease.LeaseGranted` → `Plan::Story.LockWorktree` (story_worktree_sync)
- `Plan::Story.StoryApproved` → `Conductor::MergeQueue.Enqueue` → squash-merge (pr_delivery)

So Conductor already owns worktree **allocation** (Lease), merge
**serialization** (MergeQueue), worker **liveness**, and story **claiming**.

## The two pieces still on Story

### Piece 1 — Worktree state (REDUNDANT with Lease)

Story carries `worktree_path`, `worktree_locked` + `LockWorktree` /
`UnlockWorktree`. `Conductor::Lease` already owns the worktree
(identified_by `:worktree_path`, `belongs_to Story`, lifecycle
active→expired→reclaimed, + worktree_create/remove hecksagons). The path
and lock are **doubly tracked** — the `story_worktree_sync` hecksagon
exists only to copy Lease→Story. That much is pure redundancy to collapse.

**Carve-out (advisor correction 1).** Story also carries `worktree_removed`,
but that VO is NOT clean worktree-duplication — it **gates the done
transition** via the `removed_means_done` invariant (`state ≠ done ∨
worktree_removed == true`). That is done-is-done machinery, not allocation
state. So `worktree_removed` + `removed_means_done` move with **Piece 2**,
not here. Piece 1 is `worktree_path` + `worktree_locked` +
`Lock/UnlockWorktree` + the sync hecksagon — and nothing else.

### Piece 2 — Done-is-done CI gates (a new Conductor aggregate)

Story carries 6 gate VOs (`verified`, `merged_to_main`, `worktree_clean`,
`tests_passing`, `pr_mergeable`, `main_up_to_date`) + `worktree_removed` +
`CheckOk` + `DoneCriterion`, 7 `Record*CheckResult` commands, `RunCheck` /
`RequestReady` / `MarkReady` / `ChecksFailed`, the `checking` lifecycle
state, the `ready_means_*` + `removed_means_done` invariants, the check
policies, and the hecksagons (auto_check_on_ready, main_uptodate_check,
pr_mergeable_check, worktree_removed_check). This is a self-contained
delivery sub-machine.

Target : a Conductor aggregate **`Readiness`** (working name),
`identified_by :story`, that owns the checking micro-lifecycle
(pending → checking → ready | failed), runs the live checks, and records
their outcomes. Story keeps a pure planning lifecycle.

## The seam — verify direction before relying on it (advisor correction 2)

After extraction Story's milestone transitions want to gate on the
Conductor Readiness. Two shapes, two confidence levels :

- **Forward POINT gate — exists today.** `given { Sprint(sprint).state ==
  "active" }` works ; the scalar-ref forward lookup shipped this week.
- **Reverse lookup — UNCONFIRMED.** `given { Readiness(story).state ==
  "ready" }` is NOT the forward shape : `Readiness` is `identified_by
  :story`, so this is a *reverse* lookup ("the Readiness whose story is
  me"), the same shape as `Claim.ByWorker` / `Lease.ByWorker` — still
  blocked on `runtime-cross-aggregate-where`. **Verify before building.**
- **Invariant cross-aggregate read — UNCONFIRMED.** Having `removed_means_done`
  (or an Approve gate) read `Lease(story).state` is a cross-aggregate
  resolution *inside an invariant*. The POINT/SET gates were built for
  command `given`s, resolved at dispatch — it is not confirmed invariants
  do cross-aggregate resolution at all. **Verify before building.**

Net : the *forward* seam is real ; the *reverse* Readiness-lookup and the
invariant-side read are the two things to prove out before committing to
Piece 2's shape.

## What stays on Story (planning, pure)

ref/title/tier/summary/target, sprint/project/theme membership,
dependencies (DAG), use cases, steps, tasks + pending_task_count, and the
lifecycle untasked → tasked → started → ready_for_review → done (+ deferred
⇄ untasked, cancelled). `ready_means_all_tasks_resolved` stays (tasks are
planning). The delivery gates leave.

## Dependencies / blockers (be honest)

1. **Done-is-done is mid-migration.** The gates are a hybrid today (stored
   flags armed by cascades, NOT yet enforced at any transition ; 2 of the
   Record policies already retired for inline hecksagon live-checks). Cards
   `done-is-done-as-live-checks` + `done-is-done-gate-enforcement` are in
   flight. **Do not extract a moving target.** Sequence Piece 2 AFTER the
   live-check migration settles — then you're moving live-check adapters +
   a lifecycle, not stored flags that are being deleted anyway.
2. **Piece 1 depends on Lease being in the real flow.** volunteer_pull
   SEAM 1/3 (self-select, worker-died reclaim) are blocked on
   `runtime-cross-aggregate-where` + Worker back-refs. Lease is wired on the
   grant path but not the full lifecycle.
3. **The reverse seam + invariant read** (the two UNCONFIRMED items above)
   want the same `runtime-cross-aggregate-where` capability Piece 2 carries.

## Phasing

- **Slice A (tractable now, high value) — collapse worktree path+lock into
  Lease.** Retire Story's `worktree_path` + `worktree_locked` VOs +
  `Lock/UnlockWorktree` + the `story_worktree_sync` hecksagon ; make Lease
  the single source of truth. **Leaves `worktree_removed` + `removed_means_done`
  on Story** — those go with Piece 2's done-is-done machinery. Smallest,
  cleanest, removes real duplication. Gated only on confirming nothing reads
  Story.worktree_path except the sync (the agent pass says planning-pulse
  does NOT — only state).
- **Slice B (after live-check migration) — stand up `Conductor::Readiness`.**
  Move the gate machinery + `worktree_removed` + the checking lifecycle ;
  wire the (verified) cross-aggregate gate on Story.MarkReady/Approve ; move
  the check hecksagons under Conductor.
- **Slice C — retire the Story delivery surface** once Readiness owns it ;
  Plan drops from 9 aggregates toward the 3-6 cohesion sweet spot.

## Recommendation

**Do Slice A now** (worktree path+lock → Lease collapse, `worktree_removed`
held back) — it's real debt (double bookkeeping + a sync hecksagon that
exists only to paper over it), it's bounded, and it's unblocked. **Hold
Slices B/C** behind the in-flight done-is-done live-check migration —
extracting stored flags mid-deletion is wasted motion, and the reverse
seam + invariant read need proving first. When the migration lands, B/C
become "move adapters + a lifecycle into the context that already owns
delivery," which is clean.

## Open questions for Chris

1. Aggregate name : `Readiness` ? `Review` ? `Delivery` ? (it owns the
   done-is-done verdict per story).
2. Should `worktree_removed` (the done gate) read Lease.state, or should
   Story.Approve gate on `Lease(story).state == "reclaimed"` directly ? —
   both are the UNCONFIRMED invariant/reverse-read shape ; this question is
   really "which one do we prove out first."
3. Is Slice A worth doing before Conductor's volunteer_pull lifecycle is
   fully wired, or do they land together ?
