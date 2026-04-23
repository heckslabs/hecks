//! World parser — reads .world files into the World IR.
//!
//! Line-oriented in the same idiom as hecksagon_parser. Recognizes the
//! canonical shapes used by the Ruby DSL builder and the files shipped
//! under hecks_conception/ and lib/hecks/.../appeal.
//!
//! Grammar:
//!
//!   file        := 'Hecks.world' STRING 'do' stmt* 'end'
//!   stmt        := scalar | extension_block | concern_block
//!   scalar      := SCALAR_KEY STRING              // purpose|vision|audience
//!   extension_block := IDENT 'do' kv* 'end'       // heki|ollama|sqlite|...
//!   concern_block   := 'concern' STRING 'do' kv* 'end'
//!   kv          := IDENT (STRING | INT | FLOAT | BOOL | ARRAY)
//!
//! No method calls, no interpolation, no ENV[], no File.join. The parser
//! is deliberately dumb — it only knows how to scoop key/value scalars
//! out of the nested blocks the DSL builder supports.

use crate::hecksagon_helpers::{between_quotes, strip_quotes};
use crate::world_ir::*;

/// Lowest-cost source detection — skip blank lines and `#` comments,
/// then check the first non-empty line.
pub fn is_world_source(source: &str) -> bool {
    for line in source.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') { continue; }
        return t.starts_with("Hecks.world");
    }
    false
}

const SCALAR_KEYS: &[&str] = &["purpose", "vision", "audience"];

pub fn parse(source: &str) -> World {
    let mut world = World::default();
    let source = crate::parser::strip_shebang(source);
    let raw: Vec<&str> = source.lines().collect();

    let mut i = 0;
    while i < raw.len() {
        let line = raw[i].trim();

        if line.is_empty() || line.starts_with('#') {
            i += 1;
            continue;
        }

        if line.starts_with("Hecks.world") {
            if let Some(n) = between_quotes(line) { world.name = n; }
            i += 1;
            continue;
        }

        // Scalar statements: purpose/vision/audience "…"
        if let Some(k) = scalar_key(line) {
            if let Some(v) = between_quotes(line) {
                match k {
                    "purpose"  => world.purpose  = Some(v),
                    "vision"   => world.vision   = Some(v),
                    "audience" => world.audience = Some(v),
                    _ => {}
                }
            }
            i += 1;
            continue;
        }

        // concern "Name" do ... end
        if line.starts_with("concern ") || line.starts_with("concern\"") {
            let (concern, consumed) = parse_concern(&raw[i..]);
            if let Some(c) = concern { world.concerns.push(c); }
            i += consumed;
            continue;
        }

        // Extension block: IDENT do ... end
        if let Some(ext_name) = extension_block_header(line) {
            let (cfg, consumed) = parse_extension_block(&raw[i..], &ext_name);
            if let Some(c) = cfg { world.configs.push(c); }
            i += consumed;
            continue;
        }

        // Top-level `end` closing the Hecks.world block, or anything else
        // we don't recognize.
        i += 1;
    }

    world
}

/// If the line is a top-level scalar statement (purpose/vision/audience),
/// return its key. Otherwise None.
fn scalar_key(line: &str) -> Option<&'static str> {
    for k in SCALAR_KEYS {
        if line.starts_with(&format!("{} ", k)) || line.starts_with(&format!("{}\"", k)) {
            return Some(*k);
        }
    }
    None
}

/// If the line is `IDENT do` (or `IDENT do\n...`), return the ident.
/// Otherwise None. Skips scalar keys and `concern`.
fn extension_block_header(line: &str) -> Option<String> {
    let t = line.trim();
    // Must end with `do` (possibly followed by `; ... end` on one line).
    // Find the first whitespace — that's the ident boundary.
    let rest = t;
    let ident_end = rest.find(|c: char| !c.is_alphanumeric() && c != '_').unwrap_or(rest.len());
    if ident_end == 0 { return None; }
    let ident = &rest[..ident_end];
    if SCALAR_KEYS.contains(&ident) || ident == "concern" || ident == "end"
        || ident == "Hecks" {
        return None;
    }
    // Must have a `do` after the ident (same line or the next token).
    let after = rest[ident_end..].trim_start();
    if after == "do" || after.starts_with("do ") || after.starts_with("do;") || after == "do\n" {
        return Some(ident.to_string());
    }
    // Inline single-line form: `heki do; dir "x" end` — already handled
    // above since `after` will start with `do;`. Final fallback: the
    // word "do" appears after the ident with optional whitespace.
    if after.starts_with("do") {
        let next = after.chars().nth(2);
        if next.map_or(true, |c| c.is_whitespace() || c == ';') {
            return Some(ident.to_string());
        }
    }
    None
}

