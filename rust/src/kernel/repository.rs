//! Storage trait and in-memory implementation shared by every generated aggregate.
//! The adapter persistence contract is docs/implemented/guides/writing-an-adapter.md.

use std::cell::OnceCell;
use std::collections::BTreeMap;

pub trait Repository<T: Clone> {
    fn find(&self, id: &str) -> Option<T>;
    fn save(&mut self, id: &str, record: T);
    fn all(&self) -> Vec<T>;
    fn count(&self) -> usize;
}

/// One held record plus its `to_json()` rendering, built the first time a scan asks for it.
///
/// A slot is only ever replaced whole by `save`, so the rendering can never outlive the record
/// it was built from.
#[derive(Clone)]
struct Slot<T> {
    record: T,
    json: OnceCell<super::Json>,
}

#[derive(Default, Clone)]
pub struct InMemoryRepository<T: Clone> {
    records: BTreeMap<String, Slot<T>>,
}

impl<T: Clone> InMemoryRepository<T> {
    pub fn new() -> Self {
        Self { records: BTreeMap::new() }
    }

    /// `(id, record)` pairs; `Repository::all` drops the id, which the CLI `instances` dump needs.
    /// Inherent rather than on the trait: only the hand-written CLI calls it.
    pub fn entries(&self) -> impl Iterator<Item = (&String, &T)> {
        self.records.iter().map(|(id, slot)| (id, &slot.record))
    }

    /// `(id, record.to_json())` pairs in id order, borrowed from a per-record cache.
    ///
    /// `to_json` runs once per record per save, not once per scan, so a query over an unchanged
    /// store allocates nothing until a row actually matches. `to_json` must be a pure function
    /// of the record, as every generated `to_json` is.
    pub fn json_entries<'a>(
        &'a self,
        to_json: impl Fn(&T) -> super::Json + 'a,
    ) -> impl Iterator<Item = (&'a String, &'a super::Json)> {
        self.records.iter().map(move |(id, slot)| (id, slot.json.get_or_init(|| to_json(&slot.record))))
    }
}

impl<T: Clone> Repository<T> for InMemoryRepository<T> {
    fn find(&self, id: &str) -> Option<T> {
        self.records.get(id).map(|slot| slot.record.clone())
    }

    fn save(&mut self, id: &str, record: T) {
        self.records.insert(id.to_string(), Slot { record, json: OnceCell::new() });
    }

    fn all(&self) -> Vec<T> {
        self.records.values().map(|slot| slot.record.clone()).collect()
    }

    fn count(&self) -> usize {
        self.records.len()
    }
}

/// Refuses with `NotFound` when `value` names a record missing from `repo`; empty means no check.
///
/// Generic and hand-written because the check reads a repository other than the dispatching
/// command's own; the generated `dispatch_by_name` supplies the repo and attribute.
pub fn check_reference<T: Clone>(
    repo: &impl Repository<T>,
    value: &str,
    target: &'static str,
    heads: &'static str,
) -> Result<(), super::Refusal> {
    if value.is_empty() || repo.find(value).is_some() {
        return Ok(());
    }
    // Wording goes through `RefusalSite` so it cannot drift from the Ruby table.
    Err(super::Refusal::NotFound(
        super::refusal_wording::NotFoundReferenceTargetMissingArgs { target, heads, key: value }.render_args(),
    ))
}

/// Lets the CLI list one aggregate's `(id, to_json())` pairs from a runtime name such as
/// "Banking::Account", without knowing which domain is compiled in.
///
/// The default answers `None` for every name (unknown aggregate); generated stores override it.
pub trait AggregateScan {
    fn scan(&self, aggregate: &str) -> Option<Vec<(String, super::Json)>> {
        let _ = aggregate;
        None
    }

    /// Calls `visit` with each `(id, record.to_json())` of `aggregate` in id order, borrowing the
    /// rows so a caller that keeps only some of them clones only those.
    ///
    /// Answers `false` for an unknown aggregate, where `scan` answers `None`. The default walks
    /// `scan`, so a store that overrides only `scan` still answers; generated stores override
    /// this to read their repositories' cached renderings.
    fn scan_each(&self, aggregate: &str, visit: &mut dyn FnMut(&str, &super::Json)) -> bool {
        let Some(entries) = self.scan(aggregate) else { return false };
        for (id, record) in &entries {
            visit(id, record);
        }
        true
    }
}

