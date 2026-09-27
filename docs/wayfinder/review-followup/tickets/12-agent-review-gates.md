---
type: grilling
status: open
blocked_by: []
claimed_by:
---

# Agent-built code: which review gates are real

## Question

Most commits carry an agent author or co-author trailer at about 25 a day, and a skeptical
evaluator will ask who reviews what. Only the maintainer knows the real answer. State the human
review gates (what a person reads before merge, what they do not), what CI proves versus what a
person checks, and decide the CONTRIBUTING section that says so plainly. This ticket needs the
maintainer's own account; the agent must not invent the gates.

## Prep (not a decision)

Facts gathered read-only from the repo and GitHub configuration. Nothing here says what a
person actually reads before merge; that is the maintainer's to state.

**Proven**
- Docs: `CLAUDE.md` covers comment style only. `CONTRIBUTING.md` never mentions review,
  approval or agents, and calls the pre-push hook "the actual bar a change has to clear". The
  README's "AI-native development" section is about operating on a domain through the MCP door,
  not about how the repo is built.
- Merge path: branch protection and the `merge-queue-main` ruleset both require nine status
  checks (the suite, checks, Postgres and Rust I/O, Rust parser, codegen and host, fuzzing),
  run again on the PR merged onto `main`'s tip, with no bypass actors. Both require **0
  approving reviews** and no code-owner review, and there is no CODEOWNERS file. The ruleset
  sets `require_extra_approval_for_unattributed_changes`; whether it ever triggers is not
  knowable from the API. One collaborator is visible.
- Pre-push gate (`.githooks/pre-push`): seven checks (parallel suite, fuzzing, query agreement,
  engine agreement, model check, doc coverage, rubocop), bypassable with `--no-verify`. It
  writes an HMAC attestation note keyed by tree hash; that proves the key holder ran those
  checks locally on that tree, not that anyone reviewed the code or who wrote it.
- Last 60 merged PRs: 0 of 60 recorded a review on GitHub, and all were authored and merged by
  the maintainer's account.
- Authorship: 1,433 commits over all history. Co-author trailers appear on 986 (69%) overall
  and 424 of 424 in the last 30 days. That is about 14 commits a day over 30 days, not the
  ticket's "about 25". Trailer names include several Claude models and the persistent agent
  identity, which the repo never explains.
- What CI proves mechanically: the suite, fuzzing, Postgres and Rust I/O, model check, engine
  agreement, doc coverage, rubocop, Ruby/Rust parity specs, the golden IR, and every
  `ruby`-fenced README and guide block.
- `docs/implemented/guides/verification.md:416` describes an older, narrower pre-push hook.

**Outline for the CONTRIBUTING section.** Claims 1 to 4 are provable: most commits are
AI co-authored; nothing merges except through the queue after nine checks; a local gate can be
bypassed; GitHub requires no human approval and none was recorded. Claims 5 to 7 need the
maintainer: what a person reads before merge, who or what reviews agent-written diffs, and how
an outside contributor's PR would be reviewed.

**For the maintainer**
1. Before a PR merges, what do you personally read: every diff, some paths, only CI status?
2. Do agent-run reviews happen (a review skill, subagents), and should the repo claim them?
   Nothing records them today.
3. Is 0 required approvals intentional for a solo-maintainer repo, and should outside PRs get a
   different bar?
4. What is the persistent agent identity in the author and trailer lines: a runtime or a
   reviewer?
5. Is `--no-verify` used in practice, and is the attestation meant to be shown as evidence?
6. Use the measured rate (about 14 a day) in the text?
7. Fix the stale hook description in `verification.md` as part of this?

## Answer
