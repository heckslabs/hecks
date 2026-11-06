# Step 7 of ADR 0188: adapters as Wasm components

Status: a plan, nothing built. Base: `origin/main` at `d1510ad79`. Date: 2026-11-05.
Goal: an adapter that talks to the outside (mail, payments, a clock, secrets, a store) is a sandboxed
Wasm component the host loads, not Rust compiled into the host. It reaches the world only through
WIT ports the host grants it. Every slice ships alone and leaves behaviour unchanged until the slice
that swaps a native adapter for its component.

What follows says what was **read** and what is **inferred**; an inference is marked `(inferred)`.

## What the code is today (read)

| Piece | Where | State |
|---|---|---|
| Wasm runner | `rust/host/core/src/wasm_runner.rs` (410 lines) | wasmtime 49.0.4 with `epoch_interruption`, a 100 ms epoch thread, per-run limits (10 s, 1 GiB, 64 MiB output). Loads a **core module** (`Module`) through the **WASI p1** linker (`wasmtime_wasi::p1`), stdin and stdout as memory pipes. Compiled once per path (`compile_count`) |
| Plugins | `rust/host/core/src/plugins.rs` (269 lines) | A plugin is a WASI **command**: one JSON question on stdin `{"question","args"}`, one JSON answer on stdout `{"rows"}` or `{"refused"}`. The module rides in the IR (`plugins[]`: `adapter`, `runs`, `queries`, `sha256`, base64 `module`), is checked against its SHA-256 and cached at `$TMP/hecks-plugins/<sha>.wasm`. It has **no imports**: no clock, no network, no store. A `reference_to` argument arrives as the referenced record's state |
| Plugin fixture | `spec/fixtures/wasm_plugin/doubler{,.wasm}` | the one plugin in the tree, used by the `plugins.rs` tests |
| Component Model | whole repo | **Absent.** No `.wit` file, no `wit-bindgen`, no `wasmtime::component`, no `wasm32-wasip2` (grep over the tree; only `Cargo.lock` mentions of wasmtime internals). CI builds `wasm32-wasip1` only (`ci.yml`, `ci-rust-io.yml`, `cache-warm.yml`) |
| Host adapters in Rust | `rust/host/src` | `resend.rs` (475), `payments.rs` (1,067) + `payments/`, `checkout.rs` (330), `secrets.rs` (260), `http.rs` (one shared `reqwest` client), `auth/google_signin.rs`, `platform_signin/`, `aws_lambda_invoker.rs`, `store/postgres.rs` (493), `store/journal_sql.rs` (869), `store/mint.rs` (2,726) |
| Ports in Rust | `rust/host/core/src` | `store.rs` (trait `Backend` + `UnitBackend`: `begin`, `read_state`, `head_*`, `held_eras`, `commit`, `rollback`), `lambda_client.rs` (trait `LambdaInvoker`), `clock.rs` (`unix_now`, `iso8601_now`), `needs.rs` (answers `now`/`today` before the kernel reads arguments) |
| Boundary rule | `rust/host/src/hecksagon_boundary_tests.rs` | a test scans the runtime modules (dispatch, journal, wasm_runner, needs, ...) for transport words; HTTP, env and the AWS SDK must stay in adapter modules |
| Store contract | `rust/host/src/store_conformance.rs` | one suite of cases run against every backend that implements a harness trait (commit atomicity, domain lock, reads take no lock) |
| Ruby driven adapters | `lib/hecks/adapters/driven` | 19 `.adapter` files declaring 21 adapters; each is `Hecks.adapter "X" do port "..." end`, with `field` and `secret` (`d1.adapter`) and `provides` (`postgres.adapter`) |

Findings that shape the plan:

1. **Resend has no Ruby twin.** `resend.rs` says so in its header, and I found no `mock_resend.rb` in the
   tree (ADR 0099 names `newsletter/adapters/mock_resend.rb`; that file is gone or elsewhere). So a Resend
   component has no Ruby adapter to stay equal to, and the Rust mailer's own tests are the whole oracle.
