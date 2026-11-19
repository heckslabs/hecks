# Lanes, the push train and releases

Read this before you board the train, change a lane or a required check, or work on promotion
or a release. `CLAUDE.md` holds the rules every session needs; this holds the detail. Nothing
here widens them: an agent never pushes `main` but by the train, never sets `HECKS_OWNER_PUSH`,
never uses `--no-verify`, and never writes a `Release-Approved-By` line on its own.

## Two lanes: `main` takes pushes, `stable` is promoted

The branches are data: the `Lane` rows of the Vocabulary bluebook
(`lib/hecks/language/bluebook/vocabulary.bluebook`), with the checks a
commit must pass as `RequiredCheck` rows beside them.

- **Work reaches `main` through a pull request.** Agents land work with
  `hecks landing.land! --confirm` (fast-forward or merge commit, never squashed) and then
  `hecks send_train.board! --confirm`, which opens the PR (branch `train/main-<sha>`, auto-merge on)
  for GitHub to merge once its required checks pass. Do not open a PR for `main` by hand, and do not
  push `main` directly. A push of a feature branch runs the gate's `quick` stage: shape ledger,
  RuboCop (which also reads every changed Ruby file for syntax errors), comment style, secret output,
  adapter words, command names, workflow pagination.
  Feature branches are different: the train only lands `main`. To queue an open feature PR,
  mark it ready and run `gh pr merge <number> --auto` once its checks are green; GitHub's merge
  queue then merges it. Check `gh pr view <number> --json mergeStateStatus` first: CLEAN means
  ready, and BLOCKED with pending checks means wait.
  `hecks gate_run.gate! stage=quick --wait` runs it by hand and is worth running before every
  commit. Everything slower (fuzzing, the engine and model checks, command names, workflow
  pagination, the spec suite, the push-chain specs) runs after the push, in CI and the nightly run,
  and blocks promotion to `stable`, never the push; a red one files a Work item. `hecks send_train.board!
  --confirm full_gate.value=true` runs the whole `pre_push` stage when you ask for it. Never
  force-push `main`, and never use `--admin`.
  **The push is isolated.** `send_train.board!` pushes the boarded commit, by its id, from a throwaway detached
  worktree at that commit, so the pre-push hook and the quick gate check exactly what goes out and landings onto
  local `main` meanwhile are never held and never touch the push; commits that land during it stay local and are
  named in the report. Pushes serialize on the train's one lock; a remote that moved is fetched and retried, and a
  commit not built on it is refused by name ("board again"). **A plain `git push` of `main` is refused by the pre-push hook:** the train's own
  push carries `-c hecks.trainCarry=<commit>`, which the hook reads, so any agent pushes `main` by boarding the train. The owner's
  one-off override is `HECKS_OWNER_PUSH=<reason>` (ADR 0132): the hook prints the reason, an empty value does not count, and
  agents never set it or use `--no-verify`. Branch and tag pushes are untouched.
  Push small: a rehearsed push per landed slice, or at least per day, is the norm. A rehearsal
  (`push_rehearsal.rehearse!`; `scope.value=quick` for a landing's) runs the quick stage against local
  `main` and pushes nothing; a deep one (`scope.value=deep`, opt-in) adds the specs the push's changed
  files touch (`impacted_spec_limit`, two at a time, `impacted_spec_width`; a file that fails is run again
  alone and one that then passes is reported as flaky under parallel load, not failed; a spec already
  red on `origin/main` is reported, not failed). Its result is the `PushRehearsal` record, and
  `hecks push_rehearsal.due` says how far `main` is ahead of `origin/main`, how old the oldest
  unpushed commit is and how the last quick rehearsal ended. Nothing pushes by itself.
  The size that counts as too big is the QualityControl world's `push_nudge` setting (`commits`, `hours`,
  `urgent_commits`): past it the line and the train's report say `PUSH NOW`, and neither ever refuses a push.
