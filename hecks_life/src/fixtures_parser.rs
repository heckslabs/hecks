//! Parser for .fixtures files. Surface (kept small):
//!
//!   Hecks.fixtures "Pizzas" do
//!     aggregate "Pizza" do
//!       fixture "Margherita", name: "Margherita", description: "Classic"
//!       fixture "Pepperoni",  name: "Pepperoni",  description: "Spicy"
//!     end
//!     aggregate "Order" do
//!       fixture "PendingOrder", customer_name: "Sample", quantity: 1
//!     end
//!   end
//!
//! `fixture "Label", k: v, k2: v2` reuses the same comma-separated kwarg
//! parser as the bluebook IR's inline form (see parse_blocks::parse_fixture's
//! split_top_level_commas), so values can themselves contain commas
//! (quoted strings, arrays, hashes).
//!
//! The first positional arg of `fixture` is the label (Fixture::name);
//! everything after is k:v attributes. The enclosing `aggregate "X"`
//! block sets aggregate_name on each fixture inside.
//!
//! i42 catalog-dialect extension: an `aggregate` line may carry a
//! `schema:` kwarg whose value is an inline `{ k: Type, ... }` hash
//! literal. When present, the aggregate is a "catalog" — a
//! fixture-only reference table declaring its own row schema. The
//! schema is parsed into a `Vec<CatalogAttr>` and stored under the
//! aggregate's name in `FixturesFile::catalogs`. Aggregates without
//! `schema:` parse exactly as before.
//!
//!   aggregate "FlaggedExtension", schema: { ext: String } do
//!     fixture "Ruby", ext: "rb"
//!   end
//!
//! v1 constraint: single-line schema only. Multi-line schemas
//! (opening `{` on the aggregate line, closing `}` on a later line)
//! are not supported yet — see the plan's risk 9.1.

use crate::fixtures_ir::{CatalogAttr, FixturesFile};
use crate::ir::Fixture;
use crate::parser_helpers::{extract_string, ends_with_do_block};

/// Extract the body of the first double-quoted string in `s`, honoring
/// `\"` as an embedded-quote escape. Returns the raw (still-escaped)
/// contents between the opening and closing quote, or None if there
/// isn't a complete pair. Used instead of parser_helpers::extract_string
/// for fixture attribute values so that strings like `"1/8\"=1'"` don't
/// terminate prematurely at the embedded `\"`.
fn extract_string_escape_aware(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let start = s.find('"')? + 1;
    let mut i = start;
    while i < bytes.len() {
        let c = bytes[i];
        if c == b'\\' && i + 1 < bytes.len() {
            i += 2;
            continue;
        }
        if c == b'"' {
            return Some(s[start..i].to_string());
        }
        i += 1;
    }
    None
}

