
#[cfg(test)]
mod dispatch_tests {
    use super::*;

    #[test]
    fn parses_bare_dispatch() {
        let s = parse_dispatch_statement(r#"dispatch "Body.WakeUp""#).unwrap();
        assert_eq!(s.command_name, "Body.WakeUp");
        assert!(s.with_spec.is_empty());
    }

    #[test]
    fn parses_dispatch_with_literal_and_from_event() {
        let line = r#"dispatch "Body.Tick", with: { name: "body", tick: from_event(:tick) }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.command_name, "Body.Tick");
        assert_eq!(s.with_spec.len(), 2);
        assert_eq!(s.with_spec[0].0, "name");
        assert!(matches!(s.with_spec[0].1, ValueSpec::Literal { ref value } if value == "body"));
        assert_eq!(s.with_spec[1].0, "tick");
        assert!(matches!(s.with_spec[1].1, ValueSpec::FromEvent { ref name, default: None } if name == "tick"));
    }

    #[test]
    fn parses_from_pm_with_default() {
        let line = r#"dispatch "X.Y", with: { carrying: from_pm(:carrying, default: "—") }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.with_spec.len(), 1);
        match &s.with_spec[0].1 {
            ValueSpec::FromPm { name, default } => {
                assert_eq!(name, "carrying");
                assert_eq!(default.as_deref(), Some("—"));
            }
            other => panic!("expected FromPm, got {:?}", other),
        }
    }

    #[test]
    fn tolerates_variable_whitespace_around_with() {
        let line = r#"dispatch "X.Y",          with: { tick: from_event(:tick) }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.with_spec.len(), 1);
        assert_eq!(s.with_spec[0].0, "tick");
    }

    #[test]
    fn preserves_with_declaration_order() {
        let line = r#"dispatch "X.Y", with: { a: 1, b: 2, c: 3 }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.with_spec.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(), vec!["a", "b", "c"]);
    }

    // ---- Phase 2.c — `set :attr, value_spec` parser tests ----------

    #[test]
    fn is_set_start_distinguishes_set_directive() {
        assert!(is_set_start("set :carrying, \"body\""));
        assert!(is_set_start("set\t:tick, from_event(:tick)"));
        // Don't match other identifiers that happen to begin with "set".
        assert!(!is_set_start("set_inventory :foo"));
        assert!(!is_set_start("settings :foo"));
        // Don't match dispatch (the existing keyword).
        assert!(!is_set_start("dispatch \"X.Y\""));
    }

    #[test]
    fn parses_set_with_literal() {
        let (attr, spec) = parse_set_statement(r#"set :carrying, "body""#).unwrap();
        assert_eq!(attr, "carrying");
        assert!(matches!(spec, ValueSpec::Literal { ref value } if value == "body"));
    }

    #[test]
    fn parses_set_with_from_event() {
        let (attr, spec) = parse_set_statement(r#"set :steering_target, from_event(:target)"#).unwrap();
        assert_eq!(attr, "steering_target");
        match spec {
            ValueSpec::FromEvent { name, default } => {
                assert_eq!(name, "target");
                assert!(default.is_none());
            }
            other => panic!("expected FromEvent, got {:?}", other),
        }
    }

    #[test]
    fn parses_set_with_from_pm_and_default() {
        let (attr, spec) =
            parse_set_statement(r#"set :tick, from_pm(:tick, default: "0")"#).unwrap();
        assert_eq!(attr, "tick");
        match spec {
            ValueSpec::FromPm { name, default } => {
                assert_eq!(name, "tick");
                assert_eq!(default.as_deref(), Some("0"));
            }
            other => panic!("expected FromPm, got {:?}", other),
        }
    }

    #[test]
    fn parses_set_with_string_attr_form() {
        // Defensive : the DSL surface is :attr (Symbol) but the parser
        // also tolerates the string form for hand-built fixtures.
        let (attr, spec) = parse_set_statement(r#"set "carrying", "body""#).unwrap();
        assert_eq!(attr, "carrying");
        assert!(matches!(spec, ValueSpec::Literal { ref value } if value == "body"));
    }

    #[test]
    fn rejects_malformed_set_lines() {
        // No comma — can't tell attr from value.
        assert!(parse_set_statement("set :carrying").is_none());
        // Empty attribute name after stripping :,",'
        assert!(parse_set_statement(r#"set :, "body""#).is_none());
        // Not a set line at all.
        assert!(parse_set_statement(r#"dispatch "X.Y""#).is_none());
    }

    #[test]
    fn parse_process_manager_captures_set_specs_in_declaration_order() {
        // Block-shape mirrors the synthetic 20_process_manager fixture's
        // `on "TargetSighted"` handler. The parser must collect three
        // set entries in source order, all on the same handler.
        let src = r#"process_manager "P" do
  correlates_by :id
  starts_on "Started"
  state "rem"
  on "TargetSighted", transition: { rem: :rem } do
    set :steering_target, from_event(:target)
    set :carrying, "body"
    set :tick, from_pm(:tick, default: "0")
    dispatch "Body.Steer", with: { target: from_pm(:steering_target) }
  end
end
"#;
        let lines: Vec<&str> = src.lines().collect();
        let (pm, _consumed) = parse_process_manager(&lines);
        assert_eq!(pm.handlers.len(), 1);
        let h = &pm.handlers[0];
        assert_eq!(h.event_type, "TargetSighted");
        assert_eq!(
            h.set_specs.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(),
            vec!["steering_target", "carrying", "tick"]
        );
        // The third entry is the from_pm(:tick, default: "0") form.
        match &h.set_specs[2].1 {
            ValueSpec::FromPm { name, default } => {
                assert_eq!(name, "tick");
                assert_eq!(default.as_deref(), Some("0"));
            }
            other => panic!("expected FromPm, got {:?}", other),
        }
        // Dispatches still parsed alongside set_specs on the same handler.
        assert_eq!(h.dispatches.len(), 1);
        assert_eq!(h.dispatches[0].command_name, "Body.Steer");
    }
}
