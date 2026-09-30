//! The coverage manifest `manifest.json` that `hecks rust_coverage` reads, built as
//! `domain_generator.rb` builds it; the parity spec holds the bytes identical.

use crate::json::Json;
use crate::skip_reason::SkipReason;

// Wire key order: `kind`, `id`, `generated`, then `routed`, `gap_class`, `construct`, `reason`.
struct Entry {
    kind: &'static str,
    id: String,
    generated: bool,
    routed: Option<bool>,
    gap_class: Option<&'static str>,
    construct: Option<String>,
    reason: Option<String>,
}

/// The ordered list of generate/skip decisions made for one chapter.
#[derive(Default)]
pub struct Manifest {
    entries: Vec<Entry>,
}

impl Manifest {
    /// Appends one entry.
    ///
    /// # Panics
    /// If a gap (`generated: false` or `routed: false`) has no `gap_class`, or a `gap_class`
    /// has no `construct`.
    #[allow(clippy::too_many_arguments)]
    pub fn record(
        &mut self,
        kind: &'static str,
        id: String,
        generated: bool,
        routed: Option<bool>,
        gap_class: Option<&'static str>,
        construct: Option<String>,
        reason: Option<String>,
    ) {
        assert!(
            !((!generated || routed == Some(false)) && gap_class.is_none()),
            "manifest entry {kind} {id} records a gap with no gap_class"
        );
        assert!(
            gap_class.is_none() || construct.as_deref().is_some_and(|c| !c.is_empty()),
            "manifest entry {kind} {id} declares gap_class {gap_class:?} with no construct"
        );
        self.entries.push(Entry { kind, id, generated, routed, gap_class, construct: gap_class.and(construct), reason });
    }

    /// `generated: true` with nothing else.
    pub fn generated(&mut self, kind: &'static str, id: String) {
        self.record(kind, id, true, None, None, None, None);
    }

    /// `generated: true, routed: true`.
    pub fn routed(&mut self, kind: &'static str, id: String) {
        self.record(kind, id, true, Some(true), None, None, None);
    }

    /// `generated: false, gap_class: "per_instance", construct: reason.construct, reason:`.
    pub fn skipped(&mut self, kind: &'static str, id: String, reason: SkipReason) {
        self.record(kind, id, false, None, Some("per_instance"), Some(reason.construct), Some(reason.text));
    }

    /// A per-instance gap whose construct the call site names itself
    /// (`attribute_type`, `owning_aggregate`) rather than a skip function.
    pub fn skipped_as(&mut self, kind: &'static str, id: String, construct: &str, reason: String) {
        self.record(kind, id, false, None, Some("per_instance"), Some(construct.to_string()), Some(reason));
    }

    /// `generated: true, routed: false, gap_class: "per_instance", construct:, reason:`.
    pub fn unrouted(&mut self, kind: &'static str, id: String, construct: &str, reason: String) {
        self.record(kind, id, true, Some(false), Some("per_instance"), Some(construct.to_string()), Some(reason));
    }

    /// Records every query declared on a nested entity, at any depth, as an `entity_query` gap.
    pub fn entity_query_gaps(&mut self, owner_id: &str, entities: &[Json]) {
        for entity in entities {
            let entity_id = format!("{owner_id}.{}", entity.get("name").map(Json::to_s).unwrap_or_default());
            for query in entity.get("queries").map(Json::each).unwrap_or(&[]) {
                self.record(
                    "query",
                    format!("{entity_id}.{}", query.get("name").map(Json::to_s).unwrap_or_default()),
                    false,
                    None,
                    Some("whole_kind"),
                    Some("entity_query".to_string()),
                    Some(
                        "an entity-scoped query has no generated code path — only an aggregate's own declared queries reach the QUERIES table"
                            .to_string(),
                    ),
                );
            }
            self.entity_query_gaps(&entity_id, entity.get("entities").map(Json::each).unwrap_or(&[]));
        }
    }

    /// Renders like Ruby's `JSON.pretty_generate`, which writes an empty array as `"[\n\n]"`.
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
    if let Some(construct) = &entry.construct {
        fields.push(("construct", json_string(construct)));
    }
    if let Some(reason) = &entry.reason {
        fields.push(("reason", json_string(reason)));
    }
    let lines: Vec<String> = fields.iter().map(|(k, v)| format!("    \"{k}\": {v}")).collect();
    format!("  {{\n{}\n  }}", lines.join(",\n"))
}

// Ruby `JSON.generate` escaping: only `"`, `\` and control characters; non-ASCII passes through.
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

/// Ruby's `#inspect` of an IR value, as interpolated into reason strings; `nil` when absent.
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
        m.unrouted("command", "D::A.C".to_string(), "router_identity", "q\"\\/\t\u{1}— é".to_string());
        let expected = "[\n  {\n    \"kind\": \"aggregate\",\n    \"id\": \"D::A\",\n    \"generated\": true\n  },\n  {\n    \"kind\": \"command\",\n    \"id\": \"D::A.C\",\n    \"generated\": true,\n    \"routed\": false,\n    \"gap_class\": \"per_instance\",\n    \"construct\": \"router_identity\",\n    \"reason\": \"q\\\"\\\\/\\t\\u0001— é\"\n  }\n]";
        assert_eq!(m.to_json_text(), expected);
    }

    #[test]
    fn nested_entity_queries_are_whole_kind_gaps_at_any_depth() {
        let entities = Json::parse(r#"[{"name": "Leaf", "queries": [{"name": "Recent"}], "entities": [{"name": "Twig", "queries": [{"name": "Old"}]}]}]"#).unwrap();
        let mut m = Manifest::default();
        m.entity_query_gaps("D::A.Branch", entities.each());
        let text = m.to_json_text();
        assert!(text.contains("\"id\": \"D::A.Branch.Leaf.Recent\""));
        assert!(text.contains("\"id\": \"D::A.Branch.Leaf.Twig.Old\""));
        assert_eq!(text.matches("\"construct\": \"entity_query\"").count(), 2);
    }

    #[test]
    #[should_panic(expected = "with no gap_class")]
    fn a_gap_without_a_gap_class_is_refused() {
        Manifest::default().record("command", "D::A.C".to_string(), false, None, None, None, None);
    }

    #[test]
    fn inspect_matches_ruby_for_identity_arrays_and_nil() {
        let ids = Json::parse(r##"["reference.value", "a\"b", "#{x}"]"##).unwrap();
        assert_eq!(ruby_inspect(Some(&ids)), r##"["reference.value", "a\"b", "\#{x}"]"##);
        assert_eq!(ruby_inspect(Some(&Json::Array(vec![]))), "[]");
        assert_eq!(ruby_inspect(None), "nil");
    }
}