/// Keeps the entries whose dotted `field` satisfies `comparator` against `want`, sorted by id.
///
/// The id sort matches Ruby, which orders unordered queries by `record.id.to_s`; it does not
/// rely on `AggregateScan::scan` returning id order.
pub fn filter_entries(
    entries: Vec<(String, super::Json)>,
    field: &str,
    comparator: super::query_comparators::QueryComparator,
    want: &super::Json,
) -> Vec<(String, super::Json)> {
    filter_entries_cross_domain(entries, field, comparator, want, &[])
}

/// `filter_entries` plus a `cross_domain` scan list, which `NoneInState` needs to look up other
/// aggregates. The plain function passes an empty list, so `NoneInState` is vacuously true there.
pub fn filter_entries_cross_domain(
    entries: Vec<(String, super::Json)>,
    field: &str,
    comparator: super::query_comparators::QueryComparator,
    want: &super::Json,
    cross_domain: &[(&str, &dyn AggregateScan)],
) -> Vec<(String, super::Json)> {
    let want = super::query_comparators::comparable(want);
    let mut matched: Vec<(String, super::Json)> = entries
        .into_iter()
        .filter(|(_, record)| entry_matches(record, field, comparator, &want, cross_domain))
        .collect();
    matched.sort_by(|a, b| a.0.cmp(&b.0));
    matched
}

/// True when `record`'s dotted `field` satisfies `comparator` against `want`, which the caller
/// has already reduced through `query_comparators::comparable`.
///
/// The per-record test `filter_entries_cross_domain` applies; `named_query::run` calls it on
/// borrowed rows so a record that fails is never cloned. A missing field reads as `Json::Null`.
pub fn entry_matches(
    record: &super::Json,
    field: &str,
    comparator: super::query_comparators::QueryComparator,
    want: &super::Json,
    cross_domain: &[(&str, &dyn AggregateScan)],
) -> bool {
    static NULL: super::Json = super::Json::Null;
    let held = super::query_comparators::comparable_ref(record.dig(field).unwrap_or(&NULL));
    if comparator == super::query_comparators::QueryComparator::NoneInState {
        super::query_comparators::none_in_state_matches(cross_domain, held, want)
    } else {
        comparator.matches(held, want)
    }
}

/// Prepends the field `"id"` to a record's `to_json()` object, matching Ruby's query row shape.
///
/// Shared because read models nest this wrapping at every level, not only the top row.
pub fn row_json(id: String, record: super::Json) -> super::Json {
    let super::Json::Object(mut fields) = record else { return record };
    fields.insert(0, ("id".to_string(), super::Json::Str(id)));
    super::Json::Object(fields)
}

/// True when `actor_id` holds `role` through a live (`ends_at` unset) assignment.
///
/// Runs the chapter-declared `assignments` query through `named_query::run`; `None`, or a verb
/// missing from `queries`, holds no role. Ruby likewise ignores scope and `starts_at`.
pub fn holds_role_via(
    store: &impl AggregateScan,
    queries: &[super::QueryDef],
    assignments: Option<&str>,
    actor_id: &str,
    role: &str,
) -> bool {
    let Some(def) = assignments.and_then(|verb| super::named_query::find(queries, verb)) else {
        return false;
    };
    let args = super::Json::Object(vec![("actor_id".to_string(), super::Json::Str(actor_id.to_string()))]);
    let Ok(rows) = super::named_query::run(store, def, &args, None) else { return false };
    rows.iter().any(|(_, record)| {
        let matches_role = record.dig("role_name.value").and_then(super::Json::as_str) == Some(role);
        let not_revoked = matches!(record.dig("ends_at"), None | Some(super::Json::Null));
        matches_role && not_revoked
    })
}

