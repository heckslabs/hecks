# Canonical IR is runtime-independent

**Status:** Accepted — implemented (predates this document; recorded here for the first time)

## Context

This decision predates today's session — it's already true of the codebase and has been for a while — but it was never written down, and every later decision in this file leans on it, so it's recorded here rather than left implicit.

`Projector::Exporter` serializes a booted Bluebook to a hash/JSON. `Runtime::DeclarationSnapshot` reconstructs a real Bluebook from that JSON through `Bluebook::Assembly`, without re-running the original Ruby source. Era replay depends on this: a held era boots from its structured declaration, not from re-executing the `.bluebook` file that originally produced it.

The retired Rust runtime (`docs/rust-experiment.md`) failed by *not* leaning on this hard enough — it grew a second hand-written parser, dispatcher, and evaluator that had to be kept in differential parity with the Ruby implementation by hand. Every projection this project builds going forward needs to consume canonical IR, not re-derive meaning from Ruby source, or it repeats that failure.

## Decision

Canonical IR is the durable semantic representation of a Bluebook. Ruby is a high-quality authoring and runtime environment, but it is not the thing that has to be true for a Bluebook's meaning to be reconstructed, replayed, or projected — the IR is sufficient on its own.

Concretely: `to_h` / `Bluebook::Assembly` round-trip every construct; era replay reconstructs from stored declarations, not source; and any projection (SQL, UL, OIDC, and per [0007](0007-rust-generates-code-not-ruby-source.md), Rust) is defined as canonical-IR-in, target-artifact-out.

## Consequences

- Projections can be built and tested without loading the Ruby DSL at all — they consume a `.json` IR file.
- Era history survives even if the Ruby authoring surface changes shape, since replay doesn't depend on the original source still parsing under current Ruby code.
- Any new semantic feature must be representable in canonical IR, round-trip through `to_h`/`Assembly`, and get golden/corpus coverage where the wire shape changes — this is now a standing entry in the roadmap's "definition of done" for every feature, not a one-off checklist item.
- A second hand-written interpretation of Bluebook semantics (a second parser, a second dispatcher) is a decision that requires explicit approval — it isn't the default extension point.

## Rejected alternatives

- **Re-parsing Ruby source on every replay/projection.** This is what the retired Rust runtime effectively did (via differential parity with the Ruby side) and is the specific, named failure mode this decision exists to close off.
