# Cross-entity `given` sharing

## Motivation

S10/ADR 0025 already lets a precondition be "declared once, referenced by
name" — an aggregate's own `given`, shared across that aggregate's own
commands (`AggregateBuilder#given`), and (round 4) a piece's own `given`,
shared across that ONE piece's own commands (`EntityBuilder#given`). Neither
reaches the shape real corpus duplication actually took: two DIFFERENT
pieces nested under the SAME aggregate, each independently typing the exact
same predicate.

Real, live corpus evidence (`examples/banking/bluebook/`):
`SafeDepositBox`'s own `Visit` and `KeyIssuance` — two different pieces on
one composite-identified head — each wrote, byte for byte:

```ruby
given("customer is active") { parent.customer.status == "active" }
given("box is rented")      { parent.status == "rented" }
```

Neither could reference `SafeDepositBox`'s OWN aggregate-level "customer is
active" instead — that one reads `customer.status == "active"` (no
`parent.`), a genuinely different canonical predicate, correct in the
aggregate's own execution context and wrong in a piece's own command's.

## Algorithm

1. An AGGREGATE holds one mutable "entity-shared givens" pool
   (`@entity_named_givens` in `AggregateBuilder`), created once, empty, at
   the aggregate's own build start.
2. That SAME pool object (not a copy) is threaded into every piece the
   aggregate builds (`EntityBuilder.build(..., owner_named_givens: pool)`),
   and — unchanged, the identical object — into every piece nested inside
   THAT piece, however deep (S17's own Member/Dispatch/Handler nesting).
   One pool per aggregate, reachable from anywhere in that aggregate's
   entire entity tree.
3. A piece's own `given(description) { predicate }` (block form,
   `EntityBuilder#given`) does BOTH of what it already did (store into that
   piece's own `@named_givens`, unchanged) AND writes the SAME `Given`
   object into the shared pool, keyed by description, ONLY if that key is
   not already present (`pool[description] ||= given`) — first declaration
   under a given description, anywhere in the aggregate's entity tree,
   wins; a later piece independently declaring the identical description
   with its OWN block stays local to itself, no silent overwrite.
4. A COMMAND's own bare `given(description)` (no block,
   `CommandBuilder#reference_named_given`) resolves in order:
   1. its own owner's `named_givens` (the piece it's directly declared on,
      or the aggregate, unchanged from before this rule existed);
   2. if not found there, the aggregate-wide shared pool from step 2–3
      (empty, and therefore never matching, for an aggregate-owned
      command — there is no "sibling piece" concept at that level).
   3. if not found in either, raise `Malformed` — the message names both
      places that were checked.

## Qualifies / does not qualify

| Input | Outcome |
|---|---|
| `KeyIssuance.Return` bare-references `"box is rented"`; `Visit` (a sibling piece, same aggregate) already declared it with a block | Resolves to `Visit`'s own `Given` object — qualifies |
| A piece bare-references a description ONLY the OWNING AGGREGATE declares (aggregate-scoped, not piece-scoped) | Still resolves normally through step 4.1 (the piece's own `named_givens` lookup already covers this when threaded correctly) — unaffected by this rule |
| Two sibling pieces each independently write `given("x") { same predicate }` with their OWN block | Both keep their own LOCAL declaration; the pool holds whichever ran first. Not an error, but not maximally deduped either — a real, still-open hoisting opportunity `bin/query_ir duplicates` will keep surfacing until one becomes a bare reference to the other |
| A piece bare-references a description NEITHER its own scope NOR any sibling under the same aggregate declares | `Malformed`, naming both places checked |
| Two UNRELATED aggregates' own pieces happen to phrase a rule identically | Never shared — each aggregate holds its own separate pool; cross-AGGREGATE sharing is a different, larger, not-yet-built capability (see `docs/resolution-rules/README.md`'s own scoping note and this arc's own memory) |

## Known limitations

- Sharing is scoped to ONE aggregate's entire entity tree, never across
  aggregates — `Account`/`SafeDepositBox`/`OnboardingCase`'s own
  independent "customer is active" (aggregate-scoped, not this rule's
  concern) stays three separate declarations; that is real duplication too,
  but a structurally different, bigger problem (no aggregate-to-aggregate
  reference mechanism exists anywhere in this language yet).
- First-declared-wins is a TEXTUAL-ORDER fact at declaration time inside one
  `instance_eval` pass (`given`'s own block form still builds eagerly,
  unlike `entity`/`command`/`query`, which ADR 0028 defers) — the first
  piece, in file order, whose OWN block-form `given` for a given description
  runs is the one every later sibling's bare reference resolves to. Ambiguous
  only in the sense that swapping which piece declares the block changes
  nothing observable (the `Given` object's own content, not its identity,
  is what any caller reads — see `[[project_seam_agent_codemod_pilot]]`'s
  own note that object identity itself never survives a bluebook's own
  self-hosting build regardless).
- `bin/query_ir duplicates`' own dedup (`Hecks::QueryIR#declaration_count`)
  had to be taught this rule explicitly — an entity-owned `given` rule is
  now considered "covered" not just by an exact-owner `"(declared)"` match,
  but by ANY `"(declared)"` entry sharing the same ROOT aggregate. A query
  built before a resolution rule exists cannot know about it; this is the
  general shape of that gap, not specific to this one rule.

## Reference implementation

- `lib/hecks/bluebook/dsl/aggregate_builder.rb` — `#entity` (comment),
  `@entity_named_givens` (init), `#drain_pending!` (threads the pool into
  the first level of pieces).
- `lib/hecks/bluebook/dsl/entity_builder.rb` — `#initialize`
  (`owner_named_givens:`), `#given` (write-through), `#drain_pending!`
  (threads the SAME pool into both nested pieces and this piece's own
  commands).
- `lib/hecks/bluebook/dsl/command_builder.rb` — `#initialize`
  (`entity_shared_givens:`), `#reference_named_given` (the fallback lookup).

## Reference mirror

NOT YET MIRRORED.
