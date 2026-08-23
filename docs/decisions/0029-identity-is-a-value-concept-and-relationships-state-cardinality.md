# Identity is a value concept and relationships state their cardinality

**Status:** Accepted — implementation in progress.

## Context

ADR 0025 made two simplifications that do not read like the domain language we
want Bluebooks to preserve. It made `identified_by` point at a field, even when
the domain already has a named value concept for that identity, and it removed
`has_many`, `has_one`, and `belongs_to` because their old implementations were
only aliases for a scalar reference.

The first simplification hides an SME concept at the declaration site. The
second removes useful domain vocabulary because one implementation of that
vocabulary was dishonest. In particular, the former `has_many` did not hold a
collection at all.

## Decision

This ADR supersedes the **Identity** and **References** sections of ADR 0025.
Its other decisions remain in force.

Identity has three live declaration forms:

```ruby
identified_by AccountNumber, as: :number

identified_by do
  attribute :scheme, PaymentScheme
  attribute :end_to_end_id, EndToEndIdentifier
end

identified_by :branch_code, :box_number
```

- A named value-object identity mints one attribute. `as:` names it; otherwise
  the snake-cased value-object name does.
- An inline identity uses the ordinary `ValueObjectBuilder`, mints an
  `:identity` attribute by default, and synthesizes a deterministic type name.
- A list of two or more existing attributes is an explicit compound key and
  mints nothing.
- The ambiguous one-symbol field form is retired after the live corpus is
  migrated. Frozen-era source retains its legacy interpretation.
- Every scalar leaf of a named or inline value object contributes to the
  identifier in declaration order, recursively. Existing `Naming.identity`
  and its `:` separator remain the only encoder.
- Optional or list-valued identity members are invalid. Missing or blank
  members do not name a record. A joined multi-field identifier is never split
  to guess structured state during hydration.

Relationships are structural aggregate/entity state with literal cardinality:

- `belongs_to Customer` holds one required customer identity by default;
- `has_one MailingAddress` holds one identity;
- `has_many Accounts` holds a list of identities;
- `optional:` and `as:` retain their ordinary meanings;
- `reference_to` remains the neutral structural edge when no relationship
  concept is intended;
- canonical IR retains relationship kind as well as reference target and list
  cardinality so assembly and documentation do not collapse the words.

Relationship declarations do not create inverses, do not imply aggregate
lifecycle, and do not decide whether a command inserts or updates. A command's
receiver is routing information, while cross-aggregate facts in command input
are identity values rather than retained relationships.

## Compatibility and sequencing

The language adds and proves the new forms before removing the old live form.
The self-hosted language, examples, and fixtures are migrated through one
resolved exemplar per section. Only after the live inventory is clean does the
language lifecycle mark one-symbol identity retired and make it shadow-only.

Historical relationship words remain readable with their historical scalar
shape under the era/shadow grammar. A current `has_many` always means a real
list; language/era version distinguishes those semantics.

The executable sequence, focused verification gates, and corpus migration are
specified in
[`docs/value-object-identity-and-relationships-plan.md`](../value-object-identity-and-relationships-plan.md).

## Consequences

- An SME can identify an aggregate with the name of the value concept the
  business uses, including a bespoke concept declared in place.
- Reordering identity members is semantic and may re-key stored records.
- Multi-field identity state must be stored or supplied structurally; its
  display identifier is not a reversible serialization.
- `has_many` requires collection coercion, per-member existence checks, query
  traversal, adapter storage, forms, and Ruby/Rust generation support before it
  can be admitted in the live grammar.
- IR and generated artifacts change once, after the staged corpus migration.
