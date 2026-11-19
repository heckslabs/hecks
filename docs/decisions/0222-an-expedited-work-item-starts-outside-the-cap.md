# An expedited work item starts outside the cap, one at a time

**Status:** Accepted. Date: 2026-11-19. Asked by the owner on 2026-11-13 as a "hot patch": a path
through the pipeline for an urgent item, so nobody changes the cap by hand. The plan was reviewed by
the architect (plan review run `a0291f17`, verdict changes), and its findings are taken in.

## Context

The cap (`work_limit`) and the load guard hold every item that is not red behind the queue. The
verify of 15 overdue passages waited at cap 6, and no verb put an item first: the only way through
was to raise the cap and lower it again. Red-* work items already have a way past: they rank first
in the fill, take `urgent_reserve` places beyond the cap, pass the boot budget and the epic limit,
and land while main is red.

## Decision

1. **The level is `expedite`**, above `now` in the Tickets `Priority` list and in
   `Dispatching::WorkItems::TIERS` (the two lists are the same, in the same order). The owner's
   word "hot patch" stays in prose: `expedite` is the class of service above standard, and it does
   not clash with Release, a release, `stable` or promotion. An expedited change is an ordinary
   change on `main`; `stable` stays promoted only.
2. **It takes one place outside `work_limit`.** `WorkSlots.full?` is the one rule, asked by the
   dispatch plan before a start and by the `WorkLimits` port after it: an expedited item waits only
   while another expedited item is started, it does not spend the red reserve, and it counts against
   no other item's cap. Of the guards, it passes the cap, the boot budget, the epic limit and a pause
   by load. It is deliberately let past `dispatch_max_load` up to the CPU count, a second threshold
   chosen over a full exemption, so the machine keeps a stop. Memory low, a frozen area, an area
   overlap, a dependency and a parked yield hold it as they hold any item. Gates do not stack:
   `heavy_jobs` already runs one gate at a time, and the lane adds no gate place.
3. **The orchestrator sets it, with `Work.expedite!`** (role `Orchestrator`), and each use is the
   event `WorkExpedited`, which carries the priority and which the board's plan shows in its own
   Expedited lane. `Work.prioritize!` refuses `expedite` by name, so there is one way in. Roles run
   in shadow (ADR 0216): the role records who until roles are enforced.
4. **It moves ahead at dispatch now.** It ranks after a red item and ahead of everything else in the
   fill, and a roll starts it by itself. Moving it ahead in review and on the train is left open
   (below).
5. **It reuses red's mechanism.** `WorkItems.urgent?` (red or expedited) is what the boot-budget and
   epic exemptions ask, and `WorkItems.expedited?` is what the order and the place outside the cap
   ask. A red item marked `expedite` keeps the red rules.

## Open items

- **Review and train.** The landing line, the boarding hold and the red flag key on the branch name
  through `RedFlagGuard.fix?`, a pure function of the name that the vendored Delivery calls with no
  git directory. Making an expedited branch pass them needs Delivery (Switchyard) to hand the
  guard the work item's state: a follow-up there, landed first, and the expedited item read from
  Work at the moment of the check, never from a second copy such as a marker file. Until then an
  expedited branch lands in line, and while main is red it waits like any other.
- **Review order** belongs to the LandReview tier (`lib/hecks/agents`).
