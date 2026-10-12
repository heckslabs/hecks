# An adapter declares its defaults

**Status:** Accepted. Built: the `.adapter` language, the framework step and the five persistence adapters. Date: 2026-10-12.

## Context

A `.adapter` file named the settings a world could give an adapter (`field :dir`, `field :database`) and nothing
else. What each setting meant when the world gave none lived in Ruby, one copy to an adapter: Heki's `setting(settings,
:dir, "data")`, Lambda's `"us-east-1"`, Sqlite's `"data/#{table}.db"`. Five adapters carried the same five-line helper
that read a setting under its Symbol key, then its String key, then a default.

Two things were wrong with that. A default is a fact about the adapter's configuration, so it belongs where the
configuration is declared, not in the code that reads it. And the String-key half of the helper served a case the
framework never produces: settings reach an adapter through `RepositoryFactory.adapter_settings`, after
`check_settings` has judged every key as a Symbol, so a String-keyed setting is refused as undeclared before an adapter
sees it. Only one spec, written for Lambda, passed one directly.

## Decision

Every decision says which side it is on.

1. **Bluebook (the adapter language): a field may declare `default:`.** `field :dir, default: "data"` in a `.adapter`
   file. The grammar row is `named: "default"`, `kind: "literal"`, the same shape `attribute` already uses. The
   `AdapterField` value object carries the default; `AdapterFieldDefault` admits a string only if every `{...}` in it
   names a placeholder the framework fills.
2. **Bluebook: the placeholders are `{name}` and `{storage_name}`.** They are filled from the aggregate the adapter is
   built for, so Sqlite declares `field :database, default: "data/{storage_name}.db"`. The rule is the attribute's
   `pattern:`, not code, so the adapter language refuses any other placeholder when the adapter is declared.
3. **Framework: defaults are laid under the world's settings in one place.** `Registry#with_adapter_defaults` is called
   by `RepositoryFactory.adapter_settings` after the settings are checked. A world's own value wins. A field a world
   writes as `:default` asks for the declared default, so it is dropped and the default shows through. This replaces
   Heki's own `dir: :default` handling.
4. **Adapters read what they declared.** `settings[:dir]`, not a helper and not a fallback. The Symbol-or-String helper is
   gone from all five adapters, and an adapter no longer reads a String-keyed setting.
5. **Rust: the generated grammar table gains the new argument row.** `rust/parser/src/keywords.rs` is projected from the
   adapter language by `language_run.project_parser_table`. Rust reads the row; it does not yet act on an adapter's
   defaults, because it builds no adapters from `.adapter` files.

## Not decided here

- **`domain` still defaults to the aggregate's name** in an adapter built directly (`settings.fetch(:domain) { aggregate.name }`).
  The framework always passes `domain:`, so the fallback serves only direct construction, which tests and fixtures
  use. Removing it means every such call site passing `domain:` explicitly.
- **The rehearsal adapter's settings** (`drop_after`, `allow_remote`) keep their defaults in Ruby for now.
- **The two other `setting` readers** (`postgres/shared_connection.rb` returns a string; `postgres_era` takes a
  `default:` keyword) are separate semantics, left as they are.

## Consequences

- A new adapter declares its defaults in its `.adapter` file and reads plain keys. Nothing to include or call.
- An adapter built directly, outside the framework, gets no declared defaults: it must be given every setting it
  reads. Specs that built Heki or Lambda with no `dir` or `region` relied on the Ruby fallback; the behaviour they
  checked is now tested where it lives (`spec/adapter_defaults_spec.rb`).
- **Breaking** for anyone who built an adapter directly with String-keyed settings, or called Lambda's public `setting`.
