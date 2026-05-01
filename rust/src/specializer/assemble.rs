//! Rust-native specializer for `rust/src/run_status/assemble.rs`.
//!
//! i147 Wave 8 target — the StatusReport pure read layer, regenerated
//! from the `assemble_shape` bluebook + ordered `.rs.frag` snippets at
//! codegen/assemble_shape/.
//!
//! Design — section-as-snippet (mirrors discover_shape) :
//!   The shape declares one `Section` row per ordered code section in
//!   the target. Each row's `snippet_path` points at a `.rs.frag`
//!   under `codegen/assemble_shape/snippets/`. The specializer sorts
//!   sections by `order`, reads each snippet verbatim
//!   (`read_snippet_raw` — NOT `read_snippet_body` — because each
//!   snippet's trailing blank line is the section separator), and
//!   concatenates HEADER + snippets to produce byte-identical output.
//!
//! Body_kind decision : reuse `verbatim_section`. The `str_field` /
//! `first_present` / `load` / `latest` helpers are the canonical
//! heki-loading idiom, but they're each DEFINED once at the bottom of
//! the file ; the repetition is at the call site inside build()
//! which is expression-level, not section-level. Per-call
//! fixturisation would explode row count for no compression. When a
//! second consumer shows up wanting these helpers shared (run_statusline
//! has the same pattern), lift them into a snippet pool ; today they
//! live verbatim under Section 3.
//!
//! Why HEADER as a const :
//!   The doc + imports prelude is short, stable, and not naturally
//!   tabular ; baking it as a Rust const keeps the shape's tabular
//!   rows uniform (one body_kind, one path attribute). When a future
//!   shape lands that captures imports as data, the HEADER const
//!   retires into a row.
//!
//! Usage :
//!   let rust = assemble::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/assemble.rs —
//!  i147 Wave 8 — Rust-native specializer for run_status/assemble.rs]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/assemble_shape/fixtures/assemble_shape.fixtures";

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

const HEADER: &str = r#"//! Assemble a `Report` from the heki stores + filesystem state.
//!
//! Pure read layer: no rendering, no aggregate writes. The caller stamps
//! these values into the StatusReport aggregate and hands them to the
//! renderer. Keeping this split keeps the runner under its size budget
//! and makes the data-sources test a simple fixture comparison.

use crate::heki;
use crate::runtime::adapter_registry::AdapterRegistry;
use crate::runtime::shell_dispatcher;

use std::collections::HashMap;
use std::path::Path;

"#;
