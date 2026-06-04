# Sprint 20 — Coordination Substrate — Summary

**Goal:** the fleet-coordination layer — a volunteer pool of workers claims
tasked+unblocked stories, works in leased isolated worktrees, delivers green
mergeable PRs, and the Operator accepts (reviews + merges). Main only changes
on human acceptance ; the fleet never touches it. Built operator-in-the-loop ;
it bootstraps the fleet it enables.

## Shipped — real & proven (each shown running)
- **Conductor domain** : Worker / Claim / Lease / MergeQueue + the Claim mutex
  (one held Claim per story — first Acquire wins).
- **Real adapter runtime** : the `run` / `run … result_into` leaf (spawns real
  processes in-process), dispatch `{field}` interpolation, **resolver-on-cascade**
  (multi-adapter chains run end-to-end, depth-guarded cycle-safety), quote-aware
  argv split + escape-aware hecksagon parser.
- **Worktree lifecycle** : real `git worktree add` on Lease.Grant ; real story
  worktree LOCK on LeaseGranted ; real `git worktree remove` on Reclaim.
- **Done-is-done gate** : un-fakeable (role-enforcement rejects hand-armed flags)
  AND satisfiable — all 6 checks real : worktree_clean / merged_to_main /
  tests_passing / verb_resolves (bin checks) ; **main_up_to_date** =
  `git diff --quiet main origin/main` (inline live-check) ; **pr_mergeable** =
  full `gh pr view --json … --jq` probe (PR open + mergeable + CI green).
- **PR delivery** : StoryApproved → Enqueue → StartMerge → REAL
  `gh pr merge sq/<story> --squash --delete-branch` → CompleteMerge.
- **Conductor observability** (`storehouse mailboxes`) ; plan-side
  story-dependency-dag, contract-first gate, operator roles, agent-collision mutex.

## Honestly deferred — documented, NOT faked (blocked on future runtime features)
- **volunteer auto-select** (SEAM 1/3) → `runtime-cross-aggregate-where`
  (pick the next claimable story ; map WorkerDied → its Claim/Lease).
- **stale-pr recheck / rebase** → `conditional-dispatch` + live-probe +
  cross-aggregate-where.
- **worktree unlock** → `belongs_to`-on-event (LeaseReclaimed must carry the story).
Every such seam is a documentation-only stub or a documented limit — no canned
no-ops, no sentinel dispatches, no garbage-firing adapters remain.

## The bootstrapping paradox (filed : sprint-gate-bootstrapping-paradox)
Sprint 20 BUILT the done-is-done PR-gate and the closure DoD — but its own 15
cards shipped via direct-to-main commits (no PRs), and the Sprint sat in
`planned` the whole time. So the cards cannot self-certify through the gate they
created. Closure is therefore an **operator judgment**, not an automated gate pass.

## Status at closure
- **15 stories ; 0 genuinely-pending tasks** (every non-done task is `cancelled`
  — descoped to sibling cards or redesigned out).
- All work on `origin/main` ; **229 behaviors + Ruby/Rust parity + cargo tests green**.
- The fleet **delivery** path runs end-to-end for real ; the fleet **auto-pilot**
  (worker self-select) awaits `runtime-cross-aggregate-where`.
