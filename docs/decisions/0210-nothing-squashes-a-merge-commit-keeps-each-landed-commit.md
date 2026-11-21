# Nothing squashes: a merge commit keeps each landed commit

**Status:** Accepted. Date: 2026-11-14. Asked for by the owner: "I want to stop doing squash commits
everywhere, even GitHub." Stages one and two are built; what is left waits on the delivery package and is listed at the end.

## Context

Two things squashed. GitHub squashed the push train's pull request, so the commits of a train
(often a dozen) became one commit titled `Train: main at <sha> (#N)`. The ruleset `lane-main`
allowed only `squash`, and its merge queue merged with `SQUASH`. The four places that ask GitHub to
merge passed `--squash`.

The squash cost three things:

- **History.** A landed commit lost its sha, its message and its author's intent. A bisect or a
  revert of one change was a revert of the whole train.
- **A local repair.** After a train merged, local `main` held the original commits and `origin/main`
  held one squashed commit, so every pull had to rebase and drop what was "carried by squash" (`git_main_pull/boarding.rb`,
  `main_integration/carried_check.rb`, `adoption.rb`, `main_verification.rb`).
- **A false verdict.** Because the sha a gate judged was not the sha that reached `origin/main`,
  trains were verified by subject and by patch id, not by commit.

Landings on local `main` already moved the same way: delivery 0.1.7 makes every landing its own
merge commit with the judged tree (see [0208](0208-a-landings-course-is-its-lifecycle-and-a-train-is-a-convoy.md)).
A squash on GitHub erased those merge commits, so the two had to change together.

## Decision

1. **A merge commit replaces the squash, everywhere.** `gh pr merge` is called with `--merge`, and
   the merge queue's `merge_method` is `MERGE`. Every commit of a train keeps its sha, its message
   and its author, and one train is one merge commit on the first-parent line of `origin/main`.
2. **A rebase merge is not chosen.** It keeps the messages but gives each commit a new sha, so the
   "carried" detection by patch id would stay. A merge commit makes local `main` an ancestor of
   `origin/main` after a train merges, so that detection can go.
3. **The one-commit-per-PR convention goes.** Nothing in `.github`, the release and promote
   workflows, or the board reads the subject `Train: main at`; the only readers are the carried-by-squash
   checks this decision removes. The pull request's title is still `Train: main at <sha>`; GitHub
   writes it into the merge commit's body.
4. **The ruleset allows only `merge`, and is flipped on GitHub in an order that never refuses a
   merge.** The lane specs hold that a pull request may merge only the way the queue merges it, so
   the committed ruleset names one method. It lands first; it changes nothing on GitHub until it
   is applied. Then the processes that ask GitHub to merge are restarted so they pass `--merge`,
   and last the ruleset is applied live while no train pull request is open.

## Consequences

- `main`'s history is a first-parent line of merges, each with the commits of one train or one
  landing beneath it. `git log --first-parent` reads as a list of landings; `git bisect --first-parent`
  tests one landing at a time.
- The `ReviewRequest` port ask is `Merge` (answers `MergeAnswered`, refuses `MergeRefused`), asked
  by the policy `MergeWhenRequested`, and its adapter method is `GithubPullRequests#merge`.
- `CarriedCheck` reads a commit as carried only when it is an ancestor of `origin/main`. A run
  carried only by an old squash would now read as not carried and be verified again; on
  2026-11-19 none of the open `MainIntegration` runs was in that state, so no run changes its
  answer.
- A pull request whose branch is not up to date now merges into a merge commit that is not a
  fast-forward of the tip that was tested; the merge queue builds each entry on top of the
  lane and the entries ahead of it, so what merges is what was tested.

## Stages

1. **Built:** the ruleset generator (`lib/hecks/tools/lanes/ruleset.rb`) and `main.json` allow only
   `merge` and queue with `MERGE`; the four callers pass `--merge`; their specs say so. Then the
   ruleset is applied to GitHub, in the order of point 4. Applied: `lane-main` on GitHub allows
   only `merge` and queues with `MERGE`.
2. **Built, once trains had merged as merge commits and local `main` had pulled them cleanly:**
   `CarriedCheck` keeps only the ancestry test; the `Squash` ask is renamed `Merge`; the specs
   build a train on origin as a merge commit; `adoption.rb` stays, because a pull still rebases a
   held tip onto the merge of the train ahead of it.
3. **Built:** the vendored delivery package no longer reads a squashed train. `git_main_pull/boarding.rb`
   and `git_main_pull/carried.rb` are gone, `nowhere.rb` and `git_landing/carried.rb` keep only
   ancestry and patch ids, and the rebase of a pull or a landing is a plain `--rebase-merges` onto
   `origin/main`. It is removed, not put behind a port: `CarriedCheck` is ancestry-only and none of
   the open `MainIntegration` runs was carried only by a squash (checked 2026-11-19, see
   Consequences), so no standing history needs the reading. The specs of that path
   (`hecks_pull_main_squash_spec`, `hecks_git_landing_squash_carried_spec`, the squash example of
   `hecks_pull_main_spec`) are gone with it. Delivery requires nothing of the train.
