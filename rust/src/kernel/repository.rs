// Generic over the record type — one impl (InMemoryRepository<T>) serves
// every generated aggregate, nothing domain-specific here.
//
// `find` -> `None` for an id never stored, `save` upserts by id. The
// persistence contract itself — which methods a real adapter must answer,
// which are delegated without a presence check, which are optional
// passthroughs, and that `delete`'s return value is explicitly not part of
// the contract — is documented in full in docs/implemented/guides/writing-an-adapter.md;
// this trait is a Rust-shaped minimal reading of that same contract
// (`find`/`save`/`all`/`count`), not a second, undocumented one.

use std::collections::BTreeMap;

pub trait Repository<T: Clone> {
    fn find(&self, id: &str) -> Option<T>;
    fn save(&mut self, id: &str, record: T);
    fn all(&self) -> Vec<T>;
    fn count(&self) -> usize;
}

#[derive(Default, Clone)]
pub struct InMemoryRepository<T: Clone> {
    records: BTreeMap<String, T>,
}

impl<T: Clone> InMemoryRepository<T> {
    pub fn new() -> Self {
        Self { records: BTreeMap::new() }
    }

    /// `(id, record)` pairs — `Repository::all` alone discards the id,
    /// which the CLI's `instances` dump needs (Ruby's own oracle output
    /// keys each instance `"Domain::Aggregate#id"`, per
    /// `bin/rust_conformance`'s `comparable["instances"]`). Kept on the
    /// concrete type rather than added to the `Repository` trait — nothing
    /// generated dispatches through this method, only the hand-written CLI
    /// does, and every `Store` (rust/project/json_codec.rb's
    /// `emit_registry`) holds `InMemoryRepository` concretely already.
    pub fn entries(&self) -> impl Iterator<Item = (&String, &T)> {
        self.records.iter()
    }
}

impl<T: Clone> Repository<T> for InMemoryRepository<T> {
    fn find(&self, id: &str) -> Option<T> {
        self.records.get(id).cloned()
    }

    fn save(&mut self, id: &str, record: T) {
        self.records.insert(id.to_string(), record);
    }

    fn all(&self) -> Vec<T> {
        self.records.values().cloned().collect()
    }

    fn count(&self) -> usize {
        self.records.len()
    }
}

/// `resolve_references` — `CommandRules::References#resolve_references`
/// (`lib/hecks/runtime/command_rules/references.rb`), read directly.
/// Hand-written and generic, unlike almost every other per-command check,
/// because its one caller is `registry.rs`'s generated `dispatch_by_name`
/// (`rust/project/reactions.rb`'s `emit_reference_check`) — the same place
/// Ruby's own version reaches through `@registry.repository(domain,
/// target)`, i.e. a repository OTHER than the dispatching command's own.
/// Nothing about the check itself is domain-specific; only WHICH repo and
/// WHICH command attribute to check is (generated, per command).
///
/// `value` empty is treated as "no check", mirroring Ruby's own
/// `next if key.to_s.empty?` (documented there as effectively unreachable
/// in practice — a non-string reference value is already refused earlier,
/// at the payload gate).
pub fn check_reference<T: Clone>(
    repo: &impl Repository<T>,
    value: &str,
    target: &'static str,
    heads: &'static str,
) -> Result<(), super::Refusal> {
    if value.is_empty() || repo.find(value).is_some() {
        return Ok(());
    }
    // `NotFound`/`reference_target_missing` — `resolve_references`
    // (command_rules/references.rb), read directly. Already textually
    // correct before this migration (`heads` was already the same
    // codegen-time-joined string `domain_generator.rb`'s own
    // `reference_checks` computes, `value:?` was already the same
    // `.inspect`-equivalent Debug quoting) — routed through `RefusalSite`
    // anyway, for drift-proofing: a future hand-edit here can no longer
    // silently diverge from Ruby's own table the way a bare `format!`
    // could.
    Err(super::Refusal::NotFound(super::RefusalSite::NotFoundReferenceTargetMissing.render(&[
        ("target", target),
        ("heads", heads),
        ("key", &format!("{value:?}")),
    ])))
}

