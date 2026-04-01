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

## Persistence

| Extension | Usage | Stability | Description |
|-----------|-------|-----------|-------------|
| **sqlite** | `extend :sqlite` | stable | SQLite persistence via Sequel. [README](hecks_persist/README.md) |
| **memory** | (default) | stable | In-process memory adapter, used in tests. |
| **filesystem** | `extend :filesystem_store` | stable | JSON file persistence for development. [Source](hecks_runtime/lib/hecks/extensions/filesystem_store.rb) |
| **postgres** | `extend :postgres` | experimental | PostgreSQL persistence via Sequel — not integration tested. [README](hecks_persist/README.md) |
| **mysql** | `extend :mysql` | experimental | MySQL persistence via Sequel. [README](hecks_persist/README.md) |
| **cqrs** | `extend :sqlite, as: :write` | experimental | Named read/write connections for CQRS. [Source](hecks_persist/lib/hecks/extensions/cqrs.rb) |
| **transactions** | `extend :transactions` | experimental | DB transaction wrapping for SQL adapters. [Source](hecks_persist/lib/hecks/extensions/transactions.rb) |

## Application Services

| Extension | Usage | Stability | Description |
|-----------|-------|-----------|-------------|
| **validations** | auto | stable | Field-level validation enforcement (presence, format, length). [Source](hecks_runtime/lib/hecks/extensions/validations.rb) |
| **auth** | `extend :auth` | stable | Actor-based authorization via port definitions. [Source](hecks_runtime/lib/hecks/extensions/auth.rb) |
| **tenancy** | `extend :tenancy` | experimental | Multi-tenant data isolation — not integration tested. [Source](hecks_runtime/lib/hecks/extensions/tenancy.rb) |
| **audit** | `extend :audit` | experimental | Audit trail logging for every command execution. [Source](hecks_runtime/lib/hecks/extensions/audit.rb) |
| **pii** | `extend :pii` | experimental | Encryption and masking for personally identifiable information. [Source](hecks_runtime/lib/hecks/extensions/pii.rb) |
| **idempotency** | `extend :idempotency` | experimental | Deduplicates identical command dispatches. [Source](hecks_runtime/lib/hecks/extensions/idempotency.rb) |
| **logging** | `extend :logging` | experimental | Command execution timing and logging. [Source](hecks_runtime/lib/hecks/extensions/logging.rb) |
| **rate_limit** | `extend :rate_limit` | experimental | Per-command rate limiting. [Source](hecks_runtime/lib/hecks/extensions/rate_limit.rb) |
| **retry** | `extend :retry` | experimental | Exponential backoff for transient errors. [Source](hecks_runtime/lib/hecks/extensions/retry.rb) |

## Infrastructure

| Extension | Usage | Stability | Description |
|-----------|-------|-----------|-------------|
| **web_explorer** | `extend :http` | stable | Interactive web UI with forms, lifecycle badges, event logs. [Source](hecks_runtime/lib/hecks/extensions/web_explorer.rb) |
| **serve** | `hecks serve` | stable | WEBrick HTTP server for generated static apps. [README](hecks_cli/README.md) |
| **mcp** | `hecks mcp` | experimental | MCP server for AI-driven domain modeling. [Source](hecks_workshop/lib/hecks/extensions/ai.rb) |

## Cross-Domain

| Extension | Usage | Stability | Description |
|-----------|-------|-----------|-------------|
| **listen** | `extend CommentsDomain` | experimental | Subscribe to another domain's event bus. |
| **queue** | `extend :queue, backend: :rabbitmq` | experimental | RabbitMQ-backed async event delivery — not integration tested. |
| **slack** | `extend :slack, webhook: url` | experimental | Forward events to Slack — not integration tested. |
