# A role-gated command refuses a caller who states no role

**Status:** Accepted. Date: 2026-11-18. Decided by the owner on 2026-11-06 ("your call"; the planner's
recommendations were taken). Amends the authorization rule in the update section of
[0025](0025-the-dsl-names-one-idea-one-way-and-a-word-earns-its-place-by-being-used.md) (lines 108 to 110).
Builds on [0062](0062-mcp-servers-need-real-authentication-before-any-network-transport.md) and
[0072](0072-the-mcp-door-token-waits-for-a-real-need-and-a-tool-allowlist-comes-first.md). This ADR changes no
bluebook, hecksagon, code or version: it records the rule and names the changes that follow.

## Context

ADR 0025 is a general ADR about the DSL. It holds the authorization rule only in its update section: a command's
`role` is checked against the caller's live Governance `RoleAssignment`s, and "a caller that never binds `actor_id`
still gets the old string check". Its bootstrap sentence says the first administrator grant "comes from a caller that
binds no `actor_id`, which is a bootstrap step and not a bypass".

That leaves a hole: a caller that states no role at all passes a role-gated command. The owner found it in
`miette_tools`, where `Proposal.approve!` runs from the CLI with no role, so any session can approve as the owner.
(The `miette_tools` repository is not in this checkout, so no file and line is cited here; the Work item that
builds the change cites it.)

## Decision

1. **A command that declares `role` refuses a caller who states none**, unless its bluebook marks the command open to
   the system. The refusal names the command and its role.
   - A CLI caller is an `actor_id` proved by a 1Password- or Touch ID-backed identity (as the Keeper in Miette 2),
     checked against live Governance grants. A bare role string stays only for specs. An agent gets its own
     `actor_id` with no Owner grant.
   - Proving an identity is a **port** of the hecksagon, with its adapter behind it in `lib/hecks/adapters/`. The
     bluebook names no 1Password and no Touch ID.
   - This is the CLI door's answer to the token that 0072 deferred; it does not supersede 0062's rule that a network
     door needs real authentication first, and it adds no network door.
2. **A policy reaction runs as a declared system role.** A policy says `acts_as "System"`, and Governance grants that
   role to the domain. A command marked `policy_only` refuses any CLI or MCP caller. A bulk run keeps
   `Caller.origin` ([0125](0125-a-bulk-run-sends-one-command-to-every-row-of-a-query.md)), so each row runs under the
   requester's authority.
3. **The first administrator grant is a one-time bootstrap through the owner's identity.** It is not an exception for
   an unstated caller. It replaces the bootstrap sentence in 0025 line 110.
4. **Breaking, for 7.0.0.** 6.x ships in shadow: a command that would refuse is allowed and a would-refuse is
   recorded. 7.0.0 makes refuse the default. The record is one event, raised by the authorization check and kept in
   the Governance chapter, so there is one owner of the log. 7.0.0 is a release and the owner's decision: this ADR
   bumps no version and carries no `Release-Approved-By` line.

## New vocabulary

These words do not exist yet: the marker that opens a command to the system, `acts_as` on a policy, and
`policy_only`. They are not in `lib/hecks` today. A Work item adds them through a bluebook change (the DSL, the
Ruby builder and the Rust parser), then the check, the identity port and its adapter, and the shadow event.

## Consequences

- Closes the unstated-caller hole without a per-command exception list.
- Corpus bluebooks whose commands run from policies or cron-like callers must declare `acts_as` or the open marker
  before 7.0.0; shadow mode lists them first.
- Specs keep passing a bare role string.
