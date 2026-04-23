//! Shared helpers for every Rust-native specializer target.
//!
//! Mirrors the Ruby `Hecks::Specializer::Target` mixin +
//! `Hecks::Specializer` module-level helpers. Each ported target
//! reuses these three entry points — load the shape fixtures, filter
//! by aggregate name, read a snippet-body file with its leading
//! `//`-comment header stripped.
//!
//! Usage:
//!   use crate::specializer::util;
//!   let fixtures = util::load_fixtures(shape_path)?;
//!   let rules = util::by_aggregate(&fixtures, "WarningRule");
//!   let body = util::read_snippet_body(&snippet_path)?;

use crate::fixtures_parser;
use crate::ir::Fixture;
use std::error::Error;
use std::fs;
use std::path::Path;

/// Parse a `.fixtures` file and return its flat `Fixture` list.
///
/// Ruby path shells out to `hecks-life dump-fixtures` + `JSON.parse`;
/// in Rust we skip the JSON round-trip and call `fixtures_parser::parse`
/// directly — same parser the `dump-fixtures` subcommand already uses.
pub fn load_fixtures(shape_path: &Path) -> Result<Vec<Fixture>, Box<dyn Error>> {
    let source = fs::read_to_string(shape_path)
        .map_err(|e| format!("cannot read shape {}: {}", shape_path.display(), e))?;
    Ok(fixtures_parser::parse(&source).fixtures)
}

/// Return every fixture whose `aggregate_name` matches `name`, in
/// source order. Mirrors Ruby `@fixtures.select { |f| f["aggregate"] == name }`.
pub fn by_aggregate<'a>(fixtures: &'a [Fixture], name: &str) -> Vec<&'a Fixture> {
    fixtures.iter().filter(|f| f.aggregate_name == name).collect()
}

/// Look up a fixture attribute by key. Panics-free: returns an empty
/// string for missing keys, matching the Ruby side's `a["key"]` which
/// yields `nil` then gets interpolated as `""`. Specializers that need
/// to distinguish missing-vs-empty call `attr_opt` instead.
pub fn attr<'a>(fixture: &'a Fixture, key: &str) -> &'a str {
    fixture
        .attributes
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
        .unwrap_or("")
}

/// Look up a fixture attribute by key, returning `None` when absent.
#[allow(dead_code)]
pub fn attr_opt<'a>(fixture: &'a Fixture, key: &str) -> Option<&'a str> {
    fixture
        .attributes
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
}

/// Read a `.rs.frag` snippet file, stripping the leading `//`-comment
/// header and leading blank lines. Everything from the first
/// non-comment, non-empty line onward is returned verbatim — the Ruby
/// side does exactly this and downstream specializers interpolate the
/// result as a function body.
pub fn read_snippet_body(path: &Path) -> Result<String, Box<dyn Error>> {
    let raw = fs::read_to_string(path)
        .map_err(|e| format!("snippet missing {}: {}", path.display(), e))?;

    // Split keeping line terminators so we can reassemble byte-exact.
    let mut lines: Vec<String> = Vec::new();
    let mut buf = String::new();
    for c in raw.chars() {
        buf.push(c);
        if c == '\n' {
            lines.push(std::mem::take(&mut buf));
        }
    }
    if !buf.is_empty() {
        lines.push(buf);
    }

    let start = lines.iter().position(|l| {
        let t = l.trim();
        !t.is_empty() && !t.starts_with("//")
    });

    Ok(match start {
        Some(i) => lines[i..].concat(),
        None => String::new(),
    })
}