/// Refuses with `Unauthorized` when the caller's role does not satisfy `command_role`.
///
/// Unchecked unless both a caller and a command role are present, except that an identified caller
/// (`caller_actor_id`) with no stated role is held to what Governance assigned them. With `caller_actor_id` and an
/// authorization provider compiled in (`assignments` names a query in `queries`), the role must be
/// held through `holds_role_via`; otherwise the caller's stated role is compared as a string.
/// Governance's own commands get no exemption: the running Ruby checks them like any other,
/// despite the comment above `governance_attached?` saying otherwise.
/// Only the outermost dispatch carries a caller; reactions pass `None`, as in Ruby.
pub fn check_role_via(
    command_role: Option<&str>,
    command_name: &str,
    caller_role: Option<&str>,
    caller_actor_id: Option<&str>,
    store: &impl AggregateScan,
    queries: &[super::QueryDef],
    assignments: Option<&str>,
) -> Result<(), super::Refusal> {
    let attached = assignments.and_then(|verb| super::named_query::find(queries, verb)).is_some();
    // An identified caller with no stated role is checked against what Governance assigned them: the
    // caller need not claim a role it may not hold. Unchecked without a Governance provider, as ever.
    if let (None, Some(role), Some(actor_id)) = (caller_role, command_role, caller_actor_id) {
        if !attached || holds_role_via(store, queries, assignments, actor_id, role) {
            return Ok(());
        }
        return Err(super::Refusal::Unauthorized(
            super::refusal_wording::UnauthorizedRoleMismatchArgs { command: command_name, role, caller_role: "no assigned role" }.render_args(),
        ));
    }
    let (Some(caller), Some(role)) = (caller_role, command_role) else { return Ok(()) };

    let authorized = match caller_actor_id {
        Some(actor_id) if attached => holds_role_via(store, queries, assignments, actor_id, role),
        _ => caller == role,
    };

    if authorized {
        return Ok(());
    }
    // The refusal quotes the role the caller typed, not the one `holds_role_via` found (as Ruby).
    Err(super::Refusal::Unauthorized(
        super::refusal_wording::UnauthorizedRoleMismatchArgs { command: command_name, role, caller_role: caller }.render_args(),
    ))
}

// End-to-end pin of `filter_entries_cross_domain` against the scenario in
// spec/query_none_in_state_growth_spec.rb, which expects surviving ids `c2` and `nonexistent`.
#[cfg(test)]
mod filter_entries_none_in_state_tests {
    use super::{filter_entries_cross_domain, AggregateScan};
    use crate::kernel::query_comparators::QueryComparator;
    use crate::kernel::Json;

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

    fn claim_record(state: &str) -> Json {
        Json::obj(vec![("state", Json::obj(vec![("value", Json::str(state))]))])
    }

    fn assignment_record(claim_id: &str) -> Json {
        Json::obj(vec![("claim_id", Json::str(claim_id))])
    }

    #[test]
    fn matches_the_real_ruby_spec_s_own_expected_surviving_ids() {
        let claims = FakeStore {
            domain: "AntiJoinGrowth",
            aggregates: vec![(
                "Claim",
                vec![
                    ("c1".into(), claim_record("held")),     // stays held -> excluded
                    ("c2".into(), claim_record("released")), // no longer held -> kept
                ],
            )],
        };
        let cross_domain: Vec<(&str, &dyn AggregateScan)> = vec![("AntiJoinGrowth", &claims)];

        let assignments = vec![
            ("b1:c1".to_string(), assignment_record("c1")),
            ("b1:c2".to_string(), assignment_record("c2")),
            // "nonexistent" -> no Claim record at all -> kept
            ("b1:c3".to_string(), assignment_record("nonexistent")),
        ];

        let matched = filter_entries_cross_domain(
            assignments,
            "claim_id",
            QueryComparator::NoneInState,
            &Json::str("Claim:held"),
            &cross_domain,
        );

        let claim_ids: Vec<&str> =
            matched.iter().map(|(_, record)| record.dig("claim_id").and_then(Json::as_str).unwrap()).collect();
        assert_eq!(claim_ids, vec!["c2", "nonexistent"]);
    }
}

#[cfg(test)]
mod check_role_actor_id_tests {
    use super::{check_role_via, AggregateScan};
    use crate::kernel::query_comparators::QueryComparator;
    use crate::kernel::{Json, QueryCondition, QueryConditionValue, QueryDef, Refusal};

    /// The assignments query a real Governance attachment declares.
    const GOVERNANCE_ASSIGNMENTS: &str = "Governance::RoleAssignment.AssignmentsForActor";

    fn check_role(
        command_role: Option<&str>,
        command_name: &str,
        caller_role: Option<&str>,
        caller_actor_id: Option<&str>,
        store: &impl AggregateScan,
        queries: &[QueryDef],
    ) -> Result<(), Refusal> {
        check_role_via(command_role, command_name, caller_role, caller_actor_id, store, queries, Some(GOVERNANCE_ASSIGNMENTS))
    }

    /// Mirrors the merged `Store` compiled for a domain using Governance: one `RoleAssignment`
    /// aggregate scanned under the "Governance::RoleAssignment" prefix.
    struct FakeStore {
        role_assignments: Vec<(String, Json)>,
    }

