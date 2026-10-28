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

4. **Rust reads the same queries.** `QueryConditionValue::Null` resolves to `Json::Null`, which a
   field that is unset or null equals (`Eq`) and a set field does not (`Ne`). The generator emits
   it for an `eq` or `ne` comparison with nil, so the two live queries have a generated form and
   the kernel's `holds_role_via` takes `live_assignments` rows as live without testing `ends_at`.
   The exporter and the build's `authorization` seam carry `live_assignments` into `ir.json`, and
   the host's `is_admin` asks that query through the kernel instead of scanning the assignment
   store. An `ir.json` written before the key held no admin: the host holds no role it cannot
   read from the bluebook. An ordered or membership comparison with nil still has no generated
   form (`where_literal`).

## Alternatives considered

- **Leave the key out and filter in the adapter.** It would keep the contract as it was. Rejected:
  that is the rule living outside the bluebook, which is what this removes.
- **Fold `as_of` and `scope` into the live query.** The query language has no optional argument,
  so each combination would be a query of its own. Not done; the two checks remain the caller's
  opt-in.
- **Leave the Rust host deciding liveness.** The first version of this ADR did, because the
  kernel had no null condition and a variant nothing read was not worth adding. The host now
  reads the queries, so the variant is read.
- **Change what `assignments` answers.** The fuzzer's role check reads ended grants from it.
  Changing its meaning would move that check's input without saying so.

## Consequences

- A bluebook that declares `provides "authorization"` must add the two keys. Governance is the
  only provider in this repository, and no other provider is known; none was searched for
  outside it.
- Both runtimes take the rule from the bluebook. A conformance script (`spec/corpus/governance.json`)
  asks `LiveAssignmentsForActor` after a revoke and `LiveAllowed` after a second grant, and is
  replayed through Ruby and a Rust build. The host still reads Governance by its literal names for
  the grant command (ADR 0025, update 2026-09-14).
- The fuzzer's grant steering and role check are unchanged: they read `grant` and `assignments`.
- The sentence form cannot say the live queries. A `where(ends_at: nil)` filter has no phrase
  ("is not set") in the Sentence chapter, so the formatter refuses Governance by naming the
  query, and `spec/sentence_coverage_spec.rb` lists that refusal in `SENTENCE_UNSAID`. Saying it
  takes a new `Where` form in `rust/parser/src/sentence/queries.rs` and a phrase row, so it waits
  with the Rust null condition above; deleting the `SENTENCE_UNSAID` entry is how it is retired.
