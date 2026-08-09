# Rust is a code generator over canonical IR, not an interpreter of it

**Status:** Superseded by [0011](0011-rust-compiles-types-interprets-dispatch.md) — the implementation this ADR specified was built, on a materially different architecture, documented in `docs/HECKS_IMPLEMENTATION_PLAN.md` §8's "What actually got built." The central claim below — no generic kernel interpreting IR-derived data at runtime — is the one thing 0011 does on purpose, for reasons that only became clear once per-command-shape codegen was actually attempted and didn't converge. Kept in full as the reasoning that motivated the *attempt*, not as a description of what exists. The original entry criterion below (wait for Phases 2–4 to stabilize) was already superseded by [0010](0010-ruby-is-the-reference-implementation.md) before that.

## Context

A Rust runtime was built once already and retired (`docs/rust-experiment.md`). It failed economically: a second parser, dispatcher, evaluator, and adapter stack were hand-written and kept in differential parity with the Ruby implementation by hand. Generated shapes were a small fraction of the Rust code; the expensive part was duplicated interpreter behavior, and it ran as a generic runtime that read Bluebook definitions at boot — which is exactly where the parity burden crept back in, over and over, as Ruby changed.

Rust was subsequently pruned from the roadmap as obsolete, then restored, then re-scoped through direct correction of an initial (wrong) design: the first restoration described Rust as "consuming canonical IR," which is ambiguous about *when* — and a generic runtime that reads IR at boot is structurally the same failure mode as before, just reading JSON instead of Ruby source.

## Decision

**Rust is a build-time code generator, not a runtime interpreter.** A tool reads canonical IR once, at build time, and emits native Rust source — types for records/value objects, a dispatch table, and per-command argument gates, role checks, `given` evaluation, mutation application, and event emission, all as real generated Rust code. That generated code is what compiles. A small hand-written kernel supplies only genuinely domain-independent infrastructure (a repository trait, evaluator primitives the generated code calls into, the dispatch entry point).

The governing invariant: **no canonical IR is parsed or interpreted at runtime; runtime behavior is compiled into native code.** This is deliberately narrower than "nothing IR-shaped exists in the binary" — the generator may also emit compact static metadata (for introspection, evidence, diagnostics, explaining a refusal), as long as that metadata is *read*, never *interpreted* to decide behavior. Behavior comes only from generated code paths.

**Every held era is covered, not just current.** The semantic requirement — the compiled artifact can execute or query any held era, matching Ruby's era-replay capability — is separate from how that gets implemented. The initial implementation generates one module per held era with an era-selecting dispatch entry point; this is an explicit scaling concern for long-lived domains, not a permanent architecture, and later work may deduplicate unchanged behavior across eras without touching this invariant. Minting a *new* era still requires rerunning codegen and recompiling — nothing is added to a running binary.

**There is one runtime, not a family of host bindings.** WASM is a compile target of the same generated artifact, not a separate implementation. Ruby-hosts-Rust, Python, Go, and Java bindings were removed from the roadmap entirely rather than kept as speculative alternative runtimes — if those ecosystems matter later, they bind to the one generated/compiled artifact via each language's native FFI mechanism, they do not get their own execution engine.

~~**Entry criterion — Rust work does not start until the IR is ready.** Specifically: the canonical IR introduced by authority/identity (`act_as`, Governance, Identities), and ontology/provenance (UL projection) must be stable *and* exercised by a real canonical corpus, not merely scheduled. "Stable" here means versioned and targetable as a runtime contract — not frozen, since eras mean the IR keeps evolving by design; what Rust needs is disciplined versioning and compatibility expectations, not permanent stasis.~~ **Superseded by 0010:** Rust starts now, against whatever IR exists today, validated continuously against Ruby by a differential harness (see 0010) rather than gated behind later phases landing first.

## Consequences

- A `.json` canonical IR file, at build time, is sufficient to generate a working Rust artifact — no Ruby process is involved in that generation, and no Ruby or IR file is required at runtime.
- New Bluebook syntax that affects canonical IR requires little or no handwritten Rust parsing work, because there is no Rust parser to update — only the generator's output templates.
- Roadmap placement (§8 and Phase 2 — see 0010) starts early and runs concurrently with authority/identity/ontology-adoption work rather than waiting behind it; each phase's IR/behavior additions extend the generator and, where behavioral, the kernel, verified by 0010's differential harness before they count as done.
- Any future non-Ruby runtime (Go, Java, or otherwise) inherits this same invariant by construction, since the roadmap now treats "the runtime" as singular.

## Rejected alternatives

- **A generic Rust runtime that reads canonical IR at boot.** This is the retired architecture's actual failure mode restated with JSON instead of Ruby source as the input — the parity burden is orthogonal to which format is being read at boot.
- **A family of separate host-language runtimes (Ruby-hosts-Rust, Python, Go, Java), each with its own execution model.** Considered and rejected explicitly: it reintroduces the "second/third/fourth interpreter" problem this decision exists to avoid. The one exception the roadmap keeps is a genuinely different, lower-priority, explicitly-labeled shape — a generic Rust core dynamically fed IR at runtime by a single host — but that shape is not the default and is not this decision's primary path.
- **Embedding the IR itself as static data in the binary, with a generic kernel walking it.** Rejected in favor of the generator emitting real, per-command Rust code. A kernel that walks embedded IR-shaped data to decide behavior is still an interpreter; it just moved the interpreted data from a file to `.rodata`.
- **Treating "stable enough for Rust" as "frozen."** Rejected as the wrong target, since canonical IR evolving is the entire premise of eras — the actual requirement is versioning discipline, not immutability.
- **Minting an era specifically to mark "IR is now Rust-ready."** Not evaluated as necessary here, since era-minting is IR-shape-driven (see [0008](0008-reports-are-business-facing-read-models.md)'s investigation into the same mechanism) — readiness for Rust is a corpus/golden-test property, not a shape change requiring its own era.
