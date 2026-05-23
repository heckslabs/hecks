# i727 — hecks_persist is broken by stale `domain_*` naming refs (rename drift)

The Ruby Sequel persistence library (`ruby/hecks_persist/`) references the
PRE-rename naming API throughout: `domain_module_name`, `domain_constant_name`,
`domain_snake_name`, `domain_aggregate_slug`. None of these exist anymore — the
`HecksTemplating::NamingHelpers` mixin renamed them all to `bluebook_*`
(`ruby/hecks/naming_helpers.rb`). Every entry point into the library raises
`NoMethodError`.

## Found
While building the Rust SQLite persistence adapter (feat/sqlite-persistence-adapter,
the parity counterpart), the task required proving the Ruby Sequel layer persists
identically. `SqlBoot.setup(domain, db)` died at `sql_boot.rb:57` on
`domain_module_name`. `SqlMigrationGenerator#generate` died at
`sql_migration_generator.rb:160` on `domain_aggregate_slug`. This is the
rename-drift-wiring pattern (feedback_rename_drift_wiring): a rename left stale
references that no test gate caught, because nothing exercises hecks_persist.

## Scope (25 refs across 7 files)
- `sql_setup.rb:26` — domain_module_name
- `sql_adapter_generator.rb:45,123,130` — domain_constant_name, domain_aggregate_slug, domain_snake_name
- `sql_strategy.rb:132,144,185` — domain_aggregate_slug, domain_snake_name
- `sql_boot.rb:57,97,137,140,169` — domain_module_name, domain_constant_name, domain_snake_name, domain_aggregate_slug
- `sql_builder.rb:65,97,98,101,107,110,128,150` — domain_snake_name, domain_constant_name
- `sql_migration_generator.rb:128,160` — FIXED in this PR (the schema-DDL layer the parity proof needed)
- `sql_helpers.rb:18,27` — FIXED in this PR
- `commands/migrations.rb:52,64` — domain_module_name, domain_snake_name

## Fixed in feat/sqlite-persistence-adapter (minimal, schema-layer only)
`sql_migration_generator.rb` + `sql_helpers.rb` — the self-contained DDL
generator, so the Ruby↔Rust schema parity could be demonstrated. The map is
mechanical: `domain_module_name`→`bluebook_module_name`,
`domain_constant_name`→`bluebook_constant_name`,
`domain_snake_name`→`bluebook_snake_name`,
`domain_aggregate_slug`→`bluebook_aggregate_slug`.

## Fix wanted
Apply the same mechanical rename to the remaining 5 files
(`sql_setup`, `sql_adapter_generator`, `sql_strategy`, `sql_boot`, `sql_builder`,
`commands/migrations`) so `SqlBoot.setup` works end-to-end, then add a smoke test
(e.g. `examples/pizzas/sql_app.rb` under CI) so the drift can't recur silently.
A rename-validator gate (feedback_rename_drift_wiring) would close the loop.
