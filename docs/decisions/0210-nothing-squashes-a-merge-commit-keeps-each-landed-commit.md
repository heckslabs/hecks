# Nothing squashes: a merge commit keeps each landed commit

**Status:** Accepted. Date: 2026-11-14. Asked for by the owner: "I want to stop doing squash commits
everywhere, even GitHub." Stage one is built; the later stages are listed at the end.

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
- The declared names `ReviewRequest.Squash` and the `Squash` port ask keep their names in stage
  one: they now ask GitHub for a merge commit. Renaming them (the hecksagon, deliver.bluebook, the
  CLI goldens and the specs) is stage three, with the removal of the carried-by-squash code.
- A pull request whose branch is not up to date now merges into a merge commit that is not a
  fast-forward of the tip that was tested; the merge queue builds each entry on top of the
  lane and the entries ahead of it, so what merges is what was tested.

## Stages

1. **Built:** the ruleset generator (`lib/hecks/tools/lanes/ruleset.rb`) and `main.json` allow only
   `merge` and queue with `MERGE`; the four callers pass `--merge`; their specs say so. Then the
   ruleset is applied to GitHub, in the order of point 4.
2. **After one train has merged as a merge commit and local `main` has pulled it cleanly:** remove
   the carried-by-squash code (`git_main_pull/boarding.rb`, `carried_check.rb`, `adoption.rb`,
   `main_verification.rb`, `deliver.bluebook` `ask :squash`) and its specs, and
   rename `ReviewRequest.Squash` to a merge. The vendored `git_main_pull/carried.rb` belongs to the
   delivery package, so that part goes upstream in Switchyard and is re-vendored.
