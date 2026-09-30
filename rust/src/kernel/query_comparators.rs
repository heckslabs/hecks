// Matching logic for the generated `QueryComparator` enum (`vocab::QueryComparator`),
// mirroring Ruby's `QuerySpecification::Common::Comparison#holds?`.

use super::Json;

pub use super::vocab::QueryComparator;

impl QueryComparator {
    /// The wire's `op` string, or `None` if unrecognized (callers refuse, never default to `eq`).
    pub fn parse(op: &str) -> Option<Self> {
        QueryComparator::from_name(op)
    }

    /// `Comparison#holds?`; `held`/`want` arrive already reduced through `comparable`.
    pub fn matches(self, held: &Json, want: &Json) -> bool {
        match self {
            QueryComparator::Eq => held == want,
            QueryComparator::Ne => held != want,
            QueryComparator::Gt => ordered(held, want) && as_f64(held) > as_f64(want),
            QueryComparator::Gte => ordered(held, want) && as_f64(held) >= as_f64(want),
            QueryComparator::Lt => ordered(held, want) && as_f64(held) < as_f64(want),
            QueryComparator::Lte => ordered(held, want) && as_f64(held) <= as_f64(want),
            QueryComparator::In => members(want).iter().any(|member| member == &to_s(held)),
            QueryComparator::Contains => contains(held, want),
            // Needs a repository, so `filter_entries_cross_domain` calls `none_in_state_matches`
            // first; this arm keeps the match exhaustive with the same "not excluded" default.
            QueryComparator::NoneInState => true,
        }
    }
}

/// `Comparison#none_in_state?`: `want` is `"Aggregate:state"`, `held` the referring foreign key.
/// `cross_domain` is searched in order, first match wins; an empty slice answers `true`.
pub fn none_in_state_matches(cross_domain: &[(&str, &dyn super::AggregateScan)], held: &Json, want: &Json) -> bool {
    let Some((aggregate_name, state)) = to_s(want).split_once(':').map(|(a, s)| (a.to_string(), s.to_string()))
    else {
        return true;
    };
    let held_id = to_s(held);

    for (domain_name, store) in cross_domain {
        let qualified = format!("{domain_name}::{aggregate_name}");
        let Some(entries) = store.scan(&qualified) else { continue };

        let Some((_, record)) = entries.iter().find(|(id, _)| *id == held_id) else { return true };
        let record_state = comparable(&record.dig("state").cloned().unwrap_or(Json::Null));
        return to_s(&record_state) != state;
    }

    // No domain declares the aggregate: not excluded.
    true
}

/// gt/gte/lt/lte are numeric-only; anything else is silently false, never a refusal.
fn ordered(held: &Json, want: &Json) -> bool {
    matches!(held, Json::Num(_, _) | Json::Float(_)) && matches!(want, Json::Num(_, _) | Json::Float(_))
}

/// Only called after `ordered` has gated the comparison, so the NaN fallback is unreachable.
pub(crate) fn as_f64(value: &Json) -> f64 {
    match value {
        Json::Num(n, _) | Json::Float(n) => *n,
        _ => f64::NAN,
    }
}

/// Ruby's `#to_s` on a scalar already reduced by `comparable`.
pub(crate) fn to_s(value: &Json) -> String {
    match value {
        Json::Str(s) => s.clone(),
        // The exact source text wins when there is one (BUG#147) — see `Json::write`.
        Json::Num(_, Some(raw)) => raw.clone(),
        Json::Num(n, None) if n.fract() == 0.0 && n.abs() < 1e15 => (*n as i64).to_string(),
        Json::Num(n, None) => n.to_string(),
        // Ruby's `Float#to_s` always shows a decimal point (`10.0`).
        Json::Float(n) => {
            let rendered = n.to_string();
            if rendered.contains('.') || rendered.contains('e') || rendered.contains('E') {
                rendered
            } else {
                format!("{rendered}.0")
            }
        }
        Json::Bool(b) => b.to_string(),
        Json::Null => String::new(),
        // A multi-member, non-numeric value object still arrives structured; JSON stands in
        // for Ruby's `Hash#to_s`.
        other => other.to_json_string(),
    }
}

/// `Ports::Query::InMemory#comparable`: reduces a value object one level, to its numeric member
/// or its only member; anything else passes through unchanged.
pub fn comparable(value: &Json) -> Json {
    comparable_ref(value).clone()
}

/// `comparable` without the copy: the reduced value is always `value` itself or a member of it.
pub fn comparable_ref(value: &Json) -> &Json {
    let Json::Object(fields) = value else { return value };

    if let Some((_, numeric)) = fields.iter().find(|(_, v)| matches!(v, Json::Num(_, _) | Json::Float(_))) {
        return numeric;
    }
    if fields.len() == 1 {
        return &fields[0].1;
    }
    value
}

