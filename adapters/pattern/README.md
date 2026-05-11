# pattern/

Middleware-shaped reusable patterns that wrap the bus or a repository.

| Adapter | What |
|---|---|
| `cqrs/` | Command/query separation enforcement at the dispatch layer. |
| `idempotency/` | Idempotency-key middleware ; replays return prior result. |
| `information/` | Information-pattern helpers (entity-by-id, list, etc.). |
| `rate_limit/` | Per-actor / per-command rate-limit middleware. |
| `tenancy/` | Tenant + ownership scoped repositories ; row-level isolation. |
| `validations/` | Cross-aggregate / cross-field validation rules. |
