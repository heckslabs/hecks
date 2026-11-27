# `LedgerOrdering` — retention note

**Kept.** Targeted at re-triggering, in a new business shape, the
divergence class ADR 0037's 2026-09-09 re-verification confirmed still
open on `Banking::Account.LedgerEntry.Amend`: an entity command
dispatched with both a nonexistent addressed element and an argument
that fails its own invariant.

**What this domain adds that pizzas/banking don't already cover**: a
*minimal, isolated* repro of the ordering question — one aggregate, one
entity, one command, nothing else competing for attention. Confirmed on
the Ruby side (`spec/ledger_ordering_spec.rb`): `Slip.Amend` against a
nonexistent `to.entity` carrying an invalid `amount.value` raises the
argument's own `InvariantViolation` before anything about entity
existence is even asked — same ordering LedgerEntry.Amend showed, but
here the failing argument (`amount`) is NOT the entity's own addressing
field (unlike LedgerEntry.Amend, where the addressing field itself was
the one with the unbuilt/uninvariant-checked type). That's a genuinely
different shape than the ADR's own finding, not a duplicate of it —
worth keeping on that basis alone.

**Rust-side confirmation — done, and it found BUG#13.** An earlier
version of this note said the domain was "authored and verified
Ruby-only" and that `bin/project_rust qa/stress_domains/ledger_ordering`
had not been run. That is stale: `rust/Cargo.toml` declares a
`ledger_ordering` feature, `rust/src/generated/ledger_ordering/` exists,
and `bin/qa_sweep ledger_ordering` runs this domain DIFFERENTIALLY (Ruby
vs the compiled binary). BUG#13 — a duplicate caller-supplied entity
identity accepted by one engine and refused by the other — was found
here exactly that way, on this domain's first real differential sweep,
and is the reason `SequenceGenerator`'s adversarial layer has a
`duplicate_entity_identity` mutation at all
(`lib/hecks/fuzzing/sequence_generator/adversary.rb`). The generator's
`refusal_precedence` mutation now also pairs `nonexistent` with
`mismatch` on purpose (the exact shape this domain was built to ask
about), so the ordering question is asked by every sweep, not only by
`spec/ledger_ordering_spec.rb`'s hand-written case.

`spec/rust_conformance_fuzz_spec.rb`'s `DOMAINS` includes this domain,
so the differential comparison is CI-gated here too, not only reachable
through the QA rotation.
