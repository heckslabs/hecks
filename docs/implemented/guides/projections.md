# Projections: Rust and WebAssembly

The point is not "hecks also supports Rust." It's that the bluebook is
the one authoritative definition of a domain, and everything else —
including *where code runs* — is a **projection** of that definition,
generated, not hand-maintained a second time.

```text
.bluebook  →  canonical IR  →  generated Rust source  →  native binary
                                                       →  WASM (WASI or browser)
```

## The canonical IR

Every projection starts from the same data: the canonical IR a booted
domain exports. `bin/project_rust` reads exactly this export (through a
JSON round-trip) before it writes a line of Rust.

<!-- doctest:boot
Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))
Hecks.hecksagon("Pizzas") do
  uses_framework "Governance"
  Pizzas::Order.persisted_by("Memory")
end
Hecks.hecksagon("Governance") do
  Governance::RoleAssignment.persisted_by("Memory")
  Governance::RoleTransition.persisted_by("Memory")
end
-->

```ruby
ir = Hecks::Projector::Exporter.call(runtime.registry).fetch("Pizzas")

ir[:ir_version]                                   # => 1
ir[:aggregates].map { |aggregate| aggregate[:name] } # => ["Order"]
```

[Running a runtime](running-a-runtime.md) walks the IR's shape field by
field.

## From IR to Rust

`bin/project_rust <domain>` reads a booted domain's canonical IR and
generates typed Rust structs and enums for every value object, entity,
and aggregate record. `given`/`ensures`/mutation logic stays data,
interpreted at runtime by one small, hand-written kernel
(`rust/src/kernel/{expr,dispatch}.rs`) that walks it exactly the way
`CommandInterpreter#call` does in Ruby — so extending the language
means extending one interpreter twice, not maintaining a second
hand-written implementation that silently drifts. The parser is
generated too (`bin/project_parser_table`, from the language's own
`Syntax` chapter), not hand-written a second time either.

Ruby is the reference implementation; Rust is checked against it
continuously, not just at release time: `spec/codegen_parity_spec.rb`
holds Rust's generated output byte-identical to Ruby's, and
`spec/rust_conformance_spec.rb` replays every pinned fixture script in
`spec/corpus/rust_conformance/` through the compiled binary, diffing instances, events, refusals,
reactions, sagas, and query rows against Ruby's byte-for-byte, in CI,
on every push. That parity is proven on the pinned fixtures and on the
whole-script corpus members promoted below. Measured
directly in this repository, generating and building the `pizzas`
domain from a clean `rust/src/generated/`:

```sh
$ bin/project_rust examples/pizzas      # canonical IR → Rust source
# ~4s

$ bin/project_wasm examples/pizzas      # cross-compiles the SAME binary to wasm32-wasip1
# ~13s cargo build --release; produces rust/dist/pizzas.wasm (551 KB)

$ wasmtime run rust/dist/pizzas.wasm < spec/corpus/pizzas.json
# real dispatch output — instances, events, refusals — matching Ruby's
```

