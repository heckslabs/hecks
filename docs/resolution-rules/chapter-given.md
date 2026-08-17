# Chapter-wide `given` sharing

## Motivation

S10/ADR 0025's "declared once, referenced by name" already reaches an
aggregate's own commands (`AggregateBuilder#given`), a piece's own commands
(`EntityBuilder#given`), and — earlier in this same arc —  any piece nested
under one aggregate (`docs/resolution-rules/cross-entity-given.md`). None of
those reach the widest real corpus duplication: two DIFFERENT AGGREGATES,
each independently typing the identical precondition.

Real, live corpus evidence (`examples/banking/bluebook/banking.bluebook`):
`Account`, `SafeDepositBox`, and `OnboardingCase` each wrote, byte for byte:

```ruby
given("customer is active") { customer.status == "active" }
```

All three hold a DIRECT `reference_to Customer`, so the identical relative
path resolves the identical way regardless of which aggregate's own command
asks — genuinely the same rule, not just the same words.

A SECOND, wider real case (added in a follow-up round, once the first
shipped): `ATMCard`, `CardPayment`, `ExternalTransfer`, `ScheduledPayment`,
and `Statement` each independently wrote, byte for byte:

```ruby
given("account is open")    { account.status == "open" }
given("customer is active") { account.customer.status == "active" }
```

The SAME description as the first group — "customer is active" — but a
GENUINELY DIFFERENT canonical (reached through `account`, an `Account`
reference, rather than a direct `Customer` reference). Naively sharing this
group under the same chapter-pool slot as the first would have silently
resolved to the wrong predicate; the `declared_by:` disambiguator (below)
is what let this second group hoist safely without either group's wording
having to change.

## Algorithm

1. A CHAPTER (`BluebookBuilder`) holds one mutable "chapter-named-givens"
   pool (`@chapter_named_givens`), created once, empty, at the chapter's own
   build start. Keyed by DESCRIPTION, then by DECLARING AGGREGATE'S OWN
   NAME — `pool[description][owner_name] = given` — not by description
   alone; see step 3 for why.
2. That SAME pool object is threaded into every aggregate the chapter
   builds (`AggregateBuilder.build(..., chapter_named_givens: pool)`) — NOT
   further, into that aggregate's own entities; an entity-level `given`
   (`parent.`-relative) is a structurally different predicate shape and has
   its own, separate cross-entity pool (`cross-entity-given.md`).
3. An aggregate's own `given(description) { predicate }` (block form,
   unchanged from before this rule existed) now ALSO writes the same
   `Given` object into the chapter pool, under `[description][this
   aggregate's own name]`, ONLY if that exact `[description, owner]` pair
   is not already present — first declaration under a description BY A
   GIVEN OWNER wins; a DIFFERENT owner independently declaring the
   identical description (with a genuinely different canonical, or even
   an identical one) registers its OWN entry alongside, never overwriting
   another owner's.
4. An aggregate's own bare `given(description, declared_by: nil)` (no
   block) resolves against `pool[description]`'s own candidates:
   - `declared_by:` given — look up that EXACT owner's own entry; raise
     `Malformed` if that owner never declared this description.
   - `declared_by:` omitted, exactly ONE candidate registered — resolve to
     it (the original, still-most-common shape: one owner, no ambiguity).
   - `declared_by:` omitted, ZERO candidates — raise `Malformed`, naming
     what was checked (nothing has declared this yet, anywhere).
   - `declared_by:` omitted, TWO OR MORE candidates — raise `Malformed`,
     AMBIGUOUS, naming every candidate owner and instructing the author to
     add `declared_by:`. Never silently guesses.

   The resolved `Given` is stored into the referencing aggregate's OWN
   `@named_givens` exactly as a block declaration would be, so every
   existing downstream reader (its own `preconditions`, its own commands'
   bare references) is completely unaffected by whether a description was
   declared locally or referenced, or by how many other owners share its
   wording.

## Qualifies / does not qualify

