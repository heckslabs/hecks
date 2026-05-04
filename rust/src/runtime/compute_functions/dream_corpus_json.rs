//! [antibody-exempt: rust/src/runtime/compute_functions/dream_corpus_json.rs —
//!  kernel-surface compute helper (i220 sub-gap 6, dream-corpus-tokenize).
//!  Tiny JSON serializer for the tokenize_dream_corpus payload — keeps
//!  the output dependency-free and the key order deterministic for
//!  testing. Same retirement contract as the parent.]
//!
//! Hand-rolled JSON serializer for the `tokenize_dream_corpus`
//! payload shape — keeps the output dependency-free of
//! `serde_json::to_string` and the key order stable for tests.
//!
//! The payload :
//!
//!   { "themes":            ["w1", "w2", …]
//!   , "joined":            "w1, w2, …"
//!   , "first_theme":       "w1"
//!   , "themes_above_threshold": ["w1", …] }
//!
//! When the consumer command's then_set chain learns to destructure
//! JSON, the payload field names become the destructure keys.

/// Serialize the four-field payload into the canonical JSON shape.
/// Key order is fixed (themes / joined / first_theme /
/// themes_above_threshold) so equality assertions stay stable.
pub fn serialize_payload(
    themes: &[String],
    joined: &str,
    first_theme: &str,
    above: &[String],
) -> String {
    format!(
        "{{\"themes\":{},\"joined\":{},\"first_theme\":{},\"themes_above_threshold\":{}}}",
        json_string_array(themes),
        json_string_scalar(joined),
        json_string_scalar(first_theme),
        json_string_array(above),
    )
}

/// Render a `&[String]` as a JSON string array : `["a","b"]`.
pub fn json_string_array(items: &[String]) -> String {
    let parts: Vec<String> = items.iter().map(|s| json_string_scalar(s)).collect();
    format!("[{}]", parts.join(","))
}

/// Render a single string as a JSON-quoted scalar with the standard
/// escapes (`"`, `\`, `\n`, `\r`, `\t`, control chars as `\uXXXX`).
pub fn json_string_scalar(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"'  => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
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
    fn scalar_escapes_quotes_and_backslash() {
        assert_eq!(json_string_scalar("hello"), "\"hello\"");
        assert_eq!(json_string_scalar("she said \"hi\""), "\"she said \\\"hi\\\"\"");
        assert_eq!(json_string_scalar("a\\b"), "\"a\\\\b\"");
    }

    #[test]
    fn scalar_escapes_control_chars() {
        assert_eq!(json_string_scalar("\n"), "\"\\n\"");
        assert_eq!(json_string_scalar("\t"), "\"\\t\"");
    }

    #[test]
    fn array_formats_each_item_quoted() {
        let xs = vec!["a".to_string(), "b".to_string()];
        assert_eq!(json_string_array(&xs), "[\"a\",\"b\"]");
    }

    #[test]
    fn payload_shape_is_stable() {
        let themes = vec!["ocean".to_string(), "dissolving".to_string()];
        let above = vec!["ocean".to_string()];
        let json = serialize_payload(&themes, "ocean, dissolving", "ocean", &above);
        assert!(json.starts_with("{\"themes\":["));
        assert!(json.contains("\"joined\":\"ocean, dissolving\""));
        assert!(json.contains("\"first_theme\":\"ocean\""));
        assert!(json.contains("\"themes_above_threshold\":[\"ocean\"]"));
    }
}
