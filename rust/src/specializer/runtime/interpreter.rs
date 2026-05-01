//! Rust-native specializer for `rust/src/runtime/interpreter.rs`.
//!
//! i147 Wave 4-A target (i171 closure) — the runtime expression
//! engine that evaluates givens and applies mutations, regenerated
//! from the `mutation_op_shape` bluebook + ordered `.rs.frag`
//! snippets + per-op MutationOp rows.
//!
//! Design — section-as-row, body_kind dispatches emission. The shape
//! declares one Section row per ordered code section in the target.
//! Each row's `body_kind` picks the emission template :
//!
//!   verbatim_section      — read snippet_path raw, emit unchanged.
//!                           Used for check_givens, the field_numeric
//!                           + clamp_bounds helpers, and the tail (the
//!                           given evaluator + resolve_expr family).
//!
//!   mutation_op_dispatch  — emit `pub fn apply_mutations(…)` with one
//!                           match arm per MutationOp row. The arm body
//!                           is templated per dispatch_kind ; per-op
//!                           knobs (state_method, doc_snippet, …) come
//!                           from the row.
//!
//! Six dispatch_kind templates handle the 9 MutationOp variants :
//!   resolve_call               (Set, Append)
//!   numeric_with_float_branch  (Increment, Decrement)
//!   nullary_method             (Toggle)
//!   state_flag                 (Delete)
//!   field_factor               (Multiply, Decay)
//!   clamp_bounds               (Clamp)
//!
//! The three pairs (Set/Append, Increment/Decrement, Multiply/Decay)
//! each share one template ; the three sui-generis kinds cover the
//! arms that don't fit the pattern. Real compression : 9 arms emit
//! from 6 templates, with per-op semantics living as row knobs.
//!
//! Usage :
//!   let rust = runtime::interpreter::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/runtime/interpreter.rs —
//!  i147 Wave 4-A — Rust-native specializer for runtime/interpreter.rs.
//!  Retires when the specializer itself is regenerated from a
//!  meta-shape (i78).]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::fs;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/mutation_op_shape/fixtures/mutation_op_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    // Section rows are filtered by target — `target = "interpreter"`
    // for this consumer ; the same fixture file also carries the
    // aggregate_state rows for the sibling specializer.
    let sections: Vec<&Fixture> = util::by_aggregate_sorted(&fixtures, "Section", "order")
        .into_iter()
        .filter(|f| util::attr(f, "target") == "interpreter")
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
            "mutation_op_dispatch" => {
                out.push_str(&emit_apply_mutations(repo_root, &fixtures)?);
            }
            other => {
                return Err(format!("unknown body_kind: {}", other).into());
            }
        }
    }
    Ok(out)
}

/// Emit the `pub fn apply_mutations(…)` function. Iterates each
/// MutationOp row in `order` ascending and emits one match arm per
/// row, picking the arm template by `dispatch_kind`.
fn emit_apply_mutations(
    repo_root: &Path,
    fixtures: &[Fixture],
) -> Result<String, Box<dyn Error>> {
    let ops = util::by_aggregate_sorted(fixtures, "MutationOp", "order");

    let mut out = String::new();
    out.push_str("pub fn apply_mutations(\n");
    out.push_str("    cmd: &Command,\n");
    out.push_str("    state: &mut AggregateState,\n");
    out.push_str("    attrs: &HashMap<String, Value>,\n");
    out.push_str(") {\n");
    out.push_str("    for mutation in &cmd.mutations {\n");
    out.push_str("        match mutation.operation {\n");
    for op in &ops {
        out.push_str(&emit_arm(repo_root, op)?);
    }
    out.push_str("        }\n");
    out.push_str("    }\n");
    out.push_str("}\n");
    out.push('\n');
    Ok(out)
}

