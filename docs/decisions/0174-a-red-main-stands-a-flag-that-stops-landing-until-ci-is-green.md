# A red main stands a flag that stops landing until CI is green

**Status:** Accepted (owner requirement, 2026-11-02). Date: 2026-11-02.

## Context

"While main CI is red, only a push that fixes a red-* Work row goes out" was a sentence in the briefs and
in CLAUDE.md. Nothing enforced it, and no session heard that main had gone red.

## Decision

1. **`RedFlag` is a bluebook** (`lib/hecks/hecks/redflag/redflag.bluebook`, ports in `hecks.hecksagon`), the
   flag itself a marker file in the repository's common git directory (`hecks-red-flag.json`), so every
   worktree sees it and a spec's temporary repository never sees the owner's.
2. **Events:** `RedFlagRaised` (flag id, main commit, CI run, failed jobs, red rows), `RedFlagRunNoted` (a
   second red run while flagged is recorded on the flag, not a new one), `RedFlagCheckedIn` (session, what
   it takes) and `RedFlagCleared`. A CI observation that ends red or green raises or lowers it
   (`Integration.ObserveAnswered`), and `RedFlag.sync!` does the same from GitHub's newest run of main.
3. **Subscribing** is the ordinary journal: `exe/hecks Operation.follow domain.value=Hecks
   aggregate.value=RedFlag from_now=true wait=600`. `Coder::Brief` restraints tell every session to stop
   feature work on `RedFlagRaised`, check in with `exe/hecks RedFlag.check_in!`, and resume on
   `RedFlagCleared`.
4. **Stopping:** `GitLanding` refuses a landing on main, and `GitTrain` a boarding, with `main is red: flag
   <id>`, except a branch named for a `red-*` row (a `qa/` lead is ignored). That fix's landing records its
   tip on the flag, and the train boards only that tip. Lowering the flag releases both.
5. **Seeing:** `RedFlag.status` and the PipelineBoard strip's first row print the flag, the red time, the
   failed jobs and who is helping.

## Consequences

The flag is local to a repository checkout family; a clone elsewhere learns of it through `RedFlag.sync!`.
The red Work rows an event carries are those a caller supplies (`rows`); the CI bridge supplies none.
