# A run and a day have a spend bound, declared as data

**Status:** Proposed. Date: 2026-11-18. Asked for by the work item `spend-bound-design`. The plan was
reviewed by the architect (plan review run `a2ebfc6e`, verdict sound), and its notes are taken in.
The values are the owner's and ship unset. Builds on the boot budget (`cpu_budget`,
`Hecks::Adapters::BootBudget`) and gives the open work item `fan-out-effort-budget` its ceiling.

## Context

The Tickets world (`lib/hecks/hecks/tickets.world`) limits the pipeline in four ways:

- how many work items run at once (`work_limit`, `work_cap`);
- how loaded the machine is (`dispatch_max_load`, `load_shed`);
- how many hours the launcher boots in a day (`cpu_budget`);
- how long one work item is meant to take (`Work.budget_minutes`, `tickets.bluebook`).

Nothing limits what the sessions spend on the model: no token, dollar or turn limit is declared
anywhere. A grep of `lib/` for `input_tokens`, `output_tokens`, `cost_usd`, `num_turns` and
`max-turns` finds nothing. The CLI's own `--max-turns` and `--max-budget-usd` only work in print
mode, and the dispatcher starts sessions as `claude --agent <role> --settings <json> --bg -- <brief>`
(`lib/hecks/hecks/adapters/session_line.rb`), so they don't apply.

The open item `fan-out-effort-budget` asks that each brief state an effort budget sized to the task,
and that coding fan out only where the tasks are independent. It sizes the work. It doesn't measure
it or say what happens when the work goes past it. This record covers the measuring and the limit.

### Where spend can be read

Every session writes a transcript at `~/.claude/projects/<project>/<session>.jsonl`. A session's
subagents write theirs to `<session>/subagents/agent-<id>.jsonl`, with a `.meta.json` beside each
that names `agentType` and `spawnDepth`. Each assistant entry carries its model and the usage of
the API call. One such entry, measured 2026-11-18 (read-only), with the content left out:

```json
{"type": "assistant", "timestamp": "2026-11-19T04:14:27.797Z",
 "message": {"id": "msg_…", "model": "claude-opus-5-5",
             "usage": {"input_tokens": 2, "output_tokens": 175,
                       "cache_creation_input_tokens": 32474, "cache_read_input_tokens": 31571}}}
```

One API call is written as several lines, one per content block, all under the same `message.id`.
In one transcript, 33 assistant lines held 19 ids, and 12 of those ids had more than one line.
Across five transcripts (285 ids in all), the lines that share an id always carried the same usage.
So a call is counted once, by its id.

The launcher's usage record, which `BootBudget` reads, has no token fields and logs launcher boots,
not model calls, so it can't be reused here. `lib/hecks/hecks/adapters/cost_explorer.rb` reads AWS
billing and has nothing to do with model spend.

## Decision

### Bluebook or hecksagon

1. **The limit is part of the domain, so it goes in the bluebook.** That a fill refuses a start
   once the day's spend reaches its limit is a rule of Dispatch. That a run has a spend is a fact
   of `AgentRun`. Both are declared in the bluebook, and so is the fill's reason for refusing.
2. **The values are the Tickets world's**, the same way `cpu_budget` is.
3. **Reading transcripts is outside the domain, so it goes behind a port.** A new `Spend` port is
   declared in a hecksagon, with an adapter `lib/hecks/hecks/adapters/spend_reading.rb` behind it.
   The adapter only measures: it reads entries, dedupes them by `message.id`, and returns per call
   the model, the four token counts and the timestamp. It doesn't multiply by prices, judge a model
   unpriced, or format a refusal.

### The settings, shipped unset

4. **`spend_budget "Dispatch"`** holds the limits:
   - `day_dollars`: a ceiling on a rolling 24 hours of dispatched runs;
   - `run_dollars` and `run_turns`: ceilings on one run;
   - `day_tokens` and `run_tokens`: optional, for an owner who prefers tokens to dollars.

   The line ships with no keys. A key that is absent sets no limit, as an absent `cpu_budget` does
   today. The owner chooses the values; the coder never does.
5. **`model_price "Spend"`** holds one row per model: `model:`, `input_per_mtok:`,
   `output_per_mtok:`, `cache_write_per_mtok:` and `cache_read_per_mtok:`, in dollars per million
   tokens. These are facts copied from Anthropic's published price list, not the owner's choice.
   The coder fills them from that list when building step 1.
6. **Dials.** `spend_budget.day_dollars`, `spend_budget.run_dollars` and `spend_budget.run_turns` get
   `Tune` dial rows in `tune.bluebook` beside `cpu_budget.boot_hours_per_day`. The board's settings
   page adds `spend_budget.` to the prefixes it shows. Price rows are not dials and are changed by
   editing the world.

