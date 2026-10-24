# An adapter provides capabilities, and a ledger says which dialects compile

**Status:** Accepted. Built on this branch, not released. Date: 2026-10-24. Extends [0119](0119-a-package-declares-its-own-capabilities.md) (chapter `provides`) to adapters, and [0118](0118-a-translation-is-a-neutral-plan-and-postgres-compiles-it.md) (a translation is a neutral plan) with a ledger of how each rule kind compiles.

## Context

Hecks is asked to stand in for an object-relational mapper. Some of what that needs can be done in one SQL statement on Postgres or Sqlite and only record by record in memory: a set-oriented update, a filter pushed into the store, an era's rewrite of every row. The runtime had no way to ask which kind of adapter it holds, so a caller either assumed SQL or never used it.

- `provides` was a chapter word only (`bluebook.bluebook`). An `.adapter` file said its port, fields, secrets and plugin queries, but nothing about what it can do.
- The operator admission ledger (`lib/hecks/grammar/expression_operators.json`) gives each operator a `ruby` rendering and, for most, a `rust` one. It says nothing about SQL, so nothing could say whether an expression can be pushed into a store.
- `Translation::RuleCompiler` held the Postgres form of every translation rule as Ruby string building. The translation chapter's `Rule` aggregate already has one execution per target, but no ledger fills it, so the chapter and the compiler could drift.

## Decision

1. **An adapter says what it provides.** The adapter language gains `provides "<capability>"`, admitted through `language_run` like every other word. A capability is a snake_case name (`set_transform`), stored on the adapter and exported in its IR beside its fields. `Registry#adapter_provides?(domain, aggregate, capability)` answers whether the persistence adapter the aggregate is bound to (through `BindingPolicy`, the same resolution a repository uses) declares it. The Postgres, Sqlite and PostgresEra persistence adapters declare `provides "set_transform"`: each can rewrite every row of an aggregate in one statement. Memory and Heki declare nothing, so a caller falls back to record-by-record work.
2. **The operator ledger renders each operator in `postgres` and `sqlite`.** The new rows are appended `Render` steps, replayed by `spec/operator_conformance_spec.rb` as before. An operator a dialect cannot express the way Ruby means it gets no rendering there: `.match?` has none in either (Postgres regular expressions are not Ruby's, and Sqlite has no built-in matcher), and `.split` has none in Sqlite. `Hecks::Grammar.compiles_for?(canonical, dialect)` is true exactly when every operator the canonical text evaluates through has a rendering for that dialect. It walks the evaluator's own parse (`operators_in`, which now names every suffix and call operator, not only the combinators), and text the grammar does not recognise falls back to a lookup no store can read, so it is not compilable.
3. **The translation ledger says how every rule kind executes.** `lib/hecks/grammar/translation_rules.json` proposes each `Rule.Kind`, gives it a `postgres`, a `sqlite` and an `in_process` execution, and admits it, replayed through the translation chapter's own commands. A Postgres execution is a template with `%{name}` holes. `RuleCompiler` reads its Postgres templates from the replayed ledger and fills them, so its output is unchanged; the era specs prove it. Sqlite executions are written down but not run: eras on Sqlite are a separate decision ([0122](0122-eras-beyond-postgres.md)).

## Alternatives considered

- **A closed set of adapter capabilities in the vocabulary.** It would catch a misspelt name at build. Rejected for now, as 0119 rejected it for chapters: the reader that asks for a capability is the one that knows its name, and an unknown name reads as not provided.
- **Ask the adapter class (`respond_to?(:update_all)`).** It is how saga persistence is found today, but it is mechanism, not a declared fact; the IR and the Rust host cannot see it. Rejected.
- **Generate `RuleCompiler` from the ledger.** A projection would be one more generated file to keep in step. Reading the ledger at load costs one replay of a small chapter. Rejected.

## Consequences

- The Adapter chapter's stored shape gains `provides`, so a database holding the launcher's eras needs the empty edge `lib/hecks/hecks/translations/2-75cc28.bluebook` (an added list explains itself).

- A new SQL-capable adapter says so in its `.adapter` file; nothing in the runtime names it.
- Admitting an operator now raises the question of its SQL forms. Leaving them out is allowed and means the operator keeps an expression out of the store.
- A change to a Postgres translation form is a ledger row change, checked by the era specs that compare compiled SQL with the in-process rewrite.
