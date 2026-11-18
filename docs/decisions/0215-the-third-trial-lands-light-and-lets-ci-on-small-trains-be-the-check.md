# The third trial lands light and lets CI on small trains be the check

**Status:** Accepted. Date: 2026-11-17. Asked for by the Work item
`trial-ci-first-landing-small-trains-and-ci-is-the-check` (epic `agent-scale-landing`). A trial: it starts when
the second local trial ends (00:20 on 2026-11-18) and changes no bluebook, hecksagon or code here.

## Context

Two local trials (2026-11-16 and 2026-11-17) leaned on a local check: first the impacted specs before the
merge (about 2.2 landings an hour), then the impacted specs after it (about 4 to 5 an hour, with reverts by
hand, then by policy under decision 0214). The local check took 20 to 60 minutes for part of the suite, and
both it and the local post-merge check passed three breaks that CI then failed (packaging and CLI help goldens
on PR 1502; board wiring, a resident launch and a killed spec worker on PR 1507).

**Measured 2026-11-17** (readings, not invariants; the CI figures come from `gh run view 44198098141` and its
jobs, which `gh` still reports as completed `success`, created 23:17:46Z and updated 23:23:32Z):

| What | Reading |
| --- | --- |
| A train's CI run, wall time | 5 min 46 s (87 jobs, 6,930 job-seconds in parallel, longest job 281 s) |
| What it covers | the whole suite, on 28 spec shards |
| Cost | none: `heckslabs/hecks` is public and the run shows 0 billable ms |
| Load on the owner's machine | none |
| The account's limit on concurrent runs | not known; read from the first busy hour |

## Decision

The owner approved a third trial in which CI, not a local run, is the check.

1. **Landing stays light.** Rebase, the quick gate, merge to local `main`. The shallow check is off.
2. **No local impacted-spec run is asked for** before the merge or after it; the post-merge verification
   runs the quick gate only, or is skipped. The `ShallowCheck` switch (`ShallowCheck.switch! state.value=off`)
   turns off the clone check that runs CI's failing checks; by decision 0212 item 1 it moves the impacted
   specs to the verification, it does not remove them. No switch turns the impacted run off today.
3. **A train boards at 3 commits ahead of `origin/main`, or 10 minutes after the first unshipped commit**,
   whichever comes first (the push nudge is 10 commits today). A boarding does not re-run checks the landing
   already ran, and each boarding step joins the heavy-slot queue at train priority.
4. **CI on the train's pull request is the check.** GitHub's merge queue merges it only when green, so
   `origin/main` is green by construction.
5. **A red train is bisected by CI.** The first half boards as its own train; two more runs at most for three
   commits (about 12 minutes). The culprit merge is reverted on local `main` through `SendTrain.Unland`, its
   Work item is reopened with the failing check and spec, and the rest re-board. A failure that passes on one
   rerun of the failed job is a flake and is not reverted. `RedFlag` holds landings meanwhile.
   Decision 0214 owns "main is red" and the revert policy (`RevertTheCulprit`), and a merge that reached
   `origin/main` leaves the flag standing for the owner and CI. The hand revert here stands in for that policy
   until a CI-fed `RedEpisode` exists; it is not a second owner of the flag.

## What a hand-driven first run can do without

Four things are needed before the trial runs unattended. They are filed as Work items when this is picked up.

| Build item | The first run |
| --- | --- |
| A setting for the train threshold (commits and minutes) | does without: the orchestrator reads `push_rehearsal.due` and boards by hand at 3 commits or 10 minutes |
| A `RedEpisode` fed by a train's CI result (failing check, spec, example from the job log; culprit from the CI bisect) | does without: the orchestrator reads CI, bisects by boarding halves, reverts through `SendTrain.Unland` and reopens the item |
| A dead or faulted boarding that reports itself (one died silently at 19:5x on 2026-11-17 and its shepherd waited on a pull request that did not exist) | does without, with a watch: the orchestrator checks each boarding for its pull request |
| A switch that turns the post-merge impacted run off | **depends**: no switch was found that skips the landing's impacted run (the landing runs the quick gate and the specs the change impacts); until one is confirmed or built, the first run keeps that run, and the measure says so |

So the first run can do without three of the four, and the fourth decides whether landings are as light as
item 2 says.

## Measures

Against the two local trials (2.2 landings an hour with the heavy check; about 4 to 5 with light landing):
landings per hour; minutes from hand-off to merged on `origin` (median and worst); trains per hour and the
share that go red; minutes from a red train to its culprit reverted; breaks that reach `origin/main` (must be
0); CI runs started and whether GitHub queued any for lack of runners; load and memory pressure on the machine.

## Stop rules

Stop if a break reaches `origin/main`, if runs queue for more than 10 minutes, or if red trains exceed one in
three for an hour.

## Consequences

- More runs mean more chances to meet a flaky CI test (the Rust test `store::mint materializing_the_edge_ctes`
  failed once on PR 1507 with no Rust changed); one rerun of the failed job counts it as a flake.
- A red train blocks the commits behind it until it is bisected.
- Only REST calls to GitHub: a GraphQL budget ran out on 2026-11-15.