2. **The six names in ADR 0188 are two layers (inferred).** `store`, `http-out`, `clock`, `secrets` are
   *capabilities the host grants* (a component imports them). `email` and `payments` are *what an adapter
   offers a domain* (a component exports them). The plan keeps them apart: one WIT package of imports,
   one world per exported adapter.
3. **The runner must change shape, not just grow.** Today's runner is core-module, p1, synchronous, and
   called from `spawn_blocking`. A component with host imports that do I/O (an HTTP call, a sleep) needs the
   component linker (`wasmtime::component`, `wasmtime_wasi::p2`, which the runner already imports for
   pipes) and a decision on async imports. Whether `component-model` is enabled in this crate's wasmtime
   build was not checked `(inferred: it is on by default in wasmtime 49)`.
4. **Ruby port names are not the WIT names.** The Ruby `clock` port returns whole epoch seconds as an
   Integer (`system_clock.rb`, with a comment on why). `identity_generation` (a random UUID) is a port with
   no WIT home in ADR 0188's list (see the questions).

## Bluebook or hecksagon (the question CLAUDE.md asks first)

- **Bluebook:** no change. A domain already says "send this email" or "take this payment" as a port ask
  (`asks ... answers ... refuses`, see `tickets.ports.hecksagon`); it names no provider.
- **Hecksagon:** which adapter answers a port and what it may touch is wiring. The `.adapter` file already
  declares `port`, `field`, `secret`. A component adapter says, in the same file, *which module* it runs and
  *which capabilities* it imports; the compiled hecksagon puts that in the IR's `plugins`-style entry.
  `(inferred: the exact keywords are a decision, below.)`
- **Neither (needs a reason):** the WIT files, the host-side implementations of the imports, the component
  linker. They are adapter and generator code. The reason: the kernel does no I/O (ADR 0012), so something
  must hold the socket, and the sandbox is the point.
- **Projection, not hand-written (CLAUDE.md):** a WIT file is a new output derived from a port declaration.
  Start hand-written for the four imports, which are not domain ports, and project the exported worlds
  (`email`, `payments`) from the port asks once Resend has fixed the shape.

## Map: what each adapter does and where it goes

| Adapter | What it does (read unless marked) | WIT port | Verdict |
|---|---|---|---|
| `SystemClock` (`system_clock.rb`), `clock.rs` | whole-second epoch time; Rust adds ISO 8601 rendering | import `clock`: `now-seconds() -> s64`, `sleep(ms)` | the smallest; host-owned, **stays native**, becomes an *import* |
| Host `secrets.rs` | env var, else a secret fetched from AWS Secrets Manager at boot (`provide`) | import `secrets`: `get(name) -> option<string>`, only names the adapter declares | host-owned, native; the component never sees an ARN or the AWS SDK |
| Host `http.rs` + `reqwest` | one shared TLS client; per-call timeout set by the caller | import `http-out`: `request(method, url, headers, body, timeout) -> result<response, error>`, allow-listed by host name | host-owned, native; this is the grant that makes Resend and Stripe components possible |
| `Resend` (`resend.rs`) | builds the JSON payload (html vs text, `List-Unsubscribe`, `reply_to`), POSTs `/emails` with a bearer key, retries 429 up to 4 times honouring `Retry-After` (capped 5 s), maps every failure to `Delivery{ok,message_id,reason}` and never an `Err`; a `Mock` variant logs and refuses `bounce@example.com` | export `email`: `deliver(email) -> delivery`; imports `http-out`, `secrets`, `clock` | **the proof** (below). Mock stays a second binding of the same export |
| Resend webhook (`web/resend_webhook.rs`) | Svix HMAC check with a 300 s tolerance; routes into `RecordOpen`/`RecordClick` | none | stays host: it is an inbound route, not an adapter |
| Stripe (`payments.rs`, `checkout.rs`, `payments/keystore.rs`) | Stripe REST calls through `reqwest`, key modes `test`/`live`, key storage in Secrets Manager, role gate, checkout plan | export `payments`; imports `http-out`, `secrets`, `clock` | **split (inferred, only the head of `payments.rs` read):** the Stripe API calls become a component; the role gate, routing, key store and webhook verification stay in the host |
| Google sign-in (`auth/`, `platform_signin/`) | OAuth code exchange and ID-token checks over HTTP, cookie state | would use `http-out` | **not in ADR 0188's list; leave native** (inferred: it is a driving, browser-bound flow) |
| `Memory`, `Heki`, `LocalStorage`, `SqlitePersistence`, `Postgres`, `PostgresEra`, `D1`, `Lambda` | persistence (`port "persistence"`) | export/import `store` | **last and partial** (see slice 8). Rust side: `Backend` with a transaction `Unit`. Ruby side: repository classes (not read in depth) |
| `AwsLambdaInvoker` (`aws_lambda_invoker.rs`) | cross-domain reaction delivery over the AWS SDK | `http-out` is not enough (SigV4 via the SDK) | leave native (inferred) |
| `SecureRandomIdentity` | random UUID | none in the ADR's list | needs a decision: add `random` to the imports, or the host passes an id (`needs` already does this for `now`) |
| `GovernanceAuthorization`, `IdentityRegistry`, `InProcessKeyVault` | in-process policy and key logic | none | not outside-world adapters; stay as they are (inferred from the file names and one-line `.adapter` files) |
| `ClaudeCode`, `ScriptRunner`, `Prism`, `Folder`, `TenantProvisioner`, `google_authentication`, git and deploy adapters under `lib/hecks/hecks/adapters` | tooling that runs processes, git, the filesystem | none | **out of scope**: local tooling, not deployable adapters; a sandbox would only forbid what they exist to do (inferred) |

