//! Dispatch-chain emission for `behaviors_parser` Phase D port.
//!
//! Translates a run of LineDispatch fixtures into the Rust text that
//! goes inside the `parse()` loop: the outer `if ... } else if ... }`
//! chain, each branch's condition (match_mode), and each branch's body
//! (handler_kind). Split out from `behaviors_parser.rs` so both files
//! stay under the 200-LoC cap — the parent file handles orchestration,
//! this file handles one concern: fixture-row → Rust-lines.
//!
//! Usage:
//!   let block = emit_chain(&dispatches, "suite", "lines");
//!   // → "        if line.starts_with(...) {\n            ...\n        }\n"
//!
//! [antibody-exempt: hecks_life/src/specializer/behaviors_parser_dispatch.rs —
//!  Phase D Rust-native specializer implementation]

use crate::ir::Fixture;
use crate::specializer::util;

/// Emit the `if / else if` chain body for the parse() loop. Each
/// dispatch fixture becomes one arm; bodies are indented 12 spaces
/// (matching the Ruby side's explicit-line assembly). Output always
/// ends with a trailing newline.
pub fn emit_chain(dispatches: &[&Fixture], sv: &str, lv: &str) -> String {
    let mut lines: Vec<String> = Vec::new();
    let last = dispatches.len().saturating_sub(1);
    for (idx, d) in dispatches.iter().enumerate() {
        let kw_form = if idx == 0 { "if " } else { "} else if " };
        lines.push(format!("        {kw_form}{} {{", condition(d)));
        for l in body_lines(d, sv, lv) {
            lines.push(format!("            {l}"));
        }
        if idx == last {
            lines.push("        }".to_string());
        }
    }
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

fn condition(d: &Fixture) -> String {
    let mode = match util::attr(d, "match_mode") { "" => "prefix", m => m };
    let kw = util::attr(d, "match_keyword");
    match mode {
        "prefix" => kw.split(',')
            .map(|p| format!("line.starts_with(\"{p}\")"))
            .collect::<Vec<_>>()
            .join(" || "),
        "word" => format!("line.starts_with(\"{kw} \") || line.starts_with(\"{kw}\\t\")"),
        "word_or_equal" => format!(
            "line.starts_with(\"{kw} \") || line.starts_with(\"{kw}\\t\") || line == \"{kw}\""
        ),
        other => panic!("unknown match_mode: {:?}", other),
    }
}

fn body_lines(d: &Fixture, sv: &str, lv: &str) -> Vec<String> {
    let qfn = util::attr(d, "quote_fn");
    let vfn = util::attr(d, "variadic_fn");
    let field = util::attr(d, "target_field");
    let helper = util::attr(d, "helper_fn");
    let cvar = match util::attr(d, "capture_var") { "" => "n", s => s };
    let kind = util::attr(d, "handler_kind");

    let mut lines: Vec<String> = Vec::new();
    let comment = util::attr(d, "body_comment");
    if !comment.is_empty() {
        for c in comment.split('\n') {
            lines.push(format!("// {c}"));
        }
    }

    match kind {
        "capture_quoted_into" => lines.push(format!(
            "if let Some({cvar}) = {qfn}(line) {{ {sv}.{field} = {cvar}; }}"
        )),
        "capture_quoted_into_option" => lines.push(format!(
            "if let Some({cvar}) = {qfn}(line) {{ {sv}.{field} = Some({cvar}); }}"
        )),
        "push_quoted_onto" => lines.push(format!(
            "if let Some({cvar}) = {qfn}(line) {{ {sv}.{field}.push({cvar}); }}"
        )),
        "push_all_quoted_onto" => {
            lines.push(format!("for name in {vfn}(line) {{"));
            lines.push(format!("    {sv}.{field}.push(name);"));
            lines.push("}".to_string());
        }
        "multiline_block_direct" => {
            lines.push(format!("let (test, consumed) = {helper}(&{lv}[i..]);"));
            lines.push(format!("{sv}.{field}.push(test);"));
            lines.push("i += consumed;".to_string());
            lines.push("continue;".to_string());
        }
        "multiline_block" => {
            lines.push(format!("let (gate, consumed) = {helper}(&{lv}[i..]);"));
            lines.push(format!("if let Some(g) = gate {{ {sv}.{field}.push(g); }}"));
            lines.push("i += consumed;".to_string());
            lines.push("continue;".to_string());
        }
        other => panic!("unknown handler_kind: {:?}", other),
    }

    lines
}
