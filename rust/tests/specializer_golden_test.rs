//! Golden tests for the i51 Futamura specializers.
//!
//! Phase E deleted the Ruby `bin/specialize` driver + Ruby specializer
//! modules ; the Rust-native `storehouse specialize <target>` subcommand
//! is now the only path. These tests invoke it and assert byte-identity
//! against the tracked, generated `.rs` sources under `rust/src/`.
//!
//! When any test goes green, we have a Futamura proof for that module :
//! a specialized interpreter (bluebook → Rust) that produces the same
//! artifact a human wrote.
//!
//! If a tracked .rs is edited by hand, this test fails until the
//! shape + specializer are updated to match.
//!
//! [antibody-exempt: rust/tests/specializer_golden_test.rs — golden-test
//!  scaffolding for the i51 Futamura specializer pipeline. Each `#[test]`
//!  shells to `storehouse specialize <target>` and asserts byte-identity
//!  against the tracked `rust/src/<target>.rs`. Test-only kernel-floor
//!  surface : the specializers under test ARE the path that retires
//!  generated `.rs` files, but the byte-identity harness itself is
//!  necessarily Rust (it asserts on Rust byte sequences). Retires when
//!  i78 lands and the specializer pipeline regenerates from its own
//!  meta-shape, at which point byte-identity goldens move under the
//!  meta-shape's coverage. Previously carried 25 identical per-test
//!  scaffolding markers ; consolidated to a single file-level header
//!  on 2026-05-12 (the macrophage / antibody check only inspects the
//!  first 30 lines, so mid-file markers were decorative).]

use storehouse::hecksagon_parser;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust has a parent")
        .to_path_buf()
}

#[test]
fn specializer_hecksagon_wiring_is_present() {
    // Confirms the capability wiring exists and declares the memory
    // adapter, all three shell adapters, and the Specializer gate.
    let path = repo_root().join("codegen/specializer/specializer.hecksagon");
    let src = fs::read_to_string(&path)
        .expect("specializer.hecksagon not found — capability wiring missing");
    let hex = hecksagon_parser::parse(&src);

    assert_eq!(hex.name, "Specializer");
    assert_eq!(hex.persistence.as_deref(), Some("memory"));
    // Phase E removed all shell adapters — `storehouse specialize`
    // (a Rust subcommand) is now the sole codegen path. The hecksagon
    // file keeps the `:memory` + `:fs` adapters + the Specializer
    // gate as declarative metadata. The 2026-05-12 "no bluebooks
    // without commands" sweep collapsed SpecializeRun + the four
    // catalog aggregates (IRLayer, Projection, SpecializerTarget,
    // SpecializerSubclass) into a single Specializer root with
    // value_object row-types ; the gate is renamed accordingly.
    assert!(
        hex.gates.iter().any(|g| g.aggregate == "Specializer"),
        "Specializer gate not declared",
    );
}

// Ruby-path tests deleted in Phase E PR 1 — `bin/specialize` no longer
// exists; the Rust-native `storehouse specialize` path (below) is the
// sole gate for every target now.

