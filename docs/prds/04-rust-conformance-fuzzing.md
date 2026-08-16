# PRD 04 — Feed generated sequences through the Ruby/Rust conformance harness

**Status:** Not started.

## The problem

`spec/rust_conformance_spec.rb` compares Ruby's own replay output against
the Rust-generated runtime's, byte-for-byte, on `instances`/`events`/
`refusals`/`queries`/`sagas`/`reactions` — but only over a **fixed,
hand-authored corpus** (`Dir.glob(".../spec/corpus/rust_conformance/*.json")`).
`SequenceGenerator`'s randomly generated sequences never reach this
comparison at all. Two independently-built implementations of the same
dispatch semantics is exactly where fuzzing earns its keep — a generated
sequence that produces different observable output from Ruby's interpreter
than from Rust's generated code is unambiguously a real divergence in one or
the other; there's no third, more-authoritative implementation for either
side to hide behind.

## Approach

1. `SequenceGenerator.generate` already emits steps in "the exact shape
   `spec/corpus/*.json` already uses" (its own validity spec's own words) —
   confirm this holds for the `rust_conformance/*.json` fixture shape
   specifically (it may need a slightly different envelope; check before
   assuming they're identical).
2. Build a bridge: generate N sequences (seeded, so failures are
   reproducible), run each through both `Replay.call` (Ruby) and the Rust
   conformance binary the existing spec already shells out to, diff the
   two outputs the same way `rust_conformance_spec.rb` already does.
3. This is naturally slower than the existing fixed-corpus comparison (a
   Rust subprocess spawn per generated sequence) — budget for it running as
   its own `io: true`-tagged spec (subprocess spawn qualifies under the
   existing convention) rather than joining the everyday local loop, the
   same reasoning that moved `spec/fuzzing` itself to a post-commit hook
   this session.
4. On a real divergence, don't just report it — run it through `bin/fuzz`'s
   own existing shrinker (already built, already proven) to get a minimal
   repro before filing it as a finding.

## Acceptance criteria

- [ ] At least one generated (not hand-authored) sequence, per real corpus
      domain (Pizzas, Banking at minimum), runs through both engines and is
      diffed.
- [ ] A real divergence, if found, is shrunk to a minimal repro before
      being reported/fixed.
- [ ] The new fuzzed-conformance check is tagged consistently with the rest
      of the real-I/O/subprocess-spawning suite (`io: true`), not added to
      the everyday local loop.

## Non-goals

- Fuzzing the Rust *parser* itself (malformed syntax, adversarial tokens) —
  that's PRD 06's territory; this PRD is about dispatch-semantics
  conformance on *valid*, generated command sequences, not parser
  robustness.
- Extending this to WASM or any other Rust compile target — scope is the
  same conformance binary `rust_conformance_spec.rb` already shells out to.
