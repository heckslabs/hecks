# Step 5 of ADR 0188: `Hecks.boot` as a thin client of the kernel

Status: a plan, nothing built. Base: `origin/main` at `aaca83089`. Date: 2026-11-05.
Goal: Ruby stops executing domains. `Hecks.boot` returns a dispatcher whose `dispatch` is a line of
the host protocol (ADR 0189) sent to a warm `rust --serve` process. Every slice ships alone and
leaves Ruby behaviour byte-identical until the one slice that flips a default.

What follows says what was **read** and what is **inferred**; an inference is marked.

## What the code is today (read)

| Piece | Where | State |
|---|---|---|
| Protocol server | `rust/src/kernel/serve.rs` (300 lines) | `hello` (version, features `sessions` `callbacks`, `needs`/`query_needs`/`defaults` tables), `open`/`close` sessions, one callback kind: `ask: "fact"` |
| Ruby client | `lib/hecks/rust_build/kernel_client.rb` (108 lines) | spawns `binary --serve`, `dispatch(verb, args, session:)`, answers callbacks from one block. Only caller: `spec/rust_build_kernel_client_spec.rb` (`:io`) and the bench |
| Kernel loads a domain | `rust/src/kernel/cli.rs` | **Not by IR yet.** The binary is built per domain (`cargo build --features pizzas`); `generated::active` still routes dispatch. Only `present` takes an `"ir"` key (`ir_presenter.rs`) |
| Kernel store | `rust/src/kernel/repository.rs` | in-memory only (`InMemoryRepository`); `seed`, `snapshot`, `restore` exist per session |
| Tables the host builds | `lib/hecks/rust_build/kernel_input.rb` | `defaults`, `needs`, `query_needs`, read from the domain's generated IR |
| Bench | `lib/hecks/bench` (`FuzzRun.bench!`) | targets `ruby:memory` and `rust`, workloads pizzas and banking; baseline in ADR 0188 |

Two consequences that shape everything below:

1. **Step 3 (kernel without generated code) is not finished.** Until the kernel takes a domain's IR
   at `hello`, "boot any domain" through the client is impossible; a per-domain binary is the only
   thing slice 1 can use. (inferred from `cli.rs`: six `generated::` references remain.)
2. **The protocol covers facts only.** Nothing in it lets the kernel ask Ruby to save a record,
   call a port operation, or let an adapter dispatch back into the same boot.

## Map of the in-process consumers (read, counted with grep on this tree)

`Hecks.boot` / `boot_files` / `boot_described` / `Runtime::Loader.boot*` appear in about 67 files
under `lib`/`exe`/`packages` and 147 spec files (of 623). Grouped by what they need from the
returned dispatcher:

| Group | Examples | What it uses | Kind of move |
|---|---|---|---|
| Launcher | `exe/hecks`: `Hecks.describe` then `Hecks.boot_described(described, install_driving: false)` then `CliRunner.call(runtime:)` | usage and help read the *described* registry (no boot); only a command line boots | `describe` stays Ruby (front end). Only the boot half moves |
| Driving adapters | `lib/hecks/adapters/driving/` `cli_runner`, `mcp`, `handle`, `ruby` (facade constants), `json`, `github_webhook`, `admission`, `write_guard` | `runtime.dispatch`, `runtime.query`, `runtime.registry`, `runtime.events` | mostly free once the client dispatcher has the same surface; the `ruby` facade calls `dispatcher.dispatch` (inferred, confirm in slice 4) |
| Tooling that boots domains | `lib/hecks/tools/*` (history, follow, run, stores, console, ir, ...), `lib/hecks/fuzzing/*`, `lib/hecks/bench/ruby_runner.rb`, `lib/hecks/hecks/adapters/in_process_boot.rb`, `composer/*`, `projections/deploy/*` | the same surface, plus direct reads of `registry`, `events`, repositories | move one family at a time (slice 8); `bench/ruby_runner.rb` and `fuzzing` **stay in-process on purpose**: they are the oracle until the corpus carries it (ADR 0188 point 5) |
| Rails | `packages/hecks-rails/lib/hecks/rails/booted.rb`: `Hecks.boot` then `registry`, `declaration(name)`, `door` (the installed `Module::Aggregate` constants) | declarations and the facade, not execution | `registry` stays Ruby-side (from `describe`); only `dispatch` and reads go to the kernel. Its specs (`packages/hecks-rails/spec`, 12 files) boot a `ledger` fixture |
| hecks-client | `packages/hecks-client` (TypeScript) | not read in depth | a second client of the same protocol; it is where the declared vocabulary (ADR 0189 follow-up) pays off. Out of scope for the Ruby slices |
| Specs | 147 files; 102 directly under `spec/`, 12 in `spec/runtime`, 7 in `spec/support`, 6 in `spec/adapters/driven` | | three classes, below |