### Measuring

7. **A call is a turn.** A run's turns are the distinct assistant `message.id`s in its transcripts,
   its subagents included. Its tokens are the four sums. A run's sessions are its
   `AgentRun.session` and the sessions in `forked_from`.
8. **Dollars come from the declared prices, not from the adapter.** A value object `Spend` on
   `AgentRun` (turns, the four token counts, the model) prices itself against the `model_price`
   rows. A model with no row counts its turns and tokens, and its dollars read as unpriced. A
   dollar limit is judged on priced calls only, and the board names the unpriced models, the way
   `BootBudget` reports unmeasured boots.
9. **A missing field counts as zero.** An assistant entry with no `usage`, or with a usage that lacks
   one of the four counts, adds zero for what is missing. An entry with no `message.id` is a call of
   its own. A line that isn't valid JSON is skipped and counted, and the reading reports how many
   it skipped.
10. **The day is the dispatched runs of the last 24 hours**, taken from the `AgentRun` ledger and
    placed in the window by each call's timestamp. The owner's hand-started sessions aren't counted.
11. **The read is bounded.** Only the transcripts of runs in the window are opened, never the
    whole projects directory, and each file is read from its tail up to a byte limit, as
    `UsageTail` does (8 MB). A read the limit cut short is flagged as capped, and its total is a
    floor. Once a capped floor has reached half the day limit, the limit counts as probably spent,
    by `BootBudget`'s rule: a runaway session, the very thing that fills the read, can't hide by
    overflowing it.

### At the limit

12. **The day limit refuses a start.** Once the day's priced spend reaches `day_dollars` (or
    `day_tokens`), `Dispatch.Fill` starts no session except the fix of a red-* work item, the way
    the boot budget works. The reason is a plan reason declared in the bluebook, next to the boot
    budget's, so `Priority.report` and the fill report print it from the declaration. `BootBudget`
    still formats its own refusal line; spend doesn't copy that.
13. **Reporting comes first.** Every run that ends records its `Spend`. The board gets a "Spend
    today" tile next to Boot hours, with the day's dollars, turns and tokens, how much of each limit
    is used, and any unpriced models.
14. **The run limit is asked, then enforced. This is optional and depends on step 1's data.**
    - A run whose spend passes `run_dollars` or `run_turns` records `RunSpendCrossed` on its
      `AgentRun`, with the turn count at that moment stored as a fact of the run.
    - A policy then leaves a message in the session's inbox telling it to commit what it has,
      report and end. The existing `PostToolUse` and `Stop` file hook delivers the message without
      booting the launcher. Like `Shed`, it asks; it never kills a session in the middle of a commit.
    - A run still working `spend_grace "Dispatch", turns:` turns past that stored count records
      `RunSpendGraceSpent`, and that event alone triggers the stop:
      - `StopRunPastSpendGrace` stops the session through the existing stopper and records
        `RunStoppedForSpend`;
      - a second policy turns `RunStoppedForSpend` into `Work.yield!` with the reason
        `spend bound: <reading>`.
    - The commits stay on the run's branch. The grace counter is a stored fact of `AgentRun`, never
      the adapter's state.
    - Readings are taken at the end of each turn (the `Stop` hook already runs `Turn.end!`) and by
      the Delegate sweep for runs that are in the middle of a turn. No launcher boot is added per
      tool call.

### Build order

Coder work items are created once the owner has answered:

1. **Measure and report.** The `Spend` port and transcript adapter, the `model_price` rows, the
   `Spend` value object, the board tile and the run report. Specs use scratch transcripts only.
   Check with `model_check_run.model_check` on Delegate and Tickets.
2. **The day refusal** in `Dispatch.Fill`, as a declared plan reason.
3. **The run wrap-up and stop** (decision 14). Optional: build it only if step 1's numbers show a
   single run can cost too much before the day limit catches it.
4. **`fan-out-effort-budget`'s briefs quote the run limit** as their default ceiling.

Steps 1 and 3 add `Spend` and events to `AgentRun` in `lib/hecks/hecks/delegate`, so they start only
after `agentrun-parent-run`, which is editing that area, has landed. If the owner answers "leave
unset, report only", the build ends after step 1.

## Consequences

- Spend becomes visible before any limit binds, so the owner chooses the values from measured days
  rather than guesses.
- A runaway day stops itself the same way a runaway of launcher boots already does.
- Prices are data. A new model needs only a row; until it has one, the board names it as unpriced.
- This branch holds only this record, so there is nothing to run `model_check` against yet.
  Step 1 is where that check first applies.
