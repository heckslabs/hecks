# i728 — persistence adapter family: Phase-2 kernel-hook wiring

`feat/sqlite-persistence-adapter` made `adapter :sqlite, db:` real (the runtime
builds a typed SQL table per aggregate and routes the Repository through it) and
authored the bluebook-first CONTRACT for it:
`framework/adapter_families/persistence.hecksagon` (fields, providers
`:memory/:heki/:sqlite/:postgres/:mysql`, behavior `back_aggregate_storage`).

But the runtime SEAM is hand-wired, not driven by the family registry. The
selection lives in `Runtime::apply_sqlite_persistence`
(`rust/src/runtime/mod.rs`): it reads `hecksagon.persistence == "sqlite"` +
`persistence_option("db")` directly, rather than resolving the persistence
adapter through `FrameworkRegistry` (`rust/src/runtime/framework_registry.rs`)
the way `:tts` / `:web_tool` / `:mcp` resolve their kernel hooks.

## Why it's hand-wired (and not a defect)
The FrameworkRegistry models DRIVING adapters — ones that fire a behavior ON a
command (trigger_field → kernel hook → response cascade). Persistence is
SUBSTRATE: it backs the find/save the bus already performs, it has no trigger
command and chains into nothing (the family declares `trigger_field :none`,
`response_field :none`). The registry has no "driven backend" hook category yet;
the only seeded hook is `invoke_claude_tool`. So persistence honors the bluebook
CONTRACT (the family file is the source of truth for the declaration shape) while
the runtime selection stays a direct read.

## Fix wanted
Grow the FrameworkRegistry a "storage backend" hook category so the persistence
family's `back_aggregate_storage` behavior resolves a backend constructor by
provider name (`:sqlite`→SqliteRepository, `:postgres`/`:mysql`→future,
`:heki`/`:memory`→Repository). Then `apply_sqlite_persistence` becomes a generic
`apply_persistence` that walks the family + provider instead of branching on the
hardcoded "sqlite" string — adding `:postgres` becomes a provider hecksagon +
a backend impl, no runtime-selection edit. Also retires the kernel-floor
exemption on `ruby/hecks_persist/database_connection.rb` (its header already
names this end state: ":sql_database with :sqlite / :postgres / :mysql
sub-adapters").

## Also: postgres/mysql backends
The parser + IR now route `:postgres` / `:mysql` into persistence with their
options, and the Ruby builder mirrors it, but only `:sqlite` has a Rust backend
(`SqliteRepository`). Postgres/MySQL need their own `*Repository` impls (Sequel
already covers them on the Ruby side once i727 unblocks `SqlBoot`).
