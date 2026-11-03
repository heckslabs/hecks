# What makes the command line better

**Status: planned for 7.0.0, measured against 6.x.** The measures here judge the steps of
[ADR 0163](decisions/0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md).
Most of what they measure is not built yet, so the numbers are not written down here: a
measure names what is counted, where it is read from, and which way it should move.

A step of the plan is judged by the measure it targets, not by whether it landed. A step
that lands and moves no measure was not worth its cost; a measure that moves the wrong way
is a regression, whichever step moved it.

## The measures

| Measure | Counted as | Read from | Should | Judges |
|---|---|---|---|---|
| Time to a first working command | Wall-clock from `gem install hecks` to the first command that answers, on a clean machine | The tour's own timing, run in CI from a clean image | fall | the tour (step 40), the startup budget (step 35) |
| Commands a newcomer must learn | Names in the `everyday` list of the launcher setting, plus any other name the tour makes a newcomer type | The `everyday` list in `lib/hecks/hecks/hecks.world` and the tour's transcript | fall, then hold | the everyday list (steps 1 and 49), the collapsed families (step 5) |
| Refusals recovered without reading source | Refusals whose next command the user or agent ran, over refusals seen | The deprecation log and the usage counts, once they exist; until then, a sampled session transcript | rise | refusal hints (step 10), refusal codes (step 33), the undo for every write (step 37) |
| Cold start of a command | Wall-clock from the shell prompt to the first byte a command writes, for `Checkout.status` and for a bang that writes nothing | A timing spec in CI, warm cache and cold cache both | fall, then hold under its budget | the startup budget (step 35) |
| Lines of bare `hecks` | Lines the bare launcher prints inside a hecks checkout and in a client project | The help snapshot | fall, then hold | the modules (step 4), the 7.0.0 change (step 5), the snapshot (step 21) |
| Hand-kept lists the help depends on | Lists an edit to the bluebook does not move on its own: the `legacy` table, a scope list kept beside the bluebook, a rename map written by hand | A count of such lists in the launcher setting, the MCP door and the projector | fall to none | the retired gem table (step 9 of the ADR plan), the rename table (step 26), the MCP scope from the audience (step 23) |
| Old-name calls during the warning window | Calls that reached a command through its old name, by name | The deprecation log | fall to none before the refusal ships | the bang rule (step 7), the deprecation log (step 11), the rename table (step 26) |

## How to read a measure

- **A direction, not a target.** A target number goes stale with the next machine or the
  next release; the direction does not. When a step needs a number to pass a gate, the gate
  holds the number, not this page.
- **One reading per release.** Each measure is read on the release commit, in CI, and the
  reading goes in the release notes beside the version. Two releases make a trend.
- **A client project reads differently from the checkout.** The listing is shorter outside
  a hecks checkout, because the maintainer's modules are hidden there. Every measure that
  reads the help is read in both places.
- **Agents count.** The MCP door and a shell-driven agent see the same names as a person.
  Where a measure is read from a transcript, an agent's transcript counts the same as a
  person's.

## Reviewing the everyday list

The everyday list is reviewed against `hecks usage` before each release: a name that did not run in the window is a candidate to drop, and a frequent name missing from the list is a candidate to add.

## What is not measured here

Correctness is the suite's job and the gate's, not this page's. A faster command that
answers wrongly is a bug, and no measure here excuses it.

## Startup budget

Measured on the maintainer's machine (Apple silicon, Ruby 3.3, YJIT off), the warm median of five
runs of `ruby -I lib` that loads `hecks` and answers bare `hecks` from the help cache is 0.49
seconds. A cold run (caches cleared) takes about 7.5 seconds, nearly all of it the grammar boot,
which is not measured by the budget.

The budget is a ceiling of three times that baseline, 1.5 seconds on the same machine. The check
`spec/cli_cold_start_budget_spec.rb` runs in the default test job, not the Postgres io shards,
takes the median of five warm runs, and fails above the ceiling. A slower machine changes the
baseline and the ceiling together, so the check compares a machine with itself.

The first in-process help call after a cache clear costs about one second. The 0.66-second
shell figure earlier was a warm run; the breakdown that suggested a larger figure ran straight
after the clear and measured that cold help call.