The whole `spec/corpus/banking.json` script is held to the same bar: the
conformance spec replays it in full against the compiled binary and
requires instances, events, refusals, queries, sagas, and reactions to
match Ruby byte-for-byte. Replaying it found two refusals Rust worded
differently from Ruby (a value object offered as a bare scalar, and a
read model asked for a record that does not exist), both fixed in Rust.
`spec/corpus/chess.json` is held to the same bar and agreed from the start.
Corpus scripts are promoted to that whole-script bar one at a time; the
rest are covered by the smaller pinned fixtures, or have no Rust build of
their own to compare against: the framework/grammar
[chapters](../../../README.md#chapter)
(`governance`, `identity`, `console_settings`, `expression`,
`translation` — `lib/hecks/framework` and `lib/hecks/grammar`) have no
Cargo feature and are only folded into the build of a domain that
attaches them. The history of the Ruby/Rust divergence findings is in
[`docs/audits/2026-08-11-bug-triage.md`](../../audits/2026-08-11-bug-triage.md)'s
R1–R4.

## Queries and read models in Rust

Named/declared aggregate queries and `read_model` ("report") execution
in Rust cover a real, proven subset — not "no Rust path at all," and
wider than a single-field, single-aggregate query: a `where` that hops
through one reference (`Banking::Account.OpenForSuspendedCustomers`),
an `order_by`/`limit`/`offset` on a plain field
(`Banking::ATMCard.ByFee`), and a read model whose one many-side head
carries `where`/`order_by`/`limit`/`offset` — including ADR 0055's
`on:` naming which of *several* many-side heads each option applies to
(`Banking.ComplianceDashboard`) — all execute for real and match Ruby
byte-for-byte; as of this writing every read model and query in the
real corpus generates and runs (`bin/rust_coverage --check-allowlist`
finds no allowlisted gap left to justify). A query or read model this
generator genuinely can't compile — a multi-hop reference chain, a
where clause on a field whose kind can't be resolved from the exported
IR, `cursor`/`consistency`/`inspection` — refuses with an explicit "is
not generated for this domain" error in Rust instead of running; both
sides are documented, allowlisted gaps (`rust/project/queries.rb`,
`rust/project/read_models.rb`, `bin/rust_coverage`'s own allowlist), not
silent wrong answers.

## WebAssembly

That WASM artifact is not a second implementation compiled for a
different target — it is `rust/src/main.rs`'s stdin/stdout JSON CLI,
unchanged, cross-compiled ([ADR
0012](../decisions/0012-wasm-via-wasi-stdio.md)): it reads a step
list on stdin and writes the same `{"instances","events","refusals"}`
shape the native binary and Ruby both produce, so a runtime built for a
browser tab, an edge function, or a sandboxed plugin host runs the
*same checked semantics* — no server, no Ruby, no database — as the
one CI holds equal to the reference implementation. A separate
`wasm-bindgen` build (`bin/project_wasm_browser`) targets an ES module
for the browser specifically.

## What this buys, and what it does not yet claim

What this buys, concretely: the business definition is not coupled to
where or how it executes. A human or an AI agent edits the bluebook;
hecks validates it against the same semantics regardless of target,
then projects it to whichever execution form the deployment actually
needs — a Ruby process talking to Postgres, or a portable binary with
no runtime dependencies at all. Deployment (SAM/Lambda templates via
`bin/project_deploy`, an OIDC manifest via `bin/project_oidc`, a
standalone CLI via `bin/project_cli`) is downstream of that same
projection step, not a separate hand-authored artifact.

What this does *not* yet claim: throughput and latency are measured only
by a single-machine harness (`bin/bench`; the [baseline and its
caveats](../../benchmarks.md)), not under a production-like load,
`read_model` queries outside the proven subset above are refused in Rust
rather than run, and the WASM projector is one command away
(`bin/project_wasm`) but not part of any deployed pipeline today. See
[Running a runtime](running-a-runtime.md) for
the exact field-by-field contract a third dispatch runtime would need,
and [the retired first Rust
runtime](../rust-experiment.md) for why hand-writing a
second implementation was tried and abandoned before this
generate-and-check architecture replaced it.

## Launcher options a world file switches on

A generated launcher accepts `verb name=value`, `--flag` booleans and one positional first
argument in every domain. A domain's `.world` can add more with a free-form `launcher` setting:

```text
launcher "Launcher", run_keys: true,
                     failure_states: %w[flagged failed],
                     names: { "mcp" => "serve_mcp" }
```

- `run_keys` mints the `run` key of a creating command given none, through the identity port,
  and answers it as `run`. An explicit `run=` wins.
- `names` gives a command the name the launcher lists; the internal spelling keeps working.
- `failure_states` names the lifecycle states `--wait` treats as a failure. `--wait` re-reads
  the record after its reactions ran, prints its final state and events, and exits 1 in a
  failure state. A verb that declares its own `wait` argument keeps it.

A policy reaction the domain refused does not undo the command that fired it. The answer lists
it under `refused_reactions`, read from the dispatch result (`Dispatcher::Result`). Each
dispatch collects its own reactions per thread, so concurrent dispatches on one runtime do not
mix them.