/// Emit one `MutationOp::<name> => { … }` arm. The body shape comes
/// from `dispatch_kind` ; per-op knobs (state_method, factor_expr,
/// arg_local, flag_name) provide the variable bits. doc_snippet, when
/// present, is read raw and inserted as the arm's leading doc lines.
fn emit_arm(repo_root: &Path, op: &Fixture) -> Result<String, Box<dyn Error>> {
    let op_name = util::attr(op, "op_name");
    let kind = util::attr(op, "dispatch_kind");

    let mut out = String::new();
    out.push_str(&format!("            MutationOp::{} => {{\n", op_name));

    match kind {
        // Set, Append — resolve mutation.value, then call
        // state.<state_method>(field, val).
        "resolve_call" => {
            push_doc(&mut out, repo_root, op)?;
            out.push_str("                let val = resolve_mutation_value(&mutation.value, attrs, state);\n");
            out.push_str(&format!("                state.{}(&mutation.field, val);\n",
                util::attr(op, "state_method")));
        }
        // Increment, Decrement — float-aware fast path falls through
        // to int when fract() == 0.0. Doc (when present) sits BETWEEN
        // the let-val and the float branch, mirroring the source.
        "numeric_with_float_branch" => {
            out.push_str("                let val = resolve_mutation_value(&mutation.value, attrs, state);\n");
            push_doc(&mut out, repo_root, op)?;
            out.push_str("                if let Some(f) = numeric_value(&val) {\n");
            out.push_str("                    if f.fract() != 0.0 {\n");
            out.push_str(&format!("                        state.{}(&mutation.field, f);\n",
                util::attr(op, "state_method_float")));
            out.push_str("                        continue;\n");
            out.push_str("                    }\n");
            out.push_str("                }\n");
            out.push_str("                let amount = val.as_int().unwrap_or(1);\n");
            out.push_str(&format!("                state.{}(&mutation.field, amount);\n",
                util::attr(op, "state_method_int")));
        }
        // Toggle — single-line state.<method>(field).
        "nullary_method" => {
            push_doc(&mut out, repo_root, op)?;
            out.push_str(&format!("                state.{}(&mutation.field);\n",
                util::attr(op, "state_method")));
        }
        // Delete — flips a bool field on AggregateState. Sui generis :
        // the only op that doesn't dispatch through the impl block.
        "state_flag" => {
            push_doc(&mut out, repo_root, op)?;
            out.push_str(&format!("                state.{} = true;\n", util::attr(op, "flag_name")));
        }
        // Multiply, Decay — resolve factor/rate, compute cur * factor_expr,
        // set_float. arg_local names the local f64 ; factor_expr is the
        // right-hand expression composed in terms of cur + arg_local.
        "field_factor" => {
            push_doc(&mut out, repo_root, op)?;
            out.push_str("                let val = resolve_mutation_value(&mutation.value, attrs, state);\n");
            out.push_str(&format!("                if let Some({}) = numeric_value(&val) {{\n",
                util::attr(op, "arg_local")));
            out.push_str("                    let cur = field_numeric(&mutation.field, state);\n");
            out.push_str(&format!("                    state.set_float(&mutation.field, {});\n",
                util::attr(op, "factor_expr")));
            out.push_str("                }\n");
        }
        // Clamp — sui generis. [min, max] list literal via clamp_bounds
        // helper, bounds field via cur.max(min).min(max), set_float.
        "clamp_bounds" => {
            push_doc(&mut out, repo_root, op)?;
            out.push_str("                let bounds = resolve_mutation_value(&mutation.value, attrs, state);\n");
            out.push_str("                if let Some((min, max)) = clamp_bounds(&bounds) {\n");
            out.push_str("                    let cur = field_numeric(&mutation.field, state);\n");
            out.push_str("                    let bounded = cur.max(min).min(max);\n");
            out.push_str("                    state.set_float(&mutation.field, bounded);\n");
            out.push_str("                }\n");
        }
        other => return Err(format!("unknown dispatch_kind: {}", other).into()),
    }

    out.push_str("            }\n");
    Ok(out)
}

/// Read the optional `doc_snippet` for an op and append it raw to
/// `out`. Five of the six dispatch_kind templates accept a per-arm
/// doc — extracted so each arm body stays focused on the runtime
/// shape rather than the read-and-skip-when-empty plumbing.
fn push_doc(out: &mut String, repo_root: &Path, op: &Fixture) -> Result<(), Box<dyn Error>> {
    let snippet = util::attr(op, "doc_snippet");
    if snippet.is_empty() { return Ok(()); }
    let path = repo_root.join(snippet);
    let body = fs::read_to_string(&path)
        .map_err(|e| format!("doc snippet missing {}: {}", path.display(), e))?;
    out.push_str(&body);
    Ok(())
}

const HEADER: &str = r#"//! HecksalInterpreter — evaluates givens and applies mutations
//!
//! The expression evaluator for Bluebook's declarative behavior.
//! Givens are predicates. Mutations are state changes. Both are data.
//!
//! Usage:
//!   check_givens(cmd, state, attrs)?;
//!   apply_mutations(cmd, state, attrs);
//!
//! [antibody-exempt: i106 dsl-mutation-primitives — kernel-surface
//!  runtime extension that applies Multiply / Clamp / Decay. Same
//!  retirement contract as ir.rs.]
//!
//! [antibody-exempt: rand_below(N) predicate primitive — stochastic
//!  dispatch gates (RANDOM % N == 0, every-Nth-tick) move from
//!  shell-side into bluebook givens. Lets surface_musing /
//!  musing_mint / daydream fire end-to-end via bluebook. Same i80
//!  retirement contract.]

use super::{AggregateState, RuntimeError, Value};
use crate::ir::{Command, MutationOp};
use std::collections::HashMap;

"#;