- **Red `main` is read on GitHub.** The `CI` run's status and failure email are the signal; no local
  watch repeats it. The dispatch fill plans `red-*` rows (filed by people and CI jobs) first and starts
  one before other planned work. A red `main` blocks promotion to `stable`, never a push.
- **`stable` is only ever promoted.** CI runs the full job set on every push
  to `main`; when every `RequiredCheck` passed on a commit, `promote.yml`
  fast-forwards `stable` onto it through
  `exe/hecks promotion_run.promote! lane=stable --confirm --wait`, onto the newest
  commit of `main` that every required check passed on (named `commit=<sha>` it
  judges exactly that commit and no other). Never push
  to `stable` yourself: its ruleset takes only a commit every required check
  already passed, and refuses deleting or rewinding it. Rehearse a move
  without `--confirm`: it names the
  move and makes none, and it says which check is red or still running.
- **What `stable` guarantees.** `main` is integrated state, `stable` is certified
  state, and a commit is certified by the check runs of that exact sha, never by
  "`main` was green about then". Every commit reachable from `stable` was moved
  there by a fast-forward of a commit that every `RequiredCheck` had passed on
  (the ruleset refuses anything else, and refuses rewinding or deleting it). A
  promotion is not tied to the push that started it, so a dropped, late, or
  out-of-order run changes nothing, and a certified commit is never stranded
  behind a red or still-running one. `edge` is brought up to `stable`'s head on
  every confirmed run, even one that finds `stable` already there, and its own
  ruleset (`.github/rulesets/tag-edge.json`) refuses deleting it or pointing it
  at an older commit; moving it forward is allowed.
- **A late `stable` files a finding.** `lane-watch.yml` runs every hour and asks
  `exe/hecks promotion_run.watch! lane=stable`; when `stable` has stood behind
  `main` for longer than its `Lane` row's `alert_after` hours (4), the run fails
  and files one GitHub issue a day, saying which required check is red or still
  running. Fix `main` forward or revert on it; the issue is yours to close. A failed
  watch also dispatches `promote.yml`, so a dropped promotion is retried within the
  hour (`gh workflow run promote.yml` does the same by hand).
- **Releases, `edge` and deploys come from `stable`, never `main`.** Commit
  the version bump (`lib/hecks/version.rb`, `CHANGELOG.md`, the README
  lines, `packages/hecks-client`) to `main`, wait for `stable` to contain
  it, then publish from a clean `stable`. `release.yml` enforces it: it runs
  after Promote, releases the commit on `stable` that set the version, and
  refuses any commit `stable` does not contain, a by-hand run included.
- **A release is the owner's decision.** A bump that lands on `main` ships
  only if the commit that set the version has a `Release-Approved-By: <name>`
  line in its message (the `release_trailer` of the `stable` `Lane` row;
  `lib/hecks/release/approval.rb` decides). Without it `release.yml` releases
  nothing after a promotion, and refuses a by-hand run before it tags or
  pushes; `publishing_run.publish!` refuses it too. Write the line only when
  the user has said to release; never add it on your own, and never bump the
  version for a fix that can ride `edge` (the tag at `stable`'s head, which a
  client can pin as "latest certified"). An existing tag counts as approved,
  so `gh workflow run release.yml -f tag=vX.Y.Z` still finishes a half-cut
  release; the owner may approve a bump already on `stable` with `-f
  approved_by=<name>`. Name the pending release while changes accumulate
  by writing `## [Unreleased] - planned X.Y.Z` on the CHANGELOG heading
  (`spec/changelog_planned_release_spec.rb` pins the shape); naming it does not
  approve it.
- **A red `main` blocks promotion, not pushes.** Fix forward or revert on
  `main`; `stable` does not move until a commit is green. Do not
  cherry-pick onto `stable` unless the user says production is down.
- **Change a lane or a required check by editing its row**, then run
  `exe/hecks regeneration_run.project_lanes! --wait` to rewrite
  `.github/rulesets/` and `.github/workflows/promote.yml`. Applying the
  rulesets to GitHub is a separate, confirmed step
  (`regeneration_run.project_lanes! --live --confirm`); never hand-edit the
  generated files.