## The proof: Resend, after one plumbing slice

Choice: **prove with Resend, but ship the loader on a tiny component first.**

- *Smallest first (a clock component).* Isolates the toolchain, the WIT, the component linker and the limits
  from any I/O. But a clock proves nothing about the thing ADR 0188 cares about: an adapter that touches the
  network under a grant.
- *Resend straight away.* One function (`deliver`), one outbound call, one secret, a retry loop, a single
  caller family (`newsletter_send.rs`, `newsletter.rs`, `registration_receipt.rs`), no Ruby twin, and its
  tests already pin the behaviour with a recording fake server. It exercises `http-out`, `secrets` and
  `clock.sleep` at once.
- **Recommendation:** slice 1 is a fixture component with only `clock`, so the loader risk is paid with no
  network in the way; slice 3 is Resend. If you want one slice fewer, merge 1 into 3 and accept that a
  toolchain failure and a Resend failure look the same.

## Slices

Order matters where areas overlap: 1, 2, 3 and 4 all touch `rust/host/core/src/wasm_runner.rs`,
`plugins.rs` or the new WIT directory, so they run in sequence. 6 and 7 touch disjoint code once 4 is done.

| # | Slice | Outcome | Area | Depends on | Gate | Who |
|---|---|---|---|---|---|---|
| 0 | **Decisions A to E below** | answered; recorded in a new ADR (0190 or next free) | `docs/decisions` | none | owner answers | owner |
| 1 | **Component runner and a clock fixture** | a `wasm32-wasip2` component that imports `clock` and exports `echo-time`, loaded by a new `component_runner` beside `wasm_runner` (same epoch deadline, memory cap, output cap, per-path compile cache); the core-module path is untouched | `rust/host/core/src`, `rust/host/wit`, `spec/fixtures` | 0 | the existing `plugins.rs` and `wasm_runner` tests pass unchanged; a new test shows the deadline stops a looping component and the memory cap refuses growth | coder |
| 2 | **The imports, host side** | `clock`, `secrets`, `http-out` implemented in the host over `clock.rs`, `secrets::var` and `http::client()`; each import checks the component's declared grant (secret names, host names) and refuses by name | `rust/host/src` (new `grants` module), `rust/host/wit` | 1 | a component that asks for an undeclared secret or host gets a named refusal; `hecksagon_boundary_tests` still passes (the runtime modules gain no transport word) | coder |
| 3 | **Resend as a component** | the `email` world, a component crate that holds `payload`, the 429 retry and the `Delivery` mapping, built to a committed `.wasm` with its digest; the host calls it where it calls `Mailer::deliver` today, behind a switch | `rust/host/src/resend.rs`, `rust/host/src/web/newsletter*.rs`, `rust/adapters/resend` (new) | 2 | **parity**: every case in `resend.rs` tests (fake server, 429 then 200, 429 forever, unreachable, no id, html vs text, `List-Unsubscribe`, `reply_to`) passes against both the native mailer and the component, through one shared case list; component adds under 5 ms per delivery over native on a local fake (inferred target, owner may set another) | coder |
| 4 | **Declare it in the hecksagon** | the `.adapter` file says `port "email"`, which module it runs and its grants; the Ruby compiler puts it in the IR and the host loads it by digest from the IR as plugins do; `Mailer::from_env` picks native or component by that wiring | `lib/hecks/adapters/driven` or the newsletter package's hecksagon, `lib/hecks/tools/ir.rb`, `rust/host/core/src/plugins.rs` | 3, decision B | a deploy whose hecksagon names the component sends through it; one that does not behaves exactly as today; `check_conformance` and the shape ledger agree | coder (the keyword choice is the owner's) |
| 5 | **Flip Resend and retire the native mailer** | the component is the default; `Mailer::Live` and its `reqwest` use are deleted; the mock stays a second binding of the same export | `rust/host/src/resend.rs` | 4, a clean week of deliveries | the owner's go; no regression in the newsletter send | owner decides, coder builds |
| 6 | **Payments (Stripe API half)** | the `payments` world and a Stripe component; role gate, key store, routing and webhook check stay in the host | `rust/host/src/payments*`, `checkout.rs`, `rust/adapters/stripe` | 4 | the Stripe tests in `payments/tests.rs` run against both; a live-key test is a manual, owner-run step | coder; owner approves keys handling |
| 7 | **Clock and secrets as the only imports for the rest** | the remaining native adapters that only need time, secrets or HTTP (inferred: none besides the two above) are listed and each gets a component or a written "stays native" reason | `docs/plans` | 6 | a table in this document is closed | coder |
| 8 | **Store** | a decision, then a build: see choice C. Until then no store is a component | `rust/host/core/src/store*`, `store_conformance.rs` | 4, decision C | a component backend passes `store_conformance` | owner, then coder |

