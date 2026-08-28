# PRD 05 — Numeric boundary coverage: Bignum, NaN, Infinity, negative zero

**Status:** Done. Real leak found and fixed — see "What shipped," below.

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

## What shipped

Both tables widened exactly as scoped: `INTEGER_EDGE_CASES` gained `2**100`
and its negative twin (Bignum, not just Int64 — Ruby's own `Integer` has no
ceiling at all, so there's no reason to stop at Int64); `FLOAT_EDGE_CASES`
gained `Float::NAN`, `Float::INFINITY`, `-Float::INFINITY`, and `-0.0`.

**The real leak, confirmed empirically before any fix (red)**: `Value::
Coercion#check_numeric_fields`'s own `given.is_a?(expected)` check is true
for NaN and either Infinity — both really are `Float`s — so all three sailed
through completely unchecked. Traced to two different, both real, failure
shapes:
- `-Float::INFINITY` reaching a value object with a declared invariant
  crashed inside `canonical_fields` (`JSON.generate` on the offered fields,
  building the invariant-violation MESSAGE) with `JSON::GeneratorError:
  -Infinity not allowed in JSON` — a crash raised while trying to explain a
  refusal that was itself never cleanly raised.
- `NaN` and `+Infinity` against the same value object raised NOTHING AT
  ALL — silently accepted, no invariant fired, no refusal, the genuinely
  worse of the two shapes (silent, not even loud-but-ugly).

Either way, once such a value is accepted, it also breaks
`CommandRules::Arithmetic#clamp` (`Float::NAN.clamp(0, 10)` raises a raw
`ArgumentError`, confirmed directly — not a domain refusal) and
`JSON.generate`/`#to_json` anywhere it's later persisted or replayed
(`JSON::GeneratorError`, also not a domain refusal) — matching this file's
own "silent-corruption territory" framing exactly.

**Fixed** at the single point `check_numeric_fields` already existed for:
a `Float`-typed field is now also refused (a proper `TypeMismatch`, new
`non_finite_field` wording — declared in `language/bluebook/
vocabulary.bluebook`'s `RefusalTemplate` closed set, same as every other
refusal wording, `spec/refusal_wording_conformance_spec.rb` holds the two
equal) when it is not `#finite?`. `-0.0` is deliberately NOT refused — it
IS finite, round-trips through `JSON.generate`/`#to_json` cleanly
(confirmed: `{a: -0.0}.to_json` => `'{"a":-0.0}'`), and is a legitimate
signed-zero value, not a corruption risk. Verified red-before/green-after
in `spec/runtime/numeric_boundary_spec.rb` (against a real corpus value
object — `Banking::ATMCard::DailyFee`, `attribute :amount, Float`), plus a
150-combination direct fuzzer sweep (pizzas/banking/entity_mutations ×
dozens of seeds × Memory/SQLite) confirming no crash and no property
failure with the widened tables in play.

**A second, real, but currently UNREACHABLE finding — documented, not
fixed**: `Adapters::Sqlite::Codec#encode` only JSON-serializes a value when
it's a `Hash`/`Runtime::Value` (any value-object-wrapped attribute, which
Ruby's own `JSON.generate`/`.parse` round-trips a Bignum through exactly,
confirmed directly: `2**100` survives the round-trip bit-for-bit). A BARE,
non-value-object-wrapped Integer/Float attribute would instead bind
straight through as a raw SQL parameter — and the `sqlite3` gem silently
converts an out-of-i64-range Integer to a lossy `Float` on that path,
confirmed directly:

```ruby
db.execute("INSERT INTO t VALUES (?)", [2**100])
db.execute("SELECT n FROM t").first.first  # => 1.2676506002282294e+30 (Float, not the original Integer)
```

Not shipped as a fix because it is not reachable by anything in this
corpus today: every real Integer/Float attribute, across all eight
domains, is wrapped in a value object (`arithmetic.rb`'s own "bare
primitives forbidden" note; confirmed by grep — zero bare numeric
attributes exist). If a future domain ever declares one, this is where to
look first; the fix, if needed, belongs in `Sqlite::Codec#encode`'s own
raw-scalar branch (route a bare numeric through the same JSON-text
encoding value-object fields already get, rather than binding it straight
as a native SQL parameter).
