# The conformance kit — golden IR and the parity corpus

Two artifacts already exist that function as a language-agnostic conformance target, even though
they're wired into this repo's Ruby/Rust tooling today. This document describes them precisely
enough that a third implementation can be checked against them without reading `bin/parity`'s shell
script or RSpec's runner.

## 1. Golden IR — the parser conformance target

`spec/golden/ir/*.json` (one file per domain — `Pizzas.json`, `Banking.json`, `Meta.json`, ...) is
**Ruby's own IR-export output**, checked in twice: `spec/ir_golden_spec.rb` treats it as the fixed
expected value for Ruby's own parser (regenerated with `GOLDEN=rewrite bundle exec rspec
spec/ir_golden_spec.rb` whenever a real change is intended), and `bin/parity`'s IR-parity step diffs
Rust's parser output against the same file (via `bin/ir` for Ruby, `hecksagain --dump <bluebook>`
for Rust, each piped through `bin/canonicalise` — see §3). **A new implementation's parser is
conformant when it produces this same JSON shape for the same `.bluebook` source.**

Top-level keys of one domain's IR: `name`, `vision`, `classification`, `version`, `canonical_form`,
`aggregates`, `policies`, `process_managers`, `read_models`.

An **aggregate** node: `name`, `description`, `identified_by`, `attributes`, `value_objects`,
`commands`, `entities`, `queries`, `lifecycle` (`{field, default, transitions}` or absent).

- **attribute**: `{name, type, list, default}` — `default` is a real typed JSON value (a number
  stays a number), not text.
- **command**: `{name, role, goal, references, attributes, givens, mutations, emits}`.
  `references` names the parent aggregate for an instance command, `null` for a creating command.
  `givens`/entries under a value object's `invariants` share one shape: `{description, canonical}`
  — `canonical` is the exact string the [expression grammar](grammar.md) parses.
  **`mutations`** vary by `op`:
  - `set`/`increment`/`decrement`: `{target, op, source: {kind: "argument", name} | {kind: "literal", value}}`.
  - `append`: `{target, op, fields: {<elementField>: <argName or literal text>}}` — no `source` key.
    A bare word names an argument; anything else (already `#inspect`-formatted) is a literal.
- **value_object**: `{name, attributes, invariants, closed_set, members}`. `closed_set: true` means
  the value object was declared with `one_of`; `members` is then a list of *rows*, each row a list
  of `[fieldName, value]` pairs (a whole admitted combination, not a per-field enum) — empty for
  every non-closed value object, and legitimately empty for a closed one that admits nothing yet.
- **query**: `{name, description, wheres, attributes, order_by, limit}`. `wheres` is a list of
  `{field, op, value}` — `op` is one of `Vocabulary::QueryComparator`'s eight members. `value` is
  either a kwarg reference (`":ceiling"`, resolved from the query's own arguments at call time) or a
  literal, stringified the same way a command's `set`-mutation literal is (see
  `docs/porting/behavior-notes.md`'s literal-encoding section for why that stringification exists
  and what it costs). `order_by` is `{field, direction}` or `null`; `limit` similarly names a field
  or literal count.
- **entity**: same shape as an aggregate, one level down (it can itself declare `commands`/`queries`
  of the same two shapes above), reached via an aggregate attribute typed as the entity's name with
  `list: true`.

## 2. The parity corpus — the runtime conformance target

`spec/parity/*.json` is a **script**, not a set of assertions:

```json
{
  "name": "pizzas-parity",
  "note": "free-text rationale for what this script is trying to exercise",
  "steps": [
    { "verb": "Pizzas::Pizza.CreatePizza", "args": { "id": "pizza-parity", "name": {"value": "Margherita"}, ... } },
    { "query": "Pizzas::Pizza.Available", "args": {} }
  ]
}
```