Slices 1, 2, 3, 4, 6 go to the coder. 0, 5 and 8 start with an owner decision; the flip in 5 is the owner's.

## Choices for the owner

**A. Which Wasm target?** (1) Components on `wasm32-wasip2` with WIT and the component linker (recommended:
ADR 0188 names WIT; imports are typed and the grant is the interface). (2) Keep core modules and p1 and
define a JSON-over-stdio protocol with host calls as a custom import (smallest change to `wasm_runner`, but
it re-invents WIT and every import is untyped). Your call.

**B. How does a hecksagon name a component adapter?** (1) New `.adapter` keywords: `runs "resend.wasm"` and
`imports :http_out, hosts: [...]`, `secret :api_key` (recommended: the `.adapter` file already holds `port`,
`field`, `secret`, so the wiring reads in one place). (2) A separate `.wasm` section in the hecksagon file.
(3) Keep the IR `plugins` shape and add a `kind`. I recommend 1; the IR entry follows `plugins` so the loader
is shared.

**C. How does a non-native store work (slice 8)?** (1) Leave `store` native for this step: components never
persist; the host journals. Ships now and is what slices 1 to 7 need (recommended). (2) A `store` import
with a transaction resource (`begin`, `load`, `commit`, `rollback`) so a Postgres or Sqlite backend is a
component; needs socket access under WASI p2 or a host-provided query import, and `postgres_era` (`mint.rs`,
2,726 lines) is the risk ADR 0188 puts last. (3) A `store` *export* so a component backs the kernel's journal.
Recommend 1 now, and revisit after the one-event-log step (ADR 0188 step 8) changes what a store is.

**D. The retry sleep.** (1) `clock.sleep(ms)` imported, so the component keeps the retry loop (recommended:
the loop is adapter logic, and a bounded sleep is easy to grant). (2) The host's `http-out` retries 429 itself,
which makes Resend simpler and every other adapter inherit the policy. Your call.

