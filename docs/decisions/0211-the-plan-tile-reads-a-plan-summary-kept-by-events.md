# The plan tile reads a plan summary kept by events

**Status:** Accepted. Date: 2026-11-16. Asked for by the Work item
`the-plan-tile-reads-a-plan-summary-kept-by-events`.

## Context

The board's plan tile loaded every open Work item at each drawing and worked out epic progress, the
count in each lane and the done total in Ruby (`PlanReading`, `PlanOrder.summary`). The cost grows
with the plan, and it repeats an answer the Tickets events already settle: a count changes only when
a Work or Epic event happens.

## Decision

1. **The summary is a projection of the events.** `PlanSummary` folds the Work events (planned,
   started, yielded, released, reopened, finished, dropped, lapsed, assigned, prioritized) and the
   Epic title events into held counts: per lane, open and done per epic, the done total.
2. **A drawing reads, it does not scan.** `PlanTile#plan_summary` catches the projection up with the
   events past its cursor and answers from the counts, plus the first epics by title. No Work item is
   read to answer it. The `running` lane is the only part a Work event cannot say, so a drawing
   moves the few items sessions run from their lane to it.
3. **The fold is pure.** It reads the event stream through the tickets reader's `plan_events`; the
   clock, the store and the files stay behind that reader.
4. **A source that shrinks starts the projection again** from its first events; the cursor never
   skips an event.
5. **Until the reader offers `plan_events`, the tile counts the items itself**, as before, so the
   page never goes blank.

## Consequences

- The tile's lane counts equal `PlanOrder.summary` over the same items: a spec holds the two equal.
- `PipelineTickets#plan_events` (`{work:, epic:}`, each the events oldest first) and a declared
  `PlanSummary` read model in the Tickets bluebook are the follow-on work outside the board's
  stages; the projection takes its events from either.
