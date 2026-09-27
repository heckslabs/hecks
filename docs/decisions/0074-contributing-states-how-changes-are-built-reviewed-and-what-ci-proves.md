# CONTRIBUTING states how changes are built and reviewed, and what CI proves

**Status:** Accepted — not yet implemented (2026-09-27). This ADR decides what the new CONTRIBUTING section must say. It does not write the section, and nothing in `CONTRIBUTING.md` has changed.

## Context

An outside review asked who reviews the agent-written code in this repository. `CONTRIBUTING.md` never mentions review, approval or agents. It calls the pre-push hook "the actual bar a change has to clear" (`CONTRIBUTING.md:55`, again at `:70`) and says the merge queue re-runs the Rust suite against main's tip (`:157`). The README's "AI-native development" section (`README.md:515`) is about operating on a domain through the MCP door, not about how this repository is built. The ticket that prompted this (`docs/wayfinder/review-followup/tickets/12-agent-review-gates.md`) is explicit that only the maintainer knows what a person reads before merge, and that the gates must not be invented.

The section therefore separates two kinds of claim, and each is attributed in the text.

**Proven by the repo and GitHub, re-checked on 2026-09-27.**

- History: 1,434 commits, 987 with a `Co-Authored-By:` trailer; 425 of 425 in the last 30 days, about 14 a day. The ticket's "about 25 a day" is wrong. The figures are one higher than the ticket's 986 of 1,433 because the branch tip moved.
- Merge path: ruleset `merge-queue-main` is active with no bypass actors and has a merge-queue rule and a required-status-checks rule with nine checks. Branch protection on main also lists nine. `.github/workflows/ci.yml:10-21` says the queue re-runs the checks on the PR merged onto main's tip.
- Approvals: branch protection and the ruleset's pull-request rule both require 0 approving reviews, and branch protection requires no code-owner review. There is no CODEOWNERS file. The ruleset also sets `require_extra_approval_for_unattributed_changes`; whether it ever triggers is not knowable from the API.
- The last 60 merged PRs (now #803 to #865; the ticket said #801 to #864) have zero recorded reviews on GitHub and a single author login.
- Pre-push: `.githooks/pre-push` runs seven checks and is bypassable with `--no-verify` (line 24). It writes an HMAC attestation note keyed by tree hash (lines 270-285). That proves a holder of the key ran those checks on that tree; it does not prove anyone reviewed the code. CI uses the note to skip the checks it names.
- What CI proves mechanically: the suite, fuzzing, Postgres and Rust I/O, model check, engine agreement, doc coverage, rubocop, Ruby/Rust parity specs, the golden IR, and every `ruby`-fenced README and guide block.

**Stated by the maintainer, not provable from the repo.** The maintainer reads every diff before merge. The repo does not claim agent-run reviews (a code-review skill, subagents) as a step, because nothing records them. Zero required approvals is intentional for a single-maintainer repo. A pull request from an outside author gets the maintainer's personal review before it is queued.

## Decision

1. `CONTRIBUTING.md` gets a section titled "How this project is built and reviewed".
2. It states the proven facts above as facts, each with the place a reader can check it, and states the maintainer's four statements as the maintainer's own, worded as statements and not as guarantees GitHub enforces.
3. It lists what CI proves mechanically, using the list above, and says that this is the mechanical bar and is separate from the maintainer's reading.
4. It says plainly that the pre-push hook can be bypassed and that its attestation is evidence of a local run, not of review.
5. It does not name agent-run reviews as a step.

## Consequences

- A reader learns that most commits are AI co-authored and that human review is one person's reading, not an enforced GitHub gate, before they see a claim they could disprove.
- The claim that the maintainer reads every diff is a promise with no mechanical check. It stays true only while the maintainer keeps doing it. If that lapses, the section is wrong until it is edited.
- The counts and PR ranges in the section are a snapshot and move with every commit.

## Alternatives considered

- **Require one approval for outside PRs through CODEOWNERS or a ruleset.** It would make the outside-PR statement enforceable, but with one visible collaborator nobody else can approve, and it adds a rule this decision does not adopt.
- **Require one approval for everyone.** Same objection, and it would block the maintainer's own PRs entirely.
- **Say nothing.** Cheapest, and it leaves the outside question unanswered while `CONTRIBUTING.md` implies the hook is the whole bar.

## Open items

- Who or what is the persistent agent identity in the author and trailer lines: a runtime that writes code, or a reviewer? The repo never explains it, and the section cannot describe it until the maintainer does.
- Is `--no-verify` used in practice, and is the attestation meant to be shown as evidence? The hook header calls it a speed optimization that CI may ignore.
- Is `docs/implemented/guides/verification.md:416`, which describes an older, narrower pre-push hook, fixed as part of this work?
- Should the section give the measured rate (about 14 a day) or only say "most"?
- Does the "actual bar" wording at `CONTRIBUTING.md:55` and `:70` change when the section is written, so the two do not disagree?
- Should a CODEOWNERS file exist even with no required review, so the outside-PR statement has a visible anchor?
