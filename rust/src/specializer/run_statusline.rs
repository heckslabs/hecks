//! Rust-native specializer for `rust/src/run_statusline.rs`.
//!
//! i147 Wave 7 target — the statusline runner, regenerated from the
//! `run_statusline_shape` bluebook + ordered Phase / StringMatchArm
//! rows + per-phase `.rs.frag` snippets at codegen/run_statusline_shape/.
//!
//! [antibody-exempt: rust/src/specializer/run_statusline.rs —
//!  i147 Wave 7 specializer for run_statusline.rs. Kernel-surface
//!  codegen module that walks the run_statusline_shape fixtures and
//!  emits the runner byte-identically. Sibling of cli_dispatch.rs /
//!  dump.rs / validator.rs. Retires when the specializer itself is
//!  regenerated from a meta-shape (i78).]
//!
//! Walks the RunStatuslineShape fixtures (Phase rows plus a
//! StringMatchArm catalog for the three icon tables) and emits the
//! statusline runner byte-identically. Five body_kinds :
//!
//!   - `doc_block`      — read .rs.frag verbatim ; preserves leading
//!                        `//!` lines (no comment-strip pass)
//!   - `imports_block`  — read .rs.frag verbatim, leading blank +
//!                        `use ...;` lines
//!   - `verbatim_body`  — read .rs.frag verbatim ; bulk runtime body
//!                        (run + paths + state + coherence + render)
//!   - `string_match`   — declarative `match <param> { … }` body with
//!                        padded arms ; arms read from StringMatchArm
//!                        rows whose `function` matches Phase.name
//!   - `tests_block`    — read .rs.frag verbatim ; the trailing
//!                        `#[cfg(test)] mod tests { … }` block
//!
//! The four snippet body_kinds (doc_block, imports_block,
//! verbatim_body, tests_block) collapse to one emitter today (read
//! raw, no transform). They stay distinct in the bluebook so the
//! taxonomy is explicit ; future refactors split verbatim_body
//! further (read_heki, compose_template, static_data,
//! branch_compose) so the animation tables and render branches
//! become first-class body_kinds rather than inline source. Byte-
//! identity is the gate today ; richer body_kinds become reality as
//! the implementation grows.
//!
//! Usage:
//!   let rust = run_statusline::emit(repo_root)?;
//!   print!("{}", rust);

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::fs;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/run_statusline_shape/fixtures/run_statusline_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let phases = util::by_aggregate_sorted(&fixtures, "Phase", "order");

    let mut out = String::new();
    for phase in &phases {
        out.push_str(&emit_phase(repo_root, &fixtures, phase)?);
    }
    Ok(out)
}

fn emit_phase(
    repo_root: &Path,
    fixtures: &[Fixture],
    phase: &Fixture,
) -> Result<String, Box<dyn Error>> {
    match util::attr(phase, "body_kind") {
        "doc_block" | "imports_block" | "verbatim_body" | "tests_block" => {
            emit_verbatim_snippet(repo_root, phase)
        }
        "string_match" => Ok(emit_string_match(fixtures, phase)),
        other => Err(format!("unknown body_kind: {}", other).into()),
    }
}

/// Read the snippet file at `phase.snippet_path` verbatim — no
/// leading-comment strip, no trim. The four snippet body_kinds share
/// one emitter today ; they're distinct kinds in the bluebook so the
/// taxonomy stays explicit, even when the emit logic collapses.
fn emit_verbatim_snippet(repo_root: &Path, phase: &Fixture) -> Result<String, Box<dyn Error>> {
    let path = repo_root.join(util::attr(phase, "snippet_path"));
    fs::read_to_string(&path)
        .map_err(|e| format!("snippet missing: {} ({})", path.display(), e).into())
}

/// Emit a `fn <name>(<binding>: &str) -> &'static str { match <binding>
/// { <padded arms> } }` block from StringMatchArm rows whose `function`
/// matches `phase.name`. Padding aligns each arm's `=>` so the longest
/// pattern's quoted form sets the column ; the wildcard `_` follows
/// the same column. Optional `comment` on a row appends a trailing
/// ` // <comment>` after the arm value (used today only by
/// provider_badge_for's claude default).
fn emit_string_match(fixtures: &[Fixture], phase: &Fixture) -> String {
    let fn_name = util::attr(phase, "name");
    let (binding, _) = signature_for(fn_name);
    // Per-fn gap between widest pattern and `=>`. Hand-formatted source
    // chose 1 for mood/provider, 2 for fatigue ; declared explicitly
    // on the Phase row so the layout choice survives codegen.
    let min_gap = util::attr(phase, "min_gap").parse::<usize>().unwrap_or(1);

    let arms: Vec<&Fixture> = util::by_aggregate_sorted(fixtures, "StringMatchArm", "order")
        .into_iter()
        .filter(|a| util::attr(a, "function") == fn_name)
        .collect();

    // Pattern width : `_` is bare, literals are quoted. The widest
    // emitted-pattern string sets the alignment column.
    let widest = arms
        .iter()
        .map(|a| emitted_pattern_width(util::attr(a, "pattern")))
        .max()
        .unwrap_or(0);

    let arm_lines: Vec<String> = arms
        .iter()
        .map(|a| {
            let pattern = util::attr(a, "pattern");
            let result = util::attr(a, "result");
            let comment = util::attr(a, "comment");
            let leading_comment = util::attr(a, "leading_comment");
            let emitted = emitted_pattern(pattern);
            let pad = " ".repeat(widest - emitted.len() + min_gap);
            let trailing = if comment.is_empty() {
                String::new()
            } else {
                format!(" {}", comment)
            };
            let prefix = if leading_comment.is_empty() {
                String::new()
            } else {
                // Each line of leading_comment is prefixed with 8 spaces
                // (the arm indentation) and joined with \n ; a trailing
                // \n separates the comment block from the arm itself.
                let lines: Vec<String> = leading_comment
                    .split('\n')
                    .map(|l| format!("        {}", l))
                    .collect();
                format!("{}\n", lines.join("\n"))
            };
            format!("{}        {}{}=> \"{}\",{}", prefix, emitted, pad, result, trailing)
        })
        .collect();

    // Leading `\n` separates this fn from the previous block (mirrors
    // the leading-blank convention every snippet uses).
    let mut out = format!("\nfn {}({}: &str) -> &'static str {{\n", fn_name, binding);
    out.push_str(&format!("    match {} {{\n", binding));
    out.push_str(&arm_lines.join("\n"));
    out.push_str("\n    }\n}\n");
    out
}

/// Render an arm's pattern in the form it appears in source : literal
/// strings get wrapped in quotes ; `_` is bare.
fn emitted_pattern(pattern: &str) -> String {
    if pattern == "_" {
        "_".to_string()
    } else {
        format!("\"{}\"", pattern)
    }
}

/// Width of the emitted pattern (used for arm alignment).
fn emitted_pattern_width(pattern: &str) -> usize {
    emitted_pattern(pattern).chars().count()
}

/// Today the three string_match phases share the same `&str → &'static
/// str` shape. The binding name is derived from the function name
/// (`mood_icon_for` → `mood`, etc). Promote to a fixture column when a
/// phase needs a different shape.
fn signature_for(fn_name: &str) -> (&'static str, &'static str) {
    match fn_name {
        "mood_icon_for"       => ("mood", "&'static str"),
        "fatigue_icon_for"    => ("fatigue", "&'static str"),
        "provider_badge_for"  => ("provider", "&'static str"),
        _                     => ("input", "&'static str"),
    }
}
