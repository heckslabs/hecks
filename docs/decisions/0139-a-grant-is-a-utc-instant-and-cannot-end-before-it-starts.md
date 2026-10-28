# A grant is a UTC instant, and cannot end before it starts

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-27.

## Context

Governance's `RoleAssignment` and `RoleTransition` carry `starts_at` and `ends_at` as a
`Timestamp` value object that checked only that the text was present. What made a grant
live lived in Ruby: `GovernanceAuthorization` parsed `starts_at` with `Time.parse`, failed
closed on anything it could not read, and treated a missing `ends_at` as live. The
aggregate accepted a grant whose start was `"not-a-real-date"`, or whose revoke ended
before the grant began, and the adapter was the only thing that dealt with either.

A rule that decides who may act belongs where the model states its rules. An aggregate that
accepts a grant nobody can interpret keeps the real rule outside the bluebook, in a place
the fuzzer, the Rust host and a reader of the glossary do not see.

## Decision

1. **`Timestamp` is a UTC instant.** In both aggregates it must match a date
   (`2026-01-01`) or a date and time ending in `Z` (`2026-01-01T09:30:00Z`). Both forms read
   and sort the same way, so ordering them is a string comparison the model can state. A
   grant with any other start or end is refused when it is made.
2. **A revoke cannot end before the grant starts.** `RoleAssignment.Revoke` and
   `RoleTransition.Revoke` carry the `given` "a grant ends no earlier than it starts".
3. **The adapter keeps its fail-closed read.** `started?` still treats an unparseable
   `starts_at` as not yet started, as a defence for a record written before this rule. It is
   no longer the rule.
4. **The synthesizer satisfies a field's pattern when a fixed candidate does.** A String
   field whose pattern refuses `"smoke-test"` is given the first of a short fixed list
   (`2026-01-01`, `1`, `a`) that it admits, so door and smoke specs reach a patterned
   command's role gate instead of being refused on arguments first. Nothing is random.
5. **The fuzzer's value generator does the same, at its edge-case rate.** A drawn String that a
   field's pattern refuses is replaced by the same fixed candidates, except at
   `EDGE_CASE_PROBABILITY`, so a generated grant reaches its role gate and `actor_known` is
   reachable, while the refusal path is still drawn. A value the pattern admits is left as
   drawn and costs no random draw, so no existing seed shifts.

## Alternatives considered

- **A typed date or time attribute.** The language has no temporal type, and adding one is a
  new word with a Rust parity cost. A pattern states the same constraint with what exists.
- **Offsets as well as `Z`.** Two instants with different offsets do not sort as text, so
  the ordering rule would need real time arithmetic the expression language does not have.
  UTC only keeps the rule statable.
- **Move "live" into a declared query.** A query such as `LiveAssignmentsForActor` would take
  the `ends_at`-absent test out of the adapter. It needs a new key in the `authorization`
  capability's contract, which every provider would have to supply. Not done here; it is
  the next step for this rule.
- **Add Governance's commands to the door spec's exempt list.** That would stop testing
  that their role gates refuse another role. Rejected for the synthesizer fix above.

## Consequences

- A caller that assigns or grants with a time not in these two forms is refused. The
  repository's specs and the conformance corpus use date-only values, so they are
  unaffected. A consumer that stores another format must change what it writes; none is
  known, and none was searched for outside this repository.
- A record already stored with another format is still read, and fails closed when `as_of`
  is given.
- `ends_at` being absent still marks a live grant in Ruby (`row[:ends_at].nil?`), in the
  adapter and in the fuzzer's role check. Moving that into the bluebook is the open part of
  this rule.
