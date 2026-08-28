# Chapter-wide, entity-scoped `given` sharing

## Motivation

`chapter-given.md` let an AGGREGATE's own `given` be shared with any OTHER
aggregate in the same chapter. `cross-entity-given.md` let a PIECE's own
`given` be shared with any sibling piece nested under the SAME aggregate.
Neither reaches the shape real corpus duplication actually took one level
further: two pieces nested under two DIFFERENT aggregates, each
independently typing the exact same predicate.

Real, live corpus evidence (`examples/banking/bluebook/`):
`Account::LedgerEntry` and `SafeDepositBox::Visit` — two pieces on two
different aggregate heads — each wrote, byte for byte:

```ruby
given("customer is active") { parent.customer.status == "active" }
```

Both reach "the customer" the same way — a direct `reference_to Customer`
on their own aggregate — so the canonical is genuinely identical, not a
coincidence of wording the way `ATMCard`'s own "customer is active"
(`account.customer.status`, reached through an account reference) is a
DIFFERENT canonical under the same description (`chapter-given.md`'s own
"Known limitations").

## Algorithm

1. A CHAPTER holds one mutable "chapter-entity-given" pool
   (`@chapter_entity_named_givens` in `BluebookBuilder`), created once,
   empty, at the chapter's own build start — the entity-scoped analogue of
   `@chapter_named_givens`, one level down.
2. That SAME pool object is threaded into every aggregate the chapter
   builds (`AggregateBuilder.build(..., chapter_entity_named_givens: pool)`),
   which threads it, unchanged, into every TOP-LEVEL piece it builds
   (`EntityBuilder.build(..., chapter_entity_named_givens: pool, aggregate_name: @name)`),
   which threads it further into any piece nested inside THAT piece,
   however deep — one pool, reachable from anywhere in the whole chapter's
   entire entity tree, across every aggregate.
