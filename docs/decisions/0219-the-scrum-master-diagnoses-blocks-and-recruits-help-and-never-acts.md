# The scrum master diagnoses blocks and recruits help, and never acts

**Status:** Accepted. Date: 2026-11-18. Settled with the owner in the scrum-master grilling of
2026-11-18. Builds on [0218](0218-the-product-owner-owns-what-the-planner-owns-how-and-features-land-dark.md),
whose decision 7 calls a stalled review an impediment "raised like any other"; this record says who
raises it.

## Context

Blocked work in the pipeline is found today in several places, and nobody owns the finding.

- `StallWatch` (`lib/hecks/hecks/stall_watch/stall_watch.bluebook`) times opening lines on the event
  tap against one row per stall kind (`plan-review`, `agent-run-*`, `held-lock`, `stale-boarding`,
  `landing-carry`, `train-*` and the rest). Its `Impediments` query answers what is past its row's
  minutes, oldest first, one per subject or one per kind for a row that folds. Each stall it files
  becomes one Work item for the row's fixer.
- Some blocks are not on it: a `SessionQuestion` (`lib/hecks/questions/questions.bluebook`) nobody
  answers, a `LandingRefused` that leaves a branch waiting, a `Work.yield!` whose precondition has
  since landed, and two open branches editing the same files.
- A stall filed as a Work item asks its fixer to repair it. Most blocks need no repair. They need
  someone told (a precondition landed, a file is shared), or a different session to take over, or
  the owner to answer. A Work item per block can't express any of these, and the orchestrator can't
  tell them apart.

The Lead in this record is the orchestrator, as in 0218. The name changes when the work item
`the-orchestrator-is-called-the-lead` lands; until then, read "the Lead" as the `orchestrator` role.

## Decision

### What it is

1. **The scrum master keeps blocked work moving by diagnosing blocks and recruiting help.** It never
   commits to anything: it writes no file, pushes nothing, ranks nothing, kills no session and does
   no part of the blocked work itself. What it produces is records: notices, help-wanted records,
   check-ins and tickets.

### What it reads

2. **It reads one read-only impediment view.** The view is `StallWatch`'s `Impediments` query,
   extended with rows, not a new store. Its six sources are all records that exist today:
   - a stalled `AgentRun` (the `agent-run-*` rows)
   - a `BoardingHold` (the `held-lock` row)
   - refusals: `LandingRefused` and the train's refused pushes
   - stale boardings: the `stale-boarding` row, on `Integration`'s `MainBoardingStarted`
   - an unanswered `SessionQuestion`
   - yields: a `Work.yield!` enters the view when its precondition lands, not when it grows old

   It adds one computed signal: open branches that changed the same files. Unlike the other sources
   this one is not timed, since nothing on the tap opens it. It is computed from the branches when
   the view is read.

### When it runs

3. **It wakes on events and on a timer, and is not a standing session.** The events are a hold
   placed, a refusal, red CI and a precondition landing. The timer reuses the existing clock port
   (`lib/hecks/adapters/driven/system_clock.adapter`, `port "clock"`) and the heartbeat `StallWatch`
   already answers. A timer tick boots no domain and reads only the view. It starts a short-lived
   scrum-master session only when something in the view is past its age limit, and that session ends
   when its wake ends.
4. **Observe first, ask second.** It checks in with a session only on a warning signal in the view:
   a run past its row's minutes, a question unanswered or a repeated refusal. It never checks in on a
   schedule.

### What it produces

5. **Notices go to the sessions; changes of work go to the Lead.**
   - **Notices** go straight to the sessions concerned as `Message` records (`Message.send!` in
     `lib/hecks/agents/agents.bluebook`). There is no notice aggregate of its own. Examples: a shared
     file, a precondition that has landed.
   - **Changes of work** go to the Lead as requests. Examples: hold, reorder, re-dispatch, merge two
     work items.

   Which a block gets is data: a column on the `StallKind` row of each kind in the StallWatch
   bluebook, not a branch in code.
6. **It recruits help with a help-wanted record, and the Lead assigns it.** The record names the
   block, its age, what it holds up, the help needed and the role that fits. Help-wanted is a new
   aggregate. Which context owns it, StallWatch or Agents, is settled when it is designed.
7. **A help-wanted record closes when its block leaves the view, never on a helper's report.** The
   close is a new event recorded against the help-wanted record when a later read no longer holds its
   block, the way `StallWatch`'s `Abandoned` lines close a filed stall. No record is edited in place.
8. **The owner is asked only through the board.** A help-wanted record goes to the owner in two
   cases: it is still unanswered past its age limit, or the help it needs is the owner, in which case
   it goes at once. Either way it becomes one line on the board's Waiting-on-you panel. Nothing is
   pushed to the owner.
9. **A repeated block becomes a rule, written by a coder.** When blocks of the same kind repeat, the
   scrum master files a ticket proposing the rule that would have prevented them: a row, a setting or
   a refusal. The ticket names the slip. A coder writes the rule.

### Its limits

10. **It is bounded, and every bound is a setting.**
    - each wake has a time limit
    - each block has at most one open help-wanted record
    - each overlapping pair of branches gets one notice, until either branch changes
    - each session gets at most one check-in per cool-down
11. **Duplicate auto-filed failure tickets fold into one impediment.** The view already folds lines
    of a row whose `folds` is `"kind"` (`codebase-check-failed` does), and the scrum master recruits
    once for the fold, not once per ticket. This belongs here because diagnosis starts with counting
    blocks correctly. Ten copies of one failure are one block, and ten help-wanted records for it
    would break decision 10's one-per-block bound.

## Considered and set aside

- **An Impediment aggregate.** Set aside: the impediments are already derived from the records
  that hold them, by `StallWatch`'s `Impediments` query. A stored copy would drift from its sources,
  and closing it would need a second rule beside the one in the view.
- **Regular check-ins of every session.** Set aside: most sessions are not blocked, and a check-in
  costs the session a turn. Asking only on a warning signal spends that cost where it buys
  something.
- **The scrum master acting through Hecks commands itself.** Set aside: a role that can hold,
  re-dispatch or merge competes with the Lead over the same work, and two deciders disagree.
  Diagnosis stays separate from action, and every change of work has one decider.
- **A standing session.** Set aside: it costs a session for every idle hour. Most of the time
  nothing new is blocked, and a timer that reads one view can tell that without booting anything.

## Consequences

- One view answers what is blocked, and every source in it is an existing record, so the view and
  the records cannot disagree.
- A block that needs telling is told by a message. Only a block that needs a decision reaches the
  Lead, and only an owner's block reaches the owner, as a line on the board.
- Repeated blocks turn into rows, settings and refusals, so the same slip is caught by the next
  gate instead of the next wake.
- Today's stall Work items keep their role for repairs. A kind whose help is a notice or a recruit
  moves from filing a Work item to the scrum master as its row is changed.

## Open items

None of this is built by this record. Each item below is its own work.

- **The view's new rows.** `StallKind` rows for unanswered `SessionQuestion`, `LandingRefused` and
  yields keyed on their precondition's landing, and the computed overlapping-branches signal.
- **The routing column.** The column on `StallKind` that says notice, request to the Lead, or
  repair Work item.
- **Help-wanted.** The aggregate, its close on the block leaving the view, and its line on the
  Waiting-on-you panel.
- **The wake.** The event policies and the timer tick that starts a short-lived session past an age
  limit.
- **The scrum-master role.** Its role file and Role row, read-only plus `Message.send!` and the
  records above.
- **The rule ticket.** The repetition count that files it, as a setting.
- The values of the limits in decision 10 are left to the designs that build them.
