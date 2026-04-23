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