**E. Async host calls.** (1) Keep the synchronous `spawn_blocking` pattern the runner uses today; the
component blocks while the host does its HTTP call (recommended for the proof; simplest). (2) Async
component calls. Needed only if one process serves many concurrent deliveries; measure in slice 3 first.

**F. `identity_generation` and `random`.** Add a `random` import, or keep ids a host fact like `now`? I
recommend the fact, so no component can mint its own ids.

If you answer "your call", I take the recommendations above and say so in the ADR.

## Decisions (owner said "your call" on 2026-11-05; my recommendations taken)

- **A.** Components on `wasm32-wasip2` with WIT. The core-module plugin path stays as it is.
- **B.** New `.adapter` keywords (`runs`, `imports`, `secret`); the IR entry follows `plugins` so the loader is shared.
- **C.** `store` stays native for this step; no component persists. Revisit after the one-event-log step.
- **D.** `clock.sleep(ms)` is imported, so the component keeps the 429 retry loop.
- **E.** Synchronous host calls through `spawn_blocking`; measure in slice 3 before considering async.
- **F.** Ids stay a host fact like `now`; no `random` import.

Slice 0 therefore reduces to writing these into an ADR; slice 8 is deferred by C.

## Risks

- **Wall time, epoch and host calls.** The epoch tick counts wall time. A component that waits on a host
  HTTP call (up to Resend's 15 s timeout) or sleeps (up to 5 s per retry, four attempts) can exceed the
  runner's 10 s kernel deadline. The component run needs its own limits, set per adapter. `(inferred
  from wasm_runner.rs constants; not measured)`.
- **Secrets.** Today `secrets::var` is the single place keys are read. A component that can ask for any name
  would read the whole environment. The grant list is the control; the test for it is slice 2's gate. A key
  must never appear in a component's output or log (the repo has a secret-output check in the quick gate).
- **Fan-out cost.** A newsletter send is one delivery per recipient (`Mailer::deliver` per email). A
  component instantiation per delivery, rather than per batch, may cost real time; compile once, instantiate
  per call, and pre-instantiate. Measure in slice 3.
- **No Ruby twin to compare to.** Parity here means native-vs-component, one runtime. If a Ruby Resend ever
  returns, it must be held to the same case list.
- **CI cost.** A new target and a component build add a toolchain step. Per CLAUDE.md "Keep CI under three
  minutes": the component is built once and committed with its digest, the cargo work sits in a job that
  holds that crate's cache, and no Postgres io shard builds it.
- **Committed binaries.** A committed `.wasm` is generated output and must carry a banner or a sibling
  digest file, regenerated by a command, never hand-edited. `rust/src/generated` shows the pattern; the
  commit-and-check-drift job needs a twin for this.
- **A `payments` split that cuts wrong.** The Stripe code mixes HTTP, key storage, roles and routing in one
  1,067-line file (only its head was read). Cutting the API half out first needs a read of the whole file.
- **WIT shape locks early.** The first `email` world will be copied by every later adapter. That is why
  Resend goes first and the exported worlds are projected only after it.
- **The plugins path must not regress.** Existing query plugins are core-module WASI commands. Keep that
  loader working until the owner decides to port them (the doubler fixture is the only one found).

## Not checked

The Ruby persistence adapters' internals, the whole of `payments.rs`, `checkout.rs` beyond its constants,
`platform_signin/`, how `hecks-client` or the TypeScript side would call a component, the Rust crate
layout for a new adapter crate (`rust/adapters/` is a proposed name, not an existing directory), whether
`wasmtime` is built with `component-model` and `async` here, and the Wasm size and cold-start cost of a
component on the Lambda host (`bootstrap` binary). Slices 1 and 3 each begin by checking the part they
depend on.

## Overlap with open work

`exe/hecks tickets Work.undone` was searched for wasm, adapter, component, wit, resend, http, plugin and
secret: no open Work item covers step 7. The nearest are the kernel-client items for step 5 (for example
"Kernel client: driving adapters and hecks-rails over the client dispatcher"), which do not touch
`rust/host`. `exe/hecks agents PlanReview.reviews` is not a command in this tree (`no such command:
agents`), so no review was checked. No Work items are created by this document.
