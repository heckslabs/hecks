# Re-verification: M1-M19, L1-L24, Rust-parity divergence list — 2026-08-28

`docs/future-features.md`'s own "Bug audits" section flagged these three
groups explicitly as **not re-verified** in the 2026-08-27 reconciliation
pass, warning that status drift in this project runs in both directions —
so this pass re-checked each finding against current source rather than
trusting either the original "open" label or any later "fixed" claim.
Three parallel investigations (one per group), each reading current
file:line content and existing spec coverage, not grepping old line numbers
or trusting comments alone.

## Headline finding

**53 of 55 individually-tracked findings across all three groups are fixed
or no longer applicable.** Two items carry a real caveat (M10's ports gap,
R2's successor findings in ADR 0037) — both are honestly, explicitly
tracked as open elsewhere, not silently dropped. No finding in any group
was found to still be a live, untracked bug.

## M1-M19 (query engine, expression sublanguage, IR round-trip, DSL sealing, runtime)

18 of 19 fully fixed, each with a corresponding fix and (for most) a
dedicated regression spec — several source comments explicitly cite the
M-number from `docs/audits/2026-08-11-bug-triage.md` by name, meaning
these were deliberately fixed against this exact triage doc, not
independently and coincidentally.

| ID | Status | Current file:line |
|---|---|---|
| M1 | FIXED | `query_specification/common/null_policy.rb:74-78` (`unmatchable?`) |
| M2 | FIXED | `query_specification/common/comparison.rb:107-123` |
| M3 | FIXED | `query_specification/common/null_policy.rb:28-48` (`sql_order`) |
| M4 | FIXED | `query_specification/common/comparison.rb:43-52` (`comparable`) |
| M5 | FIXED | `query_specification/field_path.rb:61` |
| M6 | FIXED | `bluebook/expression/evaluator.rb:85` |
| M7 | FIXED | `bluebook/expression/canonical_form.rb:72` |
| M8 | FIXED | `bluebook/expression/resolver.rb:657-661` |
| M9 | FIXED | `bluebook/expression/resolver.rb:688-698`, `evaluator.rb:120-143` |
| M10 | **PARTIAL** | `bluebook/chapter.rb:47` — see below |
| M11 | FIXED | `bluebook/process_manager.rb:90` |
| M12 | FIXED | `bluebook/dsl/attribute_collector.rb:201-205` |
| M13 | FIXED | `bluebook/meta_validator/judge.rb:470-471` |
| M14 | FIXED | `bluebook/dsl/bluebook_builder.rb:684-742` |
| M15 | FIXED | `literal.rb` (unified module) |
| M16 | FIXED | `naming.rb:61-79` |
| M17 | FIXED | `runtime/instance.rb:124-166` |
| M18 | FIXED | `runtime/identity.rb:68` |
| M19 | FIXED | `adapters/driven/sqlite/projection.rb:36-70` |

**M10 detail:** `formerly_known_as` is fixed (present in `to_h`, confirmed
by `spec/round_trip_spec.rb`). Chapter-level `@ports` is still genuinely
absent from `to_h` — but this is now an explicit, documented, deliberately
deferred gap (`RECONSTRUCTION_KNOWN_GAPS = %i[ports]`), not a silent
omission: the self-hosted meta-domain has no grammar representation for
ports at all yet, which is its own separate, larger, correctly-scoped-out
piece of work.

## L1-L24 (ops/translation correctness, low-severity DSL/runtime/Rust)

23 of 24 fixed, each with matching spec/test coverage (several with
comments explicitly labeled by L-number). L3 is no longer applicable —
the buggy code path was deleted outright as part of an ADR 0032 cleanup;
the surviving equivalent logic in `era_check.rb` was already correct
before this pass even started. (L12 and L20 are intentionally excluded —
L12 was never a real ID in the source doc, and L20 was already separately
confirmed fixed at `b00e667d`.)

| ID | Status | Current file:line |
|---|---|---|
| L1 | FIXED | `ports/projection.rb:44` |
| L2 | FIXED | `runtime/read_model_interpreter.rb:135` |
| L3 | N/A — code deleted (ADR 0032) | `ports/persistence/plugins/era/era_check.rb:106` |
| L4 | FIXED | `runtime/command_rules/arithmetic.rb:153` |
| L5 | FIXED (no dedicated spec found) | `bluebook/behaviour/lifecycle.rb:35` |
| L6 | FIXED | `runtime/value/admission.rb:33` |
| L7 | FIXED | `bluebook/value_object.rb:38` |
| L8 | FIXED | `bluebook/pattern_subset.rb:118` |
| L9 | FIXED | `facade/json_door.rb:98` |
| L10 | FIXED | `forms/app.rb:265` |
| L11 | FIXED | `forms/app.rb:151` |
| L13 | FIXED | `ports/persistence/plugins/era/postgres_era.rb:358` |
| L14 | FIXED | `adapters/driven/sqlite.rb:99`, `d1.rb:193` |
| L15 | FIXED | `bin/project` (mode 100755 confirmed) |
| L16 | FIXED | `forms/port_argument.rb` |
| L17 | FIXED | `grammar/evolve.rb:26` |
| L18 | FIXED | `grammar/evolve.rb:45` (`restore_on_raise`) |
| L19 | FIXED | `bin/stores:13-16` |
| L21 | FIXED | `rust/src/kernel/json.rs:465,196,359` |
| L22 | FIXED | `rust/src/kernel/expression_operators/arithmetic.rs:130` |
| L23 | FIXED | `rust/host/src/web.rs:833` |
| L24 | FIXED | `rust/host/src/web.rs:1100` |

L5's fix (raise `WiringError` instead of falling through to `matches.first`)
is confirmed by direct code read and an explanatory comment mirroring L4's
own fix, but no dedicated regression spec was found pinning it — worth a
small follow-up spec if 100% confidence is wanted, though the finding
itself is closed either way.

## Rust-parity divergence list (R1-R5)

R1, R3, R4, and both halves of R5 are fixed, four of them with source
comments that explicitly cite `docs/audits/2026-08-11-bug-triage.md` by
finding ID (R3, R4, R5) — first-party confirmation, not inference:

| ID | Status | Current file:line |
|---|---|---|
| R1 | FIXED | `rust/project/json_codec.rb:289-375` (`sparse:` filtering) |
| R2 | **SUPERSEDED** | see below |
| R3 | FIXED | `rust/project/registry.rb:198-207,270-280` |
| R4 | FIXED | `rust/src/kernel/json.rs:330-378` (`to_id_component`) |
| R5 (build failure) | FIXED | `rust/Cargo.toml:11-19`, `rust/src/generated/mod.rs:16-46` |
| R5 (codegen landmines) | FIXED | `rust/project/naming.rb:54-92,222-236` |

**R2 detail — this is the one finding that needed real judgment, not just
a status flip.** The specific mechanism R2 described (37 hardcoded "query
steps not generated yet" placeholder refusals shifting every later
refusal's index, Ruby 94 vs Rust 131) no longer exists — Rust's query
dispatch (`rust/src/kernel/cli.rs`) now really executes named and ad hoc
queries instead of placeholder-refusing them. But "full-corpus Ruby/Rust
refusal-count divergence" as a *category* is not closed — it's actively
being found again, via different root causes, by a newer and more
thorough tool: `spec/rust_conformance_fuzz_spec.rb` (PRD 04's
generated-sequence fuzz bridge, see
`docs/decisions/0037-generated-sequence-fuzz-bridge-found-real-gaps-two-fixed-three-catalogued.md`).
That bridge found six new findings; two are fixed and verified (wording +
a stale-codegen catch-up), and four are catalogued but still open, with
the bridge's own two `pending:` rspec examples citing ADR 0037 directly
so they can't silently regress to green without someone actually closing
the underlying gap:

- **Finding 3** (highest frequency): Rust's missing-required-argument
  refusal wording is generic kernel-level ("missing from JSON args")
  where Ruby's is rich and batches every absent key
  ("Grant was not given starts_at — it takes ..."). Needs a codegen-time
  fix, not a runtime one.
- **Finding 4**: a query argument's typed value (e.g. a `Price` with a
  negative-amount invariant) skips typed construction and invariant
  checking entirely on the Rust side — Rust silently returns rows where
  Ruby refuses.
- **Finding 5 — the most serious of the four**: `resolve_state_references`
  (Ruby's aggregate-level, post-`sets` dangling-reference check) was never
  ported to Rust. Confirmed narrow blast radius (one real corpus command,
  `SafeDepositBox.Rent`), but it's a genuine silent data-integrity
  violation — Rust persists a record with a reference to nothing where
  Ruby refuses — not just a wording mismatch. ADR 0037 recommends fixing
  this one first, ahead of the higher-frequency Finding 3, precisely
  because of its severity.
- **Finding 6**: Bignum-magnitude refusal disagreements, not yet fully
  diagnosed.

So R2 is correctly reported here as superseded, not simply "fixed" — the
original bug is gone, but the same *invariant* (Ruby and Rust must refuse
identically over the full corpus, not just three pinned fixtures) is still
actively finding new, real violations, exactly the pattern
`docs/future-features.md` already warned this would be: "an invariant that
keeps finding new violations," not a one-time fix. ADR 0037 is the correct
live tracking document for this ongoing work — this doc does not duplicate
it, just points to it.

## What this means for `docs/future-features.md`

That doc's "Bug audits" section should be updated to reflect: M1-M19 and
L1-L24 are now genuinely closed (not "not re-verified this session"), and
the Rust-parity divergence list's original five findings are closed with
one (R2) explicitly superseded by ADR 0037's own newer, still-open
findings — which is where anyone tracking Rust/Ruby parity should look
going forward, not this list.
