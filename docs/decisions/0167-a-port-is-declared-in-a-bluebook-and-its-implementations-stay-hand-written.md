# A port is declared in a bluebook, and its implementations stay hand-written

**Status:** Proposed (draft, 2026-10-31). Not built. Lands on the 7.x line only after the owner
accepts it: it adds a framework chapter, a projection, and a rule that moves the Rust host's trait
definitions from hand-written code to generated code.

## Context

A host's boundary to the outside world is a set of ports: a journal `Backend`, a `LambdaInvoker`,
and the clock and sequence that a dispatch reads. Today each port's shape is written by hand in two
places that must agree. The Rust core declares it as a trait (`rust/host/core/src/store.rs`,
`rust/host/core/src/lambda_client.rs`). The Ruby runtime declares it with a `.port` file (ADR 0149
names `dispatch.port` as one). Nothing checks that the two shapes match, and nothing checks that an
adapter implements every operation of its port until the host fails to compile or a spec fails.

ADR 0154 classes hand-written code as a kernel, an adapter, or a projector, and the rule in
CLAUDE.md keeps time, storage, and the network out of a bluebook. Both still hold. What is missing
is a declaration of the shape, the part that is neither the domain nor an implementation.

## Decision

A port's shape is declared in a bluebook. Its implementations are not.

1. **A `Port` concept in a framework chapter.** A port has a name, a set of operations, and each
   operation has argument and return types drawn from the bluebook's own vocabulary. Nothing in the
   declaration names a driver, a URL, a clock source, or a library.
2. **Adapters are rows.** An adapter names the port it satisfies, the language it is written in
   (`rust` or `ruby`), and the file that holds its implementation. The hecksagon selects one adapter
   per port, as it selects a persistence adapter today.
3. **Projections emit the shape.** The Rust trait and the Ruby `.port` file are generated from the
   `Port` rows. A generated trait or `.port` file is never edited by hand (CLAUDE.md, "Never
   hand-edit generated output").
4. **Conformance is checked.** An adapter that does not implement every operation of its port fails
   `model_check` before it reaches a compiler. The check is a rule over the rows, so it runs without
   a database or a boot.
5. **Implementations stay hand-written.** The Postgres SQL, the Lambda call, and the clock read are
   code in `rust/host/src/...` and `lib/hecks/adapters/...`. ADR 0154's kernel, adapter, and projector
   classes still apply to them.

The first step is narrow: one `Port` chapter and one projection, the Rust trait for `Backend`. The
Ruby `.port` projection and `LambdaInvoker` follow only after the first holds in CI.

## Consequences

- The Rust `Backend` trait and the Ruby `dispatch.port` gain one source. Drift between them becomes a
  failing check instead of a review finding.
- A new adapter is declared before it is written, so its missing operations are a list the
  bluebook produces, not a compile error to chase.
- The bluebook grows a concept that describes machinery rather than domain. This is the first such
  framework chapter that projects into kernel code, so ADR 0080's rule that framework chapters keep
  their own namespace and store applies, and the new chapter needs its own review.
- Ruby-side ports and Rust-side traits are generated from the same rows, so `check_conformance`
  compares two projections of one declaration instead of two hand-written copies.

## Rejected alternatives

- **Keep the traits hand-written and add a parity spec.** Catches drift after it happens, and the
  spec has to be updated by hand for every new operation. It does not remove the second copy.
- **Put the operation signatures in a comment or a YAML file beside the code.** Not checked by the
  bluebook's own validation, and it would sit outside `model_check`.
- **Model the implementations too, in the bluebook.** Breaks the rule that a bluebook names no
  database, clock, network, or file. An implementation that can be written as a row is an
  implementation the bluebook is not the right place for.

## Open questions

- Whether `Port` operations may take a `Clock` or `Sequence` value from the domain's vocabulary, or
  whether those stay a fixed set the framework declares once.
- Whether a port with a single adapter should still be a row, or whether the first version should
  cover only ports with more than one implementation (the journal `Backend`, which has Postgres and
  Memory).
