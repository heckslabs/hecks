//! Rust-native specializer for `hecks_life/src/run_statusline.rs`.
//!
//! [antibody-exempt: hecks_life/src/specializer/run_statusline.rs —
//!  i146 piece-3 specializer implementation. Kernel-surface codegen
//!  module that walks the Statusline fixtures and emits the runner
//!  byte-identically. Sibling of dump.rs / validator.rs / etc. ;
//!  declared by capability_runner_shape's BodyKind table at L0.]
//!
//! Walks the Statusline fixtures (capability_runner_shape's Phase rows
//! plus a StringMatchArm catalog for the three icon tables) and emits
//! the statusline runner byte-identically. i146 piece 3 — the largest
//! capability_runner_shape client yet, exercising four body_kinds :
//! `doc_block`, `imports_block`, `verbatim_body`, and `string_match`,
//! plus a `tests_block` terminator.
//!
//! ## Body kinds (extending capability_runner_shape's BodyKind table)
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
//! The runtime phase today bundles run + path resolution + state +
//! coherence + animation + render_sleep + render_awake into one
//! snippet ; a future refactor splits it along finer body_kind lines
//! (`read_heki`, `compose_template`, `static_data`, `branch_compose`)
//! once those emitters are implemented. Byte-identity is the gate
//! today ; richer body_kinds become reality as the implementation
//! grows. See the BodyKind comments in capability_runner_shape.bluebook
//! for the planned next steps.
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
    "hecks_conception/capabilities/statusline/fixtures/statusline.fixtures";

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
            let emitted = emitted_pattern(pattern);
            let pad = " ".repeat(widest - emitted.len() + min_gap);
            let trailing = if comment.is_empty() {
                String::new()
            } else {
                format!(" {}", comment)
            };
            format!("        {}{}=> \"{}\",{}", emitted, pad, result, trailing)
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