#[test]
fn rust_specializer_produces_byte_identical_validator_warnings_rs() {
    // Phase D pilot — storehouse specialize (Rust-native) produces
    // output byte-identical to the tracked .rs file. First proof that
    // the specializer itself could migrate from Ruby to Rust while
    // keeping byte-identity; Phase E subsequently deleted the Ruby
    // side. Every subsequent Phase D port added another test with the
    // same shape.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(
        bin.exists(),
        "storehouse binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "validator_warnings"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/validator_warnings.rs"))
        .expect("validator_warnings.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

#[test]
fn rust_specializer_produces_byte_identical_dump_rs() {
    // Phase D D2 — second Rust-native specializer. Stretches the
    // D1 pilot to multi-aggregate dispatch, order sorting, and the
    // padded enum_match emitter. Every subsequent Rust-emitting
    // specializer (validator, the parsers) reuses this vocabulary.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(
        bin.exists(),
        "storehouse binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "dump"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize dump failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/dump.rs"))
        .expect("dump.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

#[test]
fn rust_specializer_produces_byte_identical_hecksagon_parser_rs() {
    // Phase D — Rust-native specializer for hecksagon_parser. Third
    // parser port in the Phase D LineParser/LineDispatch/ParserHelper
    // arc (validator, behaviors_parser, fixtures_parser). The 4-row
    // dispatch exercises capture_quoted_into, push_quoted_onto,
    // multiline_block, and multiline_adapter handler kinds against the
    // simplest single-parse-loop shape.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(
        bin.exists(),
        "storehouse binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "hecksagon_parser"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize hecksagon_parser failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/hecksagon_parser.rs"))
        .expect("hecksagon_parser.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

#[test]
fn rust_specializer_produces_byte_identical_validator_rs() {
    // Phase D — Rust-native specializer for validator.rs. Largest
    // standalone specializer in the codebase (393 LoC Ruby). Seven
    // check_kind emitters (unique, non_empty, first_word_verb,
    // reference_valid, trigger_valid, unique_across, distinct_aliases)
    // plus the command_naming_support block with hand-formatted suffix
    // tables, verb-exception list, and verb-suffix list. No .rs.frag
    // snippets — all emission is inline Rust format! strings.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(
        bin.exists(),
        "storehouse binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "validator"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize validator failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/validator.rs"))
        .expect("validator.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

#[test]
fn rust_specializer_produces_byte_identical_behaviors_parser_rs() {
    // Phase D — Rust-native specializer for behaviors_parser. Ports
    // the LineParser + LineDispatch + ParserHelper 3-aggregate shape
    // including the else_if loop style, tests_snippet, and the new
    // capture_quoted_into_option / push_all_quoted_onto /
    // multiline_block_direct handler kinds.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(
        bin.exists(),
        "storehouse binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "behaviors_parser"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize behaviors_parser failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/behaviors_parser.rs"))
        .expect("behaviors_parser.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

#[test]
fn rust_specializer_produces_byte_identical_validator_corpus_rs() {
    // i146 piece 2 — Rust-native specializer for validator_corpus.rs.
    // Three corpus-aware lint rules (corpus_phantom_trigger_errors,
    // identified_by_warnings, policy_event_warnings). All embedded
    // snippets — each rule is sui generis, doesn't fit a check_kind
    // primitive, so the specializer just concatenates verbatim
    // .rs.frag bodies (doc + signature + body + closing brace) with
    // a blank line between each rule.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(
        bin.exists(),
        "storehouse binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "validator_corpus"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize validator_corpus failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/validator_corpus.rs"))
        .expect("validator_corpus.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

#[test]
fn rust_specializer_produces_byte_identical_fixtures_parser_rs() {
    // Phase D — Rust-native specializer for fixtures_parser. Ports the
    // smallest Rust-emitter Ruby specializer (~112 LoC) reusing the
    // LineParser + ParserHelper 2-aggregate shape (LineDispatch rows
    // are documentation-only; parse_body_snippet is authoritative).
    // Notable override: several helper bodies legitimately start with
    // `//` comments (e.g., extract_schema_kwarg's `// Find the first
    // top-level comma …`), so the port uses a bare file read instead
    // of util::read_snippet_body's leading-comment strip.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(
        bin.exists(),
        "storehouse binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "fixtures_parser"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize fixtures_parser failed");
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/fixtures_parser.rs"))
        .expect("fixtures_parser.rs missing");
    assert_eq!(
        generated, tracked,
        "Rust specializer output drifted from tracked file",
    );
}

// Phase E pruned all Ruby-target golden tests. The meta-specializers
// that emitted Ruby files (meta_subclass, meta_diagnostic_validator,
// meta_ruby_script, meta_ruby_module) are deleted alongside their
// target files. Bluebook + fixtures + snippets survive as historical
// data per the Phase E plan.

