# Extension Adapter Types

Every Hecks extension can declare an `adapter_type` of `:driven` or `:driving`,
following hexagonal architecture conventions.

## Concepts

- **Driven** adapters are called *by* the application (repos, validation,
  auth, logging, retry). They wire infrastructure that the domain reaches out
  to.
- **Driving** adapters call *into* the application (HTTP server, Slack
  webhook, message queue). They expose the domain to the outside world.

## Two-Phase Boot

`Hecks.boot` fires driven extensions first, then driving extensions. This
guarantees that when a driving adapter (e.g. the HTTP server) starts accepting
requests, all repos, middleware, and validation are already wired.

## Declaring Adapter Type

```ruby
Hecks.describe_extension(:sqlite,
  description: "SQLite persistence via Sequel",
  adapter_type: :driven,
  wires_to: :repository)

Hecks.describe_extension(:http,
  description: "REST and JSON-RPC server",
  adapter_type: :driving,
  wires_to: :command_bus)
```

## Query Helpers

```ruby
Hecks.driven_extensions
# => [:sqlite, :auth, :validations, :logging, ...]

Hecks.driving_extensions
# => [:http, :slack, :queue, :web_explorer, :mcp]
```

## Example Boot Sequence

```
1. wire_persistence (sqlite/postgres/mysql)
2. fire driven extensions:
   - validations (command bus middleware)
   - auth (command bus middleware)
   - logging (command bus middleware)
   - audit (event bus subscriber)
3. fire driving extensions:
   - http (adds .serve method)
   - web_explorer (registers views)
   - slack (subscribes to events)
```
