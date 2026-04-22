# Hecksagon DSL Reference

> Generated from Hecks v2026.03.31.13

Complete reference for the hexagonal architecture wiring DSL. The Hecksagon declares infrastructure concerns — gates, adapters, extensions, cross-domain subscriptions, and tenancy — separately from the domain model defined in the Bluebook.

## Overview

The Hecksagon is the infrastructure layer. The Bluebook defines *what* your domain is (aggregates, commands, events, policies). The Hecksagon defines *how* it connects to the outside world (who can access what, where data is stored, which extensions are active).

```ruby
Hecks.hecksagon do
  adapter :sqlite, database: "pizzas.db"

  gate "Pizza", :admin do
    allow :find, :all, :create_pizza, :add_topping
  end

  gate "Pizza", :guest do
    allow :find, :all
  end

  extension :audit
  subscribe "Billing"
  tenancy :row
end
```

---

## Gate

A gate is role-based access control for an aggregate. It declares which operations a specific role can perform. When a gate is active, calling a disallowed method raises an error.

Gates replace ports from the Bluebook DSL. Ports were mixed into the domain definition, but access control is an infrastructure concern — it depends on deployment context, not domain logic. The same domain might have different gates in a public API vs. an admin panel.

```ruby
gate "Pizza", :admin do
  allow :find, :all, :create_pizza, :add_topping, :delete
end

gate "Pizza", :guest do
  allow :find, :all
end

gate "Order", :customer do
  allow :find, :all, :place_order
end
```

The first argument is the aggregate name, the second is the role. The `allow` method takes any number of method symbols.

Standard methods you can gate:
- **Read**: `:find`, `:all`, `:count`, `:first`, `:last`, `:where`
- **Write**: `:create`, `:save`, `:update`, `:destroy`, `:delete`
- **Commands**: any command method name (e.g., `:create_pizza`, `:place_order`)

For the full rationale on why gates live in the Hecksagon rather than the Bluebook, and how they differ from ports, see [Architecture Decisions: Ports vs Gates](architecture_decisions.md#2-ports-vs-gates-naming-and-responsibility-split).

---

## Adapter

`adapter :kind, ...` declares an infrastructure adapter. The hecksagon grammar treats persistence and shell-out uniformly — the kind symbol selects the branch.

### Persistence (unnamed, at most one)

```ruby
# In-memory (default, no declaration needed)
adapter :memory

# SQLite
adapter :sqlite, database: "pizzas.db"

# PostgreSQL
adapter :postgres, host: "localhost", database: "pizzas", user: "app"

# MySQL
adapter :mysql2, host: "localhost", database: "pizzas"
```

Without a persistence adapter declaration, Hecks defaults to `:memory`.

> `persistence :sqlite, ...` still works as a deprecated alias for
> `adapter :sqlite, ...`; it emits a warning once per builder.

### Shell (named, many allowed)

```ruby
adapter :shell, name: :git_log do
  command "git"
  args ["log", "--format=%H", "{{range}}"]
  output_format :lines
  timeout 10
end

adapter :shell, name: :git_show_files,
                command: "git",
                args: ["show", "--name-only", "{{sha}}"],
                output_format: :lines
```

At runtime: `runtime.shell(:git_log, range: "HEAD~5..HEAD")`.

See [shell_adapter.md](shell_adapter.md) for the full reference —
security model, output formats, error surface, worked example.

---

## Extension

Extensions add cross-cutting capabilities to the runtime — audit logging, rate limiting, authentication, idempotency, etc. They hook into the boot sequence and wire behavior across all aggregates.

```ruby
extension :audit
extension :rate_limit, max: 100
extension :idempotency
```

Extensions are registered globally and fired during `Hecks.boot`. The Hecksagon declares which ones are active for this domain.

---

## Subscribe

Declares that this domain listens to events from another domain. Used in multi-domain setups where domains communicate via a shared event bus.

```ruby
subscribe "Billing"
subscribe "Shipping"
```

This enables cross-domain reactive policies: when the Billing domain publishes an event, this domain reacts to it.

---

## Tenancy

Sets the multi-tenancy isolation strategy for the domain.

```ruby
tenancy :row       # row-level isolation (tenant_id column)
tenancy :schema    # schema-level isolation (separate schemas per tenant)
```

---

## Booting with a Hecksagon

`Hecks.boot` looks for both a Bluebook (domain definition) and a Hecksagon (infrastructure wiring) in the project directory. If no Hecksagon is found, it uses defaults: memory adapter, no gates, no extensions.

```ruby
# Define domain
Hecks.domain "Pizzas" do
  aggregate "Pizza" do
    attribute :name, String
    command "CreatePizza" do
      attribute :name, String
    end
  end
end

# Define infrastructure
Hecks.hecksagon do
  adapter :sqlite, database: "pizzas.db"
  gate "Pizza", :admin do
    allow :find, :all, :create_pizza
  end
end

# Boot with a specific gate active
app = Hecks.load(domain, port: :admin)
```
