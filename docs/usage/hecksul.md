# HecksUL Language Specification

HecksUL (Ubiquitous Language) is a domain modeling language. Every Hecks domain is its own executable business language — the Bluebook defines the grammar, aggregates are types, commands are operations, and generated specs are the type checker.

## Usage

```ruby
require "hecksul"

HecksUL.syntax        # => { domain: [...], aggregate: [...], command: [...], ... }
HecksUL.compiler      # => { frontend: "Bluebook DSL", ir: "Hecks::DomainModel", ... }
HecksUL.runtime       # => { command_bus: "...", event_bus: "...", ... }
HecksUL.type_system   # => { primitives: ["String", "Integer", ...], ... }
HecksUL.module_system # => { unit: "Aggregate", grouping: "Chapter", ... }
HecksUL.io_model      # => { ports: "Commands", adapters: "...", ... }
HecksUL.self_hosting  # => { chapters: 15, aggregates: 670, commands: 836 }
```

## Describe

Print a human-readable summary:

```ruby
HecksUL.describe
# HecksUL v0.1.0
#
# Syntax:        46 keywords across 4 contexts
# Compiler:      Bluebook DSL → Hecks::DomainModel → ruby, go, node, rails
# Runtime:       CommandBus + EventBus + Repositories + Middleware
# Type system:   9 primitives, collections, references, enums, computed
# Module system: Aggregate → Chapter → Paragraph → Domain
# IO model:      Commands (ports) + Adapters (behavior)
# Self-hosting:  15 chapters, 670 aggregates, 836 commands
```

## Domains as Languages

Every Hecks domain is its own language:

- **PizzasBluebook** defines PizzasUL — a language for pizza ordering
- **LoansBluebook** defines LoansUL — a language for loan processing
- The generated specs are each language's type checker
- The runtime is each language's interpreter

HecksUL is the meta-language that defines how these business languages work.

## Sections

| Method | Returns |
|--------|---------|
| `syntax` | Keywords organized by context (domain, aggregate, command, value_object, entity) |
| `compiler` | Frontend, IR, backends, loader |
| `runtime` | CommandBus, EventBus, repository, middleware, adapters |
| `type_system` | Primitives, collections, references, enums, computed, validations, invariants, contracts |
| `module_system` | Aggregate → Chapter → Paragraph → Domain hierarchy |
| `io_model` | Ports (commands), adapters (behavior modules), built-in adapters |
| `self_hosting` | Live chapter/aggregate/command counts from Hecks's own Bluebook definitions |

## Self-Hosting

The `self_hosting` method loads all 15 Bluebook chapters that define Hecks itself and counts the aggregates and commands. This is live proof that the language is expressive enough to describe its own implementation.
