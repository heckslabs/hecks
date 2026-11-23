# Releases are cut by policy after a soak, and the changes choose the version

**Status:** Accepted. Date: 2026-11-18. Settled with the owner in the release grilling of 2026-11-18,
as the owner asked on 2026-11-07. The plan was reviewed by the architect (plan review run
`ccdefb25`, verdict sound), and its notes are taken in. The rule it retires is carried today by
`lib/hecks/release/approval.rb`, `.github/workflows/release.yml` and
`lib/hecks/hecks/release/release.bluebook`; those change as their own work (Open items).

## Context

A release today waits for the owner. A version bump ships only when the commit that set the
version carries a `Release-Approved-By: <name>` line, the `release_trailer` of the `stable` `Lane`
row. `approval.rb` decides, `release.yml` releases nothing after a promotion without it, and
`PublishingRun.Publish` refuses it too. `CLAUDE.md` ("Releases are the owner's") and
`docs/agents/lanes-and-releases.md` ("A release is the owner's decision") tell every session so.

The result is that certified changes pile up on `stable` with no version. A client pinning a gem
version does not get them, and nobody can say when they will. The owner asked on 2026-11-07 to
"drop the approval rule, release automatically too. I should see next version too".

Promotion already moved to policy. The `pipeline-no-owner-promotion` branch (merged in
`7a687f093`, 2026-11-19) retired the `release_manager` role and its `PromotionRecommendation`:
`promote.yml` moves `stable` once every required check has passed, and no one recommends it.
Releasing is the remaining step that waits on a person.

Feature flags make an automatic release safe. Under
[0218](0218-the-product-owner-owns-what-the-planner-owns-how-and-features-land-dark.md)
(decisions 10 to 14) a new behavior lands dark, behind a committed Feature row that is off. A
release that carries dark features exposes nothing new to a client. Turning a flag on is a change
like any other, reviewed, landed and pushed, and that change is what exposes the feature.

## Decision

1. **No one approves a release.** There is no `release_manager` role and no owner approval. The
   `Release-Approved-By` trailer rule is retired, with every place that enforces or repeats it.
2. **A policy cuts the next version after a soak.** When `stable` holds changes no release
   contains, and the oldest of them has been on `stable` for `soak_days`, a policy cuts the next
   version. Cutting means what a by-hand release means today: bump `lib/hecks/version.rb`, the
   `CHANGELOG.md` heading, the README lines and `packages/hecks-client`; tag; and publish through
   `release.yml` from `stable`. Releases still come only from `stable`.
3. **The changes choose the version.** Each unreleased change has a level, and the release takes
   the highest:
   - **major:** a shape change that needs a translation edge (a move the shape ledger does not
     pass as additive), and, once the public surface is declared, a removed public command or a
     removed argument of one;
   - **minor:** a new command, a new Feature row (flag), or a new bluebook concept (aggregate,
     value object, event, policy);
   - **patch:** anything else.
4. **A major soaks longer.** A release whose level is major waits `major_soak_days`, its own
   setting, not `soak_days`.
5. **The board shows the next release.** It shows the next version, the change that set its
   level, and the date it will be cut.
6. **A flag is the switch, a release is not.** A release can carry dark features because they
   expose nothing. Turning a flag on is the exposing change, and it rides the next release like any
   other change. Its level is patch, because the flag's row was already minor when it was added.
7. **The time and the settings live where the rules say.**
   - `soak_days` and `major_soak_days` are attributes of the `stable` `Lane` row in
     `lib/hecks/language/bluebook/vocabulary.bluebook`. They take the place of its
     `release_trailer` and sit next to `alert_after`. They are the owner's values, set as data.
   - The age of the oldest unreleased change reaches the policy as a fact from the clock adapter,
     behind its port. The bluebook only compares that age with the setting. It never reads the
     time itself.
8. **This supersedes the release rules that came before.** It replaces the section
   "Releases are the owner's" in `CLAUDE.md`, the "A release is the owner's decision" rule in
   `docs/agents/lanes-and-releases.md`, and the `release-is-the-owners` standing rule. It narrows
   [0165](0165-a-bad-release-is-fixed-forward-or-reverted-by-a-named-rule.md), whose choice is
   "the owner's, by the same rule that approves a release". That choice stays the owner's, but no
   rule approves a release any more. It also narrows
   [0216](0216-a-role-gated-command-refuses-a-caller-who-states-no-role.md)'s mention of the
   trailer. Neither record is edited. This record is where their narrowing is written.

