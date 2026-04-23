//! Rust port of `lib/hecks_specializer/meta_ruby_script.rb` (Phase D D3).
//!
//! Regenerates a top-level Ruby script from a single `RubyScript`
//! fixture row. First Ruby-emitting specializer to land in Rust. The
//! emission is a straight four-section concatenation of verbatim
//! snippets — no templating, no interpolation — so the port stays
//! small and mirrors the Ruby side line-for-line.
//!
//! Emission pipeline (verbatim concatenation, matching the Ruby):
//!
//!   1. shebang line + "\n" — skipped entirely if shebang is empty
//!   2. doc_snippet — read raw (already ends with "\n")
//!   3. "\n" — blank line separator
//!   4. requires_block_snippet — read raw (already ends with "\n")
//!   5. "\n" — blank line separator
//!   6. body_snippet — read raw (already ends with "\n")
//!
//! Snippets are `.rb.frag` files with no `//`-comment header, so we
//! use `util::read_snippet_raw` rather than `util::read_snippet_body`.
//! A leading `//`-strip would silently corrupt Ruby source whose lines
//! happen to start with `//` inside string literals.
//!
//! Usage:
//!   let ruby = meta_ruby_script::emit(repo_root)?;
//!   print!("{}", ruby);
//
// [antibody-exempt: hecks_life/src/specializer/meta_ruby_script.rs — Phase D D3 — Ruby-native specializer port]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "hecks_conception/capabilities/ruby_script_shape/fixtures/ruby_script_shape.fixtures";

/// Which `RubyScript` fixture row to emit for. `None` picks the first
/// row — kept simple for the PC-3 pilot, which ships with a single row
/// (Specialize). A future subclass-style port would thread this value
/// through the top-level `emit` match arm in `specializer::mod`.
fn target_row_name() -> Option<&'static str> {
    None
}

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let rows = util::by_aggregate(&fixtures, "RubyScript");
    let row = pick_row(&rows, target_row_name())?;

    let mut out = String::new();
    out.push_str(&emit_shebang(row));
    out.push_str(&emit_doc(repo_root, row)?);
    out.push_str(&emit_requires(repo_root, row)?);
    out.push_str(&emit_body(repo_root, row)?);
    Ok(out)
}

fn pick_row<'a>(
    rows: &'a [&'a Fixture],
    name: Option<&str>,
) -> Result<&'a Fixture, Box<dyn Error>> {
    let row = match name {
        Some(n) => rows.iter().find(|r| util::attr(r, "name") == n).copied(),
        None => rows.first().copied(),
    };
    row.ok_or_else(|| {
        format!(
            "no RubyScript row matching {:?}",
            name.unwrap_or("<first>")
        )
        .into()
    })
}

/// Shebang line followed by "\n". Empty string (no shebang) skips the
/// whole line — used for plain `.rb` outputs with no shebang.
fn emit_shebang(row: &Fixture) -> String {
    let shebang = util::attr(row, "shebang");
    if shebang.is_empty() {
        String::new()
    } else {
        format!("{}\n", shebang)
    }
}

/// Doc block — read verbatim. Snippet already ends with "\n".
/// Append one more "\n" to insert the blank line that separates doc
/// from requires.
fn emit_doc(repo_root: &Path, row: &Fixture) -> Result<String, Box<dyn Error>> {
    let path = repo_root.join(util::attr(row, "doc_snippet"));
    Ok(format!("{}\n", util::read_snippet_raw(&path)?))
}

/// Requires block — read verbatim. Snippet already ends with "\n".
/// Append one more "\n" to insert the blank line that separates
/// requires from body.
fn emit_requires(repo_root: &Path, row: &Fixture) -> Result<String, Box<dyn Error>> {
    let path = repo_root.join(util::attr(row, "requires_block_snippet"));
    Ok(format!("{}\n", util::read_snippet_raw(&path)?))
}

/// Imperative body — read verbatim. Final section; snippet's own
/// trailing "\n" is the file's trailing newline.
fn emit_body(repo_root: &Path, row: &Fixture) -> Result<String, Box<dyn Error>> {
    let path = repo_root.join(util::attr(row, "body_snippet"));
    util::read_snippet_raw(&path)
}
