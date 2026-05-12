//! Rust-native specializer for `storehouse/src/behaviors_runner.rs`.
//!
//! i147 Wave 4-B target — pure-memory test-suite executor regenerated
//! from the `behaviors_runner_shape` bluebook + ordered `.rs.frag`
//! snippets + per-overload `.frag` doc fragments.
//!
//! Design — section-as-row, body_kind dispatches emission. The shape
//! declares one `Section` row per ordered code section in the target.
//! Each row's `body_kind` picks the emission template :
//!
//! ```text
//!     verbatim_section — read `snippet_path` raw, emit unchanged.
//!                        Used for the types block (TestStatus / TestRun /
//!                        SuiteResult) and the long bodies that don't
//!                        naturally compress (run_one, run_query, the
//!                        ten helpers).
//!
//!     suite_overload   — emit one of the three suite-entry overloads
//!                        (run_suite, run_suite_with_fixtures,
//!                        run_suite_with_domain) from knobs : fn_name,
//!                        doc_path, kind (`delegate` | `iter`),
//!                        has_domain, has_fixtures. The dispatcher
//!                        emits the function from a shared template ;
//!                        ~38 lines of source compressed into 3 fixture
//!                        rows + 3 small doc fragments.
//! ```
//!
//! Why a new body_kind instead of falling back to verbatim_section :
//! Wave 3-A and 3-C both fell back to verbatim_section bookmarking ;
//! Wave 4 makes REAL compression non-negotiable. The three suite-entry
//! overloads share a structural template — "iterate suite.tests, call
//! run_one with this signature, collect into SuiteResult" — that IS
//! compressible : only the doc comment, the signature param set, and
//! one of two body shapes vary. Those variations are knobs ; the
//! shared skeleton is in this emitter.
//!
//! Usage :
//!
//! ```ignore
//!   let rust = behaviors_runner::emit(repo_root)?;
//!   print!("{}", rust);
//! ```
//!
//! [antibody-exempt: rust/src/specializer/behaviors_runner.rs —
//!  i147 Wave 4-B Rust-native specializer for behaviors_runner.rs.
//!  Retires when the specializer itself is regenerated from a
//!  meta-shape (i78).]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::fs;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/behaviors_runner_shape/fixtures/behaviors_runner_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let sections = util::by_aggregate_sorted(&fixtures, "Section", "order");

    let mut out = String::new();
    out.push_str(HEADER);
    for sec in &sections {
        match util::attr(sec, "body_kind") {
            "verbatim_section" => {
                let snippet_path = repo_root.join(util::attr(sec, "snippet_path"));
                let body = util::read_snippet_raw(&snippet_path)?;
                out.push_str(&body);
            }
            "suite_overload" => {
                out.push_str(&emit_suite_overload(repo_root, sec)?);
            }
            other => {
                return Err(format!("unknown body_kind: {}", other).into());
            }
        }
    }
    Ok(out)
}

/// Emit one of the three suite-entry overloads from row knobs.
///
/// Knobs :
///   fn_name      — the public function name (`run_suite`, etc.).
///   doc_path     — relative path to a .frag with the doc-comment lines
///                  that precede the `pub fn` line. Read verbatim.
///   kind         — `delegate` (single-line body delegating to
///                  run_suite_with_fixtures) or `iter` (the
///                  `iter().map(|t| run_one(...)).collect()` pattern).
///   has_domain   — `"true"` (signature carries `domain_template:
///                  &Domain`, run_one's 4th arg is Some(domain_template))
///                  or empty (no domain param ; run_one's 4th arg is
///                  None). Only consulted when kind=iter.
///   has_fixtures — `"true"` (signature carries `fixtures:
///                  Option<&FixturesFile>`) or empty. Only consulted
///                  when kind=iter ; the delegate row hard-codes its
///                  delegate target as run_suite_with_fixtures.
///
/// Each overload ends with a trailing blank line (matching the source
/// file's section convention — every section is followed by a blank
/// line before the next one).
fn emit_suite_overload(repo_root: &Path, sec: &Fixture) -> Result<String, Box<dyn Error>> {
    let fn_name = util::attr(sec, "fn_name");
    let doc_path = repo_root.join(util::attr(sec, "doc_path"));
    let doc = fs::read_to_string(&doc_path)
        .map_err(|e| format!("doc fragment missing {}: {}", doc_path.display(), e))?;
    let kind = util::attr(sec, "kind");
    let has_domain = util::attr(sec, "has_domain") == "true";
    let has_fixtures = util::attr(sec, "has_fixtures") == "true";

    let mut out = String::new();
    out.push_str(&doc);
    match kind {
        "delegate" => {
            // Single-line body. Today's only delegating shim is run_suite,
            // which forwards source_text + suite to run_suite_with_fixtures
            // with None for the optional fixtures arg.
            out.push_str(&format!(
                "pub fn {}(source_text: &str, suite: &TestSuite) -> SuiteResult {{\n",
                fn_name,
            ));
            out.push_str("    run_suite_with_fixtures(source_text, suite, None)\n");
            out.push_str("}\n");
        }
        "iter" => {
            // Multi-line signature : one param per line, trailing comma
            // before the closing paren. Then the iter().map().collect()
            // body that calls run_one with the right 4-tuple of args.
            out.push_str(&format!("pub fn {}(\n", fn_name));
            out.push_str("    source_text: &str,\n");
            if has_domain {
                out.push_str("    domain_template: &Domain,\n");
            }
            out.push_str("    suite: &TestSuite,\n");
            if has_fixtures {
                out.push_str("    fixtures: Option<&FixturesFile>,\n");
            }
            out.push_str(") -> SuiteResult {\n");
            out.push_str("    let runs = suite.tests.iter()\n");
            let domain_arg = if has_domain { "Some(domain_template)" } else { "None" };
            out.push_str(&format!(
                "        .map(|t| run_one(source_text, t, fixtures, {}))\n",
                domain_arg,
            ));
            out.push_str("        .collect();\n");
            out.push_str("    SuiteResult { runs }\n");
            out.push_str("}\n");
        }
        other => {
            return Err(format!("unknown suite_overload kind: {}", other).into());
        }
    }
    // Trailing blank line — every section in behaviors_runner.rs is
    // followed by a blank line before the next section starts.
    out.push('\n');
    Ok(out)
}

const HEADER: &str = r#"//! Behaviors test runner — executes a TestSuite against a source domain
//!
//! Pure-memory by design: uses `Runtime::boot(domain)` (no `data_dir`,
//! no hecksagon, no adapters). Each test gets a fresh runtime so
//! state doesn't leak across tests. If a test triggers IO, the source
//! bluebook is doing something it shouldn't — fix the bluebook, not
//! the test.
//!
//! Usage:
//!   storehouse behaviors path/to/X_behavioral_tests.bluebook
//!
//! The runner finds the source bluebook by stripping the
//! `_behavioral_tests` suffix (e.g. `pizzas_behavioral_tests.bluebook`
//! → `pizzas.bluebook`).
//!
//! [antibody-exempt: rust/src/behaviors_runner.rs — pure-memory test
//!  scaffolding. i156 taught find_command to handle qualified setups
//!  (Aggregate.Command) so reference-injection still finds self-refs
//!  when callers migrate from bare names.]

use crate::behaviors_ir::{Test, TestSuite};
use crate::behaviors_fixtures;
use crate::fixtures_ir::FixturesFile;
use crate::ir::Domain;
use crate::parser;
use crate::runtime::{Runtime, RuntimeError, Value};
use std::collections::{BTreeMap, HashMap};

"#;
