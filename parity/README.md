# parity/

The conformance contract between hecks's two implementations — Ruby (`lib/hecks/`) and Rust (`hecks_life/`). Neither owns this directory ; both must answer to it.

Lifted from `spec/parity/` in Round 1 of inbox `i118` (the framework reshape arc) so the role becomes visible at the top level. *Le contrat n'appartient à personne ; il tient les deux à la même règle.*

## What lives here

| File / dir                         | What it is |
|------------------------------------|---|
| `parity_test.rb`                   | The main suite — runs every fixture in `bluebooks/` and every real bluebook in `hecks_conception/` through both parsers, converts each output to the canonical JSON shape, diffs |
| `behaviors_parity_test.rb`         | Same shape, applied to `.behaviors` files |
| `fixtures_parity_test.rb`          | Same shape, applied to `.fixtures` files |
| `fixtures_auto_load_parity_test.rb`| Verifies fixtures auto-load identically across Ruby and Rust |
| `hecksagon_parity_test.rb`         | Same shape, applied to `.hecksagon` adapter declarations |
| `world_parity_test.rb`             | Same shape, applied to `.world` cross-cutting concerns files |
| `canonical_ir.rb`                  | The canonical-IR shape : the JSON contract both implementations must produce |
| `known_drift.txt`                  | Documented gaps — fixtures that fail today but are explicitly tolerated |
| `*_known_drift.txt`                | Per-suite drift lists (hecksagon, world, fixtures) |
| `bluebooks/`                       | 16 synthetic fixture bluebooks covering every IR concept |
| `behaviors/`                       | Behaviour-test fixtures used by the cross-language suite |
| `fixtures/`                        | `.fixtures` test files |
| `fuzz/`                            | The differential fuzzer — generates random valid bluebooks and asserts both parsers agree |

## Running the suite

```sh
ruby -Ilib parity/parity_test.rb              # main suite
ruby -Ilib parity/behaviors_parity_test.rb    # behaviours
ruby -Ilib parity/fixtures_parity_test.rb     # fixtures
ruby -Ilib parity/hecksagon_parity_test.rb    # hecksagons
ruby -Ilib parity/world_parity_test.rb        # worlds
ruby -Ilib parity/fuzz/fuzz_test.rb           # differential fuzzer
```

The pre-commit hook (`tooling/git-hooks/pre-commit`) runs the main + hecksagon + world tests in roughly a second and blocks unexpected drift. CI runs all of them on every PR.

## How drift gets resolved

When a fixture starts failing :

1. Read the diff. The suite prints exact byte-level differences in canonical JSON.
2. If the failure reflects a real semantic gap, **fix one parser** to match the other.
3. If the gap is structural and not yet resolvable, **add the fixture path to the appropriate `*_known_drift.txt`** with a comment explaining why ; the suite will report ⚠ instead of blocking.
4. When a known-drift fixture starts passing, the suite reports ⚑ and tells you to remove the line.

## See also

- `lib/hecks/bluebook_model/` — the Ruby half of the canonical contract
- `hecks_life/src/dump.rs` — the Rust half
- inbox `i118` — the framework reshape arc that lifted parity to a top-level peer
- inbox `i1` / `i2` — known-drift items currently keeping the nursery section soft
