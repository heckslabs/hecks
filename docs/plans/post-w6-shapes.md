# Post-W6 Shapes — Continuing i147 Kernel Disappearance

**Goal.** Once Wave 6 (`cli_dispatch_shape`, PR #553) lands, keep retiring authored
files under `rust/src/` by adding `codegen/<name>_shape/` directories that
specialize back to byte-identical Rust. This survey picks the next 3-5
shapes worth writing and orders them by payoff, novelty, and risk.

## Investigation: behaviors_runner.rs (542 LoC) is NOT a regression

W4-B did succeed. `codegen/behaviors_runner_shape/` exists with 12 snippets,
a fixtures file, and the full bluebook. `rust/tests/specializer_golden_test.rs`
asserts byte-identity (`rust_specializer_produces_byte_identical_behaviors_runner_rs`).
The 542-LoC file persists on disk because **the specialization model keeps
the target tracked in git as a golden** — the build doesn't depend on running
the specializer at compile time. Lesson: "retired" in i147 means
**regenerable**, not deleted.

## Top candidates (next in line)

| LoC | File | Proposed shape | body_kinds | Size | Notes |
|-----|------|----------------|------------|------|-------|
| 1579 | `rust/src/behaviors_conceiver/generator.rs` | `behaviors_conceiver_generator_shape` | `verbatim_section` (heavy) + new `setup_planner_block` for the precondition family | L | Distinct from already-shipped `conceiver_generator_shape` (180 LoC, in `rust/src/conceiver/`). 25+ helpers cluster around setup-chain planning + emitter family per command-kind. |
| 638 | `rust/src/run_statusline.rs` | `run_statusline_shape` | `verbatim_section`, `string_table` (icon/glyph maps), possible new `time_animation` knobs | M | Well-partitioned: read_state → render_sleep / render_awake split. Glyph helpers (moon/heart/bulb) are pure tables — natural string_table candidates. |
| 560 | `rust/src/run_restructure/mod.rs` | already blueprinted by `capability_runner_shape` | `dispatch_chain` + new `phase_dispatch` per file's own header | M | File's own doc says: "explicit blueprint for capability_runner_shape's specializer." Don't write a new shape — extend the meta-shape to absorb this. |
| 503 | `rust/src/fixtures_parser.rs` | `fixtures_parser_shape` (exists?) — re-check | `verbatim_section` + reuse `parser_shape` patterns | M | Note: there is already a `codegen/fixtures_parser_shape/` directory — verify status before counting this as new work. May be partially landed. |
| 481 | `rust/src/server/html_domain.rs` | `html_domain_shape` (or family) | new `html_section` + `html_form_template` + `string_table` for css classes | M | Many small `fn xxx_section -> String` helpers each emit a templated HTML block. Strong candidate for a new `html_section` body_kind that turns sibling HTML files (html_workflow, html_fixtures, html_kpi, html_usage, html_shared) into one shape family. |
| 458 | `rust/src/runtime/interpreter.rs` | `interpreter_shape` | `verbatim_section` + `mutation_op` reuse | M | Already adjacent to `mutation_op_shape` (W4-a). Carries antibody-exempt markers from i106 + rand_below — natural follow-on. |
| 409 | `rust/src/run_status/assemble.rs` | `assemble_shape` | new `heki_field_loader` + `verbatim_section` | M | Heavy on `str_field/first_present/load/latest` helpers. Repeated heki-record-flattening pattern is reusable across `run_statusline.rs` (same idiom there). |

## Recommended order

1. **`run_statusline_shape` first.** M-sized, self-contained, no in-flight conflict
   risk, and it teaches us **two** new body_kinds (`string_table` extension for
   glyph cycles, possibly a `time_animation` knob). 638 LoC payoff. The pattern
   then transfers to `assemble.rs` (#7) since both read heki + render strings.

2. **`assemble_shape` second.** Reuses the heki-loader idiom from #1 ; small
   marginal cost, 409 more LoC retired. Locks in the `heki_field_loader`
   body_kind for any future heki-reading file.

3. **`html_domain_shape` (family) third.** New territory — HTML emission as
   a body_kind family is the highest-novelty win and would absorb 5+ sibling
   `html_*.rs` files at once. Larger up-front design cost but compounding
   payoff. Defer until #1-2 prove out a string-template body_kind.

4. **Extend `capability_runner_shape` to swallow `run_restructure/mod.rs`.**
   Not a new shape — a meta-shape extension. The file itself names this as
   its retirement contract.

5. **Defer `behaviors_conceiver/generator.rs`.** L-sized, partitions awkwardly
   (the precondition planner is one large algorithm, not a section list), and
   it is itself a generator — specializing a generator risks bootstrapping
   confusion. Wait until 2-3 more "normal" shapes harden the body_kind catalog.

## Open questions for Chris

- **Generator-of-generators:** is `behaviors_conceiver/generator.rs` even a
  candidate? Specializing a file whose job is to generate test-suite text from
  IR creates a "what generates the generator?" loop. Worth specializing for the
  Futamura symmetry, or skip and let it stay authored?
- **`fixtures_parser_shape` status:** the directory exists in `codegen/` —
  is it half-landed, abandoned, or already golden? Need to confirm before
  W7 picks it up.
- **HTML family scope:** treat `html_domain.rs` alone, or design
  `html_section_shape` to cover all `rust/src/server/html_*.rs` siblings in
  one wave? The latter is bigger but avoids re-deriving the body_kind twice.
- **`run_restructure` extension vs. new shape:** confirm the preference is
  to extend `capability_runner_shape` (per the file's own retirement contract)
  rather than introduce `run_restructure_shape` as a stopgap.
