# Adapters are Wasm components on wasip2 with WIT, and the store stays native

**Status:** Proposed. Step 7 of the plan in ADR 0188; records decisions A to F of
`docs/plans/wasm-adapters.md`. Nothing here is built. Date: 2026-11-06.

**R** marks what was read in this tree; **I** marks an inference not yet confirmed.

## Context

ADR 0188 wants an adapter that talks to the outside (mail, payments, a clock, secrets, a store) to be a
sandboxed Wasm component the host loads, not Rust compiled into the host. Today:

- **R** `rust/host/core/src/wasm_runner.rs` loads a core module through WASI p1 under wasmtime 49.0.4,
  with epoch interruption and per-run limits. `plugins.rs` runs query plugins on it: one JSON question on
  stdin, one JSON answer on stdout, no imports.
- **R** There is no Component Model use anywhere in the repo: no `.wit` file, no `wasmtime::component`,
  no `wasm32-wasip2` target. CI builds `wasm32-wasip1` only.
- **R** The adapters (`resend.rs`, `payments.rs` with `checkout.rs`, `secrets.rs`, `http.rs`, the store
  code) are native Rust in `rust/host/src`. `resend.rs` has no Ruby twin.

The plan found that ADR 0188's six names are two layers (**I**): `secrets`, `http-out` and `store` are
capabilities the host grants, which a component imports (`clock` is not one, see decision D); `email` and `payments` are what an
adapter offers a domain, which a component exports.

The owner answered "your call" on 2026-11-05 and the plan's recommendations were taken. This record writes
them down for acceptance.

## Decision

1. **A. Components on `wasm32-wasip2`, described in WIT, run by the component linker.** The imports are
   typed and the grant is the interface. The core-module plugin path stays as it is and keeps working
   until the owner decides to port the query plugins. A new `component_runner` sits beside `wasm_runner`
   with the same epoch deadline, memory cap, output cap and per-path compile cache.
2. **B. A hecksagon names a component adapter with `.adapter` keywords.** `runs "resend.wasm"` and
   `imports :http_out, hosts: [...]` are new; `secret :api_key` already exists. The compiled hecksagon puts
   the entry in the IR following the `plugins` shape (`adapter`, `runs`, `sha256`, base64 module), so the
   loader is shared. The exact keyword spelling is settled when slice 4 builds it.
3. **C. The store stays native for this step.** No component persists; the host journals. Revisit after
   the one-event-log step of ADR 0188 (step 8) changes what a store is. ADR 0197 settles only that the
   kernel serves Memory domains; how a persisted domain reaches the kernel is its open question for step
   6, and the host owns the store and its minting (ADR 0030) until that is answered.
4. **D. Time is the kernel's `now` fact, and a component imports no clock.** A step that needs the time
   declares `needs` and the kernel asks the host for `now` (ADR 0189 `ask: "fact"`), so there is one path
   for time, and it is the one the simulation tests seed (ADR 0199). No `clock.sleep` import exists.
   **A component does not retry.** A retry policy is a rule the domain may need to know, so it is not
   adapter logic. On an HTTP 429 the component returns at once and the port refuses by name
   (`provider rate limited`, carrying the provider's retry-after seconds when it sent one). The port's
   `refuses` declares that refusal, so the domain sees the same thing whether one attempt or many were
   made; retrying is a policy in the domain on that refusal, over the `now` fact.
5. **E. Host calls are synchronous.** The component blocks while the host does its HTTP call, under the
   `spawn_blocking` pattern the runner uses now. Measure in the Resend slice before considering async
   component calls.
6. **F. Ids stay a host fact like `now`.** There is no `random` import, so no component mints its own ids.
   (Decision F is in the plan's list beyond A to E; it is recorded here so the list is whole.)
7. **The proof is Resend, after one plumbing slice.** Slice 1 is a fixture component importing
   nothing (an export only), so a toolchain failure and a Resend failure do not look the same. Slice 3 is
   Resend, which exercises `http-out` and `secrets` together. No other import is built until a second
   adapter needs one. Parity is native versus component through
   one shared case list.

### Which parts are declared and which are code

Bluebook first, then hecksagon.

- **Bluebook: no change.** A domain already says "send this email" or "take this payment" as a port ask
  (`asks`, `answers`, `refuses`); it names no provider.
- **Hecksagon:** which adapter answers a port and which capabilities it may touch is wiring: the
  `.adapter` file's `port`, `secret` and the new `runs` and `imports` (decision B).
- **Neither, with a reason:** the WIT files, the host-side implementations of the imports, and the
  component linker are adapter and generator code. The kernel does no I/O (ADR 0012), so something must
  hold the socket, and the sandbox is the point. The four imports are hand-written WIT because they are
  not domain ports; the exported worlds (`email`, `payments`) are projected from the port asks once
  Resend has fixed the shape, as CLAUDE.md prefers a projection to hand-written code.
- **Not an outside-world adapter:** the local tooling adapters (git, deploy, claude sessions), which a
  sandbox would only forbid what they exist to do, and Google sign-in and `AwsLambdaInvoker`, left native
  (**I**: the plan inferred both). Which mechanism answers a port is ADR 0196's decision 4: a port whose `.adapter`
  declares `runs` is answered by its component, any other by the Ruby callback, one per port.

## Consequences

- A component reaches the world only through the imports the host grants it, and each import checks the
  declared grant (secret names, host names) and refuses by name. That check is host code, so it is
  specced through the behaviors with a stand-in component that asks for an undeclared host and an
  undeclared secret and is refused by name for each.
- Resend becomes a component; the native mailer stays until the owner flips the default.
- The first `email` world will be copied by every later adapter, which is why Resend goes first.
- A committed `.wasm` is generated output. Its sibling `<name>.wasm.sha256` holds the digest the IR's
  `sha256` is checked against. The command that rebuilds both is
  `exe/hecks regeneration_run.regenerate_adapters! --confirm --wait`, with `--check` as the drift check,
  beside `regenerate_corpus!` (**I**: the command does not exist yet; adding it is a bluebook change to
  the `RegenerationRun` aggregate and lands with slice 1).
- The epoch tick counts wall time. A component that waits on HTTP (up to 15 s) can exceed the 10 s kernel
  deadline (**I**: from constants in `wasm_runner.rs`, not measured). Slice 3 measures it before decision
  E is relied on, and the component run takes its own limit per adapter.
- Not built, and not checked: whether `component-model` is enabled in this crate's wasmtime build (**I**:
  on by default in wasmtime 49), the whole of `payments.rs`, and Lambda cold start for a component.

## Rejected alternatives

- **Core modules with JSON over stdio and a custom import (decision A, option 2).** Smallest change to
  `wasm_runner`, but it re-invents WIT and every import is untyped.
- **A separate `.wasm` section in the hecksagon file, or a `kind` on `plugins` (decision B, options 2 and
  3).** The `.adapter` file already holds `port`, `field` and `secret`, so the wiring reads in one place.
- **A `store` import or export now (decision C, options 2 and 3).** `mint.rs` is 2,726 lines and is the
  risk ADR 0188 ranks last.
- **A `clock.sleep` import with the retry loop in the component (decision D, option 1).** Hides a retry
  rule from the domain and duplicates the kernel's `now` fact.
- **The host's `http-out` retrying 429 itself (decision D, option 2).** Simpler for Resend, but every
  adapter would inherit the policy.
- **Async component calls (decision E, option 2) and a `random` import (decision F).** Not needed by the
  proof, and `random` would let a component mint its own ids.
