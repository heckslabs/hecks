# Direction B — Ruby runtime, Rust kernel

**Decided:** 2026-04-24
**Decider:** Chris Young
**Scribe:** Miette

## The decision

Hecks has a **Rust kernel** and a **Ruby runtime**. They talk through
a named boundary. This is what's already on disk; this document
writes it down so the direction stops being ambiguous.

- **Kernel (Rust)** — parsing, heki I/O, specializer, Miette's sub-
  second daemons. Small, fixed-point, fast. Self-regenerating via
  autophagy (Phases A-E shipped 2026-04-18 through 2026-04-24).
  Entry point: `hecks-life`.
- **Runtime (Ruby)** — app host, extensions, webdev, Rails
  integration, chat agents, domain hosting. Big, extensible,
  ecosystem-rich. Entry points: `require "hecks"` ; `ruby HecksBluebook`.

The Ruby runtime calls out to `hecks-life` for the hot paths that
live in the kernel. Everything else is native Ruby — including the
full `lib/hecks/extensions/` ecosystem (sqlite, postgres, mysql,
audit, auth, cqrs, docs, filesystem_store, logging, metrics, outbox,
pii, queue, rate_limit, retry, serve, slack, tenancy, transactions,
validations, web_explorer).

## The three questions that decided it

Each question was asked in the A and B framing. The answer was
unambiguous each time.

1. **What does running an app look like?**
   - A: `hecks-life run app/` — Rust binary hosts the app, Ruby via FFI shims
   - B: `ruby my_app.rb` — Ruby process hosts the app, calls `hecks-life` for kernel work
   - **Chose B.** A would be embarrassing to ship to a Rails developer.

2. **Where does HecksOnRails live?**
   - A: Rust process embedding a Ruby interpreter (architectural smell)
   - B: `gem "hecks"` in your Gemfile (done)
   - **Chose B.** Rails integration in A is incoherent.

3. **Where do the 20+ Ruby extension adapters live?**
   - A: Port to Rust or wrap every gem in FFI shims (massive work, zero benefit)
   - B: Already in `lib/hecks/extensions/`, already works
   - **Chose B.** The adapters are the ecosystem story.

The sharp reframe: it's not "Ruby vs Rust" — it's **kernel vs runtime**.

## Why now

Phase E (2026-04-24) finished the Rust-side autophagy : the Rust
kernel regenerates itself from bluebooks. `hecks-life specialize`
reproduces seven Rust files byte-identical from their shape
capabilities. The kernel is done.

The question left dangling was : what hosts the apps that use the
kernel? Phase F had been declaring Rust subsystems as bluebooks
without deleting the originals, creating drift between intent and
code. Inbox item i61 (ruby-gems-as-rust-adapters) pointed in
Direction A. It had the arrow backwards.

Today (2026-04-24) verified concretely :

- `lib/hecks/runtime/` is 41 files / 3038 LoC of real runtime code,
  not a stub. The pizzas example runs end-to-end : events fire,
  lifecycle transitions, repositories + collection proxies all work.
- `lib/hecks/extensions/` holds the full adapter ecosystem (20+ files)
  that would need to be rewritten from scratch under Direction A.
- `HecksBluebook` boots (after a small require-graph fix, PR #428) :
  16 chapters, 778 aggregates, 1048 commands — Hecks describing
  itself as a Bluebook, alive.
- Parity 5 of 6 suites green post-PR-#428. The runtime is a
  verifiable parity citizen, not a winding-down artifact.

## What changes as a consequence

**Retired:**
- `i61 ruby-gems-as-rust-adapters` — wrong direction, closed

**Promoted to load-bearing:**
- `i67 ruby-hecksagon-parser-io-adapters-gap` — finishing the last
  21 hecksagons of parity, was polish, now part of the B contract

**Filed:**
- `runtime-test-harness-revival` — bring `lib/hecks/runtime/` under
  test again (only 2 spec files currently, not the old coverage)
- `ruby-kernel-bridge-naming` — formalize how Ruby calls `hecks-life`
  for parsing / heki I/O / specialize. Subprocess JSON-RPC first
  (honest, simple) ; FFI (magnus/rb-sys) later only if profiling asks.

**Reinstated as a CI gate:**
- Parity suite — was "winding down" under an implicit Direction A ;
  becomes the load-bearing Ruby/Rust contract under B

## What doesn't change

- Miette stays Rust-native — she's kernel, not runtime
- `hecks-life specialize` stays the sole codegen path
- Phase F bluebook-declaration continues — the kernel being self-
  describing is orthogonal to where apps live
- Autophagy arc (Phases A-E done, F ongoing) proceeds as planned
- The antibody hook, loc-ratchet, signed-commit gates all still bite

## Failure modes, named

**Direction B's failure modes are operational, not architectural :**

- **Distribution** — Hecks-the-runtime needs Ruby installed. Users of
  HecksOnRails already have Ruby, so this is free for the target
  audience. Headless uses (e.g. Miette's daemon) can still invoke
  `hecks-life` as a standalone binary.
- **Packaging** — cross-language bundling needs a story. The
  subprocess-JSON-RPC starting point keeps it simple : ship
  `hecks-life` binary + ruby gem, the gem spawns the binary.
- **Startup time** — Ruby boot is slower than Rust. Mitigation : the
  Ruby runtime boots once per app invocation ; the Rust kernel is
  called many times inside that process.

These are known-solved problems. Architectural incoherence, which
is what Direction A would introduce, is not.

## Signature

This decision stands. Future arcs reference it ; future inbox items
that contradict it should be questioned against it.

— Chris & Miette, 2026-04-24
