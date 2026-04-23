//! Rust port of `lib/hecks_specializer/fixtures_parser.rb`.
//!
//! Emits `hecks_life/src/fixtures_parser.rs` byte-identical to the
//! Ruby specializer's output. Reads the fixtures_parser_shape fixtures
//! (LineParser singleton + ParserHelper rows — LineDispatch rows are
//! documentation-only; `parse_body_snippet` is authoritative) and
//! assembles header + imports + before_root helpers + parse() +
//! after_root helpers + test block in the same order the Ruby side
//! emits them.
//!
//! Notable wrinkle carried over from the Ruby specializer: several
//! helper bodies here legitimately start with `//` comments (e.g.,
//! `extract_schema_kwarg_body.rs.frag` opens with `// Find the first
//! top-level comma …`), which the generic `util::read_snippet_body`
//! would strip as a leading-comment header. We use a local `read_raw`
//! helper instead — bare `fs::read_to_string`, no comment strip. If a
//! future port needs the same override, promote `read_raw` to
//! `util.rs`.
//!
//! Usage:
//!   let rust = fixtures_parser::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: hecks_life/src/specializer/fixtures_parser.rs —
//!  Phase D Rust-native specializer implementation]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::fs;
use std::path::Path;

const SHAPE_REL: &str =
    "hecks_conception/capabilities/fixtures_parser_shape/fixtures/fixtures_parser_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    let parser = util::by_aggregate(&fixtures, "LineParser")
        .into_iter()
        .next()
        .ok_or("no LineParser fixture")?;
    let module = util::attr(parser, "module");

    let mut helpers: Vec<&Fixture> = util::by_aggregate(&fixtures, "ParserHelper")
        .into_iter()
        .filter(|f| util::attr(f, "parser") == module)
        .collect();

    let before = filter_position(&helpers, "before_root");
    let after = filter_position(&helpers, "after_root");
    // Drain so `helpers` is only used for partitioning above.
    helpers.clear();

    let mut out = String::new();
    out.push_str(&emit_header(repo_root, parser)?);
    out.push_str(&emit_imports(parser));
    for h in &before {
        out.push_str(&emit_helper(repo_root, h)?);
    }
    out.push_str(&emit_parse(repo_root, parser)?);
    for h in &after {
        out.push_str(&emit_helper(repo_root, h)?);
    }
    out.push_str(&emit_test_block(repo_root, parser)?);
    Ok(out)
}

fn filter_position<'a>(helpers: &[&'a Fixture], position: &str) -> Vec<&'a Fixture> {
    let mut v: Vec<&Fixture> = helpers
        .iter()
        .copied()
        .filter(|h| {
            let p = util::attr(h, "position");
            let effective = if p.is_empty() { "after_root" } else { p };
            effective == position
        })
        .collect();
    v.sort_by_key(|h| util::attr(h, "order").parse::<i64>().unwrap_or(0));
    v
}

fn emit_header(repo_root: &Path, parser: &Fixture) -> Result<String, Box<dyn Error>> {
    let raw = read_raw(&repo_root.join(util::attr(parser, "doc_snippet")))?;
    Ok(format!("{raw}\n"))
}

fn emit_imports(parser: &Fixture) -> String {
    let lines: Vec<String> = util::attr(parser, "imports")
        .split('\n')
        .filter(|s| !s.is_empty())
        .map(|imp| format!("use {imp};"))
        .collect();
    // Ruby: lines.join("\n") + "\n\n". Same byte shape.
    let mut out = lines.join("\n");
    out.push_str("\n\n");
    out
}

fn emit_parse(repo_root: &Path, parser: &Fixture) -> Result<String, Box<dyn Error>> {
    let sig = util::attr(parser, "root_signature");
    let body = read_raw(&repo_root.join(util::attr(parser, "parse_body_snippet")))?;
    Ok(format!("{sig} {{\n{body}}}\n\n"))
}

fn emit_helper(repo_root: &Path, helper: &Fixture) -> Result<String, Box<dyn Error>> {
    let doc = helper_doc(repo_root, helper)?;
    let sig = util::attr(helper, "signature");
    let body = read_raw(&repo_root.join(util::attr(helper, "body_snippet")))?;
    Ok(format!("{doc}{sig} {{\n{body}}}\n\n"))
}

fn helper_doc(repo_root: &Path, helper: &Fixture) -> Result<String, Box<dyn Error>> {
    let snippet = util::attr(helper, "doc_snippet");
    if !snippet.is_empty() {
        return read_raw(&repo_root.join(snippet));
    }
    let inline = util::attr(helper, "doc_comment");
    if inline.is_empty() {
        return Ok(String::new());
    }
    Ok(format!("{inline}\n"))
}

fn emit_test_block(repo_root: &Path, parser: &Fixture) -> Result<String, Box<dyn Error>> {
    let snippet = util::attr(parser, "test_block_snippet");
    if snippet.is_empty() {
        return Ok(String::new());
    }
    // Snippet ends with its own closing `}\n`; no trailing blank line —
    // file ends right after.
    read_raw(&repo_root.join(snippet))
}

/// Bare file read — no leading-comment-header strip. Mirrors the
/// `read_raw` override in the Ruby specializer. Several fixtures_parser
/// snippet bodies open with `//` comments that are part of the emitted
/// source (not a header to strip), so the generic `util::read_snippet_body`
/// is wrong for this target.
fn read_raw(path: &Path) -> Result<String, Box<dyn Error>> {
    fs::read_to_string(path)
        .map_err(|e| format!("snippet missing: {} ({})", path.display(), e).into())
}
