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

**Not yet done — real follow-up, not a gap in this note**: Rust-side
confirmation. `bin/project_rust qa/stress_domains/ledger_ordering` was
not run (this domain was authored and verified Ruby-only, given time
already spent getting `qa/bluebook/quality_control.bluebook` codegen-
compatible in the same session — see that domain's own PR #516 for the
`<domain>/bluebook/<domain-basename>.bluebook` naming constraint this
directory shape was deliberately built to satisfy). Next real QA-loop
sweep against this Target: run `bin/project_rust
qa/stress_domains/ledger_ordering`, then diff Ruby vs. the compiled
binary for the exact dispatch `spec/ledger_ordering_spec.rb` already
exercises. If Rust disagrees (most likely: answers `NotFound` instead,
matching LedgerEntry.Amend's own pattern), log it as a `Bug` in the
ledger and treat it as confirmation the divergence is structural
(applies to any entity command, not LedgerEntry-specific) rather than a
second, unrelated finding.