    impl AggregateScan for FakeStore {
        fn scan(&self, aggregate: &str) -> Option<Vec<(String, Json)>> {
            if aggregate == "Governance::RoleAssignment" {
                Some(self.role_assignments.clone())
            } else {
                None
            }
        }
    }

    /// The `AssignmentsForActor` `QueryDef` a merged `Store` compiles.
    fn assignments_for_actor_query() -> QueryDef {
        QueryDef {
            verb: "Governance::RoleAssignment.AssignmentsForActor",
            aggregate: "Governance::RoleAssignment",
            conditions: &[QueryCondition { field: "actor_id", comparator: QueryComparator::Eq, value: QueryConditionValue::Arg("actor_id") }],
            reference_hop_conditions: &[],
            order_by: None,
            offset: None,
            limit: None,
            authorization: None,
        }
    }

    fn role_assignment(actor_id: &str, role_name: &str, ends_at: Option<&str>) -> Json {
        Json::obj(vec![
            ("actor_id", Json::obj(vec![("value", Json::str(actor_id.to_string()))])),
            ("role_name", Json::obj(vec![("value", Json::str(role_name.to_string()))])),
            ("scope", Json::obj(vec![("value", Json::str("kitchen".to_string()))])),
            ("starts_at", Json::obj(vec![("value", Json::str("2026-01-01".to_string()))])),
            ("ends_at", match ends_at {
                Some(ts) => Json::obj(vec![("value", Json::str(ts.to_string()))]),
                None => Json::Null,
            }),
        ])
    }

    // An identified actor with no grant is refused even when the typed role matches.
    #[test]
    fn refuses_an_identified_caller_with_no_matching_grant_even_though_the_typed_role_matches() {
        let store = FakeStore { role_assignments: vec![] };
        let queries = [assignments_for_actor_query()];

        let result = check_role(Some("Chef"), "Prepare", Some("Chef"), Some("attacker"), &store, &queries);

        assert!(result.is_err(), "an actor with no real grant must be refused even though it typed the right role");
    }

    // A live (non-revoked) matching grant is accepted.
    #[test]
    fn accepts_an_identified_caller_with_a_live_matching_grant() {
        let store = FakeStore { role_assignments: vec![("ra1".to_string(), role_assignment("u1", "Chef", None))] };
        let queries = [assignments_for_actor_query()];

        let result = check_role(Some("Chef"), "Prepare", Some("Chef"), Some("u1"), &store, &queries);

        assert!(result.is_ok(), "a live matching grant must be accepted: {result:?}");
    }

    // A revoked grant (`ends_at` set) is refused.
    #[test]
    fn refuses_a_revoked_grant() {
        let store = FakeStore { role_assignments: vec![("ra1".to_string(), role_assignment("u1", "Chef", Some("2026-06-01")))] };
        let queries = [assignments_for_actor_query()];

        let result = check_role(Some("Chef"), "Prepare", Some("Chef"), Some("u1"), &store, &queries);

        assert!(result.is_err(), "a revoked grant must not authorize: {result:?}");
    }

    // An identified caller that states no role is held to what Governance assigned them.
    #[test]
    fn an_identified_caller_with_no_stated_role_needs_a_live_assignment_of_the_commands_role() {
        let store = FakeStore { role_assignments: vec![("ra1".to_string(), role_assignment("u1", "Chef", None))] };
        let queries = [assignments_for_actor_query()];

        assert!(check_role(Some("Chef"), "Prepare", None, Some("u1"), &store, &queries).is_ok(), "an assigned actor needs no stated role");
        assert!(check_role(Some("Waiter"), "Serve", None, Some("u1"), &store, &queries).is_err(), "an actor not assigned the role is refused");
        assert!(check_role(Some("Chef"), "Prepare", None, Some("u2"), &store, &queries).is_err(), "an unassigned actor is refused");
    }

    // Revoked assignments do not count for a caller with no stated role either.
    #[test]
    fn an_identified_caller_with_no_stated_role_is_refused_on_a_revoked_assignment() {
        let store = FakeStore { role_assignments: vec![("ra1".to_string(), role_assignment("u1", "Chef", Some("2026-06-01")))] };
        let queries = [assignments_for_actor_query()];

        assert!(check_role(Some("Chef"), "Prepare", None, Some("u1"), &store, &queries).is_err());
    }