3. A piece's own `given(description) { predicate }` (block form) does
   everything it already did (write into its own `@named_givens`, and into
   its aggregate's own cross-entity pool, `@owner_named_givens`) AND writes
   the SAME `Given` object into the chapter-entity pool, keyed by
   **[description, "AggregateName.EntityName"]** — a dotted string, not a
   bare description, since (unlike the same-aggregate cross-entity pool)
   the SAME description can legitimately mean a genuinely different
   predicate declared by a different piece elsewhere in the chapter, the
   identical reason `chapter-given.md`'s own pool is keyed by owner too.
   First declaration under a given [description, owner] pair wins
   (`||=`) — this pool is additive, never overwritten.
4. A piece's own BARE `given(description)` (no block, optionally
   `declared_by: "AggregateName.EntityName"`) resolves, in order:
   1. `declared_by:` given → the exact [description, owner] pair, or
      DEFERRED (see step 5) if that owner hasn't declared it yet;
   2. `declared_by:` omitted, exactly one candidate registered under this
      description anywhere in the chapter → that candidate;
   3. `declared_by:` omitted, zero candidates registered SO FAR → DEFERRED
      (see step 5) — a later file in the same chapter may still declare it;
   4. `declared_by:` omitted, two or more DIFFERENT candidates registered →
      `Malformed`, naming every candidate owner and requiring `declared_by:`
      to disambiguate.
   The resolved (or placeholder) `Given` is stored on the referencing
   piece's own `@named_givens[description]` — same as a local declaration —
   AND write-through into the referencing piece's own `@owner_named_givens`
   (its aggregate's same-aggregate cross-entity pool), so a SIBLING piece
   under that SAME aggregate can still bare-reference the description at
   the COMMAND level (`CommandBuilder#reference_named_given`), unaffected
   by whether the piece it's reading from declared locally or referenced
   chapter-wide.
5. A CHAPTER MAY BE SPLIT ACROSS FILES — the identical reason
   `chapter-given.md`'s own step 5 exists. An unresolved bare reference
   (steps 4.1/4.3, above) hands back a PLACEHOLDER `Given` (embedded, by
   Ruby object reference, in the referencing piece's own `preconditions`)
   and queues the request; `BluebookBuilder#resolve_pending_chapter_entity_
   givens!` — called both from `BluebookBuilder#build` (single-file
   chapters) and from `MetaValidator.judge_deferred!` (chapters split
   across files loaded under `MetaValidator.defer`) — mutates every queued
   placeholder in place once the whole chapter has loaded, against the by-
   then-complete pool.

## Qualifies / does not qualify

| Input | Outcome |
|---|---|
| `SafeDepositBox::Visit` bare-references `"customer is active"`; `Account::LedgerEntry` (a different aggregate's own piece) already declared it with a block, and no other piece in the chapter declares this description | Resolves to `Account::LedgerEntry`'s own `Given` object, `declared_by:` omittable (single candidate) — qualifies |
| Two DIFFERENT pieces (anywhere in the chapter) declare the SAME description with a TEXTUALLY DIFFERENT predicate | Both stay as independent candidates; a later bare reference MUST supply `declared_by:` to pick one, or raises `Malformed` naming both |
| A piece bare-references a description declared only by a SIBLING piece under its OWN aggregate | Still resolves through the existing same-aggregate cross-entity pool (`@owner_named_givens`) first if that pool already holds it — the chapter-wide pool is a fallback, not a replacement, for the narrower scope `cross-entity-given.md` already covers |
| A piece bare-references a description NO piece anywhere in the chapter declares, by the time the whole chapter has loaded | `Malformed`, naming the description and that no piece in the chapter declares it |
| Two UNRELATED chapters' own pieces happen to phrase a rule identically | Never shared — each chapter holds its own separate pool; cross-CHAPTER sharing does not exist and is out of scope here, the same boundary `chapter-given.md`'s own pool respects one level up |

## Known limitations

- `declared_by:` is a **plain string** (`"AggregateName.EntityName"`), not a
  constant — unlike `chapter-given.md`'s own `declared_by:`, which names a
  real aggregate constant. A piece has no first-class, independently-
  addressable reference anywhere in this language (only its owning
  aggregate does); inventing one to make this argument's spelling
  symmetrical with the aggregate-level word was considered and explicitly
  rejected as unscoped, separate work with no real corpus need — this ships
  textual, the same way `admits:` shipped textual before its own constant-
  bridge existed.
- First-declared-wins is a textual-order fact, the same caveat
  `cross-entity-given.md`'s own "Known limitations" already names one level
  down — swapping which piece declares the block changes nothing observable.
- `bin/query_ir duplicates` CANNOT be taught this rule the way cross-entity
  sharing was — see `Hecks::QueryIR#declaration_count`'s own comment. A
  piece resolving a chapter-wide reference still write-throughs the
  resolved `Given` into its OWN `@named_givens` (so its own commands read
  it back locally without a second hop), so the exported IR shows the
  referencing piece as its own `"(declared)"` owner too — structurally
  indistinguishable from a real local declaration once anything reads
  `chapter.aggregates`. This is the SAME gap `declaration_count`'s own
  comment already names for chapter-wide AGGREGATE sharing, one level down,
  not a new one. Verify by hand whether a group naming two pieces under
  different aggregates is fresh duplication or an already-resolved
  chapter-wide reference.

## Reference implementation

- `lib/hecks/bluebook/dsl/bluebook_builder.rb` — `#initialize`
  (`@chapter_entity_named_givens`, `@chapter_entity_pending_givens`),
  `#aggregate_impl` (threads both into `AggregateBuilder.build`), `#build`
  (`resolve_pending_chapter_entity_givens!`), `#resolve_pending_chapter_
  entity_given` (the deferred-resolution algorithm, step 5).
- `lib/hecks/bluebook/dsl/aggregate_builder.rb` — `#initialize` (receives
  and stores both), `#drain_pending!` (threads both, plus `aggregate_name:
  @name`, into every top-level `EntityBuilder.build` call).
- `lib/hecks/bluebook/dsl/entity_builder.rb` — `#initialize`
  (`aggregate_name:`, `chapter_entity_named_givens:`,
  `chapter_entity_pending_givens:`), `#given_impl` (write-through, both
  block and bare-reference branches), `#reference_named_chapter_entity_
  given` (the resolution algorithm, step 4), `#pending_chapter_entity_
  given` (the deferral, step 5), `#drain_pending!` (threads all three
  unchanged into nested pieces).
- `lib/hecks/bluebook/meta_validator.rb` — `.judge_deferred!` (calls
  `resolve_pending_chapter_entity_givens!` alongside the existing
  aggregate-level call, for chapters split across files).

## Reference mirror

NOT YET MIRRORED.
