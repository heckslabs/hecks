//! Rust port of `lib/hecks_specializer/behaviors_parser.rb`.
//!
//! Emits `hecks_life/src/behaviors_parser.rs` byte-identical to the
//! Ruby specializer's output. Reads the behaviors_parser_shape fixtures
//! (LineParser singleton + LineDispatch rows + ParserHelper rows),
//! assembles header + imports + parse() body + helpers + detector +
//! tests-snippet in the same order the Ruby side emits them.
//!
//! Per-concern split (to stay under the 200-LoC cap):
//!   this file                      — orchestration + emitters for
//!                                     header/imports/parse/helper/detector
//!   behaviors_parser_dispatch.rs   — the if/else-if chain + per-handler
//!                                     body-line generator
//!
//! Usage:
//!   let rust = behaviors_parser::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: hecks_life/src/specializer/behaviors_parser.rs —
//!  Phase D Rust-native specializer implementation]

use crate::ir::Fixture;
use crate::specializer::behaviors_parser_dispatch;
use crate::specializer::util;
use std::error::Error;
use std::fs;
use std::path::Path;

const SHAPE_REL: &str =
    "hecks_conception/capabilities/behaviors_parser_shape/fixtures/behaviors_parser_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    let parser = util::by_aggregate(&fixtures, "LineParser")
        .into_iter()
        .next()
        .ok_or("no LineParser fixture")?;
    let module = util::attr(parser, "module");
    let dispatches = filtered_sorted(&fixtures, "LineDispatch", module);
    let helpers = filtered_sorted(&fixtures, "ParserHelper", module);

    let mut out = String::new();
    out.push_str(&emit_header(repo_root, parser)?);
    out.push_str(&emit_imports(parser));
    out.push_str(&emit_parse(repo_root, parser, &dispatches)?);
    for h in &helpers {
        out.push('\n');
        out.push_str(&emit_helper(repo_root, h)?);
    }
    out.push('\n');
    out.push_str(&emit_detector(parser));
    let tests = util::attr(parser, "tests_snippet");
    if !tests.is_empty() {
        out.push('\n');
        out.push_str(&util::read_snippet_body(&repo_root.join(tests))?);
    }
    Ok(out)
}

fn filtered_sorted<'a>(
    fixtures: &'a [Fixture],
    aggregate: &str,
    parser_module: &str,
) -> Vec<&'a Fixture> {
    let mut v: Vec<&Fixture> = util::by_aggregate(fixtures, aggregate)
        .into_iter()
        .filter(|f| util::attr(f, "parser") == parser_module)
        .collect();
    v.sort_by_key(|f| util::attr(f, "order").parse::<i64>().unwrap_or(0));
    v
}

fn emit_header(repo_root: &Path, parser: &Fixture) -> Result<String, Box<dyn Error>> {
    let path = repo_root.join(util::attr(parser, "doc_snippet"));
    let raw = fs::read_to_string(&path)
        .map_err(|e| format!("cannot read doc snippet {}: {}", path.display(), e))?;
    Ok(format!("{raw}\n"))
}

fn emit_imports(parser: &Fixture) -> String {
    let mut out = String::new();
    for imp in util::attr(parser, "imports").split('\n').filter(|s| !s.is_empty()) {
        out.push_str("use ");
        out.push_str(imp);
        out.push_str(";\n");
    }
    // Ruby joins with "\n" then appends "\n\n"; we emit "use X;\n" per
    // line above, then one more "\n" to produce the blank separator.
    out.push('\n');
    out
}

fn emit_parse(
    repo_root: &Path,
    parser: &Fixture,
    dispatches: &[&Fixture],
) -> Result<String, Box<dyn Error>> {
    let init = util::read_snippet_body(&repo_root.join(util::attr(parser, "state_init_snippet")))?;
    let lv = util::attr(parser, "loop_var_name");
    let sv = util::attr(parser, "state_var");
    let sig = util::attr(parser, "root_signature");
    let dispatch_block = behaviors_parser_dispatch::emit_chain(dispatches, sv, lv);

    // Explicit line-by-line assembly mirrors the Ruby side — avoids
    // heredoc dedent traps when interpolating pre-indented fragments.
    let lines: Vec<String> = vec![
        format!("{sig} {{"),
        chomp(&init).to_string(),
        String::new(),
        format!("    while i < {lv}.len() {{"),
        format!("        let line = {lv}[i].trim();"),
        String::new(),
        chomp(&dispatch_block).to_string(),
        "        i += 1;".to_string(),
        "    }".to_string(),
        String::new(),
        format!("    {sv}"),
        "}".to_string(),
    ];
    let mut out = lines.join("\n");
    out.push('\n');
    Ok(out)
}

fn emit_helper(repo_root: &Path, helper: &Fixture) -> Result<String, Box<dyn Error>> {
    let body = util::read_snippet_body(&repo_root.join(util::attr(helper, "body_snippet")))?;
    let doc = util::attr(helper, "doc_comment");
    let doc_block = if doc.is_empty() { String::new() } else { format!("{doc}\n") };
    let sig = util::attr(helper, "signature");
    Ok(format!("{doc_block}{sig} {{\n{body}}}\n"))
}

fn emit_detector(parser: &Fixture) -> String {
    let kw = util::attr(parser, "detector_keyword");
    let fn_name = util::attr(parser, "detector_fn_name");
    format!(
        "\
/// Returns true if the source's first non-blank, non-comment line is the
/// `{kw}` keyword. Used by callers to dispatch to this parser
/// instead of the regular bluebook parser.
pub fn {fn_name}(source: &str) -> bool {{
    for line in source.lines() {{
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') {{ continue; }}
        return t.starts_with(\"{kw}\");
    }}
    false
}}
"
    )
}

fn chomp(s: &str) -> &str {
    s.strip_suffix('\n').unwrap_or(s)
}
