# A role exists where it limits what an agent can touch or gives a read not anchored on the author's work

**Status:** Accepted. Date: 2026-11-20. First item of the epic `roles-only-where-they-earn-it`. The plan was
reviewed by the architect (plan review run `297cf1ec`, verdict sound). Builds on
[0218](0218-the-product-owner-owns-what-the-planner-owns-how-and-features-land-dark.md) and
[0221](0221-releases-are-cut-by-policy-after-a-soak-and-the-changes-choose-the-version.md).

## Context

The pipeline has a role file for each of the coder, planner, architect, reviewer, pruner and
orchestrator. Two questions stayed open: do the planner and the architect become one role, and does the
release manager become a gate check.

The test for any role is that it exists only where it limits what an agent can touch, or gives a read
that is not anchored on the author's work. A role that does neither is a step with a name, and a step
belongs in a policy or a check.

## Evidence

Read from the AgentRun and PlanReview ledgers (`exe/hecks agents PlanReview.reviews`,
`Fleet.verdict_mix`, `Planning.requests`) on 2026-11-20:

- **Architect.** 460 plan reviews of 724 work items. `Fleet.verdict_mix` holds 535 changes, 375 sound,
  60 rethink and 60 without a verdict. Of the 681 first reviews that were answered, 423 (62%) sent the
  plan back with changes, 46 said rethink and 213 said sound. The read changes what gets built most of
  the time, and it is made by a role that did not write the plan.
- **Planner.** 23 planning requests on record, each an epic cut or a goal. Under 0218 decisions 5 to 8
  the planner writes the whole cut as one draft and the architect reviews that cut once (decision 7).
- **Release manager.** Retired on 2026-11-19 (commit `de8dec06a`, merged in `7a687f093`): no
  `PromotionRecommendation`, no role, no session started for it. `promote.yml` moves `stable` once the
  required checks have passed, and 0221 releases by policy. No live reference to `release_manager`
  remains; two specs (`spec/pipeline_board_agents_page_owner_spec.rb`,
  `spec/pipeline_board_wiring_spec.rb`) assert its absence.

## Decision

1. **The planner and the architect stay two roles.** A merged role would review the cut it wrote, which
   is the anchoring the architect exists to remove: its independent read is what the ledger shows
   changing 62% of first plans. The planner earns its place by a limit: its tools are read tools and
   Bash, with no Edit or Write, so it drafts work and never edits files; its subagents only read. The
   architect earns its place by the independent read, with no edits and a restricted hecks door.
2. **The release manager is a gate check, and already is.** Promotion is the required checks of
   `promote.yml`; a release is cut by policy (0221). There is no role left to retire and no merge to do.
3. **A role file names its limit.** Each role file states in one line what the role cannot touch or what
   its read is independent of. A role that cannot name either is a candidate to become a policy or a
   check, and goes through this test.

## Open items

The follow-on work items are cut from this record, not created by it.

1. **Role files name their limit.** The `RoleFile` rows of the Role aggregate in
   `lib/hecks/agents/agents.bluebook` each gain the limit line; `.claude/agents/*.md` are generated from
   those rows, so edit the rows and run `exe/hecks agents project_agent_roles!`, never the files.
2. **Read the 60 plan reviews that ended without a verdict** (about 8% of the 724 work items) and find
   why: a question for a lookup, with no conclusion drawn here.
3. **No merge item and no retire item.** Decision 1 is a no, and decision 2 is already done.
