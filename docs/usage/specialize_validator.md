# specialize-validator — first-Futamura projection for validator.rs

`hecks_life/src/validator.rs` is a **generated file**. Do not edit it by hand. All changes flow through the shape fixtures.

## Quick reference

```bash
# Regenerate validator.rs (byte-identical to what's in the repo)
bin/specialize-validator --output hecks_life/src/validator.rs

# Preview what would change
bin/specialize-validator --diff

# Print the Rust to stdout (no side effects)
bin/specialize-validator
```

## Where things live

| Layer | File |
|---|---|
| **L0** — shape | `hecks_conception/capabilities/validator_shape/validator_shape.bluebook` |
| **L0** — data | `hecks_conception/capabilities/validator_shape/fixtures/validator_shape.fixtures` |
| Wiring | `hecks_conception/capabilities/specializer/specializer.hecksagon` (declares `:specialize_validator` shell adapter + `SpecializeRun` gate) |
| Adapter impl | `bin/specialize-validator` (Ruby, Phase A stopgap) |
| **L7** — output | `hecks_life/src/validator.rs` (generated, byte-identical to specializer output) |
| Tests — rules | `hecks_life/tests/validator_rules_test.rs` (6 integration tests against `hecks_life::validator::validate`) |
| Tests — golden | `hecks_life/tests/specializer_golden_test.rs` (2 tests: hecksagon wiring + byte-identity) |

## Adding or changing a validator rule

You **never** edit `hecks_life/src/validator.rs` directly. Instead:

1. Add / edit the row in `validator_shape.fixtures` under the `ValidationRule` aggregate.
2. Pick a `check_kind` that matches the rule's shape (`unique`, `non_empty`, `first_word_verb`, `reference_valid`, `trigger_valid`, `unique_across`). If none fit, extend `bin/specialize-validator` to handle a new primitive.
3. If the rule needs a new error shape, adjust `error_template`.
4. Regenerate:
   ```bash
   bin/specialize-validator --output hecks_life/src/validator.rs
   ```
5. Run the golden test to confirm determinism:
   ```bash
   cd hecks_life && cargo test --release --test specializer_golden_test
   ```
6. If you added a new rule, add a test to `hecks_life/tests/validator_rules_test.rs` and confirm:
   ```bash
   cargo test --release --test validator_rules_test
   ```
7. Commit shape changes + regenerated `validator.rs` together. The golden test fires on any drift.

## How the enforcement works

Two gates prevent hand-editing drift:

- **`specializer_produces_byte_identical_validator_rs`** in `hecks_life/tests/specializer_golden_test.rs` — runs the specializer, diffs against the tracked `validator.rs`. Fails on any mismatch.
- **CI runs this test every PR** — manual edits to `validator.rs` without corresponding shape changes fail CI.

If you need to stop generating (temporary): revert the fixture row, regenerate, and the golden test stays green.

## Why this matters

This is the first proof of **1st-Futamura projection** in the repo — a specialized interpreter producing Rust byte-equivalent to what a human wrote. See [docs/plans/i51_futamura_projections.md](../plans/i51_futamura_projections.md) for the full arc. Phase B applies the same pattern to `validator_warnings.rs`, the parsers, and `dump.rs`. Phase C lifts the specializer itself.

## Known constraints

- **Single-line fixtures** — the Rust fixtures parser only reads one line per `fixture` directive. Multi-line form silently drops attrs. Filed as inbox **i57**. Until it lands, rules + entry-point fixtures stay on single lines.
- **Ruby specializer** — Phase A adapter is Ruby for fast iteration. Phase B replaces with a `hecks-life` subcommand; the `.hecksagon` wiring stays the same (just the `command:` field flips).
- **Tests as integration tests** — validator's test block moved out of `validator.rs` in commit 4 to break the circular dep (specializer was reading tests from the file it generates). When Phase B models `TestCase` aggregates in the shape, tests come back under shape-driven emission.
