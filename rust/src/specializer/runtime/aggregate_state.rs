//! Rust-native specializer for `rust/src/runtime/aggregate_state.rs`.
//!
//! i147 Wave 4-A target (i171 closure) — the runtime's dynamic field
//! bag, regenerated from the `mutation_op_shape` bluebook. Wave 3-A
//! shipped this file as a single verbatim_section snippet under
//! `runtime_state_shape`. Wave 4-A breaks the impl block into per-
//! method snippets driven by MutatorMethod rows, so the SAME shape
//! that emits interpreter.rs's apply_mutations dispatch arms also
//! emits aggregate_state.rs's mutator method family. One shape, two
//! consumers, language-compression amortized.
//!
//! Design — section-as-row, body_kind dispatches emission. The shape
//! declares one Section row per ordered code section in the target
//! (filtered by `target = "aggregate_state"`). Each row's `body_kind`
//! picks the emission template :
//!
//!   verbatim_section — read snippet_path raw, emit unchanged. Used
//!                      for the AggregateState struct
//!                      (`mutation_op_shape/snippets/agg_state_01_struct.rs.frag`)
//!                      and the free numeric helpers
//!                      (`mutation_op_shape/snippets/agg_state_03_numeric_helpers.rs.frag`).
//!
//!   mutator_impl     — emit the impl AggregateState block. Walks
//!                      MutatorMethod rows in `order` ascending, reads
//!                      each row's snippet_path raw, concatenates with
//!                      blank-line separators between methods, and
//!                      wraps the result in `impl AggregateState {` /
//!                      closing `}`.
//!
//! Wave 3-A's `runtime_state_shape/` directory retired in this Wave —
//! its struct + numeric_helpers snippets moved into
//! `mutation_op_shape/snippets/` (renamed `agg_state_*`) so all
//! aggregate_state shape inputs live in one shape directory.
//!
//! Usage :
//!   let rust = runtime::aggregate_state::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/runtime/aggregate_state.rs —
//!  i147 Wave 4-A — Rust-native specializer for runtime/aggregate_state.rs.
//!  Re-targeted at mutation_op_shape's MutatorMethod rows ; the impl
//!  block emits per-method, not as a single verbatim snippet.]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/mutation_op_shape/fixtures/mutation_op_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    let sections: Vec<&Fixture> = util::by_aggregate_sorted(&fixtures, "Section", "order")
        .into_iter()
        .filter(|f| util::attr(f, "target") == "aggregate_state")
        .collect();

    let mut out = String::new();
    out.push_str(HEADER);
    for sec in &sections {
        match util::attr(sec, "body_kind") {
            "verbatim_section" => {
                let snippet_path = repo_root.join(util::attr(sec, "snippet_path"));
                let body = util::read_snippet_raw(&snippet_path)?;
                out.push_str(&body);
            }
            "mutator_impl" => {
                out.push_str(&emit_mutator_impl(repo_root, &fixtures)?);
            }
            other => {
                return Err(format!("unknown body_kind: {}", other).into());
            }
        }
    }
    Ok(out)
}

/// Emit the `impl AggregateState { … }` block. Walks MutatorMethod
/// rows in `order` ascending, reads each row's snippet raw, joins
/// with single blank lines between methods, and wraps in the impl
/// opener + closing brace + trailing blank line (matches the source
/// shape of the original 02_impl.rs.frag snippet byte-for-byte).
fn emit_mutator_impl(
    repo_root: &Path,
    fixtures: &[Fixture],
) -> Result<String, Box<dyn Error>> {
    let methods = util::by_aggregate_sorted(fixtures, "MutatorMethod", "order");

    let mut out = String::new();
    out.push_str("impl AggregateState {\n");
    for (i, m) in methods.iter().enumerate() {
        let path = repo_root.join(util::attr(m, "snippet_path"));
        let body = util::read_snippet_raw(&path)?;
        out.push_str(&body);
        if i + 1 < methods.len() {
            // Methods are separated by exactly one blank line in the
            // tracked source. Per-method snippets end with `\n` (one
            // closing brace, no trailing blank), so emitting one
            // extra `\n` between methods produces the inter-method
            // blank.
            out.push('\n');
        }
    }
    out.push_str("}\n");
    out.push('\n');
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
