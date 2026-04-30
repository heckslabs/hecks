// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::heki::Record;
    use serde_json::json;

    fn rec(pairs: &[(&str, serde_json::Value)]) -> Record {
        pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
    }

    #[test]
    fn filter_parses_all_ops() {
        assert_eq!(Filter::parse("a=b").unwrap().op,  FilterOp::Eq);
        assert_eq!(Filter::parse("a!=b").unwrap().op, FilterOp::NotEq);
        assert_eq!(Filter::parse("a~=b").unwrap().op, FilterOp::Prefix);
        assert_eq!(Filter::parse("a*=b").unwrap().op, FilterOp::Substring);
        assert!(Filter::parse("nope").is_err());
    }

    #[test]
    fn eq_and_neq_match_on_string_fields() {
        let r = rec(&[("status", json!("queued"))]);
        assert!(Filter::parse("status=queued").unwrap().matches(&r));
        assert!(!Filter::parse("status=done").unwrap().matches(&r));
        assert!(Filter::parse("status!=done").unwrap().matches(&r));
    }

    #[test]
    fn prefix_and_substring_ops() {
        let r = rec(&[("ref", json!("i42"))]);
        assert!(Filter::parse("ref~=i").unwrap().matches(&r));
        assert!(Filter::parse("ref*=4").unwrap().matches(&r));
        assert!(!Filter::parse("ref~=x").unwrap().matches(&r));
    }

    #[test]
    fn order_spec_parses_enum() {
        let o = OrderSpec::parse("priority:enum=high,low").unwrap();
        assert_eq!(o.field, "priority");
        assert_eq!(o.enum_order, Some(vec!["high".into(), "low".into()]));
    }

    #[test]
    fn enum_order_sorts_deterministically() {
        let r_low  = rec(&[("priority", json!("low"))]);
        let r_high = rec(&[("priority", json!("high"))]);
        let r_med  = rec(&[("priority", json!("medium"))]);
        let store: Store = vec![
            ("a".into(), r_low), ("b".into(), r_high), ("c".into(), r_med),
        ].into_iter().collect();
        let spec = OrderSpec::parse("priority:enum=high,medium,low").unwrap();
        let sorted = order_records(store.values().collect(), &spec);
        let names: Vec<_> = sorted.iter().map(|r| field_to_string(r.get("priority"))).collect();
        assert_eq!(names, vec!["high", "medium", "low"]);
    }

    #[test]
    fn numeric_order_sorts_by_value_not_lexicographically() {
        let s: Store = vec![
            ("a".into(), rec(&[("n", json!(2))])),
            ("b".into(), rec(&[("n", json!(10))])),
            ("c".into(), rec(&[("n", json!(1))])),
        ].into_iter().collect();
        let spec = OrderSpec::parse("n").unwrap();
        let sorted = order_records(s.values().collect(), &spec);
        let ns: Vec<_> = sorted.iter().map(|r| field_to_string(r.get("n"))).collect();
        assert_eq!(ns, vec!["1", "2", "10"]);
    }

    #[test]
    fn ties_break_on_created_at() {
        let r1 = rec(&[("p", json!("a")), ("created_at", json!("2026-04-21T00:00:00Z"))]);
        let r2 = rec(&[("p", json!("a")), ("created_at", json!("2026-04-21T00:00:01Z"))]);
        let s: Store = vec![("b".into(), r2), ("a".into(), r1)].into_iter().collect();
        let spec = OrderSpec::parse("p").unwrap();
        let sorted = order_records(s.values().collect(), &spec);
        let cas: Vec<_> = sorted.iter().map(|r| field_to_string(r.get("created_at"))).collect();
        assert_eq!(cas, vec!["2026-04-21T00:00:00Z", "2026-04-21T00:00:01Z"]);
    }
}
