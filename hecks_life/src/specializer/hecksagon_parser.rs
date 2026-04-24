//! Rust port of `lib/hecks_specializer/hecksagon_parser.rb`.
//!
//! Emits `hecks_life/src/hecksagon_parser.rs` byte-identical to the
//! Ruby specializer's output. Reads the hecksagon_parser_shape fixtures
//! (LineParser singleton + LineDispatch rows + ParserHelper rows),
//! assembles header + imports + detector + parse() body + helpers in
//! the same order the Ruby side emits them.
//!
//! Single-file port — hecksagon_parser.rb is simpler than
//! behaviors_parser.rb (4 LineDispatch handler kinds, no match_mode
//! variants, no tests_snippet, no state_init_snippet). The emission
//! fits under the 200-LoC cap without a dispatch-split sibling file.
//!
//! Usage:
//!   let rust = hecksagon_parser::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: hecks_life/src/specializer/hecksagon_parser.rs —
//!  Phase D Rust-native specializer implementation]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::fs;
use std::path::Path;

const SHAPE_REL: &str =
    "hecks_conception/capabilities/hecksagon_parser_shape/fixtures/hecksagon_parser_shape.fixtures";

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
    out.push_str(&emit_detector(parser));
    out.push_str(&emit_parse(parser, &dispatches));
    let last = helpers.len().saturating_sub(1);
    for (i, h) in helpers.iter().enumerate() {
        out.push_str(&emit_helper(repo_root, h, i < last)?);
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
    out.push('\n');
    out
}

fn emit_detector(parser: &Fixture) -> String {
    let kw = util::attr(parser, "detector_keyword");
    let fn_name = util::attr(parser, "detector_fn_name");
    format!(
        "\
/// Lowest-cost source detection. Skips leading blanks and `#` comments
/// and checks the first non-empty line.
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

fn emit_parse(parser: &Fixture, dispatches: &[&Fixture]) -> String {
    let sig = util::attr(parser, "root_signature");
    // One blank line between dispatch blocks; blocks are indented 8
    // spaces (inside the `while` loop).
    let blocks = dispatches
        .iter()
        .map(|d| emit_dispatch_block(d))
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "\
{sig} {{
    let mut hex = Hecksagon::default();
    let source = crate::parser::strip_shebang(source);
    let raw: Vec<&str> = source.lines().collect();

    let mut i = 0;
    while i < raw.len() {{
        let line = raw[i].trim();

{blocks}
        i += 1;
    }}

    // Default persistence to \"memory\" when no persistence adapter was
    // declared. The IR consumers have always treated None as \"memory\"
    // by convention ; normalising here removes the None possibility
    // from downstream code paths so the field is always a concrete
    // value. Keeps hecksagons that don't declare `adapter :memory`
    // (the default) equivalent to ones that do — eliminates the
    // redundant-declaration noise without introducing a None
    // representation.
    if hex.persistence.is_none() {{
        hex.persistence = Some(\"memory\".to_string());
    }}

    hex
}}

"
    )
}

fn emit_dispatch_block(dispatch: &Fixture) -> String {
    let starts_with = util::attr(dispatch, "starts_with");
    let condition = dispatch_condition(starts_with);
    let body = dispatch_body_lines(dispatch);
    let mut lines: Vec<String> = Vec::new();
    lines.push(format!("        if {condition} {{"));
    for l in body {
        lines.push(format!("            {l}"));
    }
    lines.push("            continue;".to_string());
    lines.push("        }".to_string());
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

fn dispatch_condition(starts_with: &str) -> String {
    starts_with
        .split(',')
        .map(|p| format!("line.starts_with(\"{p}\")"))
        .collect::<Vec<_>>()
        .join(" || ")
}

fn dispatch_body_lines(dispatch: &Fixture) -> Vec<String> {
    let kind = util::attr(dispatch, "handler_kind");
    let field = util::attr(dispatch, "target_field");
    let helper = util::attr(dispatch, "helper_fn");
    match kind {
        "capture_quoted_into" => vec![
            format!("if let Some(n) = between_quotes(line) {{ hex.{field} = n; }}"),
            "i += 1;".to_string(),
        ],
        "push_quoted_onto" => vec![
            format!("if let Some(n) = between_quotes(line) {{ hex.{field}.push(n); }}"),
            "i += 1;".to_string(),
        ],
        "multiline_block" => vec![
            format!("let (gate, consumed) = {helper}(&raw[i..]);"),
            format!("if let Some(g) = gate {{ hex.{field}.push(g); }}"),
            "i += consumed;".to_string(),
        ],
        "multiline_adapter" => vec![
            "let (joined, consumed) = join_adapter_lines(&raw[i..]);".to_string(),
            format!("{helper}(&joined, &mut hex);"),
            "i += consumed;".to_string(),
        ],
        other => panic!("unknown handler_kind: {:?}", other),
    }
}

fn emit_helper(
    repo_root: &Path,
    helper: &Fixture,
    trailing_blank: bool,
) -> Result<String, Box<dyn Error>> {
    let body = util::read_snippet_body(&repo_root.join(util::attr(helper, "body_snippet")))?;
    let doc = util::attr(helper, "doc_comment");
    let doc_block = if doc.is_empty() { String::new() } else { format!("{doc}\n") };
    let sig = util::attr(helper, "signature");
    let core = format!("{doc_block}{sig} {{\n{body}}}\n");
    Ok(if trailing_blank { format!("{core}\n") } else { core })
}
