---
name: hecks-contributor-guide
description: 'Developer workflow for contributing to the Hecks framework. Use before implementing any feature, fix, or refactor. Covers file checklists for every type of change, naming conventions, pre-commit hooks, and the full architecture map. Read CONTRIBUTING.md for the exhaustive guide.'
license: MIT
metadata:
  author: hecks
  version: "1.0.0"
---

# Hecks Contributor Guide

Before writing any code in this codebase, consult `CONTRIBUTING.md` at the project root. It contains exhaustive how-to guides for every type of change.

## Quick File Checklist

| Change | Files to update |
|---|---|
| New DSL keyword | IR struct, builder, HANDLE_METHODS, generators (Ruby + Go), validator, specs, FEATURES.md, docs/usage/ |
| New CLI command | `hecksties/lib/hecks_cli/commands/<name>.rb`, spec |
| New extension | `hecksties/lib/hecks/extensions/<name>.rb`, spec, FEATURES.md |
| New runtime method | `hecksties/lib/hecks/runtime.rb`, spec, FEATURES.md, docs/usage/ |
| New autoloaded class | New file, autoload in `hecksties/lib/hecks/autoloads.rb`, spec |
| New data contract | `hecksties/lib/hecks/conventions/<name>_contract.rb`, update templates, spec |
| New validation rule | `bluebook/lib/hecks/validation_rules/`, register in validator, spec |
| New example app | `examples/<name>/`, Bluebook + app.rb + Hecksagon (if needed) |
| Rename/restructure | See `skills/hecks-rename-playbook/SKILL.md` |

## Before Every Commit

1. Update `FEATURES.md` if new features were added
2. Add `docs/usage/<feature>.md` with runnable examples
3. `bundle exec rspec` — all must pass under 1 second
4. `find lib -name "*.rb" -exec wc -l {} + | sort -rn | head -5` — no file over 200 code lines
5. `ruby -Ilib examples/pizzas/pizzas.rb` — smoke test

## Naming — Never Inline String Transforms

| Need | Use |
|---|---|
| PascalCase | `Hecks::Utils.sanitize_constant(name)` |
| snake_case | `Hecks::Utils.underscore(name)` |
| Human readable | `Hecks::Utils.humanize(name)` |
| Short class name | `Hecks::Utils.const_short_name(obj)` |
| Domain module name | `Hecks::Conventions::Names.domain_module_name(name)` |
| Domain gem name | `Hecks::Conventions::Names.domain_gem_name(name)` |
| Aggregate slug | `Hecks::Conventions::Names.domain_aggregate_slug(name)` |

## Architecture (Quick Reference)

```
bluebook/       — DSL grammar, IR types, builders, validators, generators
hecksagon/      — Hexagonal infra: ACL, adapters, gates
hecksties/      — Core kernel: autoloads, utils, runtime, extensions, CLI, conventions
hecks_targets/  — Code generators (ruby/, go/)
hecks_workshop/ — Interactive REPL, web explorer
hecks_ai/       — MCP server, AI tools
examples/       — Working apps (pizzas, banking, multi_domain, governance)
```

## Key Files by Task

### Adding a DSL concept
1. `bluebook/lib/hecks/domain_model/structure/` or `behavior/` — IR node
2. `bluebook/lib/hecks/dsl/aggregate_builder.rb` — DSL method
3. `bluebook/lib/hecks/generators/domain/` — Ruby generator
4. `hecks_targets/hecks_static/` and `hecks_targets/go_hecks/` — static targets
5. `hecksties/lib/hecks/conventions/` — data contract (if cross-target)

### Modifying the command lifecycle
- Pipeline: `hecksties/lib/hecks/mixins/command/lifecycle_steps.rb`
- Step methods: `hecksties/lib/hecks/mixins/command.rb`
- Alternative: use middleware via `runtime.use` (no pipeline change needed)

### Adding persistence
- Interface: `find`, `all`, `count`, `save`, `delete`, `where`, `clear`
- Register via `Hecks.register_extension(:name)`
- Users activate with `Hecks.boot(__dir__, adapter: :name)`

## Rules

- Always work on feature branches, never commit directly to main
- Cross-component requires use `require`, not `require_relative`
- No backward compatibility shims — break APIs freely (no users yet)
- Generators show a diff when target file exists (never silently overwrite)
- Read `CONTRIBUTING.md` for the full guide with code examples