// ────────────────────────────────────────────────────────────────────
// i146 + i147 — substrate / kernel byte-identity guards
// ────────────────────────────────────────────────────────────────────
//
// Each new specializer target gets a golden test that mirrors the
// shape above : invoke `storehouse specialize <target>` from the
// repo root, compare its stdout to the tracked source. When any
// hand-edit drifts the tracked file from what the meta-shape would
// emit, the test fails — same byte-identity invariant the existing
// 6 targets enforce.

#[test]
fn rust_specializer_produces_byte_identical_dispatch_query_rs() {
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "dispatch_query"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize dispatch_query failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/dispatch_query.rs"))
        .expect("dispatch_query.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_repository_rs() {
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "repository"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize repository failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/runtime/repository.rs"))
        .expect("runtime/repository.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_run_statusline_rs() {
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "run_statusline"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize run_statusline failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/run_statusline.rs"))
        .expect("run_statusline.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_system_prompt_rs() {
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "system_prompt"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize system_prompt failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/run_boot/system_prompt.rs"))
        .expect("run_boot/system_prompt.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_behaviors_fixtures_rs() {
    // i147 wave 2 — Rust-native specializer for behaviors_fixtures.
    // Section-as-snippet shape (mirrors heki_query) : five ordered
    // verbatim_section rows for locate_path / parse_file / find_for /
    // apply / parse_fixture_value, concatenated under a HEADER const
    // that carries the doc comment + use lines.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "behaviors_fixtures"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize behaviors_fixtures failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/behaviors_fixtures.rs"))
        .expect("behaviors_fixtures.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_heki_query_rs() {
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "heki_query"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize heki_query failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/heki_query.rs"))
        .expect("heki_query.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_run_boot_discover_rs() {
    // i147 wave 2 — Rust-native specializer for run_boot/discover.rs.
    // Section-as-snippet shape (mirrors heki_query) : five ordered
    // verbatim_section rows for OrganCounts struct, count_organs,
    // write_census + n helper, count_top_level_bluebooks, and
    // count_recursive_bluebooks ; concatenated under a HEADER const
    // that carries the doc comment + use lines.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "discover"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize discover failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/run_boot/discover.rs"))
        .expect("run_boot/discover.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_aggregate_state_rs() {
    // i147 Wave 4-A (i171 closure) — re-targeted at mutation_op_shape.
    // Wave 3-A shipped the impl block as a single verbatim snippet ;
    // Wave 4-A breaks it into per-method snippets driven by
    // MutatorMethod rows so the SAME shape that emits interpreter.rs's
    // apply_mutations dispatch arms also emits aggregate_state.rs's
    // mutator method family. One shape, two consumers, byte-identity
    // preserved across the re-target.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "aggregate_state"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize aggregate_state failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/runtime/aggregate_state.rs"))
        .expect("runtime/aggregate_state.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_interpreter_rs() {
    // i147 Wave 4-A (i171 closure) — Rust-native specializer for
    // runtime/interpreter.rs. First REAL-compression retirement of
    // the apply_mutations dispatch : the new mutation_op_shape
    // declares one MutationOp row per variant (Set, Append,
    // Increment, Decrement, Toggle, Delete, Multiply, Decay, Clamp)
    // with a `dispatch_kind` knob that picks the arm template (six
    // templates cover the nine arms — three pairs share, three
    // sui-generis stand alone). Per-arm doc snippets keep byte-
    // identity against the tracked source.
    //
    // Sister to aggregate_state_rs : both consumers read the same
    // mutation_op_shape fixtures, with `target` knob filtering rows
    // per consumer. Adding a new MutationOp adds (1) a new dispatch
    // arm in interpreter.rs and (2) typically a new mutator method
    // in aggregate_state.rs, both from the one shape.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "interpreter"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize interpreter failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/runtime/interpreter.rs"))
        .expect("runtime/interpreter.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_conceiver_generator_rs() {
    // i147 wave 2 — Rust-native specializer for conceiver/generator.rs.
    // Section-as-snippet shape (mirrors heki_query) : four ordered
    // verbatim_section rows for generate_bluebook, scaffolding helpers,
    // aggregate + command emitters, and to_snake helper ; concatenated
    // under a HEADER const that carries the doc comment + use + VERSION.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "conceiver_generator"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize conceiver_generator failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/conceiver/generator.rs"))
        .expect("conceiver/generator.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_adapter_llm_rs() {
    // i147 Wave 3-B — Rust-native specializer for runtime/adapter_llm.rs.
    // First NEEDS-NEW-BODY-KIND retirement : the driven_adapter_shape
    // adds two new body_kinds — `http_post` (ollama backend) and
    // `shell_invoke` (claude backend) — alongside a verbatim_section
    // row for the dispatcher (resolve + resolve_ollama + LlmConfig).
    // The two new kinds emit different function bodies but the same
    // input → Option<String> signature family, which is what lets the
    // dispatcher route to either by config triple.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "adapter_llm"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize adapter_llm failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/runtime/adapter_llm.rs"))
        .expect("runtime/adapter_llm.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_parser_rs() {
    // i147 Wave 3-C — Rust-native specializer for parser.rs (the
    // top-level bluebook parser : state-machine line walker that builds
    // the Domain IR). Section-as-snippet shape (mirrors heki_query) :
    // seven ordered verbatim_section rows for parse, strip_shebang,
    // parse_aggregate, absorb_reference_to, absorb_shorthand, push_query,
    // needs_continuation ; concatenated under a HEADER const that
    // carries the doc comment + use lines.
    //
    // Sister to parse_blocks_rs (Wave 3-C path B). Together these two
    // goldens guard the entire bluebook parser surface — every .bluebook
    // in the corpus passes through these two files, so byte-identity
    // here is load-bearing for every parity test downstream.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "parser"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize parser failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/parser.rs"))
        .expect("parser.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_behaviors_runner_rs() {
    // i147 Wave 4-B — Rust-native specializer for behaviors_runner.rs
    // (the pure-memory test-suite executor that runs every .behaviors
    // file through Runtime::boot). REAL compression : the new
    // `suite_overload` body_kind emits the three suite-entry overloads
    // (run_suite, run_suite_with_fixtures, run_suite_with_domain) from
    // a shared template — knobs (kind, has_domain, has_fixtures) drive
    // the signature + body shape ; only the doc comments are bespoke
    // (read from .frag fragments). The remaining twelve sections are
    // verbatim_section snippets concatenated under a HEADER const.
    //
    // Load-bearing : 117 corpus .behaviors files pass through this file,
    // so byte-identity here gates every downstream parity test.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "behaviors_runner"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize behaviors_runner failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/behaviors_runner.rs"))
        .expect("behaviors_runner.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_ir_rs() {
    // i147 Wave 4-C — Rust-native specializer for ir.rs (the canonical
    // IR struct vocabulary : 16 structs + 1 enum + 1 impl that every
    // other Rust file in storehouse ultimately reads or writes). Real
    // compression : every struct field is a Field row, every enum
    // variant is a Variant row, every top-level item is a Type row.
    // Adding a struct field is now a fixture-row edit, not a Rust
    // hand-edit + cascading specializer chase across every consumer
    // that binds to ir.rs by string-literal field name.
    //
    // Cross-consumer impact : closes the stale-coupling risk that kept
    // ir.rs deferred from Wave 3. The dump_shape / parser_shape /
    // behaviors_parser_shape COULD now consult ir_shape's Field rows
    // for canonical field knowledge — that refactor is a follow-on,
    // but the door is open.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "ir"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize ir failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/ir.rs"))
        .expect("ir.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_command_dispatch_rs() {
    // i147 Wave 5-A — Rust-native specializer for runtime/command_dispatch.rs
    // (the dispatch kernel — every runtime command in the corpus passes
    // through dispatch_inner). REAL compression : the new
    // command_dispatch_shape declares one Phase row per ordered phase
    // inside dispatch_inner (resolve, bulk_short_circuit, prepare,
    // cascade_id, repo_borrow, load_state, apply_new_defaults,
    // pipeline_core, copy_create_attrs, persist, emit, return) and the
    // specializer assembles dispatch_inner from those rows. The dispatch
    // contract — the ORDER of phases that makes a command go from name
    // to event — is now data, not Rust code.
    //
    // Load-bearing : every behaviors run, every parity check, every
    // .heki write goes through this file. byte-identity is critical —
    // a regenerated drift would break every command in the corpus.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "command_dispatch"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize command_dispatch failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/runtime/command_dispatch.rs"))
        .expect("runtime/command_dispatch.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_parse_blocks_rs() {
    // i147 Wave 3-C — Rust-native specializer for parse_blocks.rs
    // (recursive-descent half of the bluebook parser : section / command
    // / value_object / entity / lifecycle / attribute / fixture /
    // mutation block readers). Section-as-snippet shape (mirrors
    // heki_query) : fifteen ordered verbatim_section rows, one per
    // top-level fn ; concatenated under a HEADER const that carries
    // the doc comment + use lines.
    //
    // Sister to parser_rs. Path B — separate shape from parser_shape
    // for clean separation ; same `verbatim_section` body_kind.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "parse_blocks"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize parse_blocks failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/parse_blocks.rs"))
        .expect("parse_blocks.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_main_rs() {
    // i147 Wave 6 — Rust-native specializer for rust/src/main.rs (the
    // CLI entry-point — every `storehouse X` invocation lands in fn
    // main()'s if-chain on argv[1]). REAL compression : the new
    // cli_dispatch_shape declares one Subcommand row per arm in the
    // dispatch chain (lexicon, terminal, transitional_print, heki,
    // conceive, develop, conceive_behaviors, behaviors, dump_fixtures,
    // dump_world, dump_hecksagon, specialize, cascade, check_io,
    // check_lifecycle, check_duplicate_policies, check_all, run, loop,
    // daemon, enforce_edit, statusline, is_dispatched, clock, sleep,
    // repl) plus one HelpRow per command in print_usage's listing.
    // The dispatch ROUTING — the ORDER of arms and the help listing —
    // is now data, not Rust code. Adding a new CLI subcommand is a
    // single fixture row + per-arm snippet.
    //
    // Load-bearing : every `storehouse X` invocation passes through
    // this file. byte-identity is critical — a regenerated drift
    // would break every CLI invocation in the corpus.
    //
    // Scope : Wave 6 retires the dispatch CHAIN + print_usage. The
    // helper function bodies (run_heki, run_specialize, run_loop, etc.)
    // stay verbatim ; per-family sub-shapes are filed as a follow-on.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "cli_dispatch"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize cli_dispatch failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/main.rs"))
        .expect("main.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_runtime_rs() {
    // i147 Wave 5-B — Rust-native specializer for runtime/mod.rs (the
    // top-level Runtime struct + boot pipeline + dispatch surface +
    // Value / RuntimeError + repo_key / repo_lookup_key + trigram
    // helpers). Three-level nested shape : Section rows for top-level
    // partitions, RuntimeMethod rows for impl-block methods, BootPhase
    // rows for the four-phase boot pipeline (wire_repositories,
    // wire_policies, wire_projections, assemble_runtime).
    //
    // Real compression : adding a boot phase (e.g. wire_adapters when
    // adapter wiring lifts out of terminal/io into the boot pipeline)
    // is now a single fixture row + snippet pair, not a hand-edit to
    // boot_with_data_dir. Same for adding an impl Runtime method.
    //
    // Sister to command_dispatch_rs (Wave 5-A). Together these two
    // goldens guard the runtime kernel's dispatch + wiring surface ;
    // every behavior test downstream passes through these files.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "runtime"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize runtime failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/runtime/mod.rs"))
        .expect("runtime/mod.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_html_domain_rs() {
    // i147 Wave 9-A — Rust-native specializer for server/html_domain.rs
    // (the dashboard's per-domain detail page : title bar, vision blurb,
    // usage section, creation cards, divider, records table, plus the
    // legacy module-card system kept for re-introduction). Section-as-
    // snippet shape (mirrors assemble_shape) : four ordered
    // verbatim_section rows for page / helpers / records_table /
    // legacy_modules ; concatenated under a HEADER const that carries
    // the doc comment + use lines.
    //
    // Family decision : SOLO. The html_*.rs siblings (workflow,
    // fixtures, kpi, usage, shared, sidebar, scripts, narration, icons,
    // help, rules, wizard, policy_chain) all emit HTML strings, but
    // their input IR + helper signatures + DOM templates diverge —
    // there's no two-consumer template that justifies inventing
    // html_section / html_form_template / string_table body_kinds
    // today. The post-W6 plan flagged the family option but explicitly
    // defers it ; promote when two siblings actually share a real
    // template.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "html_domain"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize html_domain failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/server/html_domain.rs"))
        .expect("server/html_domain.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_parser_helpers_rs() {
    // i147 Wave 9-B — Rust-native specializer for parser_helpers.rs
    // (the bluebook parser's helper grab-bag : string-extraction
    // primitives, to_snake_case + tests, and the shorthand-syntax
    // detector + parser family). Section-as-snippet shape (mirrors
    // assemble_shape) : five ordered verbatim_section rows for
    // extract_helpers / to_snake_case / snake_case_tests /
    // shorthand_tables / shorthand_parsers ; concatenated under a
    // HEADER const that carries the 4-line doc comment.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "parser_helpers"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize parser_helpers failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/parser_helpers.rs"))
        .expect("parser_helpers.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_assemble_rs() {
    // i147 Wave 8 — Rust-native specializer for run_status/assemble.rs
    // (the StatusReport pure read layer that flattens heki stores +
    // filesystem state into a Report struct for the renderer).
    // Section-as-snippet shape (mirrors discover_shape) : three ordered
    // verbatim_section rows for structs (DaemonRow + Report) / build /
    // helpers ; concatenated under a HEADER const that carries the doc
    // comment + use lines.
    //
    // body_kind decision : reuse verbatim_section. The str_field /
    // first_present / load / latest helpers ARE the canonical heki-
    // loading idiom, but they're each defined ONCE at the bottom of
    // the file ; the repetition is at the call site inside build()
    // which is expression-level, not section-level. Promote to a
    // shared snippet pool when a second consumer (run_statusline.rs
    // has the same idiom) wants to share these bodies.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "assemble"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize assemble failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/run_status/assemble.rs"))
        .expect("run_status/assemble.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}

#[test]
fn rust_specializer_produces_byte_identical_lifecycle_validator_rs() {
    // i147 Wave 9-C — Rust-native specializer for lifecycle_validator.rs
    // (the lifecycle DiagnosticValidator : two checks — unreachable
    // from_state and stuck-default warning — plus mutation-reference
    // and given-coverage helpers). First DiagnosticValidator family
    // member to graduate to a Rust-native specializer ; consumes the
    // shared DiagnosticValidator + DiagnosticHelper schema (also used
    // by duplicate_policy_validator_shape, scheduled later).
    //
    // body_kind decision : reuse the diagnostic-validator-family
    // schema (validator + helpers as fixture rows, snippet bodies for
    // each helper, report_kind = flat_with_strict drives the Report
    // struct template). The empty-body `_force_command_use` stub
    // collapses to `fn x() {}` on the signature line — handled inline
    // in the emitter rather than as a new body_kind.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    let output = Command::new(&bin)
        .args(["specialize", "lifecycle_validator"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize lifecycle_validator failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/lifecycle_validator.rs"))
        .expect("lifecycle_validator.rs missing");
    assert_eq!(generated, tracked, "Rust specializer output drifted from tracked file");
}
