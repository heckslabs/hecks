# Sprint 14 — Hecks Adapters (actor model) — closure summary

*Drafted 2026-06-01 for the Done-is-Done gate (`summary_drafted`).*

## What sprint 14 delivered

The **adapter / actor-model runtime**. Every aggregate instance is an actor
with its own mailbox; events flow between actors fire-and-forget; adapters are
bluebook-aware artifacts discovered by convention at
`<bluebook>/hecksagons/<service>.hecksagon`, subscribing via `driven on EVENT`
(bus event) or `driving on cron "<expr>"` (external trigger), wrapping one
impure call and dispatching a follow-on command. Memory + canned by default;
`.world` wires real services per deployment.

**Keystone (the sprint's success criterion):** one tool family (Shell) routes
event-in to event-out through the new runtime, with real DiD verification.
Proven by `bin/sprint14-smoke` — **9 PASS, 0 FAIL, 4 documented gated-PR SKIPs**.
A single `Tools::ShellTool.Bash` dispatch fans out to BOTH the ShellAdapter and
the Sprint14SmokeFanout adapter, each dispatching `Tools::TaskTool.Get`.

## The 29 stories, by theme

- **adapter-runtime-actor-model (9):** actor-per-aggregate-instance,
  async-event-delivery-bus, tokio-mailbox-substrate, per-actor-failure-isolation,
  wire-mailbox-registry-into-event-bus, sendmessage-on-bus,
  storehouse-actors-debug-command, ruby-actor-binding-parity,
  cron-adapter-tasktool-binding-regression
- **adapter-contract (4):** idempotent-by-construction, success+failure pairing,
  no-callback-to-bus-from-adapter-body, adapter-location-macrophage
- **adapter-runtime-followups (4):** causal-ordering-per-aggregate,
  lifecycle-tasked-state, pending-task-count-default-zero, task-completion-state
- **adapter-wiring (2):** memory-canned-defaults, world-wires-real-adapters
- **adapter-rollout (2):** migration-coexistence, sprint14-smoke-acceptance
- **compose-bluebook-through-the-door (2):** storehouse-primitive-conception,
  threading-bluebook
- **planning-safety (2):** make-heki-direct-write-impossible,
  persistence-is-aggregate-only
- **adapter-grammar-extras (1):** driving-on-grammar
- **agent-discipline (1):** agent-discipline-bypass
- **planning-surface (1):** sprint-reorder-stories
- **cross-aggregate cascade (1):** cascade-cross-aggregate-persist

## Deliberate end-state: built, verified, dormant

The actor model is **built and proven in isolation**, but the live bus is still
synchronous. `migration-coexistence` is the contract: `delivery :sync` is the
per-aggregate default, **zero** aggregates are flipped to `:actor`, and
`enqueue_and_drain` enqueues-then-drains in the same call. This is intentional —
it lets aggregates flip to `:actor` one at a time in a future sprint instead of a
big-bang cutover.

## Deferred out during closure (scope honesty)

- **`retire-sync-cascade-pipeline` -> sprint 19.** Its deliverable removes the
  sync path + `DeliveryMode` fork — the exact coexistence scaffolding this sprint
  shipped. Its own precondition ("retire sync cascade ONCE mailboxes carry
  events") is unmet: nothing is flipped to `:actor`. It is the destination of the
  migration, one sprint downstream. Its branch `sq/retire-sync-cascade-pipeline-fresh`
  is preserved.
- **`policy-cmd-needs-interpolation-or-bin-scripts` -> sprint 15.** A stale
  open-design card, never sprint-14 scope.

## Bugs found and fixed at the root during closure (zero-bug discipline)

- **Cross-aggregate cascade FK resolution** — `Task.Complete/Reopen` carried only
  `id`, so the count cascade couldn't resolve the owning Story. Fixed with
  `cascade_fk_id` in `dispatch_inner` (same-context upstream FK preferred over the
  leaked self-id).
- **CronAdapter driving-tick regression** — behaviors gate; folded into snippets.
- **Smoke rename-drift** — `bin/sprint14-smoke` asserted the pre-rename
  `MailboxRegistry`; the runtime renamed it to `Mailboxes`. The acceptance proof
  caught it; fixed at the root (not skipped).

## Hygiene

- Worktrees pruned 33 -> 1.
- Branches: all merged `sq/*` + `worktree-agent-*` deleted; only `main` and the
  sprint-19 `retire-sync-cascade-pipeline-fresh` remain.

## DoD verification

- `ci_passing`: full Rust suite green; golden 27/0/3; behaviors 564/0/0; Ruby green.
- `merged_to_main`: accumulator + cherry-picks + branch merges all landed.
- `worktrees_pruned`: 33 -> 1.
- `prs_for_open_branches`: no dangling sprint-14 branches.
- `summary_drafted`: this document.
- `all_stories_done`: the 29 stories Approved by the Operator.

## The 4 documented SKIPs (future gated PRs)

idempotent-dedup-by-event-id, macrophage-adapter-location-check,
hecksagon-canned-default-DSL — each auto-enables in the smoke when its PR lands.
Not sprint-14 failures.