    // No Governance provider attached: an actor with no stated role stays unchecked, as before.
    #[test]
    fn an_identified_caller_with_no_stated_role_is_unchecked_when_governance_is_not_attached() {
        let store = FakeStore { role_assignments: vec![] };

        let result = check_role_via(Some("Chef"), "Prepare", None, Some("u1"), &store, &[], None);

        assert!(result.is_ok(), "no provider, nothing to check against: {result:?}");
    }

    // A caller with only `role:` keeps the plain string comparison, whatever grants exist.
    #[test]
    fn a_bare_role_only_caller_is_unaffected_by_any_real_grant_data() {
        let store = FakeStore { role_assignments: vec![("ra1".to_string(), role_assignment("u1", "Customer", None))] };
        let queries = [assignments_for_actor_query()];

        // Matching string, no actor_id: accepted.
        let matches = check_role(Some("Chef"), "Prepare", Some("Chef"), None, &store, &queries);
        assert!(matches.is_ok(), "a bare matching role string must still be accepted unchanged: {matches:?}");

        // Mismatched string, no actor_id: refused.
        let mismatches = check_role(Some("Chef"), "Prepare", Some("Customer"), None, &store, &queries);
        assert!(mismatches.is_err(), "a bare mismatched role string must still refuse unchanged");
    }

    // Without an `AssignmentsForActor` query, a bound `actor_id` falls back to the string check.
    #[test]
    fn falls_back_to_the_string_check_when_this_domain_never_attached_governance() {
        let store = FakeStore { role_assignments: vec![] };
        let queries: [QueryDef; 0] = [];

        let matches = check_role(Some("Chef"), "Prepare", Some("Chef"), Some("whoever"), &store, &queries);
        assert!(matches.is_ok(), "no AssignmentsForActor query compiled in -> string fallback, matching role -> accepted: {matches:?}");

        let mismatches = check_role(Some("Chef"), "Prepare", Some("Customer"), Some("whoever"), &store, &queries);
        assert!(mismatches.is_err(), "no AssignmentsForActor query compiled in -> string fallback, mismatched role -> refused");
    }

    // The declared provider verb is honoured, not the Governance query name...
    #[test]
    fn check_role_via_reads_whichever_assignments_query_the_chapter_declared() {
        let declared = QueryDef { verb: "Access::Grant.HeldBy", ..assignments_for_actor_query() };
        let queries = [declared];

        let granted = FakeStore { role_assignments: vec![("ra1".to_string(), role_assignment("u1", "Chef", None))] };
        let accepted = check_role_via(Some("Chef"), "Prepare", Some("Chef"), Some("u1"), &granted, &queries, Some("Access::Grant.HeldBy"));
        assert!(accepted.is_ok(), "a live grant under the declared query must be accepted: {accepted:?}");

        let ungranted = FakeStore { role_assignments: vec![] };
        let refused = check_role_via(Some("Chef"), "Prepare", Some("Chef"), Some("u1"), &ungranted, &queries, Some("Access::Grant.HeldBy"));
        assert!(refused.is_err(), "no grant under the declared query must refuse even though the typed role matches");
    }

    // ...and with no declared provider, a Governance-named query is ignored.
    #[test]
    fn check_role_via_ignores_a_governance_named_query_nobody_declared() {
        let store = FakeStore { role_assignments: vec![] };
        let queries = [assignments_for_actor_query()];

        let result = check_role_via(Some("Chef"), "Prepare", Some("Chef"), Some("whoever"), &store, &queries, None);
        assert!(result.is_ok(), "no declared provider -> string fallback, matching role -> accepted: {result:?}");
    }
}

#[cfg(test)]
mod json_cache_tests {
    use super::{InMemoryRepository, Repository};
    use crate::kernel::Json;

    fn render(n: &i64) -> Json {
        Json::obj(vec![("n", Json::int(*n))])
    }

    // A save replaces the whole slot, so a scan after it never sees the old rendering.
    #[test]
    fn json_entries_follow_a_resave_and_stay_in_id_order() {
        let mut repo: InMemoryRepository<i64> = InMemoryRepository::new();
        repo.save("b", 2);
        repo.save("a", 1);
        let first: Vec<(String, Json)> = repo.json_entries(render).map(|(id, json)| (id.clone(), json.clone())).collect();
        assert_eq!(first, vec![("a".to_string(), render(&1)), ("b".to_string(), render(&2))]);

        repo.save("a", 10);
        let second: Vec<Json> = repo.json_entries(render).map(|(_, json)| json.clone()).collect();
        assert_eq!(second, vec![render(&10), render(&2)]);
    }
}
