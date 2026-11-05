# One kernel runs bluebooks, and Ruby is the front end

**Status:** Proposed. Supersedes, once accepted: ADR 0010 (Ruby is the reference implementation), ADR 0054b
(the Ruby generator stays primary), and point 6 of ADR 0154 (the Rust-only direction is paused). Nothing
here is built; step 0 is this record and the baseline below.
Date: 2026-11-05.

## Context

Hecks has two hand-written kernels. The Ruby runtime (`lib/hecks/runtime`, about 13.5k lines, plus about
9k lines of driven adapters) and the Rust kernel (`rust/src/kernel`, about 13.5k lines) both run
bluebooks, and every semantic change lands twice. `check_conformance` and the differential fuzzer exist to
catch the drift between them.

The Rust side adds three costs of its own:

1. About 257k lines of generated Rust are committed (`rust/src/generated`), and the kernel still reaches
   them through `generated::active` (typed structs, `ENTITY_QUERIES`, `check_query_args`, `present`).
2. The host core re-implements the kernel's evaluator (`rust/host/core/src/expr_json.rs`). ADR 0149 records
   that the two evaluators have already disagreed.
3. The host's drivers (web, api, payments, auth, about 57k lines) are compiled in, not behind sandboxed
   ports.

ADR 0010's tiebreaker role is already superseded by `docs/semantics` and the frozen corpus; both
runtimes answer to the corpus. ADR 0154 names the Ruby runtime a second hand-written kernel and leaves the
decision to retire it to the owner.

The owner's constraint: authoring and tooling stay in Ruby, and authoring must stay quick. Taking a
domain from a Memory-backed trial to real adapters is a hecksagon change, not a domain change.

## Decision

1. **One kernel runs bluebooks: the Rust kernel.** It does no I/O (ADR 0012) and interprets canonical IR
   (ADR 0011, 0027). It stops depending on committed generated code.
2. **Ruby is the front end and the tooling.** It parses and checks bluebooks, emits canonical IR, projects
   other outputs, and drives the CLI. It does not execute domains.
3. **Ruby reaches the kernel over one host protocol**, the promoted `--serve` line-JSON mode, with
   sessions, events, and a callback channel for Ruby-side hooks. The CLI, Rails, MCP, hecks-client and
   agents are all clients of it.
4. **The authoring loop is a gate, not a hope.** A Ruby dispatch against a warm kernel must be no slower
   than today's in-process path for a typical domain. If the binding misses, a light Ruby interpreter
   stays for local trial runs only, and the decision to retire the runtime waits.
5. **The corpus is the oracle.** `docs/semantics` plus `spec/corpus` define behavior. Property tests, QA
   findings and behaviors are folded into it before any engine is deleted.
6. **Order of work** is in the plan: contract, one evaluator, kernel without generated code, host
   protocol, Ruby binding, retire the Ruby runtime, Wasm adapters, one event log, simulation tests,
   grammar as product. Each step ships on its own and the sequence can stop after any of them.

## Baseline

Measured 2026-11-05 on the maintainer's machine, from a fresh worktree:

| Measure | Reading |
|---|---|
| Cold `exe/hecks` (grammar boot) | 7.8 s wall |
| Warm `exe/hecks` | 0.90 s wall, 0.40 s user |
| Floor: `require "bundler/setup"` only | 0.35 s wall, 0.14 s user |
| Committed generated Rust | about 257k lines |
| Ruby runtime plus driven adapters | about 22k lines |

Wall time on this run is noisier than the user time; `docs/cli-measures.md` holds the budget method
(a ratio to the floor, five fresh processes). Parity-bug count and authoring-loop dispatch latency are
not yet measured and are the first two readings of step 0.

## Consequences

- Every semantic change is made once.
- About 257k lines of generated code, most of `rust/codegen`, and the per-domain `dist/*.wasm` builds
  leave the repository once the kernel interprets IR.
- Roughly 477 specs and `packages/hecks-rails` boot the Ruby runtime today and move to the binding.
- The live Ruby oracle goes away; the corpus and the differential fuzzer must carry its weight first.
- `postgres_era` (about 4.8k lines) is the riskiest move, because eras are minted by both runtimes
  (ADR 0029, 0030, 0036, 0079). It goes last.

## Rejected alternatives

- **Keep two kernels.** The parity cost is permanent and grows with every feature.
- **Retire Ruby entirely.** Authoring in Ruby is the owner's constraint, and the DSL is where authors work.
- **A big-bang rewrite.** The payoff arrives only at the end and the risk is paid up front. Each step here
  stands alone.
