// Snippet: in-file tests module. Emitted verbatim — 9 tests
// spanning the loads / then_events_include / extract_all_strings
// surface. Ships with the file so retirement preserves all coverage.
#[cfg(test)]
mod tests {
    use super::*;

    fn suite_src(body: &str) -> String {
        format!(
            "Hecks.behaviors \"Pizzas\" do\n  vision \"v\"\n{}end\n",
            body
        )
    }

    #[test]
    fn loads_single_name_records_one_entry() {
        let src = suite_src("  loads \"pulse\"\n");
        let suite = parse(&src);
        assert_eq!(suite.loads, vec!["pulse".to_string()]);
    }

    #[test]
    fn loads_multiple_names_records_them_in_order() {
        let src = suite_src("  loads \"body\", \"being\", \"sleep\"\n");
        let suite = parse(&src);
        assert_eq!(
            suite.loads,
            vec!["body".to_string(), "being".to_string(), "sleep".to_string()]
        );
    }

    #[test]
    fn no_loads_line_leaves_loads_empty() {
        let src = suite_src(
            "  test \"Create sets name\" do\n    \
              tests \"CreatePizza\", on: \"Pizza\"\n    \
              input  name: \"M\"\n    \
              expect name: \"M\"\n  end\n",
        );
        let suite = parse(&src);
        assert!(suite.loads.is_empty(), "loads should default to empty");
    }

    #[test]
    fn then_events_include_single_name_records_one_entry() {
        let src = suite_src(
            "  test \"Cascade fires\" do\n    \
              tests \"Tick\", on: \"Mindstream\"\n    \
              input  at: \"T0\"\n    \
              then_events_include \"BodyPulse\"\n  end\n",
        );
        let suite = parse(&src);
        assert_eq!(suite.tests.len(), 1);
        assert_eq!(suite.tests[0].events_include, vec!["BodyPulse".to_string()]);
    }

    #[test]
    fn then_events_include_multiple_names_in_order() {
        let src = suite_src(
            "  test \"Cascade fires\" do\n    \
              tests \"Tick\", on: \"Mindstream\"\n    \
              input  at: \"T0\"\n    \
              then_events_include \"BodyPulse\", \"FatigueAccumulated\", \"SynapsesPruned\"\n  end\n",
        );
        let suite = parse(&src);
        assert_eq!(
            suite.tests[0].events_include,
            vec![
                "BodyPulse".to_string(),
                "FatigueAccumulated".to_string(),
                "SynapsesPruned".to_string(),
            ]
        );
    }

    #[test]
    fn no_then_events_include_leaves_events_include_empty() {
        let src = suite_src(
            "  test \"Plain\" do\n    \
              tests \"CreatePizza\", on: \"Pizza\"\n    \
              input  name: \"M\"\n    \
              expect name: \"M\"\n  end\n",
        );
        let suite = parse(&src);
        assert!(suite.tests[0].events_include.is_empty());
    }

    #[test]
    fn suite_with_loads_plus_mixed_tests() {
        // Suite-level loads, one test with then_events_include, another without.
        let src = "Hecks.behaviors \"Mindstream\" do\n  \
          vision \"v\"\n  \
          loads \"pulse\", \"body\"\n  \
          test \"Fans out\" do\n    \
            tests \"Tick\", on: \"Mindstream\"\n    \
            input  at: \"T0\"\n    \
            then_events_include \"BodyPulse\", \"FatigueAccumulated\"\n  \
          end\n  \
          test \"Plain\" do\n    \
            tests \"CreateNote\", on: \"Mindstream\"\n    \
            input  body: \"hi\"\n    \
            expect body: \"hi\"\n  \
          end\n\
          end\n";
        let suite = parse(src);
        assert_eq!(
            suite.loads,
            vec!["pulse".to_string(), "body".to_string()]
        );
        assert_eq!(suite.tests.len(), 2);
        assert_eq!(
            suite.tests[0].events_include,
            vec!["BodyPulse".to_string(), "FatigueAccumulated".to_string()]
        );
        assert!(suite.tests[1].events_include.is_empty());
    }

    #[test]
    fn input_kwargs_split_across_continuation_lines() {
        // i258 regression — Ruby's `input k: v,\n  k2: v2` natural form
        // is a single logical call with two kwargs ; the line-based
        // Rust parser must join continuation lines (line ending with
        // `,`) before dispatching to interpret_test_line. Without
        // this, only the first physical line's kwargs reach the IR
        // and the runtime falls through to apply_defaults (Value::List
        // empty) rendering as `[0 items]`. The four bin-buddy V1
        // commands (Subscribe / AddAddress / SetInventory /
        // RegisterPlan) all hit this path.
        let src = "Hecks.behaviors \"Subscription\" do\n  \
          test \"Subscribe lands an active subscription\" do\n    \
            tests \"Subscribe\", on: \"Subscription\"\n    \
            input  customer_account_email: \"alice@example.com\",\n           \
                   plan_code: \"full_in_out\",\n           \
                   monthly_price: 4500\n    \
            expect plan_code: \"full_in_out\",\n           \
                   monthly_price: 4500\n  \
          end\nend\n";
        let suite = parse(src);
        assert_eq!(suite.tests.len(), 1);
        let t = &suite.tests[0];
        assert_eq!(t.input.get("customer_account_email").map(|s| s.as_str()), Some("alice@example.com"));
        assert_eq!(t.input.get("plan_code").map(|s| s.as_str()), Some("full_in_out"));
        assert_eq!(t.input.get("monthly_price").map(|s| s.as_str()), Some("4500"));
        assert_eq!(t.expect.get("plan_code").map(|s| s.as_str()), Some("full_in_out"));
        assert_eq!(t.expect.get("monthly_price").map(|s| s.as_str()), Some("4500"));
    }

