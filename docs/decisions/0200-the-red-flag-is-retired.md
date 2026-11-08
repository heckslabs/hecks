# The red flag is retired

**Status:** Accepted, shipped. Date: 2026-11-07. Supersedes ADR 0174. Owner decision (2026-11-03):
"okay remove the red flag all together".

## Context

ADR 0174 made a red `main` stand a flag that stopped landing and boarding until CI was green
again. Since ADR 0187 `main` moves only by a pull request that GitHub merges after the required
checks pass, so `main` does not go red: a red change stays on its pull request.

## Decision

1. **The mechanism is removed.** The `RedFlag` domain, its marker file `hecks-red-flag.json`, the
   guards in `Landing` and `SendTrain`, the `Flagging` port and its adapter, the board's flag row
   and check-in action, and the Passage `Hold` step are gone. Nothing reads or writes the marker;
   a stale file in a git directory is ignored.
2. **The rule is written once**, in the Coder brief's restraints: main never goes red; agents work
   on branches and pull requests; a pull request is approved automatically when its CI is green;
   main moves only by an approved pull request; a red pull request stays on its branch and the
   session the owner names fixes it.
3. **A pushed passage is verified by a green run.** `Integration.CiPassed` replaces
   `RedFlagCleared` as the event that verifies pushed passages.

## Consequences

Work items, lessons and pull request approval stay; they carry the rule. Landing refuses only a
base behind `origin/main`.
