---
type: grilling
status: closed
blocked_by: []
claimed_by:
---

# Release cadence: what a version number promises

## Question

1.0.0 shipped 2026-08-28 and 2.0.0 (breaking) on 2026-09-22; four releases landed on
2026-09-26 alone. At that pace a semver major tells an adopter little. Decide the stability
promise: a slower train, deprecation windows before breaking changes, a pre-release channel for
fast-moving work, or keep the pace and say so plainly. Who is the adopter this promise is for,
given that deploys pin a released tag today?

## Prep (not a decision)

Gathered by a read-only agent for the grilling session. Facts are cited; the options and
recommendation are input to the decision, not the decision.

**Facts**
- Timeline (tags and rubygems agree): 1.0.0 to 1.0.2 on 08-28; 1.1.0 and 1.2.0 on 09-09;
  1.3.0 on 09-12; 1.4.0 to 1.5.1 on 09-19/20; 2.0.0 on 09-24; 2.1.0 to 2.3.0 on 09-25;
  2.4.0, 2.5.0, 2.5.1 and 2.6.0 within 09-26/27 UTC. 386 commits between v1.0.0 and v2.6.0.
- Mismatches: `CHANGELOG.md` dates 2.0.0 as 09-22 but the tag and gem are 09-24; 2.5.0 is on
  rubygems and in the CHANGELOG but has no git tag; GitHub Releases shows only v0.3.0 and v1.0.0.
- 2.0.0's three breaks were bounded-context boot refusals (`CHANGELOG.md:482-508`). 2.4.0 carried
  a "Behavior change for deployed domains" in a minor (`CHANGELOG.md:264`).
- One working deprecation window already exists in history: loose-keyword `dispatch` was
  deprecated in 1.3.x/1.4.0 with a named removal version and a codemod, removed in 1.5.0
  (`CHANGELOG.md:586-637`).
- Cutting a release (`CONTRIBUTING.md:211-222`): a version-bump PR, a tag on the merge commit,
  then `bin/release_gem` behind Touch ID. No release workflow in `.github/workflows`.
- Consumers: every Gemfile found is one of the maintainer's own repos, pinned `~> 2.x` (one
  older `~> 1.4`, one `~> 0.3`). No outside consumer is visible: rubygems reverse dependencies
  are empty, and the repo has no stars or forks. A platform-side spec checks handed-off client
  Gemfiles for a `~> 2.x` pin.
- Existing stability text is only the 1.0 promise (`README.md:569-580`,
  `docs/1.0-readiness.md:13-15`): no deprecation windows, older-major support or cadence.

**Options**
- A. Slower train. A version number says more, but it slows client-boundary fixes and protects
  no outside adopter.
- B. Deprecation windows before every break. Proven once (1.4 to 1.5), but 2.0.0's breaks were
  boot refusals a warning cannot soften, and it costs a shim per break.
- C. Pre-release channel (`3.0.0.pre1`). Keeps `2.x` clean, but adds a second lane no one
  subscribes to yet.
- D. Keep the pace and document it as two tiers: a major means a breaking DSL/runtime change
  with a CHANGELOG "Breaking:" entry; a minor may carry a "Behavior change" entry; deploys pin
  exactly.

**Recommendation from prep.** D, with B kept for any break that reaches an installed client.
Pin exact versions in deploys and let `~>` float only in development. Revisit A or C when a
first outside adopter appears.

**For the maintainer**
1. Is the adopter for this promise your own client sites or a future public user?
2. Should handed-off client Gemfiles carry `~> 2.x` or an exact pin?
3. What is the bar for a major, given a behavior change shipped in a minor?
4. Fix the missing v2.5.0 tag, the stale GitHub Releases page and the 2.0.0 date as part of this?
5. Wrap `bin/release_gem` in CI, or is the Touch ID step deliberate?

## Answer

Decided 2026-09-27: keep the pace and document a two-tier promise. A major means a breaking
DSL or runtime change and carries a CHANGELOG `Breaking:` entry; a minor may carry a
`Behavior change` entry; deploys pin exactly; a break reaching an installed client site gets one
release of warning where a warning is possible. Cleanups: the missing `v2.5.0` tag, the `2.0.0`
CHANGELOG date, the stale GitHub Releases page. Recorded in
[ADR 0068](../../../decisions/0068-releases-keep-their-pace-and-state-a-two-tier-promise.md).