**In the meantime** the trailer rule still governs in code. Until the Open items land,
`approval.rb`, `release.yml` and `PublishingRun.Publish` still refuse a bump without the trailer.
Sessions still follow `CLAUDE.md`: no session bumps a version or cuts a release on its own.

## Set aside

- **The product owner decides releases.** The product owner of 0218 decides what is built, not
  when it ships. A release decided by a session is still a release waiting on a judgment. The soak
  and the levels are the judgment, written once as data.
- **A release button for the owner.** A button keeps the owner in the path, which is the wait this
  record removes. The owner steers by setting `soak_days` and `major_soak_days`, and by switching
  flags.
- **Always-minor versions.** One level for every release would be simpler, but the version would
  then say nothing. A client cannot tell from it that an upgrade needs a translation edge. The
  levels come from facts the pipeline already records: the shape ledger, the commands and the
  Feature rows.

## Consequences

- A certified change reaches a version within `soak_days` (or `major_soak_days`), with no one's
  approval in the way.
- A client reads what an upgrade costs from the version. Major means a shape change, and minor
  means something new to call or to switch on.
- A bad release is found after a soak on `stable`, not after an approval. Its remedy is still 0165's.
- The levels are only as good as their sources. A shape change that the ledger misses is released
  as minor or patch. Until the public surface is declared, removing a public command is not seen
  as major.

## Open items

Each item is its own work item. The trailer rule stays in force until all of them land, so cut
them from every site `grep -rn Release-Approved-By` and `grep -rn release_trailer` finds. Today
those sites are:

- **The rule in code.** `lib/hecks/release/approval.rb` and `.github/workflows/release.yml`
  (its trailer check and the `approved_by` input). Also `lib/hecks/hecks/release/release.bluebook`
  (the trailer given at line 229 and the refusal at line 336), and
  `lib/hecks/hecks/adapters/main_integration/range_guard.rb` (line 16).
- **The `Lane` row.** In `lib/hecks/language/bluebook/vocabulary.bluebook`, line 1148 holds
  `release_trailer` and becomes `soak_days` and `major_soak_days`. `lib/hecks/vocabulary.rb`
  (generated) and `lib/hecks/tools/lanes/rows.rb` (the trailer-key check) follow it.
- **QualityControl.** `lib/hecks/quality_control/quality_control.bluebook` (line 2348), the trailer
  value an approval writes.
- **The agents' rules.** In `lib/hecks/agents/agents.bluebook`, the `release-is-the-owners`
  standing rule and its evidence (lines 130, 197 and 213), and the role rules at lines 289 and 299.
  `Incident.Restore`'s refusal of a batch that holds a release commit is part of this item.
  `lib/hecks/coder/coder.bluebook` (line 502) holds the coder's restraint, and
  `.claude/agents/orchestrator.md` and `.claude/agents/orchestrator-owner.md` hold the standing
  rule's text.
- **The docs.** `CLAUDE.md`, `docs/agents/lanes-and-releases.md` and `docs/compatibility.md` (line
  88).
- **The board.** `lib/hecks/pipeline_board/adapters/pipeline_web/page.html` (the Release note) and
  `agents.html` (the `Release-Approved-By` edge). The next-release tile of decision 5 is new.
- **The policy itself.** The cut policy and the next-version reading in
  `lib/hecks/hecks/release/release.bluebook`. They are fed by the shape ledger, the command list,
  the Feature rows and the clock port.
- **The public surface.** Declaring the public surface is a separate decision. It turns on the
  "removed public command or argument" half of the major rule.

## Landed

The trailer rule is retired and the policy stands (work item `release-cuts-itself-after-a-soak`).
`NextRelease` (`lib/hecks/hecks/next_release/next_release.bluebook`) is the cut policy; its
`Surveying` port reads the facts, the `Cutting` port writes the bump, and `soak_days` and
`major_soak_days` replace `release_trailer` on the `stable` `Lane` row. The level facts are a
translation edge in the changes (major) and an added aggregate, command, value object, event or
policy (minor); a Feature row is not yet read. The board's next-release tile and the public
surface half of the major rule remain open items.
