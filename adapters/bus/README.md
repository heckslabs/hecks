# bus/

The bus itself — the spine that delivers commands and events. `storehouse_api` is the lifted bluebook for remote bus calls ; the others are Ruby delivery-semantics extensions awaiting lift.

| Adapter | What |
|---|---|
| `storehouse_api/` | Bluebook for the remote bus HTTP/JSON surface. |
| `outbox/` | Transactional outbox — write events with the aggregate, drain to delivery. |
| `queue/` | Async work queue ; commands handed off for background execution. |
| `retry/` | Back-off / retry policy for transient failures. |
| `transactions/` | Per-command transaction wrapping. |
