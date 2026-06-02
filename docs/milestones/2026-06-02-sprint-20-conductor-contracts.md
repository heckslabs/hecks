# Sprint 20 — Conductor contracts (ratified 2026-06-02)

The four agreed aggregate interfaces for the Conductor (Workforce) domain. These
are the SHAPES the sprint's stories write against — ratified up front so the work
fans out in parallel : a story depends on the CONTRACT (which exists from this
agreement), never on another story finishing. File-per-aggregate so parallel
writers never touch the same file.

Decisions locked: Claim identity = story (mutex by identity) ; MergeQueue is a
singleton-per-branch (default "main").

## 1. Worker — the fleet member  (conductor/worker.bluebook)
- identity: worker_id
- attrs: status (idle/working/dead, default idle) ; current_claim (→Claim, empty when idle) ; heartbeat_at ; worktree (path, empty when idle)
- commands:
  - Register(worker_id) → idle ; emits WorkerRegistered
  - Heartbeat(worker_id, at) → sets heartbeat_at ; emits WorkerHeartbeat
  - ReleaseClaim(worker_id) → idle, clears claim+worktree ; emits WorkerClaimReleased
  - MarkDead(worker_id) → dead ; emits WorkerDied
- invariant: a working worker has a non-empty current_claim
- ownership: conductor-domain builds this FULLY (no sibling fleshes it out)

## 2. Claim — the atomic hold (the mutex)  (conductor/claim.bluebook)
- identity: story  (one Claim per story — mutex is structural ; a second Acquire on the same story collides by identity)
- attrs: worker (→Worker) ; state (held/released/expired) ; claimed_at
- commands:
  - Acquire(story, worker) → held ; GIVEN no active claim for this story ; emits ClaimAcquired
  - Release(story) → released ; emits ClaimReleased
  - Expire(story) → expired ; emits ClaimExpired
- invariant: at most one held Claim per story
- ownership: conductor-domain writes the skeleton ; prevent-agent-collision-state hardens the atomic-acquire guard

## 3. Lease — the worktree allocation  (conductor/lease.bluebook)
- identity: worktree_path  (one Lease per path — no two workers share a tree, structurally)
- attrs: story (→Story) ; leased_by (→Worker) ; expires_at ; state (active/expired/reclaimed)
- commands:
  - Grant(worktree_path, story, leased_by, expires_at) → active ; GIVEN path not already active ; emits LeaseGranted
  - Renew(worktree_path, expires_at) → emits LeaseRenewed
  - Expire(worktree_path) → expired ; emits LeaseExpired
  - Reclaim(worktree_path) → reclaimed (tree removed, back to pool) ; emits LeaseReclaimed
- invariant: at most one active Lease per path
- ownership: conductor-domain writes the skeleton ; worktree-pool-lease-reclaim writes allocation/reclaim logic

## 4. MergeQueue — serialized merge-on-accept  (conductor/merge_queue.bluebook)
- identity: branch (target, default "main" — singleton-per-branch)
- attrs: entries (queued story refs) ; current (merging now, empty when idle) ; state (idle/merging)
- commands:
  - Enqueue(branch, story) → appends ; emits MergeEnqueued  (fired by Approve cascade)
  - StartMerge(branch, story) → merging, sets current ; GIVEN state idle (one at a time) ; emits MergeStarted
  - CompleteMerge(branch, story) → idle, dequeues ; emits MergeCompleted  (→ Story done)
  - FailMerge(branch, story, reason) → idle, bounces entry (stale/conflict) ; emits MergeFailed
- invariant: at most one current merge (serialized)
- ownership: conductor-domain writes the skeleton ; pr-delivery-merge-on-accept + stale-pr-recheck-rebase write the merge behavior

## The seams (Conductor ↔ Plan)
- ClaimAcquired → Plan::Story.Start  (claim a story → it starts)
- Plan::Story.Approve → MergeQueue.Enqueue ; then MergeCompleted → Story done
- Claim is the source of truth for the hold ; Worker.current_claim mirrors it via cascade (one writer)
- Plan-side contracts (Story.depends_on, Story.pr_mergeable) are owned by story-dependency-dag / pr-delivery — the other half of the seam
