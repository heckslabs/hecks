//! Specializer for `storehouse/src/dispatch_query.rs` — i146 piece 1.
//!
//! Emits dispatch_query.rs byte-identical to the tracked file. Reads
//! the `Section` rows from dispatch_query_shape, sorts by `order`, and
//! dispatches each row by `body_kind` :
//!
//!   - `embedded_snippet` — read `snippet_path` verbatim (no leading-
//!                          comment strip ; doc comments and section
//!                          dividers are load-bearing for this target)
//!   - `string_table`     — emit `<doc>\npub const <array_name>:
//!                          &[&str] = &[\n    "<entry>",\n    ...];\n\n`
//!                          from `doc_snippet`, `array_name`, and
//!                          comma-separated `entries`
//!
//! Two structural emissions live in the fixtures : SPECIALIZER_TARGETS
//! (which now contains "dispatch_query" itself — the self-claim that
//! closes i122) and SPECIALIZER_HELPER_MODULES. Everything else is two
//! verbatim snippets : the file's leading prose (header, imports,
//! struct, top-level fn, divider) and the trailing prose (functions +
//! tests).
//!
//! Usage:
//!   let rust = dispatch_query::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: storehouse/src/specializer/dispatch_query.rs —
//!  i146 Rust-native specializer implementation]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::fs;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/dispatch_query_shape/fixtures/dispatch_query_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let sections = util::by_aggregate_sorted(&fixtures, "Section", "order");

    let mut out = String::new();
    for section in &sections {
        out.push_str(&emit_section(repo_root, section)?);
    }
    Ok(out)
}

fn emit_section(repo_root: &Path, section: &Fixture) -> Result<String, Box<dyn Error>> {
    match util::attr(section, "body_kind") {
        "embedded_snippet" => emit_embedded_snippet(repo_root, section),
        "string_table" => emit_string_table(repo_root, section),
        other => Err(format!("unknown body_kind: {}", other).into()),
    }
}

fn emit_embedded_snippet(repo_root: &Path, section: &Fixture) -> Result<String, Box<dyn Error>> {
    let path = repo_root.join(util::attr(section, "snippet_path"));
    fs::read_to_string(&path)
        .map_err(|e| format!("snippet missing {}: {}", path.display(), e).into())
}

fn emit_string_table(repo_root: &Path, section: &Fixture) -> Result<String, Box<dyn Error>> {
    let doc_path = repo_root.join(util::attr(section, "doc_snippet"));
    let doc = fs::read_to_string(&doc_path)
        .map_err(|e| format!("doc snippet missing {}: {}", doc_path.display(), e))?;
    let array_name = util::attr(section, "array_name");
    let entries = util::attr(section, "entries");

    let mut out = String::new();
    out.push_str(&doc);
    if !doc.ends_with('\n') {
        out.push('\n');
    }
    out.push_str(&format!("pub const {}: &[&str] = &[\n", array_name));
    for entry in entries.split(',') {
        out.push_str(&format!("    \"{}\",\n", entry));
    }
    out.push_str("];\n\n");
    Ok(out)
}
