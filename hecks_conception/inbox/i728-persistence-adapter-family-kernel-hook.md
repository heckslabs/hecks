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

## DESIGN UPDATE 2026-06-14 (Chris) — distinct adapters, not providers ; heki REQUIRES an adapter

Two decisions that supersede the providers framing above :

**1. Distinct adapter families, not one `persistence` family + `providers`.**
The declarative model is now : ONE port `behavior_kinds/back_aggregate_storage.hecksagon`
+ DISTINCT adapter families `adapter_families/{memory,heki,sqlite}.hecksagon`,
each declaring `behavior :back_aggregate_storage`. The `persistence` family file
is RETIRED. Mirrors the report-port reshape (4e547bf4 : render_report port +
distinct :markdown/:html families). No `provider:` selector — the adapter KIND
is the choice. (sqlite/postgres/mysql share the SQL output — a future `:sql`
adapter MAY nest them as providers, the one place provider-nesting earns its
keep ; today :sqlite is its own family.) DONE this session (declarative only).

**2. DEFAULT is memory + sync ; heki/sqlite are OVERRIDES that REQUIRE an adapter.**
The locked convention : a bluebook runs in-memory + sync by default ("it just
works", no adapter). heki / sqlite are overrides — they MUST be declared via
`adapter :heki` / `adapter :sqlite`. A `.world` `heki do dir` block is
per-deployment CONFIG for a DECLARED adapter ; with no `adapter :heki` in the
hecksagon it must be INERT (the domain falls back to the memory default), NOT
silently activate heki. THE GAP (Chris, 2026-06-14 : "it should not be able to
do heki without an adapter") : the runtime activates heki from world config
ALONE, bypassing the adapter. `world/attach.rs::collect_world_heki_dirs` +
`main.rs::find_world_heki_dir` read the world heki dir and force heki regardless
of any `adapter :heki`. SIX consumer sites gate the heki dir : run_serve/mod.rs:133,
world/attach.rs:128, run.rs:136 + :223, main.rs:729 + :3053 + :3693. The fix :
these must only apply when the hecksagon declares `adapter :heki` (i.e.
`hex.persistence == Some("heki")`) ; otherwise memory default.

**MIGRATION REQUIRED FIRST (so the gate doesn't break live persistence).** Four
domains have a `.world heki` block ; `correspondence` already declares
`adapter :heki` ; `plan` / `framework/tools` / `demo` do NOT — they rely on the
implicit path and `plan/.heki` holds LIVE data. They must each declare
`adapter :heki` (behavior-preserving) BEFORE the runtime gate flips, or they
lose persistence. plan has a `plan/hecksagons/` dir (per-aggregate hecksagons) —
the persistence adapter is per-domain, so placement needs a decision (a top-level
plan hecksagon vs each). This is i735-adjacent (the over-apply panic is in the
same resolution path) — do the migration + gate as ONE careful change with a
persistence smoke-test (Miette boots, plan/organs still persist), NOT a rushed
flip. Declarative model + pizzas wiring (`adapter :heki` + served `adapter :html`
report off Order.pending) landed this session ; the runtime gate + migration are
the next focused pass.