Spec classes (inferred from directory names, to be confirmed by running the census in slice 8):
(a) **specs of the Ruby engine itself** (`spec/runtime`, adapters): stay in-process until step 6;
(b) **specs that only need a booted domain and check events or state**: run under the client by a
CI leg; (c) **specs a `.behaviors` file can replace**, the pattern of #1216 ("Port six runtime specs
to .behaviors files"): port them, which the oracle plan needs anyway.

## Ruby-side hooks that need the callback channel (read)

| Hook | Where | Today | Needs from the protocol |
|---|---|---|---|
| `needs` (`now`, `today`) | `runtime/needs.rb`: filled *before* dispatch from `Ports::Clock.now(registry)` | built | already in v1 (`ask: "fact"`); the client must build the `needs` table from IR automatically and answer from the registry's clock port, so a spec that binds a fake clock still works |
| `Asking` | `runtime/asking.rb`, bound around every adapter call in `port_operation_interpreter.rb:119`; readers in `bulk/row_sweeper.rb`, `quality_control/adapters/run_reader.rb`, `push_due_reader.rb`, `hecks/adapters/git_rehearsal/due.rb` | an adapter answering a port operation **dispatches back into the same registry** from inside the ask | a new callback kind (`ask: "port"`: domain, aggregate, operation, args) **and re-entrancy**: ADR 0189 says the host answers a callback "before it sends anything else", so a nested dispatch is forbidden by the current text. Needs a protocol decision (slice 6) |
| Ruby driven adapters (`lib/hecks/adapters/driven`, 19 `.adapter` files, about 3,200 lines; `hecks/adapters` for tooling) | git, GitHub, desktop alert, deploy toolchain, claude sessions, ... | called by the Ruby interpreter during a policy or port operation | same `ask: "port"` callback; the kernel does no I/O (ADR 0012) so these can only be callbacks |
| Persistence (Heki, Sqlite, Postgres, PostgresEra, D1) | `adapters/driven/*` | Ruby repository classes behind the registry | **not a hook the protocol has.** Needs a storage callback or a kernel-owned journal. The biggest open design question; see risks |
| Event tap, event log, outbox, reaction/saga logs | `runtime/event_tap.rb`, `event_log.rb`, `outbox.rb`, dispatcher `events`, `reactions`, `sagas` | Ruby objects the dispatcher exposes | the answer's `events` array rebuilds Ruby `Runtime::Event` objects and fills these logs on the Ruby side; the tap keeps writing from Ruby |

## The gate (ADR 0188 point 4)

Measured with the existing bench, one new target so nothing existing moves:

- Add target `rust:client` to `Hecks::Bench::Suite::TARGETS`: the same workloads (pizzas, banking),
  200 warm-up and 1,000 timed cycles, median of 5 fresh boots, but timed *through the `KernelClient`
  dispatcher including the Ruby work on the answer* (events rebuilt as Ruby objects, logs filled).
  The existing `rust` target times a raw pipe and understates the client.
- **Pass:** `rust:client` p50 is at most `ruby:memory` p50 for every workload (pizzas 186 us,
  banking 409 us on the baseline machine), and p99 is at most 1.5 times the in-process p99. Read
  as a ratio on the same run, not as absolute microseconds (the baseline notes a load average
  of about 13).
- **Three extra workloads, because the baseline excludes them** (ADR 0188 says so): a verb that
  `needs` a fact (one callback per dispatch), a verb whose policy calls a Ruby port operation
  (callback plus re-entrant dispatch), and a 10-event reaction cascade.