/// Expand Ruby-style double-quoted string escapes byte-for-byte.
///
/// Ruby is the source of truth for `.fixtures` files because they're
/// loaded via `Kernel.load` — the string body IS Ruby source, and
/// Ruby's parser applies these substitutions before the DSL builder
/// sees the value. We reproduce the common subset here so the Rust
/// parser yields identical attribute values.
///
/// Covered:
///   \\ \" \'    — literal backslash / quote / apostrophe
///   \n \t \r    — newline / tab / CR
///   \a \b \f \v — bell / backspace / form feed / vertical tab
///   \e \0 \s    — escape (0x1B) / null / space (Ruby-specific)
///   any other `\X` — backslash dropped, X kept (Ruby's rule for
///                     unrecognized escapes in double-quoted strings)
///
/// Deferred (see followup i38-exotic): `\xNN`, `\uNNNN`, `\<digits>`
/// octal, `\C-x` / `\M-x` control-meta, and `\<newline>` line
/// continuation. None of these appear in current fixtures; add them
/// when a real fixture needs one.
fn expand_ruby_escapes(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('\\') => out.push('\\'),
                Some('"')  => out.push('"'),
                Some('\'') => out.push('\''),
                Some('n')  => out.push('\n'),
                Some('t')  => out.push('\t'),
                Some('r')  => out.push('\r'),
                Some('a')  => out.push('\x07'),
                Some('b')  => out.push('\x08'),
                Some('f')  => out.push('\x0C'),
                Some('v')  => out.push('\x0B'),
                Some('e')  => out.push('\x1B'),
                Some('0')  => out.push('\0'),
                Some('s')  => out.push(' '),
                // Unrecognized: drop the backslash, keep the next char
                // (preserves UTF-8 codepoints intact).
                Some(other) => out.push(other),
                // Trailing backslash — keep literal.
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

pub fn parse(source: &str) -> FixturesFile {
    let mut file = FixturesFile {
        domain_name: String::new(),
        fixtures: vec![],
        catalogs: std::collections::BTreeMap::new(),
    };
    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;
    let mut current_agg: Option<String> = None;
    let mut depth: usize = 0;

    while i < lines.len() {
        let line = lines[i].trim();
        if line.starts_with('#') || line.is_empty() { i += 1; continue; }

        if line.starts_with("Hecks.fixtures") {
            if let Some(name) = extract_string(line) { file.domain_name = name; }
            depth += 1;
        } else if line.starts_with("aggregate ") && ends_with_do_block(line) {
            current_agg = extract_string(line);
            if let Some(agg) = current_agg.clone() {
                if let Some(schema) = extract_schema_kwarg(line) {
                    file.catalogs.insert(agg, schema);
                }
            }
            depth += 1;
        } else if line.starts_with("fixture ") {
            // Multi-line fixture support: if the line ends with a
            // trailing comma (continuation marker), greedily consume
            // subsequent non-keyword, non-empty lines into a single
            // logical fixture line. Blank / comment lines are skipped
            // across; `fixture`, `aggregate`, `end`, and `Hecks.fixtures`
            // terminate the span. See inbox i57.
            let mut combined = line.to_string();
            while combined.trim_end().ends_with(',') && i + 1 < lines.len() {
                let next = lines[i + 1].trim();
                if next.is_empty() || next.starts_with('#') {
                    i += 1;
                    continue;
                }
                if next.starts_with("fixture ")
                    || next.starts_with("aggregate ")
                    || next.starts_with("end")
                    || next.starts_with("Hecks.fixtures")
                {
                    break;
                }
                combined.push(' ');
                combined.push_str(next);
                i += 1;
            }
            if let Some(agg) = &current_agg {
                file.fixtures.push(parse_fixture_line(&combined, agg));
            }
        } else if line == "end" {
            if depth > 0 { depth -= 1; }
            // Closing the `aggregate` block clears the current aggregate.
            // Closing the outer `Hecks.fixtures` leaves depth at 0.
            if depth == 1 { current_agg = None; }
        }
        i += 1;
    }

    file
}

/// Parse a single `fixture "Label", k: v, …` line, returning a Fixture
/// whose aggregate_name is the enclosing `aggregate "X"` block's name.
fn parse_fixture_line(line: &str, aggregate_name: &str) -> Fixture {
    let label = extract_string(line);
    let mut attributes: Vec<(String, String)> = vec![];

    if let Some(comma_pos) = line.find(',') {
        let rest = &line[comma_pos + 1..];
        for part in split_top_level_commas(rest) {
            let part = part.trim();
            if let Some(colon) = part.find(':') {
                let key = part[..colon].trim().to_string();
                let raw = part[colon + 1..].trim();
                let val = if raw.starts_with('"') {
                    extract_string_escape_aware(raw)
                        .map(|s| expand_ruby_escapes(&s))
                        .unwrap_or_else(|| raw.to_string())
                } else {
                    raw.to_string()
                };
                attributes.push((key, val));
            }
        }
    }

    Fixture {
        name: label,
        aggregate_name: aggregate_name.to_string(),
        attributes,
    }
}

/// Split on `,` at depth 0 — ignoring commas inside strings/brackets.
/// Mirrors parse_blocks::split_top_level_commas (kept private to each
/// parser to avoid forcing a public helper).
fn split_top_level_commas(s: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut start = 0;
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let c = bytes[i] as char;
        match c {
            '"' if !escaped_at(s, i) => in_str = !in_str,
            '[' | '{' | '(' if !in_str => depth += 1,
            ']' | '}' | ')' if !in_str => depth -= 1,
            ',' if !in_str && depth == 0 => {
                parts.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
        i += 1;
    }
    parts.push(&s[start..]);
    parts
}

fn escaped_at(s: &str, i: usize) -> bool {
    if i == 0 { return false; }
    let bytes = s.as_bytes();
    let mut count = 0;
    let mut j = i;
    while j > 0 && bytes[j - 1] == b'\\' {
        count += 1;
        j -= 1;
    }
    count % 2 == 1
}

/// Extract the `schema: { k: Type, ... }` kwarg from an `aggregate`
/// line. Returns None when the kwarg is absent. Single-line only
/// (v1 constraint); a multi-line `{ ... }` spanning several source
/// lines parses as absent.
///
/// Parse shape:
///   aggregate "X", schema: { ext: String } do
///                  ^^^^^^^^ ^^^^^^^^^^^^^
///                  |        |
///                  |        +-- inside {...}: top-level-comma-split
///                  |            pairs of `k: Type`, where Type is a
///                  |            verbatim token (may contain parens
///                  |            and commas — `list_of(String)` — so
///                  |            we reuse split_top_level_commas to
///                  |            respect nested brackets/parens).
///                  +-- we scan from after the first top-level comma
///                      on the aggregate line (the one separating the
///                      positional name from kwargs).
fn extract_schema_kwarg(line: &str) -> Option<Vec<CatalogAttr>> {
    // Find the first top-level comma after the aggregate's name —
    // that separates `aggregate "X"` from its kwargs. Top-level
    // matters because a future bluebook form could theoretically
    // embed commas in `"strings"` inside the name slot; current
    // names are PascalCase but we keep the code honest.
    let comma_pos = first_top_level_comma(line)?;
    let after_comma = &line[comma_pos + 1..];
    let schema_pos = after_comma.find("schema:")?;
    let after_schema = &after_comma[schema_pos + "schema:".len()..];

    // Find the opening `{` after `schema:` and its balanced `}`.
    let open = after_schema.find('{')?;
    let close = matching_close_brace(after_schema, open)?;
    let body = &after_schema[open + 1..close];

    let mut attrs = Vec::new();
    for part in split_top_level_commas(body) {
        let part = part.trim();
        if part.is_empty() { continue; }
        // Each pair is `name: Type`. We split on the first top-level
        // colon so the type token (which never legitimately contains
        // a `:`) is preserved intact even if future types do.
        let colon = part.find(':')?;
        let name = part[..colon].trim().to_string();
        let type_name = part[colon + 1..].trim().to_string();
        if name.is_empty() || type_name.is_empty() { return None; }
        attrs.push(CatalogAttr { name, type_name });
    }
    Some(attrs)
}

/// Locate the first `,` at bracket/paren depth 0 and outside any
/// string literal. Used to find where positional args end and kwargs
/// begin on the aggregate line.
fn first_top_level_comma(s: &str) -> Option<usize> {
    let mut depth = 0i32;
    let mut in_str = false;
    for (i, c) in s.char_indices() {
        match c {
            '"' if !escaped_at(s, i) => in_str = !in_str,
            '[' | '{' | '(' if !in_str => depth += 1,
            ']' | '}' | ')' if !in_str => depth -= 1,
            ',' if !in_str && depth == 0 => return Some(i),
            _ => {}
        }
    }
    None
}

/// Given `s` and the byte index of an opening `{`, return the byte
/// index of the matching closing `}` — respecting nested braces and
/// skipping string literals. Returns None if unbalanced (which in v1
/// means the schema spans multiple lines; we decline to parse it).
fn matching_close_brace(s: &str, open: usize) -> Option<usize> {
    let bytes = s.as_bytes();
    if bytes.get(open) != Some(&b'{') { return None; }
    let mut depth = 0i32;
    let mut in_str = false;
    let mut i = open;
    while i < bytes.len() {
        let c = bytes[i] as char;
        match c {
            '"' if !escaped_at(s, i) => in_str = !in_str,
            '{' if !in_str => depth += 1,
            '}' if !in_str => {
                depth -= 1;
                if depth == 0 { return Some(i); }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tiny helper: parse a source snippet and return the catalogs
    // map. Keeps the assertion surface focused on the i42 add.
    fn catalogs_of(source: &str) -> std::collections::BTreeMap<String, Vec<(String, String)>> {
        parse(source).catalogs
            .into_iter()
            .map(|(k, v)| (k, v.into_iter().map(|a| (a.name, a.type_name)).collect()))
            .collect()
    }

    #[test]
    fn schema_kwarg_records_one_catalog_attr() {
        let src = r#"
            Hecks.fixtures "Antibody" do
              aggregate "FlaggedExtension", schema: { ext: String } do
                fixture "Ruby", ext: "rb"
              end
            end
        "#;
        let cats = catalogs_of(src);
        assert_eq!(cats.len(), 1);
        assert_eq!(cats.get("FlaggedExtension").unwrap(),
                   &vec![("ext".into(), "String".into())]);
    }

    #[test]
    fn no_schema_kwarg_means_no_catalog_entry() {
        // Pre-i42 shape — unchanged behavior.
        let src = r#"
            Hecks.fixtures "Pizzas" do
              aggregate "Pizza" do
                fixture "Margherita", name: "Margherita"
              end
            end
        "#;
        assert!(catalogs_of(src).is_empty());
    }

    #[test]
    fn schema_kwarg_records_multiple_attrs_in_order() {
        let src = r#"
            Hecks.fixtures "Antibody" do
              aggregate "ShebangMapping", schema: { match: String, ext: String } do
                fixture "Ruby", match: "ruby", ext: "rb"
              end
            end
        "#;
        let cats = catalogs_of(src);
        assert_eq!(cats.get("ShebangMapping").unwrap(), &vec![
            ("match".into(), "String".into()),
            ("ext".into(),   "String".into()),
        ]);
    }

    #[test]
    fn schema_kwarg_handles_list_of_parens() {
        // `list_of(String)` has a comma-free inner but the parens
        // must nest correctly so a schema like
        // `{ items: list_of(String), name: String }` splits on the
        // top-level comma only — not on a comma inside the parens.
        let src = r#"
            Hecks.fixtures "Antibody" do
              aggregate "TestCase", schema: { items: list_of(String), name: String } do
                fixture "Sample", items: ["a"], name: "sample"
              end
            end
        "#;
        let cats = catalogs_of(src);
        assert_eq!(cats.get("TestCase").unwrap(), &vec![
            ("items".into(), "list_of(String)".into()),
            ("name".into(),  "String".into()),
        ]);
    }

    #[test]
    fn nested_fixture_block_does_not_confuse_aggregate_scan() {
        // A fixture line that happens to contain `schema:` or nested
        // blocks shouldn't bleed into catalogs; only `aggregate` lines
        // feed the catalog extractor.
        let src = r#"
            Hecks.fixtures "Mixed" do
              aggregate "Pizza" do
                fixture "Margherita", name: "Margherita"
              end
            end
        "#;
        let ff = parse(src);
        assert!(ff.catalogs.is_empty());
        assert_eq!(ff.fixtures.len(), 1);
        assert_eq!(ff.fixtures[0].aggregate_name, "Pizza");
    }

    #[test]
    fn plain_and_catalog_aggregates_coexist() {
        let src = r##"
            Hecks.fixtures "Mixed" do
              aggregate "Pizza" do
                fixture "Margherita", name: "Margherita"
              end
              aggregate "Color", schema: { hex: String } do
                fixture "Red", hex: "#FF0000"
              end
            end
        "##;
        let ff = parse(src);
        assert_eq!(ff.catalogs.len(), 1);
        assert!(ff.catalogs.contains_key("Color"));
        assert!(!ff.catalogs.contains_key("Pizza"));
        // Fixtures from both aggregates still land in the flat list.
        assert_eq!(ff.fixtures.len(), 2);
    }

    #[test]
    fn multi_line_fixture_consumes_continuation_lines() {
        // i57 fix — when a fixture line ends in a trailing comma, the
        // parser greedily consumes indented continuation lines until a
        // keyword (fixture / aggregate / end / Hecks.fixtures) or a
        // non-comma-ended line closes the span. Before this fix the
        // parser silently produced empty attributes for multi-line
        // fixtures, forcing authors to collapse everything onto one line.
        let src = r#"
            Hecks.fixtures "Multi" do
              aggregate "Widget" do
                fixture "SingleLine", name: "single", value: "foo"
                fixture "MultiLine",
                        name: "multi",
                        value: "bar",
                        extra: "baz"
                fixture "AfterMulti", name: "after"
              end
            end
        "#;
        let ff = parse(src);
        assert_eq!(ff.fixtures.len(), 3);
        let multi = ff.fixtures.iter()
            .find(|f| f.name.as_deref() == Some("MultiLine"))
            .expect("MultiLine fixture");
        let attrs: std::collections::BTreeMap<_, _> =
            multi.attributes.iter().cloned().collect();
        assert_eq!(attrs.get("name").map(String::as_str), Some("multi"));
        assert_eq!(attrs.get("value").map(String::as_str), Some("bar"));
        assert_eq!(attrs.get("extra").map(String::as_str), Some("baz"));
        // Continuation consumption must not leak into the next fixture.
        let after = ff.fixtures.iter()
            .find(|f| f.name.as_deref() == Some("AfterMulti"))
            .expect("AfterMulti fixture");
        let after_attrs: std::collections::BTreeMap<_, _> =
            after.attributes.iter().cloned().collect();
        assert_eq!(after_attrs.get("name").map(String::as_str), Some("after"));
    }
}
