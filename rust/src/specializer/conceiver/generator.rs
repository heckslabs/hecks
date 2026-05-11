//! Rust-native specializer for `storehouse/src/conceiver/generator.rs`.
//!
//! i147 wave 2 target — produce .bluebook DSL text from archetypes,
//! regenerated from the `conceiver_generator_shape` bluebook + ordered
//! `.rs.frag` snippets.
//!
//! Design — section-as-snippet, mirrors heki_query_shape :
//!   The shape declares one `Section` row per ordered code section in
//!   the target. Each row's `snippet_path` points at a `.rs.frag`
//!   under `capabilities/conceiver_generator_shape/snippets/`. The
//!   specializer sorts sections by `order`, reads each snippet
//!   verbatim (`read_snippet_raw` — not `read_snippet_body` — because
//!   each snippet starts with a `///` doc comment that is file content,
//!   not doc-strip fodder), and concatenates HEADER + snippets to
//!   produce byte-identical output.
//!
//! Why a fixed HEADER constant rather than a leading section :
//!   The first 12 lines of generator.rs (doc comment + `use` + blank +
//!   `const VERSION` + blank) are stable across every section split.
//!   Promoting the version string to a fixture column is a future
//!   refactor ; today the const is embedded here so the file's first
//!   bytes are always identical.
//!
//! Usage :
//!   let rust = conceiver::generator::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: storehouse/src/specializer/conceiver/generator.rs —
//!  i147 wave 2 — Rust-native specializer for conceiver/generator.rs]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/conceiver_generator_shape/fixtures/conceiver_generator_shape.fixtures";

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
            other => {
                return Err(format!("unknown body_kind: {}", other).into());
            }
        }
    }
    Ok(out)
}

const HEADER: &str = r#"//! Generator — produce .bluebook DSL text from archetypes
//!
//! Takes a Domain IR (the archetype) and generates a new bluebook
//! with the same structural shape but placeholder names.
//!
//! Usage:
//!   let text = generate_bluebook("Geology", "study of rocks", &archetype);

use crate::ir::{Domain, Aggregate, MutationOp};

const VERSION: &str = "2026.04.11.1";

"#;