| Input | Outcome |
|---|---|
| `SafeDepositBox` bare-references `"customer is active"` with no `declared_by:`; only `Account` has ever declared it | Resolves to `Account`'s own `Given` (the single-candidate case) — qualifies |
| `CardPayment` bare-references `"customer is active"` with `declared_by: ATMCard`; both `Account` and `ATMCard` have declared DIFFERENT canonicals under that description | Resolves to `ATMCard`'s own `Given` specifically — qualifies, disambiguated |
| `CardPayment` bare-references `"customer is active"` with NO `declared_by:`, and both `Account` and `ATMCard` have declared different canonicals | `Malformed`, AMBIGUOUS — refuses rather than guessing which one was meant |
| Two aggregates each independently write `given("x") { same predicate }` with their OWN block, and NEITHER ever references the other bare | Both keep their own local declaration; the pool holds both, one per owner. Not an error, but not maximally deduped — a real, still-open hoisting opportunity, same as any un-hoisted local declaration |
| An aggregate bare-references a description no aggregate anywhere in the chapter has declared | `Malformed` |
| An aggregate bare-references `declared_by: SomeAggregate`, but `SomeAggregate` never declared that description at all | `Malformed`, naming the aggregate that doesn't have it |

## Known limitations

- **No canonical verification at reference time, by design** — a bare
  reference (with or without `declared_by:`) trusts its own author to have
  verified the SAME predicate applies, the identical trust model every
  other scope this mechanism already relies on. `declared_by:` picks WHICH
  declaration to trust when more than one exists; it does not, and cannot,
  check that the referencing aggregate's own intent actually matches what
  it resolves to — that is a human/codemod responsibility before
  converting a declaration to a reference, the same discipline
  `bin/codemod_hoist_local_givens` already exercises programmatically one
  level down.
- **`bin/query_ir duplicates`' own dedup cannot see this rule at all** — a
  referenced (bare) `given` write-throughs into its own aggregate's
  `@named_givens` exactly like a locally-declared one does, so the EXPORTED
  IR is identical either way; every aggregate sharing a description via
  either `declared_by:` or the single-candidate form still shows as its
  OWN separate "(declared)" owner in `bin/query_ir duplicates`' own
  output, even once genuinely deduped in source. See
  `lib/hecksagain/query_ir.rb`'s own `declaration_count` comment — this is
  the SAME root cause as object identity not surviving a bluebook's own
  self-hosting build, one level wider, and is not fixable from the
  exported IR alone.
- **`declared_by:` only disambiguates AGGREGATE-level chapter sharing** —
  it does not reach into entity-level cross-aggregate sharing (two
  DIFFERENT aggregates' own nested pieces independently declaring the
  identical `parent.`-relative predicate — real, live, still open:
  `Account.LedgerEntry` and `SafeDepositBox.Visit`'s own "customer is
  active"). That would need its own, separate widening — the
  cross-entity-given pool is scoped to ONE aggregate's entity tree, the
  chapter pool doesn't reach into entities at all (step 2, above) — left
  as a real, named follow-up, not built here.

## Reference implementation

- `lib/hecksagain/bluebook/dsl/bluebook_builder.rb` — `@chapter_named_givens`
  (init), `#aggregate` (threads the pool into every `AggregateBuilder.build`
  call).
- `lib/hecksagain/bluebook/dsl/aggregate_builder.rb` — `#initialize`
  (`chapter_named_givens:`), `#given` (`declared_by:` kwarg, write-through
  keyed by `[description][owner name]`, bare-reference dispatch),
  `#reference_named_chapter_given` (the disambiguation logic — exact-owner
  lookup, single-candidate resolve, or ambiguity refusal).
- `lib/hecksagain/language/bluebook/syntax.bluebook` — new Argument row,
  `given`/`Aggregate` context, `named: "declared_by"`, `kind: "constant"` —
  required ONLY because `syntax_conformance_spec.rb` checks every keyword
  argument a builder method takes against the language's own self-
  description; `declared_by:` fills no real IR field (a `Given`'s own
  shape is unchanged), so this is the one propagation-checklist step that
  applies here despite there being no new `Construct#field` (see that
  spec's own failure message if this row goes missing: "`Aggregate.given`'s
  builder takes `[\"declared_by\"]`, which the language does not declare").

## Reference mirror

NOT YET MIRRORED — the FIRST version of this rule (single-owner-per-
description, no `declared_by:`) IS mirrored (`rust/parser/src/parse/
{chapter,aggregate}.rs`, `Vec<ir::Given>`-shaped pool); the `declared_by:`
disambiguation is a follow-up Rust-mirror round of its own, since the
pool's own shape needs to change (owner-keyed, not a flat list) to match.