Every step is either a command dispatch (`verb` + `args`) or a query (`query` + `args`); `args`
values that are value-object-typed are nested objects matching that value object's own `attributes`
shape (confirmed above), not flat scalars. **There is no per-step expected-value field anywhere in
these files.** Conformance isn't "does step 7 return X" — it's "does running the *whole script*
produce the same full output as the reference runtime." Scripts deliberately include refusal-path
steps (empty names, negative amounts, non-numeric arguments, references to nonexistent records,
undeclared enum members) specifically because a runtime that *accepts* what the other refuses is the
failure most worth catching — not just the happy path.

One optional top-level key, present on some scripts (`banking.json` uses it, `pizzas.json` doesn't):
`expectations: {event_names: [...], refusals: [{verb, includes}], instances: {"Domain::Aggregate#id": {field: value}}}`.
This is **not** part of the cross-runtime comparison — it's a self-check `bin/run` performs once,
against its own execution, aborting if the script doesn't actually exercise what it claims to (e.g.
"this script must cause at least one `TransferCredited` event" or "this refusal's message must
contain this substring"). Useful as a guard against a script silently degrading to a no-op over
time; not a mechanism a third implementation needs to reproduce, only to be aware exists.

## 3. `bin/parity`'s actual comparison algorithm

For each domain, in order (any stage failing stops that domain and reports which):

1. **IR parity.** `bin/ir <domain>` (Ruby) and `hecksagain --dump <bluebook>` (Rust) each produce an
   IR JSON; both piped through `bin/canonicalise`, then `diff -u`.
2. **Behavior parity.** `bin/run <domain> <script>` executes every step against a fresh runtime and
   emits one JSON object: `{instances, events, refusals, reactions, sagas, queries}` — `instances`
   keyed `"Domain::Aggregate#id" → state`, `events` as `{name, aggregate, id, payload}`, `refusals`
   as `{verb, error}` (the **exact** exception message), `queries` as `{query, args, rows}` or
   `{query, args, error}`. Ruby and Rust each produce this once, both canonicalized, then `diff -u`.
   Before that diff runs, a **SILENT guard** checks each runtime's `events` list is non-empty — two
   runtimes that refuse every single step "agree" vacuously, and that guard exists because exactly
   this happened once (a script reported AGREED while exercising no domain logic at all).
3. **History parity.** The append-only persistence log each runtime wrote (`bin/history`),
   canonicalized and diffed the same way.
4. **Store parity.** Whatever rows each runtime's adapter actually persisted (`bin/stores`),
   canonicalized and diffed — only run when either side produced rows (in-memory-only domains
   produce none).

**The one and only normalization rule, anywhere in this pipeline**: `bin/canonicalise` recursively
sorts JSON object keys and nothing else (`bin/canonicalise` is nine lines — read it, it really is
just a key sort). Key order isn't semantics, so normalizing it away is correct; **event order,
final state, and refusal wording all have to match on their own, byte for byte.** This is the single
most important fact for a new implementation to internalize: an error message's exact text is part
of the contract, not incidental prose — `docs/porting/behavior-notes.md` documents several places
where the Rust side deliberately reimplements a piece of Ruby formatting (`#inspect`-style
quoting, sorted argument-name lists) specifically because this diff is byte-exact.

## 4. The vocabulary JSON exports — reuse, don't re-derive

`rust/src/bluebook/expression/operators.json` (the six comparison operators' `compares_less_than` /
`compares_equal` / `negated` algebra) and `rust/src/runtime/mutation_ops.json` (the four mutation
ops' arithmetic sign) are **already language-agnostic** — plain JSON, generated by `bin/operators`
and `bin/mutation_ops` from Ruby's live tables and checked equal to the `Vocabulary::Comparison` /
`Vocabulary::MutationOp` declarations in `lib/hecksagain/language/bluebook.bluebook` by
`spec/vocabulary_conformance_spec.rb`. A third implementation should embed these two files directly
(the way Rust does — `include_str!` at compile time) rather than re-deriving the tables by reading
Ruby source. Regenerate them with `bin/operators > <path>` / `bin/mutation_ops > <path>` if
`Vocabulary::Comparison`/`MutationOp` ever changes; there's no automatic staleness check beyond
`spec/operators_export_spec.rb` comparing the checked-in file against the generator's current
output, so a language without that spec's equivalent should re-run the generators as part of its own
build.
