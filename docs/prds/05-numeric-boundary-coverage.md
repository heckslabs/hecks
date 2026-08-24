# PRD 05 — Numeric boundary coverage: Bignum, NaN, Infinity, negative zero

**Status:** Not started. Smallest PRD in this set — good first pick.

## The problem

`lib/hecks/fuzzing/value_generator.rb`'s own edge-case tables:

```ruby
INTEGER_EDGE_CASES = [0, -1, 2_147_483_647, -2_147_483_648]  # Int32 only
FLOAT_EDGE_CASES   = [0.0, -0.5, -100.25]                     # no NaN/Infinity/-0.0
```

Neither table reaches Int64/Bignum, and the float table has no
`Float::NAN`, `Float::INFINITY`, `-Float::INFINITY`, or negative zero
(`-0.0`) anywhere. A grep of the whole `lib/`/`spec/` tree confirms none of
those four float values appear in any hand-written spec either —
`spec/identifier_numeric_coercion_growth_spec.rb` covers a specific,
narrower bug (numeric `identified_by` re-seeding), not general boundary
behavior.

This is classic silent-corruption territory: a `NaN` sailing through a
`clamp` mutation's `current.clamp(min, max)` (Ruby's own `Comparable#clamp`
raises `ArgumentError` comparing against `NaN` — does the runtime's own
`TypeMismatch` refusal catch this cleanly, or does a raw Ruby exception leak
through?), or a Bignum silently truncating somewhere a 32-bit assumption
snuck into a comparator or a stored-column type.

## Approach

1. Widen `INTEGER_EDGE_CASES` to include a real Int64 boundary and at least
   one genuine Bignum (`2**64`, `-(2**64)`) — and separately, since Bignum
   behavior can differ by *storage* adapter (a SQL column type has real
   limits Ruby's own `Integer` doesn't), cross-reference this with PRD 02 —
   a Bignum through Memory only proves the Ruby-side coercion path, not
   what a real database does with it.
2. Add `Float::NAN`, `Float::INFINITY`, `-Float::INFINITY`, `-0.0` to
   `FLOAT_EDGE_CASES`.
3. Trace what each of these actually does through
   `lib/hecks/runtime/value/coercion.rb`'s `check_numeric_fields`
   (`coercion.rb:313-327`) and `CommandRules::Arithmetic#multiply`/`#clamp`
   (touched twice already this session — the `clamp` phantom-field fix,
   and the four independent recompute functions in
   `mutations_match_recompute`) — does each edge value get a clean,
   named refusal, or does something leak a raw Ruby `ArgumentError`/
   `FloatDomainError` past the domain's own refusal vocabulary?
4. Any leak found is a real bug (an unnamed, un-refused failure mode) —
   fix it the same way the `clamp` phantom-field asymmetry got fixed this
   session, not just documented as a known gap.

## Acceptance criteria

- [ ] `INTEGER_EDGE_CASES`/`FLOAT_EDGE_CASES` include Bignum and
      NaN/Infinity/negative-zero.
- [ ] Every one of those values, run through the full command-dispatch
      pipeline (not just unit-tested against `coercion.rb` in isolation),
      either succeeds correctly or refuses with a named `DOMAIN_REFUSAL`
      class — never a raw Ruby exception.
- [ ] Any leak found gets fixed; the fix ships with its own spec proving it
      red-before/green-after, the standard this session held to throughout.

## Non-goals

- String pattern-matching edge cases (`coercion.rb`'s own `check_patterns`)
  — patterns are pre-vetted by `PatternSubset` at declare time per that
  file's own comment, a materially different risk surface from raw numeric
  boundaries; worth its own pass if it turns out to matter, not folded in
  here.
- Redesigning how the fuzzer weights edge-case selection — this PRD widens
  the *table*, not `value_generator.rb`'s own `EDGE_CASE_PROBABILITY`
  weighting logic.