/// Reads `in`'s argument or a `list_of` value as elements; other text is comma-separated.
fn members(value: &Json) -> Vec<String> {
    if let Json::Array(items) = value {
        return items.iter().map(|item| to_s(&comparable(item))).collect();
    }
    to_s(value).split(',').map(|piece| piece.trim().to_string()).collect()
}

/// Element membership for a `list_of` field, substring match for anything else.
fn contains(held: &Json, want: &Json) -> bool {
    if matches!(held, Json::Array(_)) {
        return members(held).iter().any(|member| member == &to_s(want));
    }
    to_s(held).contains(&to_s(want))
}

// `none_in_state_matches`, including the cross-domain search no real deployment exercises.
#[cfg(test)]
mod none_in_state_tests {
    use super::{none_in_state_matches, Json};
    use crate::kernel::AggregateScan;

    /// Stand-in for a generated `Store`: scans by the domain-qualified aggregate name.
    struct FakeStore {
        domain: &'static str,
        aggregates: Vec<(&'static str, Vec<(String, Json)>)>,
    }

    impl AggregateScan for FakeStore {
        fn scan(&self, aggregate: &str) -> Option<Vec<(String, Json)>> {
            let bare = aggregate.strip_prefix(&format!("{}::", self.domain))?;
            self.aggregates.iter().find(|(name, _)| *name == bare).map(|(_, entries)| entries.clone())
        }
    }

    /// A record whose `state` is a single-field value object, as in the real corpus fixture.
    fn record_in_state(state: &str) -> Json {
        Json::obj(vec![("state", Json::obj(vec![("value", Json::str(state))]))])
    }

    #[test]
    fn with_no_domains_to_search_answers_vacuously_true() {
        // Ruby's `return true unless registry`.
        assert!(none_in_state_matches(&[], &Json::str("c1"), &Json::str("Claim:held")));
    }

    #[test]
    fn excludes_a_row_whose_target_is_currently_in_the_named_state() {
        let store = FakeStore { domain: "AntiJoinGrowth", aggregates: vec![("Claim", vec![("c1".into(), record_in_state("held"))])] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("AntiJoinGrowth", &store)];
        assert!(!none_in_state_matches(&stores, &Json::str("c1"), &Json::str("Claim:held")));
    }

    #[test]
    fn keeps_a_row_whose_target_has_moved_out_of_the_named_state() {
        let store = FakeStore { domain: "AntiJoinGrowth", aggregates: vec![("Claim", vec![("c2".into(), record_in_state("released"))])] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("AntiJoinGrowth", &store)];
        assert!(none_in_state_matches(&stores, &Json::str("c2"), &Json::str("Claim:held")));
    }

    #[test]
    fn keeps_a_row_whose_target_was_never_filed_at_all() {
        // No record reads the same as a record in another state.
        let store = FakeStore { domain: "AntiJoinGrowth", aggregates: vec![("Claim", vec![])] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("AntiJoinGrowth", &store)];
        assert!(none_in_state_matches(&stores, &Json::str("nonexistent"), &Json::str("Claim:held")));
    }

    #[test]
    fn keeps_every_row_when_no_domain_declares_the_named_aggregate_at_all() {
        let store = FakeStore { domain: "AntiJoinGrowth", aggregates: vec![] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("AntiJoinGrowth", &store)];
        assert!(none_in_state_matches(&stores, &Json::str("c1"), &Json::str("NoSuchAggregate:held")));
    }

    #[test]
    fn searches_a_second_domain_when_the_first_does_not_declare_the_aggregate() {
        // Cross-domain search; no real deployment has this shape.
        let domain_a = FakeStore { domain: "DomainA", aggregates: vec![("Widget", vec![])] };
        let domain_b =
            FakeStore { domain: "DomainB", aggregates: vec![("Claim", vec![("c1".into(), record_in_state("held"))])] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("DomainA", &domain_a), ("DomainB", &domain_b)];
        assert!(!none_in_state_matches(&stores, &Json::str("c1"), &Json::str("Claim:held")));
    }

    #[test]
    fn first_match_wins_when_two_domains_declare_the_same_bare_aggregate_name() {
        // Pins first-match-wins (Ruby's `find_aggregate_by_name`): DomainA's "held" must win
        // over DomainB's "released".
        let first = FakeStore { domain: "DomainA", aggregates: vec![("Claim", vec![("c1".into(), record_in_state("held"))])] };
        let second =
            FakeStore { domain: "DomainB", aggregates: vec![("Claim", vec![("c1".into(), record_in_state("released"))])] };
        let stores: Vec<(&str, &dyn AggregateScan)> = vec![("DomainA", &first), ("DomainB", &second)];
        assert!(!none_in_state_matches(&stores, &Json::str("c1"), &Json::str("Claim:held")));
    }
}
