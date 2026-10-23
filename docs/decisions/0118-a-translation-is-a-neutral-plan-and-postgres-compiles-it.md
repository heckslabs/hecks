# A translation is a neutral plan, and Postgres is one compiler of it

**Status:** Accepted, partly built. Built: the plan schema (`Bluebook::TranslationPlan`, `Translation#to_plan`); `derive` with its expression language and `rekey_to`, interpreted in Ruby and compiled to Postgres; `examples/directory`'s edge rewritten with them; and the removal of `compute` and `rekey sql:` together with the approval machinery they required, planned for 4.0.0 and live on `edge`. Not built: the hecksagon escape hatch for SQL, which nothing uses yet. Date: 2026-10-16.

## Context

A data translation says how one era's stored state becomes the next era's after a shape change. Its rules are `rename`, `move`, `convert` (with a `values:` table), `drop`, `retype`, `backfill`, and two that take a raw Postgres expression: `compute ..., sql:` and `rekey sql:`.

Two things follow from the raw expressions, and one from the way the rules run.

- **The bluebook names a storage engine.** `sql: "lower(regexp_replace((__s -> 'name') ->> 'value', '\\s+', '.', 'g')) || '@example.com'"` mentions `__s`, `->>`, `::int` and `jsonb_build_object`. A translation is part of the domain's model, and the model is meant to be adapter-free: the bluebook comes first and adapters are declared in the hecksagon. A `sql:` string is an adapter detail written on the model side.
- **`compute` and `rekey` have one implementation.** `Lineage#translate` is the in-process reference for `rename`, `move`, `convert` and `drop`, and the conformance fixtures check the Postgres head view against it. Its own comment says `compute` "is not applied here — its SQL is the only implementation". The expression is audited by hand, and the Rust host, which ports the lineage SQL verbatim, has nothing to compare it with.
- **The SQL text is the contract.** The mint step compiles every rule into `hecks_tr_*` calls chained into one materialized view per aggregate per era, plus a head view. The Rust host and the Ruby adapter agree because the Rust code copies the Ruby SQL. Era translation therefore only runs on Postgres, and `Lineage` refuses to boot anywhere else.

How often the escape hatch is used matters for the size of the fix. In the repositories surveyed, the only `compute`/`rekey` translations are two: a rekey from a name to an email (`compute` and `rekey` carrying the same expression twice, because `Lineage#translate` never touches an entry's id) and a lookup that assigns three known people their addresses. One of them routes its value through an unrelated field, `status`, because `compute` always consumes its `from:` field and there is no read-without-removing primitive. No translation in a production domain uses either word; the live ones use `backfill`, `rename` and `convert`.

## Decision

1. **The parser emits a translation plan: data, not SQL.** One schema, one op list per aggregate, shared by every runtime. Each existing structured rule keeps its meaning and gets one op (`rename`, `move`, `convert`, `drop`, `retype`, `backfill`). The plan, not the SQL it compiles to, is what `ir.json` carries and what a minted era records.

2. **`compute` and `rekey` become `derive` and `rekey_to` over a closed expression language.**

   ```ruby
   aggregate "Member" do
     derive :email, as: 'concat(lower(replace(name.value, " ", ".")), "@example.com")'
     rekey_to :email
   end
   ```

   - The expression is text in a small language of its own, parsed to a tree of plain arrays that is also its plan form. Writing it as text keeps the builder free of expression methods, and gives the Ruby and Rust sides one thing to read.
   - `derive` reads the record as stored, so it runs before every other rule and sees the held era's shape. It does not consume what it reads, so the `status` workaround disappears; `drop` removes a field.
   - `rekey_to` names the field whose value becomes the aggregate's id, so the expression is written once. A record where the derive has no value keeps its id. Like `derive` it is pure and needs no approval, and `Lineage#translate` changes the id in process.
   - The language is pure and total: a field reference reads a stored text value (anything else has no value), a literal, `null`, `lower`, `upper` (ASCII only), `concat`, `replace` (plain text, never a pattern), and `lookup` (a table plus a fallback that is a string or `null`). A function with a valueless argument has no value, and a record where the whole expression has no value gets no new field.
   - Arithmetic (`multiply`, `divide`) is not in the first version. Ruby and Postgres disagree on what `100 / 100` is and how a decimal prints as JSON, so adding it needs a number model both can honour first.
   - Case folding is ASCII only and `replace` is not a pattern because Postgres's `lower` follows the database collation and its patterns are POSIX; either would let the in-process rewrite and the head disagree on a record.
   - A derive needs no approval gate. It is pure, so unlike `compute` and `rekey` it has nothing a person must sample, and it is left out of what an approval digests.

3. **One interpreter and one compiler read the plan; the Rust host runs what Ruby compiled.** Ruby (`Lineage#translate`) interprets every op in process. The Postgres adapter compiles the plan into the existing `hecks_tr_*` chain, materialized views and head view, which stay as they are. The Rust host does not interpret rules: it reads the compiled expression Ruby exports and runs it in Postgres, and its build pass refuses any rule it has not ported. A Rust interpreter would be a second implementation to hold to the corpus, and is built only when a Rust path needs to translate without Postgres. The compiler is the only code that knows `jsonb`. It refuses at mint time an op it cannot express, instead of failing in a query.

4. **The conformance corpus is the arbiter.** A fixture is a plan plus seed rows plus the expected rows, frozen. The Ruby interpreter and the Postgres compiler must both produce the expected rows, so `derive` and `rekey_to` finally have a second implementation to disagree with. `spec/adapters/driven/postgres_era/derive_equivalence_spec.rb` does this for `derive` today.

5. **Raw SQL is removed, not moved.** `sql:` on `compute` and `rekey` is gone from the bluebook language, and the approval, audit-sampling and rehearsal-gating machinery that existed only to review such edges is deleted with it. An adapter-scoped escape hatch in the hecksagon is not built: nothing in the corpus needs one, and it can be added when a translation does. Arithmetic and pattern matching are the likely first needs.

6. **Existing eras are not rewritten.** A minted era stores the compiled SQL it was minted with, and the lineage hash covers it. The two translations that use `compute`/`rekey sql:` are rewritten once, as ordinary new translations; the other live translations need no edit.

## Consequences

- A translation reads as part of the model and runs on any adapter that implements the plan interpreter, which makes a non-Postgres adapter for era translation possible for the first time.
- The Rust host keeps running the SQL Ruby compiles; a Rust interpreter of the plan is a later step, built when something needs to translate without Postgres.
- One more representation (the plan) and one more compiler path to keep honest; the corpus is what keeps it honest.
- The vocabulary is a ceiling. A translation that needs more than it offers uses the hecksagon escape hatch, which is more friction than writing `sql:` today. With two real uses on record, that is the intended trade.
- Open question: whether `lookup` should be a `convert` with a computed source, folding two words into one.
