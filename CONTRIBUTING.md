# Contributing to Hecks

## Setup

```bash
git clone https://github.com/chrisyoung/hecks.git
cd hecks
bundle install
bundle exec rspec          # 1170+ specs, under 1 second
ruby -Ilib examples/pizzas/app.rb  # smoke test
```

## Rules

- **No file over 200 lines of code** — doc comment headers don't count. Extract by concern when approaching it.
- **Tests must run under 1 second** — enforced by pre-commit hook. Adjust with `SPEC_SPEED_LIMIT=2`.
- **Every lib file has a doc comment header** — class name, purpose, usage example.
- **Memory adapters for tests** — fast, isolated, no database setup.
- **Cross-component requires use `require`, not `require_relative`** — enforced by pre-commit hook.
- **CalVer versioning** — YYYY.MM.DD.N.

## Workflow

1. Create a branch from `main`
2. Write code and specs
3. Run `bundle exec rspec` — all must pass under 1 second
4. Run `ruby -Ilib examples/pizzas/app.rb` — smoke test
5. Check file sizes: `find lib -name "*.rb" -exec wc -l {} + | sort -rn | head -5`
6. Update `FEATURES.md` if you added a new feature
7. Add `docs/usage/<feature>.md` with runnable examples
8. Open a pull request

---

## Architecture

Hecks is a monorepo. Each directory is a component with its own `lib/`:

```
hecks/
├── bluebook/          # DSL grammar, IR node types, builders, validators, generators
├── hecksagon/         # Hexagonal infra: ACL, adapters, gates, strategic DSL
├── hecksties/         # Core kernel: autoloads, utils, runtime, extensions, CLI, conventions
├── hecks_targets/     # Code generators
│   ├── ruby/          #   Static Ruby target
│   └── go/            #   Static Go target
├── hecks_workshop/    # Interactive REPL, web explorer, playground
├── hecks_ai/          # MCP server, AI domain modeling tools
├── hecks_on_rails/    # Rails integration (ActiveHecks, HecksLive)
├── lib/hecks.rb       # Meta-gem loader (adds all sub-gem lib/ dirs to $LOAD_PATH)
├── examples/          # Working example apps
├── docs/usage/        # Feature documentation (one file per feature)
└── skills/            # Agent skills (custom + third-party)
```

### How loading works

`lib/hecks.rb` adds every `*/lib` directory to `$LOAD_PATH`, then loads `hecksties/lib/hecks.rb` which sets up autoloads via `hecksties/lib/hecks/autoloads.rb`.

### Key namespaces

| Namespace | Location | Purpose |
|---|---|---|
| `Hecks` | `hecksties/lib/hecks.rb` | Top-level module, boot, configure, registries |
| `Hecks::DomainModel::Structure` | `bluebook/` | IR types: Domain, Aggregate, ValueObject, Entity, Attribute |
| `Hecks::DomainModel::Behavior` | `bluebook/` | IR types: Command, Event, Policy, Lifecycle, Workflow |
| `Hecks::DSL` | `bluebook/` | Builders: DomainBuilder, AggregateBuilder, CommandBuilder |
| `Hecks::Generators` | `bluebook/` | Code generators for domain classes, SQL, infrastructure |
| `Hecks::Runtime` | `hecksties/` | Command bus, event bus, repositories, middleware |
| `Hecks::Conventions` | `hecksties/` | Data contracts, naming helpers |
| `Hecks::Utils` | `hecksties/` | Shared utilities (sanitize_constant, underscore, humanize) |

---

## How to: Add a new DSL keyword

Example: adding `annotation` to aggregates.

### 1. Add the IR node

Create a struct in `bluebook/lib/hecks/domain_model/structure/` or `behavior/`:

```ruby
# bluebook/lib/hecks/domain_model/structure/annotation.rb
Annotation = Struct.new(:name, :text, keyword_init: true)
```

Register it in the parent module's autoload file.

### 2. Add it to the aggregate (or domain) IR

Edit the Aggregate struct to include an `annotations` field:
- `bluebook/lib/hecks/domain_model/structure/aggregate.rb`

