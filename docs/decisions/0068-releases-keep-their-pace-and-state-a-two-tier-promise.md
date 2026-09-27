# Releases keep their pace, and the stability promise is stated as two tiers

**Status:** Accepted — not yet implemented. The promise text, the missing tag, the CHANGELOG date and the GitHub Releases page described under "Decision" have not been done. Date: 2026-09-27.

## Context

`1.0.0` shipped on 2026-08-28 and `2.0.0` on 2026-09-24 (the tag and the gem agree; `CHANGELOG.md:482` says 2026-09-22, which is wrong). Between them came `1.0.1` through `1.5.1`. Four releases (`2.4.0`, `2.5.0`, `2.5.1`, `2.6.0`) landed on 2026-09-26 and 2026-09-27. At that pace a major version alone tells a reader little about what a bump will do to them.

The only stability text today is the 1.0 promise: the DSL and runtime API in the DSL reference "won't change in a breaking way without a major-version bump" (`README.md:569-580`, `docs/1.0-readiness.md:13-15`). It says nothing about deprecation windows, support for older majors, cadence, or what a minor may change. The two majors so far were both breaking, but a minor has also carried a change to running systems: `2.4.0` records a "Behavior change for deployed domains" (`CHANGELOG.md:264`), and several later entries carry "Behavior change for hosts".

Two precedents exist. Loose-keyword `dispatch` was deprecated in `1.3.x`, given a named removal version and a codemod (`bin/codemod_legacy_dispatch_args`), and removed in `1.5.0` (`CHANGELOG.md:586-637`). `2.0.0`'s three breaks were different: attaching a bounded context without its sibling hecksagon, or marking a chapter `bounded` without a `translates` ACL, now refuses to boot (`CHANGELOG.md:484-503`). A warning cannot soften a boot refusal.

The consumers are the maintainer's own client sites and deployed domains. Their Gemfiles are pinned `~> 2.x` (one older site is on an earlier line), and no outside consumer is visible. A release is cut by a version-bump PR, a tag on the merge commit, then `bin/release_gem` behind a Touch ID prompt (`CONTRIBUTING.md:211-222`); no release workflow exists. Three records disagree: `2.5.0` is on rubygems and in the CHANGELOG but has no git tag, and the GitHub Releases page shows only `v0.3.0` and `v1.0.0`.

## Decision

Keep the release pace and state the promise in two tiers, in one place: `docs/1.0-readiness.md`, which the README's "Project status" section already points to. That file gets the text; this ADR does not edit it.

1. **A major version means a breaking DSL or runtime change, and always carries a CHANGELOG `Breaking:` entry.**
2. **A minor version may carry a `Behavior change` entry**, as `2.4.0` did for deployed domains.
3. **Deploys pin exactly.** `~>` floats only in development.
4. **A break that reaches an installed client site gets one release of warning where a warning is possible.** The `1.4` to `1.5` removal is the model: a named removal version, a warning, and a codemod.
5. **The warning is not required where the break is a boot refusal a warning cannot soften**, as with `2.0.0`. The CHANGELOG entry still says exactly what now refuses and what to change.
6. **A slower train or a pre-release channel is revisited when a first outside adopter appears.**

Cleanups decided with it:

- Create the missing `v2.5.0` git tag on the release's merge commit.
- Correct the `2.0.0` CHANGELOG date to 2026-09-24.
- Refresh the GitHub Releases page so it lists the tags that exist.

## Consequences

- An adopter can read one page and know what each kind of bump may do, and can see that a minor is not a promise of no behavior change.
- The pace of client-boundary fixes is not slowed by a release calendar.
- A major signals a breaking DSL or runtime change. Readers must read `Behavior change` entries on a minor to know what a running system will do.
- Exact pins mean a deployed site moves only when someone bumps it. The cost is that a site does not pick up a fix without a deliberate change.
- The warning-window rule costs a shim and a codemod for each break it applies to, and only for breaks a warning can soften.

## Alternatives considered

- **A slower train.** A version number would say more, but it delays fixes the client sites need and protects no outside adopter, since none is visible.
- **Deprecation windows for every break.** Proven once (`1.4` to `1.5`), but `2.0.0`'s breaks are boot refusals a warning cannot soften, and each window costs a shim.
- **A pre-release channel (`3.0.0.pre1`).** Keeps `2.x` clean, but adds a second lane no one subscribes to yet. Kept for when one does.

## Open items

- Do handed-off client Gemfiles carry `~> 2.x` or an exact pin? The decision says deploys pin exactly; what the handoff writes into a client's Gemfile is not settled.
- What is the bar for a major, now that a behavior change has shipped in a minor? Where the line falls between a `Behavior change` in a minor and a `Breaking:` in a major, and whether a boot refusal such as `2.0.0`'s always needs a major, is unanswered.
- Should `bin/release_gem` be wrapped in CI, or is the Touch ID step deliberate? Until answered, releases stay manual.
