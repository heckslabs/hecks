# i37 — Remove Python from Hecks

Source: inbox `i37` + plan by Agent a65a3a6a on 2026-04-22.

## Current footprint (verified 2026-04-22)

- **120 `python3 -c` invocations** across 17 shell scripts. Heaviest: `test_miette.sh` (53), `pulse_organs.sh` (12), `rem_branch.sh` (9), `statusline-command.sh` (6), `dream_content_smoke.sh` (6), `mint_musing.sh` (6).
- **3 standalone non-Summer `.py` files**: `tools/features_audit.py` (301 LoC), `hecks_conception/status_format.py` (**deleted in PR #273** during status.sh migration), `hecks_conception/mark_musing_shown.py` (63 LoC).
- **Summer `.py` files**: 5 totaling 920 LoC under `hecks_conception/summer/` + top-level `summer/` Rust crate + `boot_summer.sh` shim.

## What shipped (Phase A, PR #272)

**8 heki subcommands landed in `hecks_life/src/heki_query.rs`** (156/156 tests green):

- `heki get <file> <id> [<field>]` — one record by id, optional field projection
- `heki list <file> [--where k=v]... [--order <field>:<mod>] [--fields a,b] [--format json|tsv|kv]` — filter + order + project
- `heki count <file> [--where k=v]...` — integer
- `heki next-ref <file> [--prefix i] [--field ref]` — monotonic ref allocator
- `heki latest-field <file> <field>` — scalar shortcut for statusline patterns
- `heki values <file> <field>` — newline-delimited value list
- `heki mark <file> --where ... --set k=v...` — bulk update, subsumes `mark_musing_shown.py`
- `heki seconds-since <file> <field>` — ISO-8601 timestamp delta for `mindstream.sh` idle check

Byte-for-byte parity verified against 3 existing Python patterns.

## Remaining phases

### Phase B — sweep shell scripts (UNBLOCKED; mechanical)

Target: 120 → 0 `python3 -c` call sites across 17 shell scripts.

Strategy: top-down by count so parity tests confirm each sweep:

| Batch | Script | Count | Dominant pattern | Replacement |
|---|---|---|---|---|
| 1 | `inbox.sh` | 4 | ref lookup, next-ref, sort | `heki get`, `heki next-ref`, `heki list --order priority:enum=...` |
| 2 | `test_miette.sh` | 53 | `heki latest \| py field` | `heki latest-field` |
| 3 | `pulse_organs.sh` | 12 | field + numeric compare | `heki latest-field` + shell arith |
| 4 | `rem_branch.sh` | 9 | same | same |
| 5 | `mint_musing.sh` | 6 | musing lookup / dedupe | `heki list --where` / `heki count --where` |
| 6 | `statusline-command.sh` | 6 | same | same |
| 7 | `tests/dream_content_smoke.sh` | 6 | same | same |
| 8 | remaining 24 in `boot_miette.sh`, `consolidate.sh`, `mindstream.sh`, `surface_musing.sh`, `daydream.sh`, `interpret_dream.sh`, `tests/*_smoke.sh` | 24 | mixed | case-by-case |

One commit per batch, message lists the count delta (`120 → 116 → …`). Expected net: `−600` shell lines (heredocs are verbose), `+220` heki invocations.

**Verification after each batch**: diff against `tests/status_golden.expected`-style fixtures. Antibody check should flag strictly fewer files per batch.

### Phase C — rewrite 3 standalone `.py` in Ruby

- **`mark_musing_shown.py` — DELETES ENTIRELY.** Subsumed by `heki mark`. Update `surface_musing.sh:51` to call `$HECKS heki mark`.
- **`tools/features_audit.py` → `tools/features_audit.rb`.** Mechanical port: `subprocess.run(["rg", ...])` → `Open3.capture3("rg", ...)`. `argparse` → `OptionParser`. `pathlib.Path` → `Pathname`. Update `docs/usage/features_audit.md` invocation examples. ~280 LoC Ruby.
- **`status_format.py` already deleted** (PR #273).

### Phase D — delete Summer

Per Chris's direction earlier in session: Summer was premature.

- `hecks_conception/summer/` tree (5 `.py` + adapter + __pycache__)
- `summer/` top-level Rust crate
- `boot_summer.sh` shim
- Remove `"summer" => "Summer"` arm in `hecks_life/src/main.rs::being_from_argv0`

**Before deletion**: `rg -i summer install.sh deployments/ .github/workflows/` — verify no live consumers. Remove assertions on `being_from_argv0` for "summer".

### Phase E — antibody update

- `bin/antibody-check`: **promote Python from "requires exemption" to "forbidden outright"**. If ANY `.py` file appears in a touched-files list, fail with a message pointing at i37 as policy basis. No exemption accepted.
- Remove "external Python dep (Modal/MLX)" line from antibody docstring.
- Grep-sweep codebase for any stored exemption marker referencing Python — remove.

## Sequencing + parallelism

```
Phase A (shipped) → Phase B → Phase C.2 (features_audit), C.3 folded into B
                           \
                            → Phase D (independent, parallel)
                           /
Phase E ─────────────────── (last; after D removes the one legit python exemption)
```

Recommended PR sequence: one PR per phase: B → C → D → E.
Total effort: ~2 weeks pipelined / ~6 sequential.

## Aggregate impact

- Python deleted: ~1,487 LoC (920 Summer + 567 standalone)
- Shell simplified: −600 LoC
- Ruby added: ~460 LoC
- Rust added: ~380 LoC + 90 test (Phase A already shipped)
- **Net: −1,247 LoC, ~120 subprocess-Python call sites eliminated**

## Risks

- Output-format drift during Batch 1 (inbox.sh) — `heki next-ref` must match current Python byte-for-byte (validated in Phase A)
- Filter edge cases for priority enum ordering (use `--order priority:enum=high,medium,normal,low`)
- `test_miette.sh`'s 53-fork test suite gets FASTER after sweep (hecks-life cold start is ~5× faster than Python); net speedup expected
- Wall-clock surprise: the `seconds-since` subcommand exists (Phase A). No Python needed for idle computation.

## Key files

- MODIFY: 17 shell scripts under `hecks_conception/` (per Phase B table)
- DELETE: `hecks_conception/mark_musing_shown.py`
- NEW: `tools/features_audit.rb` (port from .py)
- DELETE: `tools/features_audit.py`
- DELETE: entire `hecks_conception/summer/` tree
- DELETE: `summer/` Rust crate
- DELETE: `boot_summer.sh`
- MODIFY: `hecks_life/src/main.rs::being_from_argv0` (remove Summer arm)
- MODIFY: `bin/antibody-check` (forbid Python outright)
