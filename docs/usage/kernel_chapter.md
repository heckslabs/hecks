# Kernel Chapter

The Kernel chapter is a descriptive Bluebook chapter that models the bootstrap
infrastructure as aggregates. It covers the DSL builders, domain model IR,
registries, core utilities, and the chapter system itself.

## Why descriptive-only?

The kernel is the infrastructure that makes chapters possible. It cannot load
itself via chapters (chicken-and-egg), so the interpreted Ruby runtime still
uses `require_relative`. The chapter definitions prove the Bluebook covers
100% of the framework. The compiled binary (Hecks v0) will use these
definitions for chapter-dispatch loading.

## Inspecting the Kernel chapter

```ruby
require "hecks"
Kernel.load("HecksBluebook")

domain = Hecks::Chapters::Kernel.definition
puts domain.aggregates.map(&:name)
# => ["BootstrapKernel", "DomainBuilder", "AggregateBuilder", ...]
```

## Paragraphs

The Kernel chapter is organized into five paragraphs:

- **DslBuilders** — DomainBuilder, AggregateBuilder, CommandBuilder, and all
  sub-builders that parse domain definitions into IR
- **DomainModel** — Structure, Behavior, Names, and Tokenizer IR modules
- **Registries** — Registry, SetRegistry, and all specialized registries
  (extensions, capabilities, domains, targets, adapters, validations, etc.)
- **Core** — Errors, Conventions, Autoloads, ModuleDSL, CoreExtensions,
  Stats, EventSourcing, Deprecations
- **ChapterSystem** — The chapter loading infrastructure itself

## Verification

The Kernel chapter is verified by `bin/verify` alongside all other chapters:

```sh
bin/verify --verbose
# Kernel (38 aggregates, 59 commands)
#   BootstrapKernel — Root of the kernel infrastructure...
#   DomainBuilder — Top-level DSL builder...
#   ...
```
