# Fargate's persistent server keeps `rust/host`'s single mutex-guarded connection; a pool is deferred, not built

**Status:** Accepted — implemented. `rust/host/src/server.rs` (PR #773, `HECKS_SERVE_MODE=1`), reusing `dispatch.rs`'s existing `Arc<Mutex<Client>>`.

## Context

`rust/host` has always run as a Lambda custom-runtime process (`lambda_runtime::run(service_fn(...))`), which hands the process one event at a time — there was never a real possibility of two dispatches overlapping in the same process. `dispatch.rs` already guards its single `tokio_postgres::Client` with a `Mutex`, but its own header comment on that choice was explicit that this was defensive, not load-bearing under Lambda: "if this process is ever invoked concurrently in-process (lambda_runtime's default loop is one-event-at-a-time, but nothing in this crate depends on that staying true), two calls can't interleave statements on the one connection this crate holds."

Adding a persistent HTTP server (`server.rs`, for the new `AwsFargate` deploy target) makes that "ever" real: an axum listener can receive genuinely concurrent HTTP requests, so the mutex stopped being a defensive nicety and became the thing actually deciding whether concurrent writes are safe.

## Decision

**Keep the existing `Arc<Mutex<Client>>` as-is.** Every write path (`handle`, `handle_facts`, `handle_routed`) already holds that lock for its full duration, including the WASM execution nested inside via `spawn_blocking` — so under the server, concurrent requests serialize on the write path but never interleave statements or corrupt state. Read paths (`dispatch::read`, snapshot queries) hold the lock only briefly, and wasmtime's `Engine`/`Module` are already `Arc`-shared and safe to instantiate from multiple threads, so the actual computation still parallelizes; only the database write itself is single-threaded.

Verified against real concurrent load, not assumed: 10 concurrent HTTP requests dispatching the identical duplicate-identity `CreatePizza` command all returned 200 with no crash or deadlock, and exactly 1 of the 10 was actually journaled (confirmed by a follow-up read and a direct row count) — proof the mutex plus the domain's own advisory-lock-based idempotency correctly serialize the write path rather than racing.

## Consequences

- Write throughput for a single `rust/host` process is bounded to one transaction at a time, regardless of how many concurrent HTTP requests arrive. Acceptable for lifeadelics' current traffic; would become a real bottleneck under sustained concurrent writers.
- No change needed anywhere else in the crate — `auth.rs`, `api.rs`, `web.rs`, `checkout.rs`, `journal.rs`, `mint.rs`, `approval.rs` all already take `&Mutex<Client>` and needed no rework to be correct under the new server.
- The next real capacity question (a connection pool) is now a documented, deliberate follow-up rather than an unexamined gap.

## Rejected alternatives

- **Replace the mutex with a connection pool now** (`deadpool-postgres`, `bb8`), letting independent requests hold independent connections and write in genuine parallel. Rejected for now: it's a real refactor touching every one of the 7+ files above, not something to fold into "add an HTTP listener," and there's no current traffic that needs it. It also isn't a drop-in swap — the domain's idempotency guard (proven correct above) relies on Postgres advisory locks, and a pool means those locks are being taken from whichever connection a given request happens to check out rather than one, and this needs to be explicitly reverified against a pool, not assumed to carry over, before it's built.
- **Serialize with a global in-process lock outside Postgres** (a plain `tokio::sync::Mutex<()>` gating the whole dispatch, instead of reusing the one already wrapping the client). Rejected as strictly worse than what already existed: it would add a second, redundant serialization point with no additional safety, since the existing `Mutex<Client>` already serializes every write end to end.
