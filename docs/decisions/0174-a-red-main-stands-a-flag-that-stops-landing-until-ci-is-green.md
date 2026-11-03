# A red main stands a flag that stops landing until CI is green

**Status:** Accepted (owner requirement, 2026-11-02). Date: 2026-11-02.

## Context

"While main CI is red, only a push that fixes a red-* Work row goes out" was a sentence in the briefs and
in CLAUDE.md. Nothing enforced it, and no session heard that main had gone red. On 2026-11-02 main stood
red from 20:31Z to 23:12Z across eleven pushes, each landing on top of the last failure, while every
session fixed forward on a red main.

## Decision

1. **`RedFlag` is a bluebook** (`lib/hecks/hecks/redflag/redflag.bluebook`, ports in `hecks.hecksagon`), the
   flag itself a marker file in the repository's common git directory (`hecks-red-flag.json`), so every
   worktree sees it and a spec's temporary repository never sees the owner's.
2. **Events:** `RedFlagRaised` (flag id, main commit, CI run, failed jobs, red rows), `RedFlagRunNoted` (a
   second red run while flagged is recorded on the flag, not a new one), `RedFlagCheckedIn` (session, what
   it takes), `RedFlagKicked` (the commits reverted and the Work row filed) and `RedFlagCleared`. A CI
   observation that ends red or green raises or lowers it (`Integration.ObserveAnswered`), and
   `RedFlag.sync!` does the same from GitHub's newest run of main. A run is recorded on the flag once: the
   same CI result reported twice, by the saga and by the board, or by two boards, answers `RedFlagUnchanged`.
3. **Every session hears the events through the event tap**, not a database and not a file it reads by
   hand: the Hecks world's `event_log` names `payloads: %w[RedFlag]`, so the tap carries the red flag's
   payloads, and `Operation.follow` reads the tap whenever a world declares one. The tap is the route
   because it survives Memory: the Hecks domain persists no journal, the push train runs in Memory in
   another checkout, and the journal store (`agent_run.db`) holds only the aggregates the owner's
   uncommitted local hecksagon binds, which the flag is not. The one line is
   `exe/hecks Operation.follow domain.value=lib/hecks/hecks aggregate.value=RedFlag from_now=true wait=60`;
   it returns the events since its cursor or an empty list after 60 seconds, and the next call takes the
   answered cursor as `since.value`. `Coder::Brief` restraints tell every session to stop feature work on
   `RedFlagRaised`, check in with `exe/hecks RedFlag.check_in!`, and resume on `RedFlagCleared`.
4. **Stopping:** `GitLanding` refuses a landing on main, and `GitTrain` a boarding, with `main is red: flag
   <id>`, except a branch named for a `red-*` row (a `qa/` lead is ignored). That fix's landing records its
   tip on the flag, and the train boards only that tip. Lowering the flag releases both. The train's own
   copy (`~/.claude/hecks-train`) is brought to `origin/main` before each boarding the integration saga
   makes (`MainIntegration::Train#refresh`), so it carries the guard.
5. **Seeing:** `RedFlag.status` and the PipelineBoard strip's first row print the flag, the red time, the
   failed jobs and who is helping.
6. **The PipelineBoard server drives the flag from real CI.** CI completes on GitHub, which emits nothing
   this machine hears, so the one long-running process the owner already runs reads it: while the board
   serves, `PipelineBoard::FlagWatch` reads main's newest CI run every `board_sync_seconds` (the world's
   `red_flag` setting; 0 is off) and, once per newly completed run, asks `RedFlag.sync!` through the
   launcher at top level. No HTTP route reaches it. Two boards, or the board and the saga's observe step,
   are harmless together because a run is recorded once.
7. **The owner is told on the desktop** through the `Alerts` port already used for a push: a
   `RedFlag.Flag` ask on the flag's answer, beside the recording, so the chain stays within the reaction
   depth bound. An alert that cannot be shown is recorded as refused and changes nothing.
8. **A flag that stands too long kicks the batch off main.** `RedFlag.kick!` (after the world's
   `kick_after_minutes`, or at once with `force.value=true`) reverts every first-parent commit since the
   last green head of main, newest first, on a branch `red-kick-<flag>`, lands it on local main as a red
   row's fix, files a Work row `reland-<flag>` naming the commits for their owner to land again once fixed,
   and records the kick on the flag; the train boards the landed tip and the green run that follows lowers
   the flag. The unit is the push batch, because CI runs once per push and a push carries several landings;
   a bisect inside the batch costs a CI run per step. A revert beats fixing forward here because the red
   afternoon of 2026-11-02 stacked eleven failures: each fix-forward landed on an unverified main and the
   flag would have stood for hours either way, while a revert makes main green in one CI run and gives the
   fixer a green base. Nothing is force-pushed: the revert is a new commit.

## Consequences

The flag is local to a repository checkout family; a clone elsewhere learns of it through `RedFlag.sync!`.
The red Work rows an event carries are those a caller supplies (`rows`); the CI bridge supplies none.
Specs never write the owner's tap or the checkout's flag (`spec/support/live_state_guard.rb`): the Memory
overlay declares no tap, a spec that wants one points a tap at its own file, and every spec builds its
own repository.