/// Every generated domain's own `Store` gets this — `kernel/cli.rs`'s ad
/// hoc, single-comparator "query" step (the OBJECT form) needs to turn a
/// bare runtime STRING ("Banking::Account") into that one aggregate's
/// own (id, to_json()) listing, without knowing at compile time which
/// domain is active (`generated::active` is a Cargo-feature re-export —
/// see cli.rs's own header). The DEFAULT — `None`, for every name — is
/// what a `Store` gets for free the moment it exists, before
/// `rust/project/registry.rb`'s `emit_registry` has generated a REAL
/// per-aggregate override for it (a domain generated before this trait
/// existed, or one this repository holds no bluebook source for at all —
/// see kernel/cli.rs's own note on Embryonaut, whose generated tree is
/// hand-patched with the bare default impl rather than a real one, for
/// exactly that reason). `cli.rs` turns `None` into the SAME clean
/// "unknown aggregate" refusal either way — from the caller's side there
/// is no difference between "this aggregate doesn't exist" and "this
/// domain hasn't been regenerated with scan support yet," and there does
/// not need to be: both are honestly "cannot answer this," never a wrong
/// answer or a panic.
pub trait AggregateScan {
    fn scan(&self, aggregate: &str) -> Option<Vec<(String, super::Json)>> {
        let _ = aggregate;
        None
    }
}

/// THE MINIMAL QUERY ENGINE'S OWN FILTER STEP — given one aggregate's
/// full (id, to_json()) listing (`AggregateScan::scan`, above) and a
/// single dotted field path/comparator/wire value, return only the
/// matching (id, json) pairs, sorted by id ascending.
///
/// Id-ascending, ALWAYS, matches Ruby exactly even though nothing here
/// declares an `order_by` at all: `Ports::Query::Ordering.apply`'s own
/// header explains why — "the identity tier is what makes an ask total";
/// a query with no declared order still sorts by `record.id.to_s` before
/// returning, in BOTH `Ports::Query::InMemory.execute` and
/// `QueryInterpreter#interpret`. `InMemoryRepository`'s own backing store
/// is a `BTreeMap` (already id-ascending on the way in), so this sort is
/// a no-op in practice for THIS kernel and a correctness guarantee in
/// principle — nothing about `AggregateScan::scan`'s own contract
/// promises id order forever, and a future adapter behind the same
/// trait might not back onto a `BTreeMap` at all.
///
/// `field`/`comparator`/`want` ground truth: `Ports::Query::InMemory#holds?`
/// (lib/hecks/ports/query/in_memory.rb) — see query_comparators.rs's
/// own header for the full citation, including the real, adversarially-
/// exercised specs this was checked against rather than merely read.
pub fn filter_entries(
    entries: Vec<(String, super::Json)>,
    field: &str,
    comparator: super::query_comparators::QueryComparator,
    want: &super::Json,
) -> Vec<(String, super::Json)> {
    filter_entries_cross_domain(entries, field, comparator, want, &[])
}

/// `filter_entries`'s own real implementation, with one addition: an
/// explicit `cross_domain` search list for `NoneInState` (query_
/// comparators.rs's own header has the full story on why that one
/// comparator alone needs repository access `matches` cannot provide).
/// `filter_entries` above is a thin, behavior-preserving wrapper passing
/// an EMPTY list — every existing caller (every generated domain's own
/// `registry.rs`, `named_query::run`, `cli.rs`'s ad hoc filter step) goes
/// on calling the plain, unchanged `filter_entries` and gets `NoneInState`
/// -as-vacuously-true, the honest default for a comparator no real
/// deployed process can currently answer for real (see `none_in_state_
/// matches`'s own header). Split out, rather than adding a defaulted
/// parameter to `filter_entries` itself, so every one of those existing
/// call sites keeps compiling completely unchanged.
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
        .filter(|(_, record)| {
            let held = record.dig(field).cloned().unwrap_or(super::Json::Null);
            let held = super::query_comparators::comparable(&held);
            if comparator == super::query_comparators::QueryComparator::NoneInState {
                super::query_comparators::none_in_state_matches(cross_domain, &held, &want)
            } else {
                comparator.matches(&held, &want)
            }
        })
        .collect();
    matched.sort_by(|a, b| a.0.cmp(&b.0));
    matched
}

