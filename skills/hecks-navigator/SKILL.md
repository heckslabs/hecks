---
name: hecks-navigator
description: 'Navigate the Hecks domain compiler framework. Use when exploring the codebase, finding where things live, understanding the compiler pipeline, or figuring out how modules connect. Covers the bluebook DSL, hecksagon runtime, generators, CLI, workshop, AI tools, and examples.'
license: MIT
metadata:
  author: hecks
  version: "1.0.0"
---

# Hecks Codebase Navigator

Hecks is a domain compiler: you write a domain model in a Ruby DSL (Bluebook), it builds an in-memory IR (Hecksagon), and generators emit runnable code for multiple targets (Ruby, Go).

## Top-Level Layout

| Directory | Purpose |
|-----------|---------|
| `bluebook/` | DSL parser — the source-of-truth grammar for domain models |
| `hecksagon/` | Runtime IR — aggregates, value objects, commands, events, policies as live objects |
| `hecksties/` | Glue layer — `Hecks.boot`, `Hecks.domain`, CLI, multi-domain support |
| `hecks_targets/` | Code generators — `ruby/` and `go/` static targets |
| `hecks_workshop/` | Interactive workshop UI (web explorer for domains) |
| `hecks_ai/` | AI/MCP tools — domain modeling via tool calls, watcher agent |
| `hecks_on_rails/` | Rails integration — `Hecks.configure`, HecksLive/Turbo |
| `lib/hecks.rb` | Meta-gem loader — adds all sub-gem lib/ dirs to `$LOAD_PATH` |
| `examples/` | Working example apps (pizzas, banking, multi_domain, rails, sinatra) |
| `docs/` | Usage documentation, one file per feature |
| `bin/` | CLI entrypoint |

## The Compiler Pipeline

```
Bluebook DSL  →  Builders  →  Hecksagon IR  →  Generators  →  Ruby/Go code
     ↓                            ↓
  bluebook/lib/          hecksagon/lib/
  bluebook/lib/hecks/    hecksagon/lib/hecksagon/
```

1. **Write**: User defines domain in Bluebook DSL (`Hecks.domain "Pizzas" { ... }`)
2. **Parse**: `bluebook/lib/bluebook/` builders construct IR nodes
3. **Build**: `hecksagon/lib/hecksagon/structure/` holds the IR types (Aggregate, ValueObject, Command, Event, etc.)
4. **Validate**: `hecksagon/lib/hecksagon/contract_validator.rb` runs data contracts for cross-target consistency
5. **Generate**: `hecks_targets/hecks_static/` or `hecks_targets/go_hecks/` emit static code from the IR

## Key Modules

### Bluebook (DSL)
- `bluebook/lib/bluebook.rb` — entry point
- `bluebook/lib/bluebook/` — DSL blocks, builders, validators
- `bluebook/lib/hecks/` — `Hecks.domain` definition hook

### Hecksagon (Runtime IR)
- `hecksagon/lib/hecksagon.rb` — entry point
- `hecksagon/lib/hecksagon/structure/` — IR node types (Aggregate, Command, Event, Policy, ValueObject, Entity, etc.)
- `hecksagon/lib/hecksagon/dsl/` — runtime DSL for extending domains
- `hecksagon/lib/hecksagon/contract_validator.rb` — 8 data contracts
- `hecksagon/lib/hecksagon/domain_mixin.rb` — mixed into domain modules
- `hecksagon/lib/hecksagon/adapter_registry.rb` — persistence adapter registry
- `hecksagon/lib/hecksagon/acl_builder.rb` — anti-corruption layer builder

### Hecksties (Glue / CLI)
- `hecksties/lib/hecks.rb` — `Hecks.boot`, `Hecks.configure`, `Hecks.hecksagon`
- `hecksties/lib/hecks_cli.rb` — CLI framework
- `hecksties/lib/hecks_cli/` — individual CLI commands (one file each)
- `hecksties/lib/hecks_multidomain.rb` — multi-domain orchestration, FilteredEventBus

### Targets (Code Generation)
- `hecks_targets/hecks_static/` — static Ruby target generator
- `hecks_targets/go_hecks/` — static Go target generator
- Generators use `HecksTemplating::Names` for naming conventions

### Workshop (Interactive UI)
- `hecks_workshop/lib/` — web-based domain explorer
- `hecks_workshop/explorer/` — frontend assets

### AI Tools
- `hecks_ai/lib/hecks_ai.rb` — entry point
- `hecks_ai/lib/hecks_ai/mcp_server.rb` — MCP server for AI domain modeling
- `hecks_ai/lib/hecks_ai/aggregate_tools.rb` — aggregate CRUD via MCP
- `hecks_ai/lib/hecks_ai/build_tools.rb` — build/compile tools
- `hecks_ai/lib/hecks_ai/play_tools.rb` — play mode (execute commands live)
- `hecks_ai/lib/hecks_ai/session_tools.rb` — session management
- `hecks_ai/lib/hecks_ai/inspect_tools.rb` — domain inspection
- `hecks_ai/watcher_agent/` — file watcher agent

### Persistence
- `hecksagon/lib/hecks_persist.rb` — persistence layer
- `hecksagon/lib/hecks_persist/` — adapters (memory, SQL, migrations)

## Examples — Quick Reference

| Example | What it demonstrates |
|---------|---------------------|
| `examples/pizzas/` | Canonical single-domain app — aggregates, commands, events |
| `examples/banking/` | Lifecycle/state machines, domain services |
| `examples/multi_domain/` | Cross-domain events, FilteredEventBus, subscribe DSL |
| `examples/pizzas_rails/` | Rails integration with `Hecks.configure` |
| `examples/pizzas_static_ruby/` | Static Ruby target output |
| `examples/pizzas_static_go/` | Static Go target output |
| `examples/governance/` | Policy-heavy domain, specifications |
| `examples/sinatra_app/` | Sinatra integration |

## Entry Points

- **Boot an app**: `Hecks.boot(__dir__)` — loads `bluebook/` subfolder, builds IR
- **Rails config**: `Hecks.configure { domain "Pizzas", path: "..." }`
- **Run examples**: `ruby -Ilib examples/pizzas/app.rb`
- **CLI**: `bin/hecks` or `bundle exec hecks`
- **Specs**: `bundle exec rspec` (must run under 1 second)

## Conventions

- Aggregates are pure domain objects — no persistence logic
- Memory adapters for tests — fast and isolated
- CalVer versioning (YYYY.MM.DD.N)
- Module grouping: parent file with `.bind`, children in subdirectory
- CLI commands: one file each under `hecksties/lib/hecks_cli/commands/`
- Generators show a diff when a target file already exists (never silently overwrite)
- 200-line limit per lib file (doc headers excluded)
