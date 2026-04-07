# HecksCode Language Specification

HecksCode is a domain modeling language. The `HecksCode` module is the language specification — it exposes the syntax, compiler, runtime, type system, module system, and IO model as inspectable components.

## Usage

```ruby
require "heckscode"

HecksCode.syntax        # => { domain: [...], aggregate: [...], command: [...], ... }
HecksCode.compiler      # => { frontend: "Bluebook DSL", ir: "Hecks::DomainModel", ... }
HecksCode.runtime       # => { command_bus: "...", event_bus: "...", ... }
HecksCode.type_system   # => { primitives: ["String", "Integer", ...], ... }
HecksCode.module_system # => { unit: "Aggregate", grouping: "Chapter", ... }
HecksCode.io_model      # => { ports: "Commands", adapters: "...", ... }
HecksCode.self_hosting  # => { chapters: 15, aggregates: 670, commands: 836 }
```

## Describe

Print a human-readable summary:

```ruby
HecksCode.describe
# HecksCode v0.1.0
#
# Syntax:        46 keywords across 4 contexts
# Compiler:      Bluebook DSL → Hecks::DomainModel → ruby, go, node, rails
# Runtime:       CommandBus + EventBus + Repositories + Middleware
# Type system:   9 primitives, collections, references, enums, computed
# Module system: Aggregate → Chapter → Paragraph → Domain
# IO model:      Commands (ports) + Adapters (behavior)
# Self-hosting:  15 chapters, 670 aggregates, 836 commands
```

## Full Spec

Get everything as a single hash:

```ruby
HecksCode.spec
# => { syntax: {...}, compiler: {...}, runtime: {...},
#      type_system: {...}, module_system: {...}, io_model: {...},
#      self_hosting: {...} }
```

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
