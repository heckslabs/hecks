//! Rust-native specializer for `rust/src/parser_helpers.rs`.
//!
//! i147 Wave 9-B target — the bluebook parser's helper grab-bag,
//! regenerated from the `parser_helpers_shape` bluebook + ordered
//! `.rs.frag` snippets at `codegen/parser_helpers_shape/`.
//!
//! Design — section-as-snippet (mirrors assemble_shape) :
//!   The shape declares one `Section` row per ordered code section in
//!   the target. Each row's `snippet_path` points at a `.rs.frag`
//!   under `codegen/parser_helpers_shape/snippets/`. The specializer
//!   sorts sections by `order`, reads each snippet verbatim
//!   (`read_snippet_raw` — NOT `read_snippet_body` — because each
//!   snippet's trailing blank line is the section separator), and
//!   concatenates HEADER + snippets to produce byte-identical output.
//!
//! Body_kind decision : reuse `verbatim_section`. The string-extraction
//! idiom is genuine repetition (find quote, slice between quotes, …)
//! but each fn diverges enough at the edges (default kwarg parsing,
//! acronym detection, role-vs-as kwarg disambiguation) that
//! parameterising it would balloon the body_kind into a mini-language.
//! When a second consumer of these helpers shows up, promote the
//! most-reused chunks into a shared snippet pool ; today they live
//! verbatim under sections 1 and 5.
//!
//! Why HEADER as a const :
//!   The 4-line doc prelude is short, stable, and not naturally
//!   tabular ; baking it as a Rust const keeps the shape's tabular
//!   rows uniform (one body_kind, one path attribute). When a future
//!   shape lands that captures doc-comment headers as data, the
//!   HEADER const retires into a row.
//!
//! Usage :
//!   let rust = parser_helpers::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/parser_helpers.rs —
//!  i147 Wave 9-B — Rust-native specializer for parser_helpers.rs]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/parser_helpers_shape/fixtures/parser_helpers_shape.fixtures";

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

const HEADER: &str = r#"//! Parser helpers — string extraction and DSL pattern matching
//!
//! Utilities for pulling strings, symbols, blocks, and keywords
//! out of Bluebook DSL lines. Used by the parser module.

"#;
