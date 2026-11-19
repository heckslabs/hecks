# The product owner owns what, the planner owns how, and features land dark

**Status:** Accepted. Date: 2026-11-18. Settled with the owner in the planner grilling of 2026-11-18.
Narrows [0194](0194-interviews-are-the-beginning-of-work.md): its decision 4, where an accepted Point
leads to the planner. Builds on [0204](0204-an-epic-is-an-aggregate-whose-state-comes-from-its-work.md)
and [0206](0206-an-epic-completes-only-when-its-outcome-is-measured-as-met.md) for the epic.

## Context

Three questions came out of the same grilling, and each answer depends on the others.

- **Who decides what gets built.** The owner starts a session by hand, the `orchestrator-owner` role,
  which has every tool and no routing guard. It plans, ranks, edits code and coordinates, so the
  owner's intent and the team's implementation are mixed in one session. Nothing records which asks
  the owner made and which choices an agent made for them.
- **Who decides how it gets built.** The planner is started by `Planning.request!`, which the
  orchestrator, the board's plan box and the interview's fan-out can all reach. A plan asks the owner
  to confirm options, and the architect reviews items one at a time, so a cut of an epic waits on the
  owner and is reviewed as fragments, never as a whole.
- **When the owner sees a feature.** A change is live on `main` when it lands. A feature made of many
  work items is visible half-built, and the owner sees it for the first time when it is already
  everyone's behavior.

The Lead in this record is the orchestrator. The name changes when the work item
`the-orchestrator-is-called-the-lead` lands; until then, read "the Lead" as the `orchestrator` role.

## Decision

### The product owner

1. **The product owner is the owner's hand-started session.** It is the owner's voice in the
   pipeline: it files the owner's asks as epics and work items and ranks them from the charter. It
   never edits code, and it has no coder's tools.
2. **It replaces `orchestrator-owner`, which is retired by this decision.** Removal of the role file
   and its rows follows as its own work (Open items). The pipeline's own `orchestrator`, the Lead, is
   unchanged: it routes and pushes, and it does not decide what is built.
3. **It wakes on short events and ends.** An epic completed or reopened, or a charter line approved,
   starts one run of the product owner that reranks and ends. It does not stay open watching.
4. **The charter is drafted by the product owner and approved by the owner.** A charter line takes
   effect when the owner approves it. Until then it is a draft and ranks nothing.

### The planner

5. **The planner owns how; the product owner owns what.** The product owner marks an epic ready to
   cut once its outcome and its demo script are settled. Marking it ready starts one planner run.
   Feedback from a demo marks it ready again.
6. **The planner records the whole cut as one draft and never asks the owner.** Where it would have
   asked, it takes its recommended option and records the assumption in the draft.
7. **The architect reviews the whole cut once.** A clean verdict creates every work item of the cut
   at once. A stalled review is an impediment, raised like any other. A rethink about how goes back
   to the planner, up to a set limit of rounds; a rethink about what goes to the product owner.
8. **The planner is reached only through readiness, with one exception.** The board's plan box goes
   to the product owner, as an ask. `Planning.request!` is the Lead's only, and only for repair
   design: a red main, a stall or a refused landing that needs a plan.
9. **An accepted work Point becomes an ask for the product owner.** This replaces the planner path of
   ADR 0194 decision 4, whose closing paragraph reads: "Splitting a large piece of work into Work rows
   is not done by the interview that found it. It is a follow-on interview with the planner that
   cites the first." and "Interviews emits the event that requests the planner and does not take them
   over." Under this record the interview hands the work to the product owner, who files it into an
   epic; the planner is started when that epic is ready to cut. The rest of 0194, its decision 4's
   `decision` and discovery kinds included, stands.

### Features land dark

10. **One flag per new epic that changes behavior.** Fixes, refactors and tooling need none. Epics
    that exist today get no flags.
11. **A flag is a committed Feature row, switched by a one-line landing through the train.** Turning
    a flag on or off is a change like any other: it is reviewed, landed and pushed, and the tree says
    which flags are on.
12. **Specs run the flagged behavior both on and off.** A flagged epic lands member by member with the
    flag off, so `main` stays the behavior everyone had, and the flag-on path is tested from the first
    member.
13. **A board page shows and switches the flags.** `:4747/features` lists every Feature row and its
    state, and its switch files the one-line landing.
14. **The last member's landing brings a demo.** When the last member of a flagged epic lands, a
    coder records a demo with the flag on, in a scratch checkout, following the epic's demo script. A
    live demo is given on request, through the product owner.
15. **"Not yet" is more work on the same epic.** The owner's feedback on a demo becomes new members of
    the same epic, and a fresh demo follows when they land.
16. **A flag that has stayed on is removed.** After a set number of days on and on `stable`, a policy
    files the flag's removal as a work item, so the old path and the row go.

## Alternatives considered

- **A hands-on owner session as break-glass.** Set aside: a session with every tool is the mixing of
  what and how this record ends. The owner keeps a terminal of their own; the pipeline does not seat
  one.
- **Merge the planner into the product owner or the architect.** Set aside: merged into the product
  owner, how and what are one session again; merged into the architect, the reviewer reviews its own
  cut.
- **Per-item plan review for a planned epic.** Set aside: an epic's cut is judged as a whole, and a
  review per item never sees the order or the gaps between items.
- **The owner confirms plans.** Set aside: the owner settles the outcome and the demo script; how they
  are met is the team's, and a confirmation step makes every cut wait on the owner.
- **Flags kept on the machine, with Tune::Dial or in a store.** Set aside: a dial is machine-local, so
  two checkouts can disagree and the tree cannot say what is on. A committed row, switched through the
  train, is reviewed, pushed and the same everywhere.
- **A flag per work item.** Set aside: a work item is a part of a feature, not a feature; flags per
  item multiply switches nobody turns on alone.
- **Landing that waits for a demo.** Set aside: members land dark, so a landing has nothing to show
  yet; holding them would stall the train behind the slowest demo.

## Consequences

- The owner's intent is recorded as asks, epics and approved charter lines, separate from the
  choices agents make, and the owner is never asked how.
- A planned epic is reviewed once, and its work items all appear together or not at all.
- Every behavior-changing epic carries a flag, its specs double for on and off, and the flag is later
  removed by policy, so flags do not pile up.
- `main` can hold a finished feature that is off. The demo, not the landing, is where the owner first
  sees it.
- The planner is no longer reached from an interview's fan-out or the board's plan box directly, so
  those callers change.

## Open items

None of this is built by this record. Each item below is its own work.

- **Retire `orchestrator-owner`.** Remove `.claude/agents/orchestrator-owner.md` and
  `spec/agents_orchestrator_owner_spec.rb`, and its rows in `lib/hecks/agents/agents.bluebook`,
  `lib/hecks/pipeline_board/pipeline_board.bluebook`, `lib/hecks/hecks/hecks.world` and
  `lib/hecks/pipeline_board/adapters/pipeline_web/agents.html`; seat the product owner role in its
  place.
- **Charter.** A new aggregate holding charter lines, drafted and approved; which context owns it is
  settled when it is designed.
- **Epic readiness.** Ready to cut, the outcome and the demo script, on `Epic` in
  `lib/hecks/tickets/bluebook/tickets.bluebook`.
- **Feature.** The committed flag row, in Tickets or a context of its own, with its board page and
  its removal policy.
- **Planning.request! narrowed to the Lead.** The `RoutingRule` rows and the board's plan box in the
  Agents and PipelineBoard bluebooks; the interview's `work` fan-out pointed at the product owner.
- The limit on how-rethink rounds and the number of days before a flag's removal are left to the
  designs that build them.
