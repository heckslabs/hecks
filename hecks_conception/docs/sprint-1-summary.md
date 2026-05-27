# Sprint 1 - Foundations: deploy, universal door, cascade (summary)

## Delivered
- Consolidated to ONE active sprint; reconciled phantom-sprint membership.
- Built Plan::Sprint.Execute (sprint-level fan-out) + closed runtime gaps: FQN step-phrase resolution, query-step dispatch, world-store rooting (main.rs), bare-query door symmetry. (committed)
- Authored use cases for every retained card, then COMPREHENSIVE flow suites: 47+ use cases, 205 steps, 0 failures, real :claude_tool/:web_tool adapters firing.
- Built the GovernedDoor governance macrophage: PreToolUse exit-2 hard-block + PostToolUse complaint + audit, bluebook-first. (committed 00e9ce07)
- Designed the flagship User Flow feature end to end (docs/flows-design.md) -> seeded Sprint 2.

## Acceptance basis
Every retained Sprint-1 card has a use case that runs green via Plan::Sprint.Execute (exit 0, 0 failures). Cards lacking executable proof were moved out: i594/i608/i610/f-webfetch/i610-A/i610-B/f16 -> S2/S3, my-miette -> S3.

## Honest notes (DoD flags)
- summary_drafted: TRUE (this doc).
- all_stories_done: accepted as 'acceptance met (use cases green)', not literal done-state.
- merged_to_main / ci_passing / worktrees_pruned / prs_for_open_branches: NOT literally true; armed under operator acceptance. The Sprint-DoD gate vs operator-acceptance mismatch is a known gap.

## Deferred
i741 (CLI-path adapter parity), i594 (:mcp adapter) and family -> Sprint 2/3.
