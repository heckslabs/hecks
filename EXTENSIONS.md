# Hecks Extensions

All extensions use the unified `extend` API:

```ruby
app = Hecks.boot(__dir__) do
  extend :sqlite
  extend :tenancy
  extend :slack, webhook: ENV["SLACK_URL"]
end
```

## Stability

| Label | Meaning |
|-------|---------|
| **stable** | Integration-tested, suitable for production |
| **experimental** | Works but not integration-tested — use with caution |

## Adapter Types

Extensions are classified as **driven** or **driving** adapters (hexagonal architecture):

| Type | Direction | Examples |
|------|-----------|----------|
| **driven** | Application calls out (repos, middleware, validation) | sqlite, auth, validations, logging |
| **driving** | External world calls in (HTTP, queue, Slack) | serve, queue, slack, web_explorer, mcp |

Boot fires driven extensions first so driving adapters see the fully wired runtime.

## Persistence (driven)

| Extension | Usage | Adapter Type | Stability | Description |
|-----------|-------|-------------|-----------|-------------|
| **sqlite** | `extend :sqlite` | driven | stable | SQLite persistence via Sequel. [README](hecks_persist/README.md) |
| **memory** | (default) | driven | stable | In-process memory adapter, used in tests. |
| **filesystem** | `extend :filesystem_store` | driven | stable | JSON file persistence for development. [Source](hecks_runtime/lib/hecks/extensions/filesystem_store.rb) |
| **postgres** | `extend :postgres` | driven | experimental | PostgreSQL persistence via Sequel — not integration tested. [README](hecks_persist/README.md) |
| **mysql** | `extend :mysql` | driven | experimental | MySQL persistence via Sequel. [README](hecks_persist/README.md) |
| **cqrs** | `extend :sqlite, as: :write` | driven | experimental | Named read/write connections for CQRS. [Source](hecks_persist/lib/hecks/extensions/cqrs.rb) |
| **transactions** | `extend :transactions` | driven | experimental | DB transaction wrapping for SQL adapters. [Source](hecks_persist/lib/hecks/extensions/transactions.rb) |

## Application Services (driven)

| Extension | Usage | Adapter Type | Stability | Description |
|-----------|-------|-------------|-----------|-------------|
| **validations** | auto | driven | stable | Field-level validation enforcement (presence, format, length). [Source](hecks_runtime/lib/hecks/extensions/validations.rb) |
| **auth** | `extend :auth` | driven | stable | Actor-based authorization via port definitions. [Source](hecks_runtime/lib/hecks/extensions/auth.rb) |
| **tenancy** | `extend :tenancy` | driven | experimental | Multi-tenant data isolation — not integration tested. [Source](hecks_runtime/lib/hecks/extensions/tenancy.rb) |
| **audit** | `extend :audit` | driven | experimental | Audit trail logging for every command execution. [Source](hecks_runtime/lib/hecks/extensions/audit.rb) |
| **pii** | `extend :pii` | driven | experimental | Encryption and masking for personally identifiable information. [Source](hecks_runtime/lib/hecks/extensions/pii.rb) |
| **idempotency** | `extend :idempotency` | driven | experimental | Deduplicates identical command dispatches. [Source](hecks_runtime/lib/hecks/extensions/idempotency.rb) |
| **logging** | `extend :logging` | driven | experimental | Command execution timing and logging. [Source](hecks_runtime/lib/hecks/extensions/logging.rb) |
| **rate_limit** | `extend :rate_limit` | driven | experimental | Per-command rate limiting. [Source](hecks_runtime/lib/hecks/extensions/rate_limit.rb) |
| **retry** | `extend :retry` | driven | experimental | Exponential backoff for transient errors. [Source](hecks_runtime/lib/hecks/extensions/retry.rb) |

## Infrastructure (driving)

| Extension | Usage | Adapter Type | Stability | Description |
|-----------|-------|-------------|-----------|-------------|
| **web_explorer** | `extend :http` | driving | stable | Interactive web UI with forms, lifecycle badges, event logs. [Source](hecks_runtime/lib/hecks/extensions/web_explorer.rb) |
| **serve** | `hecks serve` | driving | stable | WEBrick HTTP server for generated static apps. [README](hecks_cli/README.md) |
| **mcp** | `hecks mcp` | driving | experimental | MCP server for AI-driven domain modeling. [Source](hecks_workshop/lib/hecks/extensions/ai.rb) |

## Cross-Domain (driving)

| Extension | Usage | Adapter Type | Stability | Description |
|-----------|-------|-------------|-----------|-------------|
| **listen** | `extend CommentsDomain` | driving | experimental | Subscribe to another domain's event bus. |
| **queue** | `extend :queue, backend: :rabbitmq` | driving | experimental | RabbitMQ-backed async event delivery — not integration tested. |
| **slack** | `extend :slack, webhook: url` | driving | experimental | Forward events to Slack — not integration tested. |