    #[test]
    fn array_literal_single_line_preserved() {
        // Sanity : single-line array literal value still works after
        // adding bracket-aware continuation joining.
        let src = suite_src(
            "  test \"Single line array\" do\n    \
              tests \"Tick\", on: \"Mindstream\"\n    \
              input  at: \"T0\"\n    \
              expect emits: [\"A\", \"B\"]\n  end\n",
        );
        let suite = parse(&src);
        assert_eq!(suite.tests.len(), 1);
        assert_eq!(
            suite.tests[0].expect.get("emits").map(|s| s.as_str()),
            Some("[\"A\", \"B\"]")
        );
    }

    #[test]
    fn array_literal_multi_line_with_trailing_comma_joins() {
        // i497 — opening `[` should trigger continuation joining even
        // when the opening line doesn't end with `,`.
        let src = suite_src(
            "  test \"Multiline array trailing comma\" do\n    \
              tests \"Tick\", on: \"Mindstream\"\n    \
              input  at: \"T0\"\n    \
              expect emits: [\n      \"A\",\n      \"B\",\n    ]\n  end\n",
        );
        let suite = parse(&src);
        assert_eq!(suite.tests.len(), 1);
        let v = suite.tests[0].expect.get("emits").cloned().unwrap_or_default();
        assert!(v.contains("\"A\""), "value should retain A : got {}", v);
        assert!(v.contains("\"B\""), "value should retain B : got {}", v);
        assert!(v.starts_with('['), "value should start with [ : got {}", v);
        assert!(v.trim_end().ends_with(']'), "value should end with ] : got {}", v);
    }

    #[test]
    fn array_literal_multi_line_no_trailing_comma_joins() {
        // i497 — same as above but no trailing comma before the `]`.
        let src = suite_src(
            "  test \"Multiline array no trailing comma\" do\n    \
              tests \"Tick\", on: \"Mindstream\"\n    \
              input  at: \"T0\"\n    \
              expect emits: [\n      \"A\",\n      \"B\"\n    ]\n  end\n",
        );
        let suite = parse(&src);
        assert_eq!(suite.tests.len(), 1);
        let v = suite.tests[0].expect.get("emits").cloned().unwrap_or_default();
        assert!(v.contains("\"A\""), "value should retain A : got {}", v);
        assert!(v.contains("\"B\""), "value should retain B : got {}", v);
        assert!(v.starts_with('['), "value should start with [ : got {}", v);
        assert!(v.trim_end().ends_with(']'), "value should end with ] : got {}", v);
    }

    #[test]
    fn nested_hash_with_array_multi_line_joins() {
        // i497 — nested literals : `{ bar: [1, 2] }` spanning lines.
        // Both `{` and `[` must keep the join going.
        let src = suite_src(
            "  test \"Nested hash array\" do\n    \
              tests \"Tick\", on: \"Mindstream\"\n    \
              input  at: \"T0\"\n    \
              expect foo: {\n      bar: [1, 2]\n    }\n  end\n",
        );
        let suite = parse(&src);
        assert_eq!(suite.tests.len(), 1);
        let v = suite.tests[0].expect.get("foo").cloned().unwrap_or_default();
        assert!(v.starts_with('{'), "value should start with {{ : got {}", v);
        assert!(v.trim_end().ends_with('}'), "value should end with }} : got {}", v);
        assert!(v.contains("bar"), "value should contain bar : got {}", v);
        assert!(v.contains("[1, 2]") || v.contains("[1,2]"),
            "value should contain inner array : got {}", v);
    }

    #[test]
    fn bracket_depth_helper_counts_correctly() {
        assert_eq!(bracket_depth("[]"), 0);
        assert_eq!(bracket_depth("["), 1);
        assert_eq!(bracket_depth("[[]"), 1);
        assert_eq!(bracket_depth("{ a: ["), 2);
        assert_eq!(bracket_depth("\"[\""), 0); // bracket inside string ignored
        assert_eq!(bracket_depth("\"\\\"[\""), 0); // escaped quote then bracket inside string
    }

    #[test]
    fn extract_all_strings_handles_multiple_tokens() {
        assert_eq!(
            extract_all_strings("loads \"a\", \"b\", \"c\""),
            vec!["a".to_string(), "b".to_string(), "c".to_string()]
        );
    }

    #[test]
    fn extract_all_strings_empty_when_no_quotes() {
        let r: Vec<String> = extract_all_strings("loads");
        assert!(r.is_empty());
    }
}
