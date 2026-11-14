# An epic completes only when its outcome is measured as met

**Status:** Accepted. Date: 2026-11-13. Asked for by the owner's work item
`epic-outcome-is-measured-before-it-closes` ("an epic does not close just because its items are done").
Narrows [0204](0204-an-epic-is-an-aggregate-whose-state-comes-from-its-work.md), whose decision 3 completed
an epic when its last open member closed and whose open question left the outcome's check for later.

## Context

An epic's `outcome` is a sentence, and under ADR 0204 nothing reads it: the epic completes when its last
member is done or dropped. On 2026-11-13 several items recorded as fixed were not (a stale boarding, a
yield while the session was live), so an epic made of such items would have completed with its outcome
untrue. Closed items say the work was attempted. They do not say the outcome holds.

## Decision

1. **An epic names its measure.** `Epic` gains an optional `measure`, the name of an `OutcomeMeasure`
   row, set by `Epic.measure_by!`. Epics stay data: naming a measure is a command.
2. **A measure is a row.** `OutcomeMeasure` rows in the Tickets bluebook each say one number to read
   from the event tap and its bounds: the `events` of an `aggregate` counted over the last `minutes`
   (or, with `per: "id"`, the most one aggregate id records inside any `span` minutes), with `at_least`
   and `at_most`. The first rows are those the tier-1 epics' outcomes can be read by:
   `load-stays-under-its-mark`, `no-item-started-twice-a-minute`, `main-is-verified-three-times`,
   `no-train-pr-is-left-for-a-hand`, `two-branches-land` and `no-stall-is-filed`.
3. **Cleared members ask for a reading, not a completion.** `Epic.MembersCleared` asks the
   `OutcomeReadings` port, which answers the number, the row's bounds, the reading in words and the key a
   miss would be planned under. The port compares nothing.
4. **The bluebook judges.** The answer is handed to `Epic.Complete` and to `Epic.Miss`. `Complete`
   refuses a reading under its least or over its most; `Miss` refuses one within them; so exactly one
   passes. `Complete` keeps the reading as the epic's `evidence`.
5. **A miss is a new member.** `EpicOutcomeMissed` plans the work item `<epic>-outcome-<n>` with the
   reading as its detail, born a member of the epic (`Work.Plan` gains an optional `epic`), and reopens
   an epic that was complete. `Epic.review!` reads the outcome again at any time, so an epic that was
   complete and no longer holds returns to open with its evidence.
6. **Nothing read plans nothing.** An epic that names no measure, or a name no row carries, or a boot
   with no event tap, is refused by the port (`OutcomeUnread`). The epic keeps the reason as its
   `evidence` and stays as it was. No work item is planned, since no work item changes what was unread.

## Consequences

- **Every epic open today stops completing until it names a measure.** None of the epics in the ledger
  on 2026-11-13 is complete and none names a measure, so all of them are held: the nine of tier 1
  (`agent-scale-landing`, `board-lean-and-declared`, `handoffs-without-hands`, `hands-off-train`,
  `idle-and-paused-work-stops`, `load-aware-dispatch`, `team-roles-for-the-pipeline`,
  `train-reviews-and-machine-health`, `train-stuck-runs-unstick`) and every epic of tiers 2 to 8. An
  epic whose members are all closed shows the reason in its `evidence`.
- **Three tier-1 outcomes have no row.** `board-lean-and-declared` (server memory flat for an hour),
  `handoffs-without-hands` (a goal reaching a release with no manual dispatch) and
  `idle-and-paused-work-stops` (a paused pipeline requests no rolls) are not counts of events the tap
  holds today. Each needs an event to count before it can name a row, and cannot complete until then.
- **A new row is a bluebook edit**, and a regenerated corpus with it. Naming a row on an epic is not.
- **A row with only `at_most: 0` is met by an idle hour.** It says nothing went wrong, not that
  anything ran. Where the outcome produces an event, the row that counts it (`at_least`) is the
  stronger measure. An epic names one row; an outcome that needs two numbers needs a row for the one
  that matters most, or a later change to name several.
- **The rules judge what they are handed.** `Complete` carries no role, as before, so a caller who
  dispatches it by hand with a reading of their own completes the epic. The gate protects the policy
  path, which is the only one the pipeline uses; it is not a guard against a maintainer.
- **Tickets rows name Hecks aggregates and read the Hecks world's tap.** The tap is where the
  pipeline's events are, so the rows name `Hecks::Machine`, `Hecks::Integration` and others. A Tickets
  boot standing alone (a fuzz, a model check) declares no tap, so there every reading is refused and no
  epic completes. That is decision 6, not a miss.
- **`OutcomeMeasure` is not `StallKind`.** A `StallKind` row pairs an opening event with the event that
  closes it and prices the wait; an `OutcomeMeasure` row counts events against bounds. They share the
  tap and the reader (`Runtime::EventFeed`), not a shape.
- **`OutcomeReadings` is a port of its own beside `EpicMembers`.** `EpicMembers` reads the Work items
  and its adapter lives with the Hecks domain's adapters; this port reads the tap.
- **A measure over a window can miss right after the fix.** The evidence item finishing reads the
  outcome at once, and an hour that still holds the old events misses again and plans the next item.
  Its detail names `Epic.review!`, which reads again once the window has passed.

## How it is checked

`spec/hecks_tickets_epic_outcome_spec.rb` closes members against a throwaway tap: a reading within its
bounds completes, one outside them plans `<epic>-outcome-1` and keeps the epic open, a second miss plans
`-2`, a complete epic reviewed after its outcome stopped holding reopens, and an unmeasured epic plans
nothing. `spec/tickets_outcome_readings_spec.rb` reads each kind of row from the adapter alone.
