# Packaging

Hecks features ship as separate packages — install only what you use.

## What's Available

| Package | What It Adds |
|---|---|
| `hecks` | Core: DSL, code generation, runtime, event bus, memory adapters |
| `active_hecks` | Rails: validations, forms, callbacks, railtie, generators |
| `hecks_live` | Real-time: domain events stream to browsers via Turbo Streams |
| `hecks_on_rails` | Bundles `active_hecks` + `hecks_live` |
| `hecks_sqlite` | Persistence: SQLite via Sequel |

## Rails

```ruby
gem "hecks_on_rails"
```

Brings everything: ActiveModel compat, real-time events, generators.

## Plain Ruby

```ruby
gem "hecks"
```

Core only. Add persistence with `gem "hecks_sqlite"`.

## How They Compose

```
hecks_on_rails
├── active_hecks
│   └── hecks
└── hecks_live
    └── hecks
```

Extension packages auto-wire when present. No configuration needed.

## Building and Installing Locally

Build all component gems and the meta-gem:

```bash
$ hecks gem build
Building hecksties...
Building hecks_model...
Building hecks meta-gem...
```

Build and install everything locally:

```bash
$ hecks gem install
Building hecksties...
Installed hecksties-2026.03.26.0.gem
...
Installed hecks-2026.03.26.0.gem
```

Components build in dependency order. Missing components are skipped. The build stops on the first failure.
