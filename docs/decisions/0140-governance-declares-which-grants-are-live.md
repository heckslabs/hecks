# Governance declares which grants are live

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-27. Finishes the rule
[0139](0139-a-grant-is-a-utc-instant-and-cannot-end-before-it-starts.md) left open.

## Context

ADR 0139 made a grant's start and end real times that the aggregate checks. What made a grant
live still lived in Ruby: `GovernanceAuthorization` read every row the `assignments` and
`transitions` queries answered and kept those with no `ends_at`, in three places (`holds_role?`,
`live_role_for`, `authorized_as?`). The bluebook said a grant could end and never said that an
ended grant stops counting. A comment in Governance claimed the language could not ask for an
absent field; `where(field: nil)` does.

The authorization capability is a language-defined contract: a provider must name exactly the
keys in `Capabilities::CONTRACTS`, and every reader (the dispatch-time role check, the adapter,
the fuzzer) takes its verbs from there.

## Decision

1. **Governance declares two queries for liveness.** `RoleAssignment.LiveAssignmentsForActor`
   answers the assignments of one actor that were never revoked, and `RoleTransition.LiveAllowed`
   answers the grants of one role acting as another that were never revoked. Both are
   `where(..., ends_at: nil)`. The history queries stay, since the fuzzer reads revoked grants
   too.
2. **The authorization contract names them.** `live_assignments` and `live_transitions` join
   `assignments`, `grant` and `transitions` as required keys, each a query. A provider that does
   not name them is refused when its bluebook is built.
3. **The adapter reads, and decides nothing about liveness.** `holds_role?`, `live_role_for` and
   `authorized_as?` ask the provider's live queries and take their rows as live. `as_of` and
   `scope` stay what they were: checks the caller opts into, applied to rows that are already
   live.

4. **The Rust generator skips a query that compares to nil.** The kernel's
   `QueryConditionValue::Literal` holds a `&str` and has no null, and the generator printed
   `nil` for such a condition, which would not compile. `query_where_skip_reason` now skips it
   under the existing `where_literal` family, so the two live queries have no generated Rust form
   and the committed pizzas output is unchanged.

## Alternatives considered

- **Leave the key out and filter in the adapter.** It would keep the contract as it was. Rejected:
  that is the rule living outside the bluebook, which is what this removes.
- **Fold `as_of` and `scope` into the live query.** The query language has no optional argument,
  so each combination would be a query of its own. Not done; the two checks remain the caller's
  opt-in.
- **Give the kernel a null literal.** It would make the live queries generate. Not done: the Rust
  host decides liveness itself and does not call them, so a kernel change would add a variant
  nothing reads.
- **Change what `assignments` answers.** The fuzzer's role check reads ended grants from it.
  Changing its meaning would move that check's input without saying so.

## Consequences

- A bluebook that declares `provides "authorization"` must add the two keys. Governance is the
  only provider in this repository, and no other provider is known; none was searched for
  outside it.
- The Rust host decides liveness for itself and still reads Governance by its literal names
  (ADR 0025, update 2026-09-14). It is unchanged by this, so the two runtimes now take their
  rule from different places until the host reads the capability.
- The fuzzer's grant steering and role check are unchanged: they read `grant` and `assignments`.
