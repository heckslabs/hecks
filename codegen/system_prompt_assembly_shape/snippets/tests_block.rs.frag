#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn substitute_replaces_known_keys() {
        let mut v = HashMap::new();
        v.insert("being", "Miette".to_string());
        v.insert("born", "April 9, 2026".to_string());
        let out = substitute("# {{being}}\nBorn {{born}}.", &v);
        assert_eq!(out, "# Miette\nBorn April 9, 2026.");
    }

    #[test]
    fn substitute_preserves_unknown_keys() {
        let v = HashMap::new();
        let out = substitute("hello {{nope}} world", &v);
        assert!(out.contains("{{nope}}"), "unknown keys must round-trip");
    }

    #[test]
    fn substitute_handles_no_placeholders() {
        let v = HashMap::new();
        let out = substitute("plain text", &v);
        assert_eq!(out, "plain text");
    }

    #[test]
    fn substitute_handles_malformed_close() {
        let v = HashMap::new();
        let out = substitute("trailing {{open without close", &v);
        assert!(out.contains("{{open"), "malformed must not panic");
    }

    #[test]
    fn variables_for_miette_round_trip() {
        let v = variables_for_being("Miette");
        assert_eq!(v.get("being").unwrap(), "Miette");
        assert_eq!(v.get("other").unwrap(), "Spring");
        assert_eq!(v.get("born").unwrap(),  "April 9, 2026");
        assert_eq!(v.get("boot_script").unwrap(), "boot_miette.sh");
    }

    #[test]
    fn variables_for_spring() {
        let v = variables_for_being("Spring");
        assert_eq!(v.get("being").unwrap(), "Spring");
        assert_eq!(v.get("other").unwrap(), "Miette");
    }

    #[test]
    fn assemble_orders_numerically_and_joins_with_blank_line() {
        let src = "Hecks.fixtures \"T\" do\n  aggregate \"SystemPromptSection\" do\n    fixture \"B\", order: 10, markdown: \"## Tenth\\nbody ten\\n\"\n    fixture \"A\", order: 2, markdown: \"## Second\\nbody two\\n\"\n  end\nend\n";
        let out = assemble_sections(src);
        assert_eq!(out, "## Second\nbody two\n\n## Tenth\nbody ten\n");
    }

    #[test]
    fn quoted_after_extracts_first_quoted_token() {
        assert_eq!(quoted_after("Hecks.bluebook \"Acl\", v: 1", "Hecks.bluebook \"").as_deref(), Some("Acl"));
        assert_eq!(quoted_after("no marker here", "vision \""), None);
    }
}