/// One matched record, as a ROW — the field named `"id"` prepended to
/// whatever `to_json()` already produced, matching Ruby's own row shape
/// exactly (`QueryInterpreter#call`'s `{ id: record.id }.merge(record.
/// state)`, and — for a read model — `ReadModelInterpreter#row`'s own
/// plain `record.to_h`, which for a live Ruby aggregate record already
/// carries `id` alongside every other attribute, unlike this kernel's own
/// generated `to_json()`): an answer names its own id inline, distinct
/// from `instances()`'s own "Domain::Aggregate#id" -> state MAP shape,
/// which carries id only in the key, never inside the value. Shared here,
/// not left private to `cli.rs`, because a read model's own output nests
/// this same wrapping at EVERY level (the root row AND every reference-
/// matched sibling row, `kernel/read_model.rs`'s own `run`) — not just
/// the single top-level row an ad hoc filter or a named query ever
/// produces.
pub fn row_json(id: String, record: super::Json) -> super::Json {
    let super::Json::Object(mut fields) = record else { return record };
    fields.insert(0, ("id".to_string(), super::Json::Str(id)));
    super::Json::Object(fields)
}

/// `Ports::Authorization.holds_role?` -> `GovernanceAuthorization.
/// holds_role?` (`lib/hecksagain/adapters/driven/governance_
/// authorization.rb`), read directly:
/// ```ruby
/// def holds_role?(registry, actor_id:, role:)
///   rows = Runtime::Dispatcher.new(registry).query(
///     "Governance::RoleAssignment.AssignmentsForActor",
///     actor_id: { value: actor_id.to_s }
///   )
///   rows.any? { |row| row[:role_name][:value] == role.to_s && row[:ends_at].nil? }
/// end
/// ```
/// An ACTIVE assignment, not merely a historical one — every row
/// `AssignmentsForActor` returns for this actor (`ends_at` left for the
/// caller to read, matching Ruby's own deferral), filtered down to a
/// live (non-revoked) row naming exactly this role. No scope/starts_at
/// check — Ruby's own deliberate restraint, not ported as an omission.
///
/// `store`/`queries` are the SAME compiled `Store`/`QUERIES` table
/// `kernel::cli.rs`'s own "query" step already answers a real
/// `Governance::RoleAssignment.AssignmentsForActor` ask through
/// (`named_query::run`) — this reuses that real, compiled query path
/// rather than hand-rolling a second one. `named_query::find` returning
/// `None` means this compiled domain never merged Governance's own
/// aggregates in at all (no `uses_framework "Governance"`) — `false`,
/// same as "no matching row", is the right answer either way; `check_role`
/// below is the one that decides whether that should fall back to the
/// plain string comparison rather than read as an outright refusal.
pub fn holds_role(store: &impl AggregateScan, queries: &[super::QueryDef], actor_id: &str, role: &str) -> bool {
    let Some(def) = super::named_query::find(queries, "Governance::RoleAssignment.AssignmentsForActor") else {
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

/// `refuse_role_mismatch` — `CommandRules::Authorization`
/// (`lib/hecksagain/runtime/command_rules/authorization.rb`), read
/// directly:
/// ```ruby
/// def refuse_role_mismatch(command, domain)
///   caller = Caller.current
///   return unless caller
///   return if command.role.to_s.empty?
///   authorized =
///     if caller.actor_id && governance_attached?(domain)
///       Ports::Authorization.holds_role?(registry, actor_id: caller.actor_id, role: command.role)
///     else
///       caller.role == command.role
///     end
///   return if authorized
///   raise Unauthorized, ...
/// end
/// ```
/// Doubly opt-in, matched exactly: no bound caller (`caller_role: None` —
/// no `role:` on this step at all, the ordinary case for all but a
/// deliberately role-checking corpus fixture) → unchecked; no role the
/// command itself declared (`command_role: None`) → unchecked. Ruby's
/// caller comes from thread-local ambient state (`Caller.current`,
/// `Hecks.as_caller`) that this kernel has no analogue for — a
/// step's own `role:` key plays that part instead, read once at the CLI
/// boundary (`cli.rs`) and threaded through `orchestrate`'s OUTERMOST
/// dispatch only, exactly mirroring `Dispatcher#reenter`'s own
/// `Caller.without`: a policy/process-manager REACTION never carries a
/// caller in Ruby either, so a reaction's own re-entry into `orchestrate`
/// always passes `None` here, never the triggering step's role.
///
/// `caller_actor_id` is the SAME sibling opt-in `role:` always was —
/// present ONLY when a step also names WHO it is, exactly `Caller`'s own
/// (`role:`, `actor_id: nil`) shape (`lib/hecksagain/runtime/caller.rb`).
/// `None` here (every step before this addition, and every step that
/// still states only a bare `role:`) reproduces the string-equality
/// check exactly as it always ran — this branch is UNCHANGED, forever,
/// not merely today.
///
/// `Some(actor_id)` reaches the real check ONLY when THIS compiled
/// domain actually has Governance's own `RoleAssignment` aggregate
/// merged in (`named_query::find` below succeeding) — Ruby's own
/// `governance_attached?(domain)` gate, read off `registry.hecksagon
/// (domain)&.framework_members&.include?("Governance")` at dispatch
/// time; this kernel has no such live registry to ask, so it asks the
/// SAME question the only way a compiled artifact can: whether the
/// query codegen actually wired in for this domain includes the one
/// query real Governance attachment always produces
/// (`rust/project/registry.rb`'s own `emit_query_table`,
/// `bin/project_rust`'s `framework_queries` union). No compiled
/// `AssignmentsForActor` row → exactly "governance not attached" →
/// falls through to the plain string comparison, never an unconditional
/// refusal.
///
/// GOVERNANCE'S OWN COMMANDS ARE **NOT** SELF-EXEMPT — checked directly
/// against the running Ruby (`bundle exec ruby`, not merely read): a
/// caller who names `actor_id:` while dispatching `Governance::
/// RoleAssignment.Assign` itself is checked the SAME real way as any
/// other governed command's caller, `governance_attached?`'s own
/// `domain.to_s == "Governance"` clause included. An attacker who
/// self-declares `role: "Governance administrator", actor_id: "eve"`
/// with no real grant is REFUSED, not waved through by a same-domain
/// exemption — the doc comment immediately above `governance_attached?`
/// in `command_rules/authorization.rb` claims the opposite ("its own
/// commands are always checked by the string fallback"), but that
/// comment does not match what the code it sits on top of actually
/// does; the executing behavior — the only thing "already proven
/// correct" can honestly mean — is what this function ports. See this
/// change's own commit message / task report for the full empirical
/// trace. Nothing here special-cases a command's own domain at all —
/// `holds_role` is reached whenever `caller_actor_id` is bound AND this
/// compiled Store happens to carry the AssignmentsForActor query,
/// which is already true, unconditionally, for a domain's own merged-in
/// Governance chapter.
pub fn check_role(
    command_role: Option<&str>,
    command_name: &str,
    caller_role: Option<&str>,
    caller_actor_id: Option<&str>,
    store: &impl AggregateScan,
    queries: &[super::QueryDef],
) -> Result<(), super::Refusal> {
    let (Some(caller), Some(role)) = (caller_role, command_role) else { return Ok(()) };

    let authorized = match caller_actor_id {
        Some(actor_id) if super::named_query::find(queries, "Governance::RoleAssignment.AssignmentsForActor").is_some() => {
            holds_role(store, queries, actor_id, role)
        }
        _ => caller == role,
    };

    if authorized {
        return Ok(());
    }
    // `Unauthorized`/`role_mismatch` — `refuse_role_mismatch`
    // (command_rules/authorization.rb), read directly. Already textually
    // correct before this migration; routed through `RefusalSite` for the
    // same drift-proofing reason `check_reference` above now is.
    // `caller_role: caller` (the SELF-DECLARED string, not the actor's
    // real live role) — matching Ruby's own `caller_role: caller.role`
    // exactly, even on the real-check branch: `refuse_role_mismatch`'s
    // refusal message always quotes what the caller TYPED, never what
    // `holds_role?` actually found.
    Err(super::Refusal::Unauthorized(super::RefusalSite::UnauthorizedRoleMismatch.render(&[
        ("command", command_name),
        ("role", role),
        ("caller_role", caller),
    ])))
}

// Item #9, whole-project table-unification survey — an END-TO-END proof
// that `filter_entries_cross_domain` reproduces spec/query_none_in_
// state_growth_spec.rb's own real scenario exactly: a `Board::Assignment`
// row's `claim_id` field, filtered by `none_in_state: "Claim:held"`,
// against three `Claim` records (`held`, `released`, and one never filed
// at all). Not `#[cfg(test)]`-only fixture invention — the SAME three
// cases and the SAME expected surviving ids (`"c2"`, `"nonexistent"`) the
// Ruby spec itself asserts (`contain_exactly("c2", "nonexistent")`),
// proving this Rust port agrees with the real, adversarially-written
// Ruby behavior, not merely with its own `none_in_state_matches` unit
// tests (query_comparators.rs).
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

/// `check_role`'s `caller_actor_id` branch — a real Governance
/// `RoleAssignment` lookup instead of the plain string comparison, once
/// `actor_id:` is bound. Ground truth: `Ports::Authorization.holds_role?`
/// -> `GovernanceAuthorization.holds_role?`
/// (`lib/hecksagain/adapters/driven/governance_authorization.rb`) and
/// `CommandRules::Authorization#refuse_role_mismatch`
/// (`lib/hecksagain/runtime/command_rules/authorization.rb`), both read
/// directly (this module's own doc comments above have the full
/// citations) — checked EMPIRICALLY against the real, running Ruby
/// (`bundle exec ruby`, not merely read) for the one case its own doc
/// comment and its own code disagree about (an identified caller
/// dispatching one of Governance's OWN commands): see `check_role`'s own
/// doc comment for that trace.
#[cfg(test)]
mod check_role_actor_id_tests {
    use super::{check_role, AggregateScan};
    use crate::kernel::query_comparators::QueryComparator;
    use crate::kernel::{Json, QueryCondition, QueryConditionValue, QueryDef};

    /// The SAME compiled shape `bin/project_rust` actually emits once a
    /// domain declares `uses_framework "Governance"`
    /// (`rust/src/generated/pizzas/merged.rs`'s own real `QUERIES` table,
    /// read directly) — one `RoleAssignment` aggregate, scanned under
    /// the "Governance::RoleAssignment" prefix every real merged `Store`
    /// uses.
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

    /// The exact `AssignmentsForActor` `QueryDef` a real merged `Store`
    /// compiles — `rust/src/generated/pizzas/merged.rs`, read directly
    /// (verb/aggregate/conditions all copied verbatim).
    fn assignments_for_actor_query() -> QueryDef {
        QueryDef {
            verb: "Governance::RoleAssignment.AssignmentsForActor",
            aggregate: "Governance::RoleAssignment",
            conditions: &[QueryCondition { field: "actor_id", comparator: QueryComparator::Eq, value: QueryConditionValue::Arg("actor_id") }],
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

    // (a) An actor with NO matching `RoleAssignment` at all, dispatching
    // with `actor_id` set, is REFUSED — even though it also states
    // exactly the right bare `role:` string. This is the whole point:
    // the string a caller types can no longer forge a role it doesn't
    // really hold, once it also names who it is.
    #[test]
    fn refuses_an_identified_caller_with_no_matching_grant_even_though_the_typed_role_matches() {
        let store = FakeStore { role_assignments: vec![] };
        let queries = [assignments_for_actor_query()];

        let result = check_role(Some("Chef"), "Prepare", Some("Chef"), Some("attacker"), &store, &queries);

        assert!(result.is_err(), "an actor with no real grant must be refused even though it typed the right role");
    }

    // (b) An actor WITH a live (non-revoked) matching `RoleAssignment` is
    // accepted.
    #[test]
    fn accepts_an_identified_caller_with_a_live_matching_grant() {
        let store = FakeStore { role_assignments: vec![("ra1".to_string(), role_assignment("u1", "Chef", None))] };
        let queries = [assignments_for_actor_query()];

        let result = check_role(Some("Chef"), "Prepare", Some("Chef"), Some("u1"), &store, &queries);

        assert!(result.is_ok(), "a live matching grant must be accepted: {result:?}");
    }

    // (c) A REVOKED assignment (`ends_at` set) is refused — even though
    // it once matched.
    #[test]
    fn refuses_a_revoked_grant() {
        let store = FakeStore { role_assignments: vec![("ra1".to_string(), role_assignment("u1", "Chef", Some("2026-06-01")))] };
        let queries = [assignments_for_actor_query()];

        let result = check_role(Some("Chef"), "Prepare", Some("Chef"), Some("u1"), &store, &queries);

        assert!(result.is_err(), "a revoked grant must not authorize: {result:?}");
    }

    // (d) A caller supplying only `role:` (no `actor_id:`) behaves
    // EXACTLY as before this addition — the plain string comparison,
    // unaffected by whatever `RoleAssignment` data does or doesn't
    // exist. Proven both ways: a caller whose stated role doesn't match
    // still refuses even with a real grant sitting right there for a
    // DIFFERENT actor, and a caller whose stated role DOES match still
    // succeeds with no grant at all in the store.
    #[test]
    fn a_bare_role_only_caller_is_unaffected_by_any_real_grant_data() {
        let store = FakeStore { role_assignments: vec![("ra1".to_string(), role_assignment("u1", "Customer", None))] };
        let queries = [assignments_for_actor_query()];

        // Matches the string, no actor_id at all -> accepted, exactly as
        // it always has been, regardless of what RoleAssignment holds.
        let matches = check_role(Some("Chef"), "Prepare", Some("Chef"), None, &store, &queries);
        assert!(matches.is_ok(), "a bare matching role string must still be accepted unchanged: {matches:?}");

        // Does not match the string, no actor_id -> refused, exactly as
        // it always has been.
        let mismatches = check_role(Some("Chef"), "Prepare", Some("Customer"), None, &store, &queries);
        assert!(mismatches.is_err(), "a bare mismatched role string must still refuse unchanged");
    }

    // Governance not attached at all (no `AssignmentsForActor` row in
    // this compiled domain's own `QUERIES` table) — `actor_id` being
    // bound must fall back to the plain string comparison, never an
    // unconditional refusal, matching Ruby's own `governance_attached?`
    // returning false.
    #[test]
    fn falls_back_to_the_string_check_when_this_domain_never_attached_governance() {
        let store = FakeStore { role_assignments: vec![] };
        let queries: [QueryDef; 0] = [];

        let matches = check_role(Some("Chef"), "Prepare", Some("Chef"), Some("whoever"), &store, &queries);
        assert!(matches.is_ok(), "no AssignmentsForActor query compiled in -> string fallback, matching role -> accepted: {matches:?}");

        let mismatches = check_role(Some("Chef"), "Prepare", Some("Customer"), Some("whoever"), &store, &queries);
        assert!(mismatches.is_err(), "no AssignmentsForActor query compiled in -> string fallback, mismatched role -> refused");
    }
}