/// Parse `concern "Name" do; description "..." end`. Returns the concern
/// and the number of source lines consumed.
fn parse_concern(lines: &[&str]) -> (Option<Concern>, usize) {
    let first = lines[0].trim();
    let mut concern = Concern::default();
    if let Some(n) = between_quotes(first) { concern.name = n; }

    // Inline-form: everything fits on one line (`concern "X" do; ... end`).
    if first.ends_with("end") && first.contains("do") {
        absorb_inline_block_body(first, &mut |k, v| {
            if k == "description" { concern.description = Some(v); }
        });
        return (if concern.name.is_empty() { None } else { Some(concern) }, 1);
    }

    let mut i = 1;
    let mut depth = if first.trim_end().ends_with("do") { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" { depth -= 1; i += 1; continue; }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        // Nested `do` inside a concern is not grammar-legal — but keep
        // the depth counter honest anyway.
        if ends_with_do(t) { depth += 1; }
        if let Some((k, v)) = parse_kv_line(t) {
            if k == "description" { concern.description = Some(v); }
        }
        i += 1;
    }

    if concern.name.is_empty() { (None, i) } else { (Some(concern), i) }
}

/// Parse `IDENT do ... end` — return ExtensionConfig + lines consumed.
fn parse_extension_block(lines: &[&str], name: &str) -> (Option<ExtensionConfig>, usize) {
    let first = lines[0].trim();
    let mut cfg = ExtensionConfig { name: name.to_string(), values: vec![] };

    // Inline: `ext do; key "val"; key2 "val2" end`
    if first.ends_with("end") && first.contains("do") {
        absorb_inline_block_body(first, &mut |k, v| {
            cfg.values.push((k, v));
        });
        return (Some(cfg), 1);
    }

    let mut i = 1;
    let mut depth = if ends_with_do(first) { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" { depth -= 1; i += 1; continue; }
        if t.is_empty() || t.starts_with('#') { i += 1; continue; }
        if ends_with_do(t) { depth += 1; i += 1; continue; }
        if let Some((k, v)) = parse_kv_line(t) {
            cfg.values.push((k, v));
        }
        i += 1;
    }

    (Some(cfg), i)
}

/// Does this line end with `do` (trailing whitespace ignored)?
fn ends_with_do(line: &str) -> bool {
    let t = line.trim_end();
    t == "do" || t.ends_with(" do")
}

/// Parse a single `key value` line. Values can be:
///   - quoted strings  "foo"
///   - integers        123
///   - floats          1.5
///   - booleans        true/false
///   - arrays          ["a", "b"]
fn parse_kv_line(line: &str) -> Option<(String, String)> {
    let t = line.trim().trim_end_matches(';');
    let ident_end = t.find(|c: char| !c.is_alphanumeric() && c != '_')?;
    if ident_end == 0 { return None; }
    let key = t[..ident_end].to_string();
    let rest = t[ident_end..].trim();
    if rest.is_empty() { return None; }
    Some((key, render_value(rest)))
}

/// Render a raw value token as canonical text. Strings unwrap their
/// quotes; everything else is preserved verbatim (after trimming).
fn render_value(raw: &str) -> String {
    let t = raw.trim().trim_end_matches(';').trim();
    if t.starts_with('"') && t.ends_with('"') && t.len() >= 2 {
        return strip_quotes(t);
    }
    t.to_string()
}

/// Walk an inline `do; k v; k v end` body and invoke `visitor(k, v)` for
/// each pair. The body is whatever sits between `do` and the trailing
/// `end` on a single line.
fn absorb_inline_block_body(line: &str, visitor: &mut dyn FnMut(String, String)) {
    let t = line.trim();
    let Some(after_do_idx) = find_do_keyword(t) else { return; };
    let after_do = &t[after_do_idx..];
    let body = after_do.trim_start().trim_start_matches("do")
        .trim_start_matches(|c: char| c == ';' || c.is_whitespace());
    // Strip trailing `end`.
    let body = body.trim_end().trim_end_matches("end").trim();
    for piece in body.split(';') {
        let p = piece.trim();
        if p.is_empty() { continue; }
        if let Some((k, v)) = parse_kv_line(p) {
            visitor(k, v);
        }
    }
}

/// Find the byte index of the standalone `do` keyword in a line. Used to
/// locate the start of an inline block body.
fn find_do_keyword(line: &str) -> Option<usize> {
    let bytes = line.as_bytes();
    let mut i = 0;
    while i + 2 <= bytes.len() {
        if &bytes[i..i + 2] == b"do" {
            let left_ok = i == 0 || (bytes[i - 1] as char).is_whitespace();
            let right_ok = i + 2 == bytes.len() || {
                let c = bytes[i + 2] as char;
                c.is_whitespace() || c == ';'
            };
            if left_ok && right_ok { return Some(i); }
        }
        i += 1;
    }
    None
}
