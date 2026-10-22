# A translation is a neutral plan, and Postgres is one compiler of it

**Status:** Proposed. Nothing is built. Date: 2026-10-16.

## Context

A data translation says how one era's stored state becomes the next era's after a shape change. Its rules are `rename`, `move`, `convert` (with a `values:` table), `drop`, `retype`, `backfill`, and two that take a raw Postgres expression: `compute ..., sql:` and `rekey sql:`.

Two things follow from the raw expressions, and one from the way the rules run.

- **The bluebook names a storage engine.** `sql: "lower(regexp_replace((__s -> 'name') ->> 'value', '\\s+', '.', 'g')) || '@example.com'"` mentions `__s`, `->>`, `::int` and `jsonb_build_object`. A translation is part of the domain's model, and the model is meant to be adapter-free: the bluebook comes first and adapters are declared in the hecksagon. A `sql:` string is an adapter detail written on the model side.
- **`compute` and `rekey` have one implementation.** `Lineage#translate` is the in-process reference for `rename`, `move`, `convert` and `drop`, and the conformance fixtures check the Postgres head view against it. Its own comment says `compute` "is not applied here — its SQL is the only implementation". The expression is audited by hand, and the Rust host, which ports the lineage SQL verbatim, has nothing to compare it with.
- **The SQL text is the contract.** The mint step compiles every rule into `hecks_tr_*` calls chained into one materialized view per aggregate per era, plus a head view. The Rust host and the Ruby adapter agree because the Rust code copies the Ruby SQL. Era translation therefore only runs on Postgres, and `Lineage` refuses to boot anywhere else.

How often the escape hatch is used matters for the size of the fix. In the repositories surveyed, the only `compute`/`rekey` translations are two: a rekey from a name to an email (`compute` and `rekey` carrying the same expression twice, because `Lineage#translate` never touches an entry's id) and a lookup that assigns three known people their addresses. One of them routes its value through an unrelated field, `status`, because `compute` always consumes its `from:` field and there is no read-without-removing primitive. No translation in a production domain uses either word; the live ones use `backfill`, `rename` and `convert`.

## Decision

1. **The parser emits a translation plan: data, not SQL.** One schema, one op list per aggregate, shared by every runtime. Each existing structured rule keeps its meaning and gets one op (`rename`, `move`, `convert`, `drop`, `retype`, `backfill`). The plan, not the SQL it compiles to, is what `ir.json` carries and what a minted era records.

2. **`compute` and `rekey` become `derive` and `rekey_to` over a closed expression vocabulary.**

   ```ruby
   aggregate "Member" do
     derive :email, from: :name, as: concat(lower(replace(name, /\s+/, ".")), "@example.com")
     rekey_to :email
   end
   ```

   - `derive` reads `from:` without consuming it, so the status workaround disappears. `drop` is how a field is removed.
   - `rekey_to` names the field whose value becomes the aggregate's id, so the expression is written once.
   - The vocabulary is pure and total: field reference, literal, `lower`, `upper`, `concat`, `replace`, `lookup` (a table with a required `else:` or a refusal for an unmapped value, the behaviour `convert` already has), `multiply`, `divide`. A word is added when a real translation needs it, with a conformance fixture, and not before.
   - There is no expression that can fail for a data-dependent reason the mint step cannot see, and no function with side effects.

3. **Two interpreters and one compiler read the plan.** Ruby (`Lineage#translate`) and Rust each interpret every op in-process. The Postgres adapter compiles the plan into the existing `hecks_tr_*` chain, materialized views and head view, which stay as they are. The compiler is the only code that knows `jsonb`. It refuses at mint time an op it cannot express, instead of failing in a query.

4. **The conformance corpus is the arbiter.** A fixture is a plan plus seed rows plus the expected rows, frozen. Ruby, Rust and the Postgres compiler must all produce the expected rows, so `derive` and `rekey_to` finally have a second implementation to disagree with.

5. **Raw SQL is an adapter-scoped escape hatch, not a bluebook word.** A translation that needs an expression the vocabulary lacks declares it in the hecksagon, under the Postgres adapter, with `via: :sql`. A plan holding such an op cannot run on another adapter, and `model_check` says so before mint. `sql:` on `compute` and `rekey` is removed from the bluebook language.

6. **Existing eras are not rewritten.** A minted era stores the compiled SQL it was minted with, and the lineage hash covers it. The two translations that use `compute`/`rekey sql:` are rewritten once, as ordinary new translations; the other live translations need no edit.

## Consequences

- A translation reads as part of the model and runs on any adapter that implements the plan interpreter, which makes a non-Postgres adapter for era translation possible for the first time.
- The Rust host stops copying SQL from Ruby and implements the same plan, tested against the same corpus.
- One more representation (the plan) and one more compiler path to keep honest; the corpus is what keeps it honest.
- The vocabulary is a ceiling. A translation that needs more than it offers uses the hecksagon escape hatch, which is more friction than writing `sql:` today. With two real uses on record, that is the intended trade.
- Open question: whether `lookup` should be a `convert` with a computed source, folding two words into one.