- **Boot cost, separately:** the kernel spawn, `hello` and IR load added to the front of
  `exe/hecks`. Measure with `docs/cli-measures.md` (a ratio to the floor, five fresh processes);
  the warm `exe/hecks` is 0.90 s wall, 0.40 s user, and a per-invocation child must not add more
  than the budget that doc names. (The doc's number was not read; confirm it in slice 2.)
- **Fallback if the gate misses:** `Hecks.boot(path, engine: :ruby)` (and `HECKS_ENGINE=ruby`) keeps
  the in-process interpreter for local trial runs. The switch ships in slice 1, so the fallback
  exists from the first day and the gate only decides the *default* (slice 10). If the callback
  workloads miss but plain dispatch passes, the default flips for domains with no Ruby port
  callbacks and the Ruby interpreter stays for the rest. A miss also holds step 6 (retiring the
  runtime), as ADR 0188 says.

## Slices

Order matters where areas overlap: 4, 5, 6, 7 all touch `lib/hecks/rust_build/` and the protocol and
must run in sequence; 8 and 9 touch disjoint consumers and can run side by side once 5 has landed.

| # | Slice | Outcome | Area | Depends on | Who |
|---|---|---|---|---|---|
| 1 | **Pizzas through the client** | `Hecks.boot("examples/pizzas...", engine: :kernel)` returns a `KernelDispatcher` over a `KernelClient` and a per-domain binary (built the way `build_rust_for` does). A twin spec dispatches the pizzas bench cycle through both engines and compares the events as canonical JSON (name, aggregate, attributes; `occurred_at` fixed by a bound clock). Default stays `:ruby`; an unknown or unavailable binary refuses by name and does not fall back silently | `lib/hecks/rust_build/`, `lib/hecks/runtime/` (new dispatcher class), `spec/` | none | coder |
| 2 | **The gate** | `rust:client` bench target and the three extra workloads; the report prints the ratio and pass/fail against the rule above; no default changes. Adds the boot-cost measurement | `lib/hecks/bench/` | 1 | coder |
| 3 | **Load by IR** | the kernel takes the domain's canonical IR at `hello` (or `load`) instead of a feature build; Ruby sends `Hecks.describe`'s IR. This is the unfinished part of ADR 0188 step 3 and is owned there; this plan only consumes it. Slice 1's per-domain binary is replaced by the one binary | `rust/src/kernel/` | step 3 | not a coder item here: it belongs to step 3 and needs the owner's sequencing |
| 4 | **The dispatcher surface** | `KernelDispatcher` answers everything `Runtime::Dispatcher` is asked: `dispatch`, `dispatch_flat`, `dry_run?`, queries, `events`, `reactions`, `sagas`, `outbox`, `verbs`, `registry` (from `describe`), `redrive_sagas!`; a refusal (`ok: false`, ADR 0186) is raised as the same Ruby error class and message the in-process path raises (`NotFound`, `GivenNotMet`, `UnknownArgument`, ... see `refusal_wording.rb`). Twin spec grows from pizzas to banking and the corpus domains | `lib/hecks/runtime/` (client dispatcher), `spec/` | 1 (3 for non-pizzas without a build) | coder |
| 5 | **Facts and the generated tables** | `hello` is built from IR automatically (`needs`, `query_needs`, `defaults`, replacing the test-only `KernelInput` call); the answerer reads the registry's clock port, so fake clocks in specs keep working; the `needs` extra workload is in the gate | `lib/hecks/rust_build/` | 4 | coder |
| 6 | **Port callbacks and re-entrancy** | amend ADR 0189 (new ADR): `ask: "port"` callback, and a rule for a nested dispatch from inside an ask (options below). Kernel and client implement it; `Asking.with(registry)` is bound by the client around the Ruby adapter call so `run_reader`, `push_due_reader`, `row_sweeper` and `git_rehearsal/due` work unchanged | `rust/src/kernel/serve.rs`, `lib/hecks/rust_build/`, `docs/decisions/` | 5 | design and ADR: the owner; implementation after acceptance: coder |
| 7 | **Persistence** | a decision, then a build: see options below. Until it lands, `engine: :kernel` **refuses by name** any domain whose resolved persistence is not Memory, and the default engine serves it | `docs/decisions/`, `rust/src/kernel/`, `lib/hecks/adapters/driven/` | 6 | the owner decides; architect drafts; coder builds |
| 8 | **Driving adapters and Rails** | `cli_runner`, `mcp`, `handle`, `ruby` facade and `packages/hecks-rails` run over the client dispatcher under `HECKS_ENGINE=kernel`; their existing specs pass in both engines. Rails keeps `Booted.registry`/`declaration`/`door` from the described registry | `lib/hecks/adapters/driving/`, `packages/hecks-rails/` | 4 (5 for `needs`) | coder |
| 9 | **Specs under the kernel** | a CI leg runs the class (b) specs with `HECKS_ENGINE=kernel`; class (c) are ported to `.behaviors`; class (a) stay. A list of known-different specs shrinks per slice. Must respect "keep CI under three minutes": the leg lives in a Rust job that holds the cargo cache, never a Postgres io shard | `spec/`, `.github/workflows/` | 4 | coder; the workflow edit goes through the generated-workflow command, not by hand |
| 10 | **`exe/hecks` and the default flip** | `exe/hecks` boots through the client for commands whose world is Memory or whose persistence slice 7 covers; the default engine flips only when slice 2's gate passes on CI hardware and slice 9's leg is green; `engine: :ruby` stays as the light interpreter | `exe/hecks`, `lib/hecks/assembly.rb` | 2, 7, 8, 9 | the flip is the owner's call; the `exe/hecks` change is a coder item after it |

Slices 1, 2, 4, 5, 8, 9 go to the coder role. 3, 6 and 7 start with a decision (and 3 is another
step's work); 10's flip is the owner's.

## Choices for the owner

**A. How does a nested dispatch from inside a Ruby adapter work (slice 6)?**
1. Allow the host to send one nested step while a callback is open, replied to before the callback's
   answer. Smallest change; the kernel must be re-entrant on the same session (it holds a `Session`
   mutably during `handle`, so this is a real change).
2. A second connection to the same store (named "not built" in ADR 0189). Cleaner, needs shared state.
3. Forbid it: the adapter returns data and the kernel dispatches the follow-up. Changes adapter code.
Recommend 3 where an adapter only reads, and 1 for those that dispatch (`row_sweeper`). Your call.

**B. How does a non-Memory domain persist (slice 7)?**
1. Storage callbacks (`ask: "load"`/`"save"`) into the existing Ruby repositories. Keeps every
   adapter; costs a round trip per read or write, which will probably miss the gate on write-heavy
   domains (inferred).
2. The kernel keeps state in memory and emits its events; Ruby writes the journal and reseeds with
   `seed` at boot. Fast, but moves the source of truth to the event log and touches eras (ADR 0029,
   0030, 0036, 0079), the risk ADR 0188 puts last.
3. Memory only through the kernel; persisted domains stay on the Ruby interpreter until step 6 of
   ADR 0188 decides. Ships soonest and is the fallback anyway.
Recommend 3 now and 2 as the design for step 6. Your call.

**C. Process lifetime.** (1) one child per Ruby process, killed at exit; (2) a long-lived daemon
that `exe/hecks` attaches to over a socket, which is what "warm" means across CLI invocations but
is a new transport ADR 0189 rejected for now. Recommend 1; measure boot cost in slice 2 before
deciding whether 2 is needed.

**D. Where the Ruby `Event` comes from.** Rebuild `Runtime::Event` from the answer's JSON (recommended:
the logs and subscribers stay Ruby), or hand callers the Hash. The first keeps subscribers working.

## Risks

- **Slice 1 is a proof, not the product.** It uses a feature-built binary and pizzas alone, so it
  says nothing about arbitrary domains or persistence. Do not read a pass as the gate passing.
- **Byte identity is bounded by what the twin spec compares.** Events and error text are compared;
  hash ordering, float formatting and `occurred_at` are the likely differences. ADR 0149 records
  that two evaluators already disagreed once.
- **Re-entrancy deadlock.** A Ruby adapter that dispatches while the kernel waits on a callback would
  hang today. Refuse it by name in the client until slice 6.
- **Callback cost.** Each callback is a pipe round trip plus JSON each way; a policy chain that asks
  per step can lose the 15x margin. The extra gate workloads exist to see this early.
- **A spec that touches live state.** The client spawns a process; specs must give it a temporary
  tap (`HECKS_EVENT_TAP`) as the repo's guards demand.
- **Build time in CI.** A feature build per domain costs minutes without the cargo cache; the leg in
  slice 9 must sit in a job that holds it (see "Keep CI under three minutes").
- **Two kernels remain until step 6.** Every slice keeps both, so a semantic change still lands twice
  until retirement; the twin spec is what stops drift in the meantime.
- **The oracle.** Slices keep `fuzzing` and `bench/ruby_runner.rb` in-process on purpose; porting
  them early would remove the comparison the retirement decision needs.

## Not checked

`packages/hecks-client`, the cli-measures budget number, the exact surface list the Ruby facade
calls on the dispatcher, whether the kernel's `--serve` answers queries (the step shape for queries
was not read), and the real spec census for the three classes. Slices 1, 2 and 4 each begin by
checking the part they depend on.

## Overlap with open work

`exe/hecks tickets Work.undone` was searched for the kernel, host protocol, thin client and boot:
no open Work item covers step 5. (Matches were bluebook-gap items that mention Rust kernel rules.)
`exe/hecks agents PlanReview.reviews` printed only persistence warnings and no review. No Work
items are created by this document.
