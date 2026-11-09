# A write from a worktree to a shared ledger runs in the main checkout

**Status:** Accepted. The owner asked for the fix on 2026-11-09 after the probe below showed the loss, and it was
built the same day. Date: 2026-11-09.
Follows [0201](0201-a-resident-per-checkout-holds-the-described-domain-and-forks-a-launcher-line.md), whose resident
serves a worktree's lines the same way it serves any other.

## Context

The shared ledgers (`~/.claude/hecks-dev/tickets.db`, `agent_run.db`, `pipeline.db`, `agents.db`) are bound to
aggregates by the main checkout's gitignored overlay files (`lib/hecks/hecks/*.local.hecksagon` and `*.local.world`).
A linked worktree has none of them, so every aggregate bound there stores in the worktree's Memory.

`WriteGuard` was meant to stop a write that would land in Memory from a worktree whose main checkout stores it
elsewhere. It looked the store up by bluebook (`store Tickets`), but the bindings are per aggregate: `store Tickets`
reads Memory while `store Tickets::Work` is SQLite. The guard never fired. Probe on 2026-11-09:

```
exe/hecks tickets Work.plan! work.value=zz-guard-probe title.value=probe --wait   # from a worktree
status: planned                                                                    # live tickets.db: no such row
```

The same happens to `AgentRun`, `Revision`, `LinkedTree`, `Landing` and `SendTrain` (agent_run.db),
`Tickets::Finding`, `Pipeline::Passage` and the `Agents` aggregates `Role`, `PlanReview`, `SubmissionReview`,
`Planning`, `Routing` and `PromotionRecommendation`. The git effects of a landing happened; its record never reached the
shared ledger, so a policy that reacts to the record (a landed branch finishing its Work item) never fired there.

## Decision

1. **The guard is aggregate-aware.** It looks up `store <Bluebook>::<Aggregate>` for the command's own aggregate, then
   `store <Bluebook>`, in the main checkout and in the worktree. A write is lost when the main checkout's kind is not
   Memory and the worktree's differs. Aggregates a reaction reaches are the shared ledger's business: only the command's
   own aggregate counts.
2. **A lost write is forwarded, not refused.** `LedgerForward` runs the same line with the main checkout's
   `exe/hecks`, in the main checkout, with the same arguments and environment, and answers its standard output and exit
   status; its standard error is relayed. The forwarded run's launcher is the main checkout's own, so it uses the main
   checkout's resident when one stands. The forwarded run writes the usage row; the worktree process writes none.
3. **A command that names a checkout is told which.** The main checkout would read its own directory as the default
   `checkout.value`, so a command that takes one and was given none gets `checkout.value=<the worktree>`.
4. **Forwarding can be turned off, and cannot loop.** `HECKS_NO_FORWARD=1` refuses with the old message, naming the
   store and the main checkout to run the command from. A forwarded run carries `HECKS_FORWARDED=1`; a guard that fires
   under it refuses and never forwards again. A forwarded run also drops `BUNDLE_GEMFILE`, so the main checkout's
   launcher picks its own.
5. **The warning says so.** The worktree warning now says a command that writes such a bluebook runs in the main checkout.

## Consequences

- A worktree's `Work.*`, `Landing.*`, `LinkedTree.*`, `AgentRun.*`, `SendTrain.*` and `Agents` writes reach the
  shared ledger. Queries are not guarded and still read the worktree's own (Memory) store: a read of a shared ledger
  from a worktree needs `{main}/exe/hecks`, as the coder brief's review commands already use.
- Commands on Memory-bound aggregates (`TestSuiteRun`, `StyleRun`, `GateRun`, `RegenerationRun`, `ConformanceRun`, the
  Hecks `Operation` and `Codebase` aggregates) stay local: they work on the worktree's files, which the main checkout
  cannot see.
- A line costs one more launcher call when forwarded (the worktree's boot or resident, then the main checkout's).
- A forwarded run does not see `-v` or `-q`, which the runner strips before the guard.
- A line of the QA ledger (`hecks quality_control ...`) is routed by the launcher before the runner sees it, so it
  is not forwarded; `QualityControl` is Memory in the main checkout and needs no forwarding.

## Alternatives considered

- **Refuse only.** The guard's old message said to run the command from the main checkout. Every brief and fork runs
  these commands from worktrees, so refusing would stop the workflow. Forwarding is what the message asked for.
- **Link the overlay files into each worktree.** It would send the worktree's reads and writes to the shared ledgers,
  which includes its specs and gates, and adds local files to a development checkout (CLAUDE.md forbids it).
- **Forward the whole launcher.** Specs, style and gates must see the worktree's files; only ledger writes move.
