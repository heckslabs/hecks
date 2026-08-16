# PRD 06 — Adversarial fuzzing for the Rust parser

**Status:** Not started. Zero existing fuzzing infrastructure on the parser
side, confirmed by grep (`rust/`, `spec/*pars*`) — every "fuzz" hit found is
a comment referencing the Ruby `Fuzzing::` module's JSON wire format, not an
actual Rust fuzz target.

## The problem

`spec/parser_parity_spec.rb`, `spec/parser_coverage_spec.rb`,
`spec/codegen_parity_spec.rb`, and `rust/parser/tests/gates.rs` are all real
and all valuable — but every one of them compares against **valid,
hand-written, or deliberately hand-picked-invalid** bluebook fixtures. None
of them throw genuinely adversarial input at the parser: malformed syntax,
deeply nested structures, huge inputs, random byte/token mutation of real
source. This is precisely the classic bug class a parser fuzzer exists to
find — crashes, panics, or undefined behavior on input nobody wrote a
fixture for, as opposed to input someone remembered to test.

## Approach

1. Stand up a `cargo-fuzz` (or AFL, if there's a reason to prefer it — worth
   a quick comparison, but `cargo-fuzz`/libFuzzer is the more common default
   for a Rust project with no existing fuzzing infra) target under
   `rust/parser/fuzz/`, seeded from the real corpus (`spec/corpus/*.json`'s
   own bluebook sources, `rust/parser/tests/fixtures/*`) so mutation starts
   from realistic structure rather than blind random bytes.
2. Fuzz the actual parse entry point `hecks-parse` (or whatever internal
   function it wraps) directly — the goal is "does this ever panic/crash
   instead of returning a clean error," not IR correctness (that's what
   parity/coverage specs already check on valid input).
3. Run it for a bounded budget locally (minutes, not hours) to establish it
   works and catches something in the seed corpus's own mutated
   neighborhood; the real, ongoing value comes from running it on a
   schedule (CI nightly, or a dedicated `bin/` target a session can kick off
   on demand) rather than a one-time pass.
4. Any crash found gets minimized (`cargo-fuzz` does this natively) and
   turned into a `rust/parser/tests/fixtures/` regression case — the parser
   should never regress on something it once crashed on.

## Acceptance criteria

- [ ] A real `cargo-fuzz` target exists, seeded from the real corpus, and
      runs clean for a bounded local budget without panicking.
- [ ] Any crash found during initial standup is minimized and fixed, with a
      regression fixture added.
- [ ] The target is runnable on demand (`cargo fuzz run <target>`) and
      documented (a short section in this PRD or a sibling doc — not left
      as tribal knowledge).

## Non-goals

- Fuzzing dispatch/runtime semantics (PRD 04's territory) — this is parser
  robustness only: does malformed/adversarial *syntax* ever crash the
  parser, not "does a valid-but-fuzzed command sequence behave correctly."
- Coverage-guided generation feeding back into `bin/fuzz` (PRD 08) — that's
  the Ruby-side generator's own separate concern; `cargo-fuzz` already does
  coverage-guided mutation internally for this PRD's own target, which is a
  different system entirely.
- Continuous/CI integration of the fuzz target on day one — get it standing
  up and catching real things locally first; wiring it into a schedule is a
  fast follow, not a blocker for calling this PRD's core value delivered.
