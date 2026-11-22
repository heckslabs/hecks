# The train keeps its one-pull-request rule after the merge queue; removal waits on a measurement

**Status:** Accepted. Date: 2026-11-22. A finding, no code change. The architect reviewed the plan (sound).

## Question

`main` now moves only through the GitHub merge queue (ruleset `lane-main`, `ci.yml` on `merge_group`). Does
the push train still need its rule of one train pull request open at a time?

## What the queue already guarantees

From `.github/rulesets/main.json` (built by `Hecks::Tools::Lanes::Ruleset::MERGE_QUEUE`):

- **Only a pull request moves `main`.** The `pull_request` rule allows the `merge` method and needs no review;
  `deletion` and `non_fast_forward` are refused and `bypass_actors` is empty.
- **Required checks.** Ten, each reported by the GitHub Actions app (`integration_id` 15368): `rspec`, `checks`,
  `rspec_postgres_io`, `rspec_postgres_io_parallel`, `rspec_rust_io`, `rspec_rust_parser`, `rspec_rust_codegen`,
  `rspec_rust_host`, `rspec_fuzzing`, `release_consistency`. `strict_required_status_checks_policy` is false: the
  queue, not that policy, is what tests a pull request on top of the others.
- **Batching.** `grouping_strategy` ALLGREEN, up to 5 entries built and 5 merged at once,
  `min_entries_to_merge` 1 after a 1-minute wait, merge method MERGE.
- **Timeout.** `check_response_timeout_minutes` 60: an entry whose checks do not answer in an hour leaves the queue.
- **Order.** Entries are tested on `main` plus every entry ahead of them. That first-in-first-out order is GitHub's
  queue behaviour; no ruleset field states it.

## What the train adds

- **A pull request per tip.** `lane-main` refuses a push, so each boarded tip of local `main` needs a pull
  request, `train/main-<sha>`. A pull request is the snapshot the queue tests; the queue cannot make one.
- **Attestation.** `.github/actions/check-attestation` keys the pre-push hook's signed note by tree hash, so a
  `merge_group` run whose tree equals an attested one skips the work. The queue knows nothing of it.
- **The order rule.** `MainIntegration` walks a landed commit through `verifying`, `verified`, `boarding`,
  `pushed`, `ci_running`, `merged`, `green` (or `red`). `MainBoarding` refuses a boarding while another run is
  pushed or watched; `NewestFirst` boards the newest verified tip first, and its train carries every older tip,
  which answers `superseded`. The refusal is the whole of the rule: it makes the line wait, it orders nothing the
  queue would not.

The train already batches. A train pull request is main's whole range above `origin/main`, so the commits that land
while one is in flight ride the next. Another batching mechanism would duplicate that.

## Measurement

Sample: the 20 most recent merged `train/main-*` pull requests on 2026-11-22, #2046 to #2098 (created 05:04Z to
14:14Z, merged by 14:20Z), read with `gh pr list`. It is not the tap: `Operation.follow` returned no events from
this checkout, so `BoardingRequested` to pull request created and `TrainMergeSeen` are **not measured**, and the
sample spans about 9 hours, not 24.

- Created to merged: median 12.2 min, mean 14.2, range 5.2 to 35.0.
- Merged to the next one created: median about 13 min, range 6.4 to 38.2.
- One overlap in 20: #2052 was created 4.2 min before #2051 merged, so two train pull requests were open at once
  at least once.

Read plainly: a tip that lands during a train waits for that train's roughly 12 minutes, and in this sample the line
sat idle between trains about as long as a train ran. What a tip waited behind another pull request is not shown.

## Recommendation

**Keep the rule for now; do not add batching; remove the rule only after the tap measures the wait.**

- Removal is the better direction (it is a refusal, and the queue plus `NewestFirst` already collapse stale tips),
  but it would let a second train enter the queue and spend a full ten-check run on a tip the first one carries.
  The evidence that this costs less than the wait it saves is the missing tap data.
- The one overlap shows the rule is not airtight, which the measurement below should explain before it is relied on.
- Next step, a Work item: report the minutes from `MainBoardingRequested` to the pull request created, per tip, over
  24 hours. If the median wait stays under one train run, the rule costs little and stays; if tips wait more than
  one run, replace the refusal with queue ordering.