### 3. Add the DSL builder method

Edit the aggregate builder to handle the new keyword:
- `bluebook/lib/hecks/dsl/aggregate_builder.rb` — add a method like `def annotation(name, text:)`

The builder must also be listed in `HANDLE_METHODS` in the grammar if using the implicit DSL.

### 4. Add validation rules (optional)

- `bluebook/lib/hecks/validation_rules/` — add a new rule class or extend an existing one
- Rules implement `call(domain)` returning `[errors, warnings]`

### 5. Update generators

- `bluebook/lib/hecks/generators/domain/` — Ruby class generators
- `hecks_targets/hecks_static/` — static Ruby target
- `hecks_targets/go_hecks/` — static Go target
- If the concept appears in the UI: `hecks_workshop/explorer/`

### 6. Add a data contract (if cross-target)

If the concept must render identically in Ruby and Go:
- `hecksties/lib/hecks/conventions/` — add a `*_contract.rb`
- Templates consume contract methods, never inline logic

### 7. Write specs

- Spec file mirrors lib path: `bluebook/spec/` or `hecksties/spec/`
- Use memory adapters, inline domain definitions
- Must run under 1 second total

### 8. Update docs

- `FEATURES.md` — add a bullet
- `docs/usage/<feature>.md` — runnable example
- `docs/usage/dsl_reference.md` — if it's a DSL keyword

---

## How to: Add a new CLI command

### 1. Create the command file

```ruby
# hecksties/lib/hecks_cli/commands/my_command.rb
Hecks::CLI.register_command(:my_command, "Description of what it does",
  options: { verbose: { type: :boolean, desc: "Verbose output" } },
  args: ["NAME"]
) do |name|
  # Command body — `say`, `domain`, `write_or_diff` helpers available
  say "Hello #{name}", :green
end
```

That's it — `register_command` auto-registers it in the CLI. One file per command.

### 2. The file is auto-discovered

CLI commands in `hecksties/lib/hecks_cli/commands/` are loaded automatically. No autoload entry needed.

---

## How to: Add a new extension

### 1. Register it

```ruby
# hecksties/lib/hecks/extensions/my_extension.rb
Hecks.register_extension(:my_extension) do |domain_mod, domain, runtime|
  # Wire your extension into the runtime
  runtime.use :my_extension do |command, next_handler|
    # middleware logic
    next_handler.call
  end
end
```

### 2. Users activate it

```ruby
Hecks.boot(__dir__) { extend :my_extension }
```

Or add `gem "hecks_my_extension"` to Gemfile for auto-wiring.

---

## How to: Add a new runtime method

### 1. Edit Runtime

- `hecksties/lib/hecks/runtime.rb` — add public method

### 2. If it needs a new class

- Create the file in `hecksties/lib/hecks/`
- Add autoload entry in `hecksties/lib/hecks/autoloads.rb`
- Write spec in `hecksties/spec/`

---

## How to: Add a new data contract

Contracts live in `hecksties/lib/hecks/conventions/`. They ensure Ruby and Go targets produce identical output.

### 1. Create the contract

```ruby
# hecksties/lib/hecks/conventions/my_contract.rb
module Hecks::Conventions
  module MyContract
    def self.some_rule(input)
      # deterministic transformation
    end
  end
end
```

### 2. Use it in templates

Both Ruby and Go generators call the contract method. Never inline the logic in a template.

### 3. Write specs

Test that the contract produces expected output for representative inputs.

---

## How to: Add a new generator target

### 1. Create the directory

```
hecks_targets/my_lang/
  lib/
    my_lang_hecks/
      generator.rb      # main entry point
      templates/         # ERB or string templates
  spec/
```

### 2. Register it

Use `Hecks.register_target(:my_lang) { |domain| MyLangHecks::Generator.new(domain).generate }` or call it directly.

### 3. Add a CLI command

```ruby
# hecksties/lib/hecks_cli/commands/build_my_lang.rb
Hecks::CLI.register_command(:build_my_lang, "Generate MyLang from domain") do
  domain = resolve_domain
  MyLangHecks::Generator.new(domain).generate
end
```

