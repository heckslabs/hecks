//! Port of `rust/project/domain_generator.rb`'s coverage manifest — the
//! `manifest_entry` helper, the `manifest` accumulator `DomainGenerator.call`
//! threads through every generate/skip decision, and the
//! `JSON.pretty_generate(manifest)` bytes it writes to `manifest.json`.
//!
//! `bin/rust_coverage` reads that file and matches its `ALLOWLIST` regexes
//! against the `reason` text, so the reason strings are a contract: every
//! one is built at the same decision point `domain_generator.rs` already
//! reaches, from the same skip-reason functions, and
//! `spec/codegen_manifest_parity_spec.rb` holds the two generators'
//! `manifest.json` byte-identical.

use crate::json::Json;

/// One `manifest_entry(kind:, id:, generated:, reason:, gap_class:, routed:)`.
/// Key order on the wire is Ruby's own Hash insertion order: `kind`, `id`,
/// `generated`, then `routed`/`gap_class`/`reason` only when set.
struct Entry {
    kind: &'static str,
    id: String,
    generated: bool,
    routed: Option<bool>,
    gap_class: Option<&'static str>,
    reason: Option<String>,
}

#[derive(Default)]
pub struct Manifest {
    entries: Vec<Entry>,
}

impl Manifest {
    /// `manifest << manifest_entry(...)` — same argument set, same order.
    pub fn record(
        &mut self,
        kind: &'static str,
        id: String,
        generated: bool,
        routed: Option<bool>,
        gap_class: Option<&'static str>,
        reason: Option<String>,
    ) {
        self.entries.push(Entry { kind, id, generated, routed, gap_class, reason });
    }

    /// `generated: true` with nothing else.
    pub fn generated(&mut self, kind: &'static str, id: String) {
        self.record(kind, id, true, None, None, None);
    }

    /// `generated: true, routed: true`.
    pub fn routed(&mut self, kind: &'static str, id: String) {
        self.record(kind, id, true, Some(true), None, None);
    }

    /// `generated: false, gap_class: "per_instance", reason:`.
    pub fn skipped(&mut self, kind: &'static str, id: String, reason: String) {
        self.record(kind, id, false, None, Some("per_instance"), Some(reason));
    }

    /// `generated: true, routed: false, gap_class: "per_instance", reason:`.
    pub fn unrouted(&mut self, kind: &'static str, id: String, reason: String) {
        self.record(kind, id, true, Some(false), Some("per_instance"), Some(reason));
    }

    /// `JSON.pretty_generate(manifest)` (json 2.7): two-space indent,
    /// `"key": value`, no trailing newline — and an EMPTY array renders
    /// as `"[\n\n]"`, not `"[]"`.
    pub fn to_json_text(&self) -> String {
        if self.entries.is_empty() {
            return "[\n\n]".to_string();
        }
        let objects: Vec<String> = self.entries.iter().map(entry_json).collect();
        format!("[\n{}\n]", objects.join(",\n"))
    }
}

fn entry_json(entry: &Entry) -> String {
    let mut fields = vec![
        ("kind", json_string(entry.kind)),
        ("id", json_string(&entry.id)),
        ("generated", entry.generated.to_string()),
    ];
    if let Some(routed) = entry.routed {
        fields.push(("routed", routed.to_string()));
    }
    if let Some(gap_class) = entry.gap_class {
        fields.push(("gap_class", json_string(gap_class)));
    }
    if let Some(reason) = &entry.reason {
        fields.push(("reason", json_string(reason)));
    }
    let lines: Vec<String> = fields.iter().map(|(k, v)| format!("    \"{k}\": {v}")).collect();
    format!("  {{\n{}\n  }}", lines.join(",\n"))
}

/// Ruby `JSON.generate`'s string escaping (json 2.7, `script_safe: false`):
/// `"`/`\` and control characters only — `/`, DEL, and non-ASCII (the
/// em dashes every reason string carries) pass through raw.
fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Ruby's `#inspect` on an IR value interpolated into a reason string —
/// in practice `identified_by` (`["number"]`), or `nil` when absent.
pub fn ruby_inspect(value: Option<&Json>) -> String {
    match value {
        None | Some(Json::Null) => "nil".to_string(),
        Some(Json::String(s)) => ruby_inspect_str(s),
        Some(Json::Array(items)) => {
            let parts: Vec<String> = items.iter().map(|item| ruby_inspect(Some(item))).collect();
            format!("[{}]", parts.join(", "))
        }
        Some(other) => other.to_s(),
    }
}

fn ruby_inspect_str(s: &str) -> String {
    let mut out = String::from("\"");
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '#' if matches!(chars.peek(), Some('{') | Some('$') | Some('@')) => out.push_str("\\#"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_manifest_matches_ruby_pretty_generate() {
        assert_eq!(Manifest::default().to_json_text(), "[\n\n]");
    }

    #[test]
    fn optional_keys_follow_ruby_insertion_order_and_escape_like_json_generate() {
        let mut m = Manifest::default();
        m.generated("aggregate", "D::A".to_string());
        m.unrouted("command", "D::A.C".to_string(), "q\"\\/\t\u{1}— é".to_string());
        let expected = "[\n  {\n    \"kind\": \"aggregate\",\n    \"id\": \"D::A\",\n    \"generated\": true\n  },\n  {\n    \"kind\": \"command\",\n    \"id\": \"D::A.C\",\n    \"generated\": true,\n    \"routed\": false,\n    \"gap_class\": \"per_instance\",\n    \"reason\": \"q\\\"\\\\/\\t\\u0001— é\"\n  }\n]";
        assert_eq!(m.to_json_text(), expected);
    }

    #[test]
    fn inspect_matches_ruby_for_identity_arrays_and_nil() {
        let ids = Json::parse(r##"["reference.value", "a\"b", "#{x}"]"##).unwrap();
        assert_eq!(ruby_inspect(Some(&ids)), r##"["reference.value", "a\"b", "\#{x}"]"##);
        assert_eq!(ruby_inspect(Some(&Json::Array(vec![]))), "[]");
        assert_eq!(ruby_inspect(None), "nil");
    }
}
