# adapters/

The single home for every adapter the framework knows about, organized by category. An adapter is *driven* (the bus calls out to it — storage, transport, llm) or *driving* (it calls into the bus — web surface, cli, scheduler). Each adapter folder holds whatever combination of these files exists for it :

```
adapters/<category>/<name>/
├── <name>.bluebook       — the UL (ubiquitous language) for the adapter
├── <name>.hecksagon      — the wiring : adapter_type, wires_to, named bindings
├── <name>.behaviors      — happy-path tests for the bluebook
└── <name>.rb             — current Ruby realization, retires under i80
```

Not every adapter has every file yet — some are bluebook-only, some are Ruby-only (pre-lift). The lift target is : every adapter has at least the bluebook + hecksagon ; Ruby is the realization that retires once a Rust runtime picks up the hecksagon's bindings.

## Categories

| Category | What lives here |
|---|---|
| `auth/` | actor / role / session / authorization decision middleware |
| `audit/` | command-execution audit trail |
| `bus/` | the bus itself — `storehouse_api` for remote bus calls, `outbox` / `queue` / `transactions` for delivery semantics, `retry` for back-off |
| `codegen/` | emitters for downstream targets (Ruby call sites, WASM workers, Pages functions, embedded bluebooks) |
| `integration/` | external systems — Slack, Stripe, Twilio, Resend, Cloudflare deploy, etc. |
| `llm/` | model adapters — Ollama, Claude, others |
| `observability/` | logging, metrics, PII marking |
| `pattern/` | CQRS, validations, idempotency, rate_limit, tenancy — middleware-shaped reusable patterns |
| `serving/` | docs surface, web explorer, app serving (`serve`, `web_components`, `web_application_creation`) |
| `storage/` | heki, r2, filesystem store, mysql, postgres, sqlite, in_memory |

## Why one folder

Before this consolidation, adapters were spread across `hecks_conception/adapters/`, `ruby/hecks/extensions/`, `discipline/`, `integrations/`, and case-by-case homes inside other concerns. The scatter made it hard to see what existed, what was lifted, and what was still Ruby-only.

One folder, categorized. New adapters land here. Lifts (Ruby → bluebook) happen in place. The framework's hexagonal surface becomes legible at a glance.