---

## How to: Modify the command lifecycle

The pipeline is defined in `hecksties/lib/hecks/mixins/command/lifecycle_steps.rb`:

```ruby
PIPELINE = [
  GuardStep, HandlerStep, PreconditionStep, CallStep,
  PostconditionStep, PersistStep, EmitStep, RecordStep
].freeze
```

Each step is a lambda. To add a step:

1. Define it as a lambda in `lifecycle_steps.rb`
2. Insert it at the right position in `PIPELINE`
3. Add the corresponding private method in `hecksties/lib/hecks/mixins/command.rb`

To hook in without modifying the pipeline, use **command bus middleware** via `runtime.use`.

---

## How to: Add a persistence adapter

### 1. Implement the adapter interface

Every adapter must implement: `find(id)`, `all`, `count`, `save(entity)`, `delete(id)`, `where(**conditions)`, `clear`.

### 2. Register it

```ruby
Hecks.register_extension(:my_db) do |mod, domain, runtime|
  domain.aggregates.each do |agg|
    repo = MyDbAdapter.new(agg)
    runtime.swap_adapter(agg.name, repo)
  end
end
```

### 3. Users activate it

```ruby
Hecks.boot(__dir__, adapter: :my_db)
```

---

## File checklist for common changes

| Change | Files to update |
|---|---|
| New DSL keyword | IR struct, builder, HANDLE_METHODS, generators (Ruby + Go), validator, specs, FEATURES.md, docs/usage/ |
| New CLI command | `hecksties/lib/hecks_cli/commands/<name>.rb`, spec |
| New extension | `hecksties/lib/hecks/extensions/<name>.rb`, spec, FEATURES.md |
| New runtime method | `hecksties/lib/hecks/runtime.rb`, spec, FEATURES.md, docs/usage/ |
| New autoloaded class | New file, autoload entry in `hecksties/lib/hecks/autoloads.rb`, spec |
| New data contract | `hecksties/lib/hecks/conventions/<name>_contract.rb`, update templates, spec |
| New validation rule | `bluebook/lib/hecks/validation_rules/`, register in validator, spec |
| New example app | `examples/<name>/`, Bluebook + app.rb + Hecksagon (if needed) |
| Rename/restructure | See `skills/hecks-rename-playbook/SKILL.md` for full checklist |

---

## Pre-commit hooks

The hook at `.git/hooks/pre-commit` (symlinked to `bin/pre-commit`) runs:

1. `bundle exec rspec` — must pass under 1 second
2. `HecksWatchers::CrossRequire` — blocks if `require_relative` crosses component boundaries
3. `HecksWatchers::FileSize` — warns at 180 lines
4. `HecksWatchers::Autoloads` — warns if new files aren't in autoloads
5. `HecksWatchers::SpecCoverage` — warns if lib files lack specs
6. `HecksWatchers::DocReminder` — warns if FEATURES.md/CHANGELOG not updated

CrossRequire blocks the commit. Everything else is advisory.

---

## Naming conventions

Use `Hecks::Utils` and `Hecks::Conventions::Names` — never inline string transforms:

| Need | Use |
|---|---|
| PascalCase from any string | `Hecks::Utils.sanitize_constant(name)` |
| snake_case from PascalCase | `Hecks::Utils.underscore(name)` |
| Human readable from PascalCase | `Hecks::Utils.humanize(name)` |
| Short class name from `A::B::C` | `Hecks::Utils.const_short_name(obj)` |
| Domain module name | `Hecks::Conventions::Names.domain_module_name(name)` |
| Domain gem name | `Hecks::Conventions::Names.domain_gem_name(name)` |
| Aggregate slug (pluralized) | `Hecks::Conventions::Names.domain_aggregate_slug(name)` |

---

## Reporting Issues

Use [GitHub Issues](https://github.com/chrisyoung/hecks/issues). Include:
- What you expected
- What actually happened
- Steps to reproduce
- Ruby version and OS
