# Sprint 20 — Conductor contracts (ratified 2026-06-02, revised for relationships + adapters-only)

The agreed interfaces for the Conductor (Workforce) domain. Stories write to these
shapes independently, in parallel — a story depends on the CONTRACT, never on another
story finishing. File-per-aggregate so parallel writers never touch the same file.

**The `conductor.bluebook` aggregate stubs ARE the ratified contract and the single source of truth** (this markdown is a throwaway planning aid — documentation is the bluebook). Tasks POINT at it ; they
never re-state the shape.

## Architecture constraints (both axes, born clean)
1. **Zero runtime modification.** The runtime is finished (sprint 14). The Conductor is
   built ENTIRELY on that substrate : bluebook aggregates + hecksagon adapters
   (`driven on EVENT` / `driving on` — wrapping impure git/worktree/cargo calls,
   canned-by-default, world-wired for real) + cascade policies + invariants. No `rust/`
   changes. If a task's acceptance is “edit the runtime,” it is mis-modelled.
2. **Relationships, not FK ids.** Use the relationship DSL (`belongs_to` / `has_many`).
   The association is owned in ONE direction ; the reverse is a DERIVED QUERY, never a
   stored mirrored FK. No `*_ref` attributes, no mirror cascades.
3. **Uses the existing relationship DSL** — belongs_to/has_many/has_one are already in production ; add-relationship-dsl is canonicalization, NOT a prerequisite.
4. **Does NOT depend on `hex-runtime-port-eval-hook`** (a runtime mod). Synchronous gates
   use the existing cascade → RecordResult → flag → invariant pattern that already gates
   the four Story DoD checks (worktree_clean et al.).
5. **Two adapter kinds, never conflated** (hex-invocation-principle) : LIVE-CHECK adapters `satisfy` a port and answer INLINE — return ok/fail, never dispatch, never call back into the bus ; ORCHESTRATION adapters are `driven on` an event and DISPATCH a follow-on command. A gate that dispatches, or an orchestrator that answers inline, is mis-modelled.
6. **Reads go through aggregate queries, never storage** — observability/projections read via Story/Worker/Claim/Lease/MergeQueue queries, never `.heki` directly (persistence-is-aggregate-only). Associations use the relationship DSL (belongs_to/has_one/has_many), never list-of-ref or `*_ref`.

## 1. Worker — the fleet member  (conductor/worker.bluebook)
- identity: worker_id
- attrs: status (alive/dead, default alive) ; heartbeat_at
- **derived (NOT stored)**: “current claim” = query Claim where worker=me, state=held ;
  “worktree” = query Lease where leased_by=me, state=active ; “working?” = has a held Claim
- commands: Register → WorkerRegistered ; Heartbeat(at) → WorkerHeartbeat ; MarkDead → WorkerDied
- (no current_claim attr, no ReleaseClaim, no worktree attr, no mirror cascade — all derived)

## 2. Claim — the atomic hold (the mutex)  (conductor/claim.bluebook)
- identity: story  (one Claim per story — structural mutex)
- **belongs_to Worker** (the association, owned here)
- attrs: state (held/released/expired) ; claimed_at
- commands: Acquire(worker) → held, GIVEN no active claim for this story → ClaimAcquired ;
  Release → ClaimReleased ; Expire → ClaimExpired
- invariant: at most one held Claim per story ; atomic-acquire guard hardened by prevent-agent-collision-state

## 3. Lease — the worktree allocation  (conductor/lease.bluebook)
- identity: worktree_path  (one Lease per path)
- **belongs_to Story, belongs_to Worker**
- attrs: expires_at ; state (active/expired/reclaimed)
- commands: Grant(expires_at) → active, GIVEN path not already active → LeaseGranted ;
  Renew(expires_at) → LeaseRenewed ; Expire → LeaseExpired ; Reclaim → LeaseReclaimed
- invariant: at most one active Lease per path ; allocation/reclaim LOGIC added by worktree-pool-lease-reclaim

## 4. MergeQueue — serialized merge-on-accept  (conductor/merge_queue.bluebook)
- identity: branch (default main, singleton-per-branch)
- **has_many queued Stories (by reference)** ; current = the merging Story (empty when idle)
- attrs: state (idle/merging)
- commands: Enqueue(story) → MergeEnqueued (fired by an Approve adapter) ;
  StartMerge(story) → merging, GIVEN idle → MergeStarted ;
  CompleteMerge(story) → idle → MergeCompleted (→ Story done) ;
  FailMerge(story, reason) → idle, bounce → MergeFailed
- invariant: at most one current merge (serialized) ; merge-on-accept BEHAVIOR added by pr-delivery + stale-pr

## The seams — all ADAPTERS, never runtime
- ClaimAcquired → (adapter) → Plan::Story.Start
- Plan::Story.Approve → (adapter) → MergeQueue.Enqueue ; MergeCompleted → (adapter) → Story done
- Lease lifecycle ↔ Story.LockWorktree / UnlockWorktree via adapters
- Worker liveness + lease-expiry reclamation : a `driving on` (tick/cron) adapter, not a runtime loop
- A Worker's current claim / worktree : DERIVED QUERIES, not stored back-refs

## Plan-side contracts (owned by Plan stories, the other half of the seam)
- Story.depends_on (list) + Claimable query — story-dependency-dag (relationships, not FK)
- Story.pr_mergeable + the PR-delivery DoD shape — pr-delivery-merge-on-accept ; gates via cascade+invariant, no runtime
