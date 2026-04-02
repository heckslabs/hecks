# Creating Extensions

Extensions add cross-cutting capabilities to Hecks domains -- persistence,
authorization, logging, queues, and more. Every extension follows a standard
file layout so the framework can discover, describe, and wire it automatically.

## File Layout

Each extension lives in a single file under `lib/hecks/extensions/`. The file
name becomes the registration key (e.g. `audit.rb` registers as `:audit`).

```ruby
# Hecks::MyExtension
#
# One-paragraph description of what this extension does.
#
# Future gem: hecks_my_extension
#
# Usage:
#   app = Hecks.boot(__dir__) do
#     extend :my_extension
#   end
#

# 1. Describe -- declare metadata for introspection
Hecks.describe_extension(:my_extension,
  description: "What this extension does in one line",
  adapter_type: :driven,          # :driven or :driving
  config: {
    MY_ENV_VAR: { default: 42, desc: "What it controls" }
  },
  wires_to: :command_bus)         # :command_bus, :event_bus, or :repository

# 2. Register -- the boot hook that wires the extension
Hecks.register_extension(:my_extension) do |domain_mod, domain, runtime|
  # Wire middleware, swap adapters, or subscribe to events here.
end

# 3. Supporting classes (if any) -- namespaced under Hecks::
module Hecks::MyExtension
  # Helper classes go here.
end
```

## describe_extension Fields

| Field | Required | Description |
|---|---|---|
| `description` | yes | One-line summary shown in `hecks extensions` |
| `adapter_type` | yes | `:driven` (repos, middleware) or `:driving` (HTTP, queues) |
| `config` | no | Hash of config keys with `default:` and `desc:` |
| `wires_to` | no | What the extension attaches to: `:command_bus`, `:event_bus`, or `:repository` |

## Naming Rules

- **File name = registration key.** `rate_limit.rb` registers as `:rate_limit`.
- **Supporting classes** live under `Hecks::` namespace (e.g. `Hecks::Audit`, `Hecks::PII`).
- **Future gem name** follows the pattern `hecks_<key>` (e.g. `hecks_audit`).
- **Aliases** use `Hecks.alias_extension(:short, :long)` instead of direct registry mutation.

## Driven vs Driving

**Driven extensions** (`:driven`) are infrastructure adapters that the domain
calls out to -- persistence, validation, auth, logging. They fire first at boot
so the runtime is fully configured before any driving adapters see it.

**Driving extensions** (`:driving`) are entry points that call into the domain
-- HTTP servers, message queues, Slack webhooks. They fire second at boot so
they see the final wired runtime.

## Example: A Metrics Extension

```ruby
# Hecks::Metrics
#
# Counts command executions per aggregate. Exposes totals via
# domain_mod.metrics for dashboards.
#
# Future gem: hecks_metrics
#
# Usage:
#   app = Hecks.boot(__dir__) do
#     extend :metrics
#   end
#   PizzasDomain.metrics  # => { "Pizza" => 3 }
#
Hecks.describe_extension(:metrics,
  description: "Command execution counters per aggregate",
  adapter_type: :driven,
  config: {},
  wires_to: :command_bus)

Hecks.register_extension(:metrics) do |domain_mod, _domain, runtime|
  counts = Hash.new(0)

  runtime.use :metrics do |command, next_handler|
    agg = command.class.name.split("::")[-3]
    counts[agg] += 1
    next_handler.call
  end

  domain_mod.define_singleton_method(:metrics) { counts.dup }
end
```
