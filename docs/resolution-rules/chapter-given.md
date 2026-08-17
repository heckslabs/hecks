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

## Algorithm

1. A CHAPTER (`BluebookBuilder`) holds one mutable "chapter-named-givens"
   pool (`@chapter_named_givens`), created once, empty, at the chapter's own
   build start.
2. That SAME pool object is threaded into every aggregate the chapter
   builds (`AggregateBuilder.build(..., chapter_named_givens: pool)`) — NOT
   further, into that aggregate's own entities; an entity-level `given`
   (`parent.`-relative) is a structurally different predicate shape and has
   its own, separate cross-entity pool (`cross-entity-given.md`).
3. An aggregate's own `given(description) { predicate }` (block form,
   unchanged from before this rule existed) now ALSO writes the same
   `Given` object into the chapter pool, keyed by description, ONLY if that
   key is not already present (`pool[description] ||= given`) — first
   declaration under a description, anywhere in the chapter, wins; a later
   aggregate independently declaring the identical description with its OWN
   block stays local to itself, no silent overwrite.
4. An aggregate's own bare `given(description)` (no block) resolves in
   order: the chapter pool (there is no narrower "in-between" scope between
   one aggregate and the whole chapter) — if not found, raise `Malformed`,
   naming what was checked. The resolved `Given` is stored into the
   referencing aggregate's OWN `@named_givens` exactly as a block
   declaration would be, so every existing downstream reader (its own
   `preconditions`, its own commands' bare references) is completely
   unaffected by whether a description was declared locally or referenced.

## Qualifies / does not qualify

| Input | Outcome |
|---|---|
| `SafeDepositBox` bare-references `"customer is active"`; `Account` (declared earlier in the file) already wrote it with a block, identical canonical | Resolves to `Account`'s own `Given` — qualifies |
| `ATMCard`'s own `"customer is active"` (`account.customer.status == "active"`, reached through `Account`, not `Customer` directly) | Same WORDS, a genuinely DIFFERENT predicate — NOT converted to a bare reference against `Account`'s own entry (would silently check the wrong thing). Stays a separate, real, local declaration; a real remaining duplication opportunity across `ATMCard`/`CardPayment`/`ExternalTransfer`/`ScheduledPayment`'s own matching copies of EACH OTHER, left as a deliberate follow-up (see Known limitations) |
| Two aggregates each independently write `given("x") { same predicate }` with their OWN block | Both keep their own local declaration; the pool holds whichever ran first (aggregates build in file order, eagerly — unlike `entity`/`command`/`query`, `aggregate` itself is never deferred). Not an error, but not maximally deduped — a real, still-open hoisting opportunity |
| An aggregate bare-references a description no aggregate anywhere in the chapter has declared with a block | `Malformed` |

## Known limitations

- **No canonical verification at reference time, by design** — a bare
  reference trusts its own author to have verified the SAME predicate
  applies, the identical trust model every other scope this mechanism
  already relies on (nothing here re-checks that a referencing aggregate's
  OWN intended meaning matches what it resolves to; that is a human/codemod
  responsibility before converting a declaration to a reference, the same
  discipline `bin/codemod_hoist_local_givens` already exercises
  programmatically one level down).
- **Same description, genuinely different canonical, does NOT auto-merge —
  and must not be forced to** — `ATMCard`/`CardPayment`/`ExternalTransfer`/
  `ScheduledPayment`'s own "customer is active" (`account.customer.status`)
  legitimately collides, by TEXT alone, with `Account`'s own (bare
  `customer.status`). Since the pool is keyed by description only, whichever
  aggregate is declared FIRST in the file "owns" that description slot;
  converting ANY of the second group to a bare reference would silently
  resolve to the WRONG canonical. This round deliberately converted ONLY
  the verified-identical group (`Account`/`SafeDepositBox`/`OnboardingCase`)
  and left the second group's own four aggregates with their own local
  declarations, untouched — a real, named follow-up: it needs EITHER a
  second, disambiguated description string, OR a pool keyed by
  (description, canonical) with reference-time canonical verification (a
  materially bigger change than this round's own scope), before it can be
  safely closed the same way.
- **`bin/query_ir duplicates`' own dedup cannot see this rule at all** — a
  referenced (bare) `given` write-throughs into its own aggregate's
  `@named_givens` exactly like a locally-declared one does, so the EXPORTED
  IR is identical either way; `Account`/`SafeDepositBox`/`OnboardingCase`
  still show as three separate "(declared)" owners in `bin/query_ir
  duplicates`' own output even after this round converts two of them to
  references. See `lib/hecksagain/query_ir.rb`'s own `declaration_count`
  comment — this is the SAME root cause as object identity not surviving a
  bluebook's own self-hosting build, one level wider, and is not fixable
  from the exported IR alone.

## Reference implementation

- `lib/hecksagain/bluebook/dsl/bluebook_builder.rb` — `@chapter_named_givens`
  (init), `#aggregate` (threads the pool into every `AggregateBuilder.build`
  call).
- `lib/hecksagain/bluebook/dsl/aggregate_builder.rb` — `#initialize`
  (`chapter_named_givens:`), `#given` (write-through / bare-reference
  dispatch), `#reference_named_chapter_given` (the fallback lookup).

## Reference mirror

NOT YET MIRRORED.
