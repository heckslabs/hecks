//! Rust-native specializer for `rust/src/runtime/command_dispatch.rs`.
//!
//! i147 Wave 5-A target — the dispatch kernel. Every runtime command
//! in the corpus passes through `dispatch_inner` ; the new
//! `command_dispatch_shape` lifts the pipeline contract out of Rust
//! code and into declarative rows.
//!
//! Design — section-as-row, body_kind dispatches emission. Two
//! aggregates :
//!
//!   Phase    — one row per ordered phase inside dispatch_inner. Each
//!              row carries a snippet_path for the phase body. The
//!              specializer concatenates phases in `order` ascending,
//!              separated by blank lines, between the dispatch_inner
//!              signature and its closing brace.
//!
//!   Section  — one row per ordered top-level code block in the file.
//!              `body_kind` picks the emitter :
//!                verbatim_section — read snippet_path raw, emit raw.
//!                dispatch_inner   — synthetic ; assemble from Phase rows.
//!
//! REAL compression : the dispatch contract is the ORDER of phases that
//! makes a command go from name to event, plus the SET of phases that
//! do the work. Both are now data — adding / removing / reordering
//! phases is a fixture-row edit, not a Rust hand-edit.
//!
//! Usage :
//!   let rust = runtime::command_dispatch::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: rust/src/specializer/runtime/command_dispatch.rs —
//!  i147 Wave 5-A — Rust-native specializer for runtime/command_dispatch.rs.
//!  Retires when the specializer itself is regenerated from a meta-shape (i78).]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/command_dispatch_shape/fixtures/command_dispatch_shape.fixtures";

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
            "dispatch_inner" => {
                out.push_str(&emit_dispatch_inner(repo_root, &fixtures)?);
            }
            other => {
                return Err(format!("unknown body_kind: {}", other).into());
            }
        }
    }
    Ok(out)
}

/// Emit the `fn dispatch_inner(...)` function. Iterates each Phase row
/// in `order` ascending, concatenates the phase bodies (read raw from
/// each row's snippet_path), separates phases with one blank line,
/// then closes the function with `}` and a trailing blank line.
fn emit_dispatch_inner(
    repo_root: &Path,
    fixtures: &[Fixture],
) -> Result<String, Box<dyn Error>> {
    let phases = util::by_aggregate_sorted(fixtures, "Phase", "order");

    let mut out = String::new();
    out.push_str("fn dispatch_inner(\n");
    out.push_str("    rt: &mut Runtime,\n");
    out.push_str("    command_name: &str,\n");
    out.push_str("    attrs: HashMap<String, Value>,\n");
    out.push_str("    cascade_hint: Option<(String, String)>,\n");
    out.push_str(") -> Result<CommandResult, RuntimeError> {\n");

    let last = phases.len().saturating_sub(1);
    for (i, phase) in phases.iter().enumerate() {
        let snippet_path = repo_root.join(util::attr(phase, "snippet_path"));
        let body = util::read_snippet_raw(&snippet_path)?;
        out.push_str(&body);
        if i != last {
            out.push('\n');
        }
    }
    out.push_str("}\n");
    out.push('\n');
    Ok(out)
}

const HEADER: &str = r#"//! Command dispatch — the core execution loop
//!
//! Resolves a command name to its aggregate + definition,
//! enforces givens, checks lifecycle, applies mutations,
//! transitions state, persists, and emits.
//!
//! Usage:
//!   let result = dispatch(&mut runtime, "CreatePizza", attrs)?;
//!
//! [antibody-exempt: rust/src/runtime/command_dispatch.rs — kernel-floor
//!  dispatch path. i156 added strict bare-name resolution gated by the
//!  HECKS_STRICT_DISPATCH env var ; the rest of the file is pre-i156.]

use super::{AggregateState, Event, Runtime, RuntimeError, Value};
use super::interpreter;
use crate::ir::{Command, Lifecycle};
use std::collections::HashMap;

"#;
