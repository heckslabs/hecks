//! Rust-native specializer for `hecks_life/src/runtime/aggregate_state.rs`.
//!
//! i147 Wave 3-A target — the runtime's dynamic field bag (struct +
//! Value-typed mutators + numeric helpers) regenerated from the
//! `runtime_state_shape` bluebook + ordered `.rs.frag` snippets.
//!
//! Design — section-as-snippet (mirrors heki_query / behaviors_fixtures
//! / discover / conceiver/generator) :
//!   The shape declares one `Section` row per ordered code section in
//!   the target. Each row's `snippet_path` points at a `.rs.frag`
//!   under `codegen/runtime_state_shape/snippets/`. The specializer
//!   sorts sections by `order`, reads each snippet verbatim
//!   (`read_snippet_raw` — NOT `read_snippet_body` — because each
//!   snippet opens with `#[derive(...)]` or `impl AggregateState {` or
//!   a `fn` declaration that is file content, not doc-strip fodder),
//!   and concatenates HEADER + snippets to produce byte-identical
//!   output.
//!
//! Why a purpose-built `runtime_state_shape` (option (b) from the
//! Wave 3 design choice) rather than extending `dump_shape` :
//!
//!   - The mutator method bodies vary too much to share a template
//!     (set is a one-line insert, append lazily creates a Value::List,
//!     increment does an Int round-trip, the float siblings parse
//!     strings, toggle flips a Bool). A `body_kind: typed_setter`
//!     row in dump_shape would still need one body-template per
//!     method — defeating unification.
//!   - dump_shape is byte-identical today. Any change to its row
//!     vocabulary triggers its golden test ; a purpose-built shape
//!     keeps the blast radius confined to this Wave 3-A landing.
//!
//! Why HEADER as a const :
//!   The doc + antibody-marker + use-line prelude is short, stable,
//!   and not naturally tabular ; baking it as a Rust const keeps the
//!   shape's tabular rows uniform (one body_kind, one path attribute).
//!   When a future shape lands that captures imports + antibody markers
//!   as data, the HEADER const retires into a row.
//!
//! Usage :
//!   let rust = runtime::aggregate_state::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: hecks_life/src/specializer/runtime/aggregate_state.rs —
//!  i147 Wave 3-A — Rust-native specializer for runtime/aggregate_state.rs]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/runtime_state_shape/fixtures/runtime_state_shape.fixtures";

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

const HEADER: &str = r#"//! AggregateState — dynamic bag of fields
//!
//! Aggregates are not typed structs — they're Value maps
//! shaped by the Bluebook IR at runtime.
//!
//! Usage:
//!   let mut state = AggregateState::new("pizza_1");
//!   state.set("name", Value::Str("Margherita".into()));
//!
//! [antibody-exempt: i106 dsl-mutation-primitives — adds `set_float`
//!  for Multiply / Clamp / Decay. Same retirement contract as ir.rs.]

use super::Value;
use std::collections::HashMap;

"#;
