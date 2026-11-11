# An epic is an aggregate whose state comes from its work

**Status:** Proposed. Date: 2026-11-11. Proposed by the owner's question "what would a real epic act like?".

## Context

The board groups work with `Category`, a value object on `Work` whose `one_of` list is fixed in
`lib/hecks/tickets/bluebook/tickets.bluebook`. A category is a label. It has no identity, no goal, no
state and no end, and a new theme means editing the bluebook. Of the fourteen values, some are areas
of the product (`delivery`, `language`, `parity`, `host`, `tooling`), some are arcs that never finish
(`autonomous-pipeline`, `landing-review-and-train`, `agent-roles-and-handoff`), and none is a body of
work that has an outcome and an end. Real bodies of work already exist without a home: the rows
`adr0190-01..20`, `adr0194-01..14`, and the plan steps of
[ADR 0163](0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md) are each one decision
carried out across many items, with nowhere to ask "is it done?".

## Decision

1. **`Epic` is an aggregate in the Tickets domain.** It has an id, a `title`, an `outcome` (one
   sentence saying what is true when it is finished), an optional `reference_to Adr, as: :decision`,
   and a `status` of `open` or `complete`.
2. **Membership is a reference.** `Work` gains `reference_to Epic, as: :epic, optional: true`, one epic
   per item, set by a `Work.assign!` command that refuses a done or dropped item. Epics are data:
   `Epic.open!` adds one, with no bluebook edit.
3. **Status comes from the members.** A policy on `WorkFinished`, `WorkDropped` and `WorkReopened`
   moves the epic: `Epic.complete!` when its last open member closes, `Epic.reopen!` when a member
   returns. Nobody sets the status by hand.
4. **Completion can be refused.** `Epic.complete!` has a `given` that no member is planned or started,
   and an epic with no members cannot complete.
5. **Two queries.** `EpicProgress` (done, dropped and open counts for one epic, and its next planned
   item in plan order) and `UndoneInEpic`, the epic counterpart of `UndoneInCategory`.
6. **`Category` stays a label.** It keeps naming the area or arc an item belongs to and never decides
   anything. An item may have a category and an epic. The three never-ending arcs stay categories and
   do not become epics.
7. **First epics come from decisions.** ADR 0190, ADR 0194 and ADR 0163 are opened as epics, with
   their existing rows assigned. The 434 uncategorized rows are not migrated into epics.

## Consequences

- The board can answer "is this decision carried out" from data instead of by counting rows.
- `Work` gains one optional attribute; existing rows are unaffected.
- Closed rows can be assigned only if `Work.assign!` accepts them. This ADR keeps the open-only guard
  that `Categorize` has, so epics opened over finished work start with their members already closed
  and complete at once; whether to relax the guard is left to the separate decision on
  `Categorize`.
- Epic state is derived, so a policy that fails to fire leaves a stale status. The policy needs a
  spec that finishes the last member and expects `complete`.

## Open questions

- Whether an epic may contain epics. This ADR says no; one level keeps `EpicProgress` a count.
- Whether `outcome` should be checkable (a named spec or query) instead of a sentence.
