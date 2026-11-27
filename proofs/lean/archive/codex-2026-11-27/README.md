# Codex session of 2026-11-27: the "one Relationship" experiment, preserved verbatim

STATUS: ARCHIVE, UNREVIEWED. Preserved so nothing is lost. Not the canonical proof project (that is `proofs/lean/` once its toolchain pin and CI job exist), not wired into CI, not a claim that Relationship is sufficient. Private; nothing here is published, merged to main, tagged or released.

## Provenance
- Source: `/Users/christopheryoung/Documents/Codex/2026-11-27/referenced-chatgpt-conversation-this-is-an/` on the owner's Mac. `outputs/` is copied whole; from `work/` every text file under 400 KB (Lean sources, Ruby probes, JSON audits, logs) is copied. Hashes: `MANIFEST.sha256`.
- NOT copied: `work/lean-4.36.0-darwin/` (3.1 GB toolchain) and `work/lean-4.36.0-darwin.tar.zst` (617 MB), `work/vendor/` (93 MB), `*.olean`/`*.ilean`. Toolchain: Lean 4.36.0, x86_64-apple-darwin24.6.0, commit 611c117bfaf7b7ae1cfcf246ce6fba31e8f509e9. They stay on that disk until the owner says otherwise.
- The ancestral implementation was not changed (Codex's statement; not independently checked).

## Contents
The Ruby probes (`*.rb`, from `outputs/` and `work/`) are kept verbatim in `ruby-probes.tar.gz` (original hashes in `RUBY-PROBES.sha256`), not as loose files: the repository's rubocop style gate rejects them and they must not be edited. Extract with `tar -xzf ruby-probes.tar.gz`.
Lean sources (7, also duplicated under `work/`): `RelationshipExperiment.lean` (relation laws), `OneFire.lean` (single `fire?` table), `CrystalExperiment.lean`, `AuthorityRelationship.lean`, `ExecutableRelationship.lean`, `RealizationBoundary.lean`, `PreStateEffects.lean`. Reports: `one-construct-accounting.md` (the complexity ledger), `verification-report.md`, `relationship-reduction-report.md`, `final-crystal-era-verdict.md`, `executable-boundaries-verdict.md`, `full-corpus-conformance-verdict.md`, `authority-relationship-report.md`, `realization-boundary-report.md`, `one-fire-proof-attempt.md`, `twenty-type-audit.md`, `ir-relationship-report.md`. Probes (`*.rb`) and results (`*.json`, `*-lean-check.txt`).

## What Codex reported (not verified by the scrum master except where stated)
- Executable coverage of the frozen Bluebook semantics corpus by the reduced Relationship model: first 9 of 52; then 32 of 52 (15 stopped at unsupported behavior, five produced wrong results); LATEST 37 of 52 plus five focused authorization / projection / reaction regressions matching the ancestral observations, 15 fixtures still unsupported. The ancestral Ruby baseline matches 52 of 52.
- Mathematical result: Relationship as one relation type holds at the level of denotation (a Condition is a subidentity relation; composition laws, chains, invariant preservation). The ledger says plainly which complexity is REMOVED (the separate Condition type; proof repetition by depth) and which is RELOCATED (choice into determination, rule language growth from 11 to 16 instruction tags and 9 to 12 expression tags, dispatch precedence and refusal kinds, pre-state effects, queries, commit and reactions, authority) and which is OPEN (time, concurrency, outside effects, Worlds). The smallest remaining piece not obtainable from relation truth is the realization of a selected transition.
- Mathematical sufficiency and executable sufficiency are different claims here: the first is proved for the model; the second is 37 of 52, not 52 of 52.

## Independent re-check (scrum master, 2026-11-27, same toolchain)
All 7 `.lean` files compiled with that Lean: exit 0, 0 errors, 0 `sorry`/`admit`, 0 `axiom` declarations of their own. Axioms the theorems depend on, from Codex's `*-lean-check.txt`: `propext` throughout; one theorem (`AuthorityRelationship.unauthorized_program_cannot_commit`) also depends on `Classical.choice` and `Quot.sound`. These are Lean's three standard axioms; the owner has not yet approved an allow-list, so the acceptance rule "no unapproved axioms" is OPEN until he does. This check does NOT prove the Ruby IR compiler matches the model (Codex states no such proof exists).

## Open obligations from this archive
1. Review and move into `proofs/lean/` with a pinned `lean-toolchain` and a `lake build` CI job that fails on `sorry`/`admit` and on axioms outside an approved allow-list.
2. 15 of 52 fixtures unsupported; 5 wrong results earlier; close or classify each (counterexample, missing semantics, or out of scope).
3. The three discrepancies (authorization, projection refresh, reaction scheduling): five focused regressions match; the proofs and any residual counterexample still need an owner and a Lean statement.
4. Time, concurrency, outside effects, Worlds, Prisms: open, explicitly not eliminated.
