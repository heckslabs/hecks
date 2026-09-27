//! Interprets a compiled `report` block (`ReadModelDef`) against a domain's generated
//! `READ_MODELS` table — the hand-written counterpart to `rust/project/read_models.rb`.

use super::refusal_wording::{InvariantViolationGroupByCollisionArgs, NotFoundReadModelReferenceMissingArgs, UnauthorizedTenantRequiredArgs};
use super::{named_query, query_comparators, query_ordering, repository, AggregateScan, Json, QueryCondition, QueryConditionValue, Refusal};

/// A `where` clause that crosses one or more references on the eligible head
/// (`account/status`, or a longer `member/sponsor/standing` chain via `through`).
#[derive(Debug, Clone, Copy)]
pub struct ReferenceHopCondition {
    /// The eligible head's own reference field this hop crosses through first.
    pub via_field: &'static str,
    /// The first hop's target aggregate, domain-qualified ("Banking::Account").
    pub target_aggregate: &'static str,
    /// Further chain steps beyond the first hop, in declared order; `&[]` for a single hop.
    pub through: &'static [HopStep],
    /// The remaining where-clause field, resolved against the chain's final target.
    pub inner_field: &'static str,
    pub inner_comparator: query_comparators::QueryComparator,
    pub inner_value: QueryConditionValue,
}

/// One further step in a `ReferenceHopCondition` chain.
#[derive(Debug, Clone, Copy)]
pub struct HopStep {
    pub via_field: &'static str,
    pub target_aggregate: &'static str,
}

/// A reference field on a non-root head's own aggregate that may match back to `target_aggregate`.
#[derive(Debug, Clone, Copy)]
pub struct ReferenceField {
    pub target_aggregate: &'static str,
    pub field: &'static str,
}

/// One declared `include`, plus `is_root`/`reference_fields` precomputed at codegen time rather
/// than re-derived per call. Both are empty/false for the root head, which is fetched directly
/// by the caller's id argument rather than matched by reference.
#[derive(Debug, Clone, Copy)]
pub struct ReadModelHead {
    pub aggregate: &'static str,
    pub as_name: &'static str,
    pub many: bool,
    pub is_root: bool,
    pub reference_fields: &'static [ReferenceField],
}

/// A read model's declared `order_by`, applying to `ReadModelDef::filtered_head` alone — an
/// alias, not a distinct type, since `named_query.rs` needs the identical shape.
pub type ReadModelOrderBy = query_ordering::OrderBy;

/// A read model's declared `limit N`, applying to `ReadModelDef::filtered_head` alone.
pub type ReadModelLimit = query_ordering::Limit;

/// A read model's declared `offset N`, applying to `ReadModelDef::filtered_head` alone.
pub type ReadModelOffset = query_ordering::Offset;

/// One many-side head's own where/order_by/offset/limit. ADR 0055's `on:` lets a read model
/// with several many-side heads filter/order/page each independently; a read model with exactly
/// one many-side head and untargeted options still compiles to a single entry here, unchanged
/// from the shape this carried before ADR 0055 (`filtered_head`/`conditions`/... lived directly
/// on `ReadModelDef` then, one per whole read model rather than one per head).
#[derive(Debug, Clone, Copy)]
pub struct FilteredHead {
    /// The `ReadModelHead::as_name` this entry's options apply to.
    pub as_name: &'static str,
    pub conditions: &'static [QueryCondition],
    /// `where` clauses that hop through a reference, on this same head.
    pub reference_hop_conditions: &'static [ReferenceHopCondition],
    pub order_by: Option<ReadModelOrderBy>,
    pub offset: Option<ReadModelOffset>,
    pub limit: Option<ReadModelLimit>,
}

/// A compiled `report "X" do ... end` block — the read-model analogue of `QueryDef`.
/// `verb` is the "Domain.Name" wire string a read-model ask is matched against.
#[derive(Debug, Clone, Copy)]
pub struct ReadModelDef {
    pub verb: &'static str,
    /// `None` for a rootless read model (no `reference_to` declared) — every head then reads its
    /// own aggregate's whole table instead of being fetched/matched by a caller-supplied id.
    pub reference_name: Option<&'static str>,
    pub heads: &'static [ReadModelHead],
    /// One entry per many-side head this read model declares where/order_by/offset/limit for
    /// (ADR 0055's `on:`) — `&[]` when none do. At most one entry when the read model has a
    /// single many-side head (the pre-ADR-0055 shape); more than one only when `on:` targets
    /// distinct heads, since an untargeted option is only legal with a single many-side head
    /// (`ReadModelBuilder#seal_query_options` refuses any other combination before this table is
    /// ever built).
    pub filtered_heads: &'static [FilteredHead],
    /// `authorize policy, tenant: :field` — reuses `named_query::TenantAuth` directly; the
    /// tenant-argument check runs at the same point in `run` as it does for a declared query.
    /// `on:` doesn't extend to `tenant:` (a deliberate ADR 0055 scope limit — a read model with
    /// several many-side heads and a declared tenant is refused outright, not attached to one),
    /// so this is only ever `Some` alongside a single many-side head, the same as before.
    pub authorization: Option<named_query::TenantAuth>,
    /// `group_by :field, ...`, applied to the one `many`-side head this read model declares.
    /// A per-read-model generated function rather than data here, because unwrapping a
    /// single-attribute value object needs codegen-time type knowledge `run`'s generic body,
    /// holding already-serialized `Json`, doesn't have.
    pub group_by: Option<fn(Vec<(String, Json)>) -> Result<Json, Refusal>>,
    /// `count` on the one `many`-side head — a bare marker; row-count needs no per-read-model
    /// generated function, unlike `group_by`.
    pub count: bool,
    /// `median :field` — the declared numeric field's median across the one `many`-side head.
    pub median_field: Option<&'static str>,
}

/// Whether a `group_by` leaf is checked for a second row — decided once, by the generator, from
/// the declaration alone (ADR 0061, decision D1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LeafCheck {
    /// The key path covers the grouped aggregate's whole identity, so no two
    /// rows can reach one leaf and none is checked.
    IdentityCovered,
    /// Any other key path: two rows reaching one leaf refuse, naming this
    /// read model (its bare declared name).
    RefuseCollision(&'static str),
}

/// One level of nesting per declared `group_by` field. Grouping is a Vec-based linear scan, not
/// a `HashMap`, because `Json` has no `Hash` impl and groups must stay in first-occurrence order
/// (matching Ruby's `Hash#group_by`) so both runtimes report the same first collision.
pub fn nest(rows: Vec<Json>, fields: &[&str], check: LeafCheck) -> Result<Json, Refusal> {
    nest_level(rows, fields, fields, check, &[])
}

/// One level of `nest`. `all_fields` is the whole declared `group_by`
/// (the refusal names it); `reached` is the key path walked so far, one
/// `(field, key)` per level above this one.
fn nest_level(rows: Vec<Json>, all_fields: &[&str], fields: &[&str], check: LeafCheck, reached: &[(&str, Json)]) -> Result<Json, Refusal> {
    let (field, rest) = fields.split_first().expect("nest called with empty fields — read_model_skip_reason should refuse a group_by with none");
    let mut groups: Vec<(Json, Vec<Json>)> = Vec::new();
    for row in rows {
        let (key, stripped) = match row {
            Json::Object(pairs) => {
                let key = pairs.iter().find(|(k, _)| k == field).map(|(_, v)| v.clone()).unwrap_or(Json::Null);
                let stripped = Json::Object(pairs.into_iter().filter(|(k, _)| k != field).collect());
                (key, stripped)
            }
            other => (Json::Null, other),
        };
        match groups.iter_mut().find(|(k, _)| *k == key) {
            Some((_, group)) => group.push(stripped),
            None => groups.push((key, vec![stripped])),
        }
    }
    let mut out = Vec::with_capacity(groups.len());
    for (key, group) in groups {
        let mut path = reached.to_vec();
        path.push((field, key.clone()));
        let value = if rest.is_empty() { leaf(group, all_fields, check, &path)? } else { nest_level(group, all_fields, rest, check, &path)? };
        // A non-String key must stringify the same way Ruby's `Hash#[]=` does when used as a
        // JSON object key.
        out.push((super::query_comparators::to_s(&key), value));
    }
    Ok(Json::Object(out))
}

/// The one row a `group_by` key path reached, or the `group_by_collision` refusal when a
/// checked path was reached by more than one.
fn leaf(group: Vec<Json>, all_fields: &[&str], check: LeafCheck, path: &[(&str, Json)]) -> Result<Json, Refusal> {
    let read_model = match check {
        LeafCheck::RefuseCollision(read_model) if group.len() > 1 => read_model,
        _ => return Ok(group.into_iter().next().unwrap_or(Json::Null)),
    };
    let ids: Vec<String> = group.iter().map(|row| row.get("id").map(super::query_comparators::to_s).unwrap_or_default()).collect();
    let id_refs: Vec<&str> = ids.iter().map(String::as_str).collect();
    let key = path.iter().map(|(field, value)| format!("{field} = {}", super::query_comparators::to_s(value))).collect::<Vec<_>>().join(", ");
    Err(Refusal::InvariantViolation(
        InvariantViolationGroupByCollisionArgs { read_model, fields: all_fields, ids: &id_refs, key: &key }.render_args(),
    ))
}

/// The declared field's median across `rows`. An odd count returns the true middle value
/// unconverted; an even count averages the two middle values as a `Json::Float` (matching
/// Ruby's forced float division). An empty collection is `Json::Null`, not zero, so a caller
/// cannot mistake "nothing to average" for "averaged to zero".
fn median(rows: &[(String, Json)], field: &'static str) -> Json {
    let mut values: Vec<Json> = rows
        .iter()
        .filter_map(|(_, row)| row.get(field))
        .map(query_comparators::comparable)
        .filter(|value| !matches!(value, Json::Null))
        .collect();
    if values.is_empty() {
        return Json::Null;
    }
    values.sort_by(|a, b| query_comparators::as_f64(a).partial_cmp(&query_comparators::as_f64(b)).unwrap_or(std::cmp::Ordering::Equal));

    let middle = values.len() / 2;
    if values.len() % 2 == 1 {
        values[middle].clone()
    } else {
        Json::Float((query_comparators::as_f64(&values[middle - 1]) + query_comparators::as_f64(&values[middle])) / 2.0)
    }
}

/// The lookup a read-model ask (a bare "Domain.Name" string, no "::") dispatches through — a
/// linear scan over a generated domain's `READ_MODELS` table. Accepts either the declared verb
/// spelling or its snake_case alias (`matches_snake_alias`, below), since a real corpus caller
/// uses the snake_case form for this read model's own query step.
pub fn find<'a>(table: &'a [ReadModelDef], verb: &str) -> Option<&'a ReadModelDef> {
    table.iter().find(|def| def.verb == verb || matches_snake_alias(def.verb, verb))
}

/// True when `declared_verb` and `asked` name the same domain and `asked`'s name half equals
/// `declared_verb`'s name half run through `to_snake`.
fn matches_snake_alias(declared_verb: &str, asked: &str) -> bool {
    let Some((domain, name)) = declared_verb.split_once('.') else { return false };
    let Some((asked_domain, asked_name)) = asked.split_once('.') else { return false };

    domain == asked_domain && to_snake(name) == asked_name
}

/// A port of `Hecks::Naming.snake` (lib/hecks/naming.rb). No regex engine in this
/// dependency-free kernel, so the two `gsub` passes collapse into one left-to-right scan of
/// adjacent-character pairs; every declared read-model/query name is plain ASCII.
fn to_snake(name: &str) -> String {
    let chars: Vec<char> = name.chars().collect();
    let mut out = String::with_capacity(name.len() + 4);

    for (i, &c) in chars.iter().enumerate() {
        if i > 0 {
            let prev = chars[i - 1];
            // "HTTPServer" splits before the "S" of "Server", not before the "H" of "HTTP".
            let rule1 = prev.is_ascii_uppercase() && c.is_ascii_uppercase() && chars.get(i + 1).is_some_and(char::is_ascii_lowercase);
            // "customerPortfolio" splits before "P".
            let rule2 = (prev.is_ascii_lowercase() || prev.is_ascii_digit()) && c.is_ascii_uppercase();
            if rule1 || rule2 {
                out.push('_');
            }
        }
        out.push(c);
    }

    out.make_ascii_lowercase();
    out
}

#[cfg(test)]
mod snake_alias_tests {
    use super::*;

    // Every case here was checked against the real Ruby `Naming.snake`, not just this port.
    #[test]
    fn to_snake_matches_ruby_naming_snake() {
        assert_eq!(to_snake("CustomerPortfolio"), "customer_portfolio");
        assert_eq!(to_snake("ComplianceDashboard"), "compliance_dashboard");
        assert_eq!(to_snake("Active"), "active");
        assert_eq!(to_snake("ByFee"), "by_fee");
        assert_eq!(to_snake("HTTPServer"), "http_server");
        assert_eq!(to_snake("Type2Foo"), "type2_foo");
    }

    #[test]
    fn find_accepts_both_the_declared_and_the_snake_cased_spelling() {
        let table = [ReadModelDef {
            verb: "Banking.CustomerPortfolio",
            reference_name: Some("reference"),
            heads: &[],
            filtered_heads: &[],
            authorization: None,
            group_by: None,
            count: false,
            median_field: None,
        }];

        assert!(find(&table, "Banking.CustomerPortfolio").is_some());
        assert!(find(&table, "Banking.customer_portfolio").is_some());
        assert!(find(&table, "Banking.somethingelse").is_none());
        assert!(find(&table, "Other.customer_portfolio").is_none());
    }
}

/// ADR 0061, decision D1 — a `group_by` leaf holds one row.
#[cfg(test)]
mod nest_tests {
    use super::*;

    fn part(id: &str, bin: &str) -> Json {
        Json::obj(vec![("bin", Json::str(bin)), ("id", Json::str(id))])
    }

    #[test]
    fn refuses_two_rows_on_one_checked_key_path() {
        let rows = vec![part("p2", "b1"), part("p3", "b2"), part("p1", "b1")];

        let err = nest(rows, &["bin"], LeafCheck::RefuseCollision("PartsByBin")).expect_err("p1 and p2 share bin b1");

        assert_eq!(
            err,
            Refusal::InvariantViolation(
                "PartsByBin groups by bin, but rows \"p1\", \"p2\" share bin = b1 — a group_by leaf holds one row; add a field that tells them apart"
                    .to_string()
            )
        );
    }

    #[test]
    fn answers_when_every_key_path_holds_one_row() {
        let rows = vec![part("p1", "b1"), part("p3", "b2")];

        let nested = nest(rows, &["bin"], LeafCheck::RefuseCollision("PartsByBin")).expect("no two parts share a bin");

        assert_eq!(nested, Json::obj(vec![("b1", Json::obj(vec![("id", Json::str("p1"))])), ("b2", Json::obj(vec![("id", Json::str("p3"))]))]));
    }

    #[test]
    fn names_every_level_of_a_multi_field_key_path() {
        let row = |id: &str| Json::obj(vec![("bin", Json::str("b1")), ("shelf", Json::Num(2.0)), ("id", Json::str(id))]);

        let err = nest(vec![row("p1"), row("p2")], &["bin", "shelf"], LeafCheck::RefuseCollision("PartsByShelf")).expect_err("same bin and shelf");

        assert_eq!(
            err,
            Refusal::InvariantViolation(
                "PartsByShelf groups by bin, shelf, but rows \"p1\", \"p2\" share bin = b1, shelf = 2 — a group_by leaf holds one row; add a field that tells them apart"
                    .to_string()
            )
        );
    }
}

/// Exercises `ReferenceHopCondition`'s fold end-to-end through `run`, not just the isolated
/// `apply_filtered_head_options` helper, so a wiring mistake at either call site fails this the
/// same way it would fail a real caller.
#[cfg(test)]
mod reference_hop_tests {
    use super::*;
    use crate::kernel::AggregateScan;

    /// `domain` plus `(bare aggregate name, entries)` pairs, searched the same
    /// domain-qualified way a real generated `Store::scan` is.
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

    fn account(status: &str, customer: &str) -> Json {
        Json::obj(vec![("status", Json::str(status)), ("customer", Json::str(customer))])
    }

    fn customer(status: &str) -> Json {
        Json::obj(vec![("status", Json::str(status))])
    }

    fn store() -> FakeStore {
        FakeStore {
            domain: "Banking",
            aggregates: vec![
                (
                    "Account",
                    vec![
                        ("acc-suspended-open".to_string(), account("open", "cust-suspended")),
                        ("acc-active-open".to_string(), account("open", "cust-active")),
                        ("acc-suspended-closed".to_string(), account("closed", "cust-suspended")),
                    ],
                ),
                (
                    "Customer",
                    vec![
                        ("cust-suspended".to_string(), customer("suspended")),
                        ("cust-active".to_string(), customer("active")),
                    ],
                ),
            ],
        }
    }

    /// A rootless read model with one `many` head carrying both an ordinary local condition
    /// (`status == "open"`) and one hop condition (`customer/status == "suspended"`).
    fn open_for_suspended_customers_def() -> ReadModelDef {
        ReadModelDef {
            verb: "Banking.OpenForSuspendedCustomers",
            reference_name: None,
            heads: &[ReadModelHead { aggregate: "Banking::Account", as_name: "accounts", many: true, is_root: false, reference_fields: &[] }],
            filtered_heads: &[FilteredHead {
                as_name: "accounts",
                conditions: &[QueryCondition { field: "status", comparator: query_comparators::QueryComparator::Eq, value: QueryConditionValue::Literal("open") }],
                reference_hop_conditions: &[ReferenceHopCondition {
                    via_field: "customer",
                    target_aggregate: "Banking::Customer",
                    through: &[],
                    inner_field: "status",
                    inner_comparator: query_comparators::QueryComparator::Eq,
                    inner_value: QueryConditionValue::Literal("suspended"),
                }],
                order_by: None,
                offset: None,
                limit: None,
            }],
            authorization: None,
            group_by: None,
            count: false,
            median_field: None,
        }
    }

    #[test]
    fn a_hop_condition_keeps_only_rows_whose_local_and_hopped_conditions_both_hold() {
        let def = open_for_suspended_customers_def();
        let result = run(&store(), &def, &Json::obj(vec![])).expect("a rootless read model with no authorization needs no args");

        let accounts = result.get("accounts").expect("the one declared head").as_array().expect("a many head answers an array");
        let ids: Vec<&str> = accounts.iter().map(|row| row.get("id").and_then(Json::as_str).expect("row_json always stamps id")).collect();

        assert_eq!(ids, vec!["acc-suspended-open"]);
        // Named explicitly so a regression that widens either condition fails on the specific
        // wrong row it would admit, not just a count.
        assert!(!ids.contains(&"acc-active-open"), "open but NOT suspended — the hop condition alone should have excluded this");
        assert!(!ids.contains(&"acc-suspended-closed"), "suspended customer but NOT open — the ordinary local condition alone should have excluded this");
    }

    #[test]
    fn a_hop_against_an_unscannable_target_aggregate_refuses_cleanly() {
        let mut def = open_for_suspended_customers_def();
        def.filtered_heads = &[FilteredHead {
            as_name: "accounts",
            conditions: &[QueryCondition { field: "status", comparator: query_comparators::QueryComparator::Eq, value: QueryConditionValue::Literal("open") }],
            reference_hop_conditions: &[ReferenceHopCondition {
                via_field: "customer",
                target_aggregate: "Banking::NoSuchAggregate",
                through: &[],
                inner_field: "status",
                inner_comparator: query_comparators::QueryComparator::Eq,
                inner_value: QueryConditionValue::Literal("suspended"),
            }],
            order_by: None,
            offset: None,
            limit: None,
        }];

        let err = run(&store(), &def, &Json::obj(vec![])).expect_err("scanning an aggregate this store doesn't declare must refuse, not silently answer empty");
        assert!(matches!(err, Refusal::TypeMismatch(_)));
    }

    // An included nested entity has no table of its own; the head answers an empty array and
    // the sibling head's rows are untouched.
    #[test]
    fn a_head_with_no_table_of_its_own_reads_as_empty_rather_than_refusing() {
        let mut def = open_for_suspended_customers_def();
        def.filtered_heads = &[];
        def.heads = &[
            ReadModelHead { aggregate: "Banking::Account", as_name: "accounts", many: true, is_root: false, reference_fields: &[] },
            ReadModelHead { aggregate: "Banking::LedgerEntry", as_name: "ledger_entries", many: true, is_root: false, reference_fields: &[] },
        ];

        let result = run(&store(), &def, &Json::obj(vec![])).expect("an entity head must not refuse the read model");

        assert_eq!(result.get("accounts").and_then(|v| v.as_array()).map(|rows| rows.len()), Some(3));
        assert_eq!(result.get("ledger_entries").and_then(|v| v.as_array()).map(|rows| rows.len()), Some(0));
    }

    // A declared query folds its hop the same way a read model head does.
    #[test]
    fn a_named_query_folds_its_hop_conditions_like_a_read_model_head() {
        let def = crate::kernel::named_query::QueryDef {
            verb: "Banking::Account.OpenForSuspendedCustomers",
            aggregate: "Banking::Account",
            conditions: &[QueryCondition { field: "status", comparator: query_comparators::QueryComparator::Eq, value: QueryConditionValue::Literal("open") }],
            reference_hop_conditions: &[ReferenceHopCondition {
                via_field: "customer",
                target_aggregate: "Banking::Customer",
                through: &[],
                inner_field: "status",
                inner_comparator: query_comparators::QueryComparator::Eq,
                inner_value: QueryConditionValue::Literal("suspended"),
            }],
            order_by: None,
            offset: None,
            limit: None,
            authorization: None,
        };

        let rows = crate::kernel::named_query::run(&store(), &def, &Json::obj(vec![]), None).expect("no authorization, no args needed");
        let ids: Vec<&str> = rows.iter().map(|(id, _)| id.as_str()).collect();

        assert_eq!(ids, vec!["acc-suspended-open"]);
    }

    // An entity query flattens every card's withdrawals, ordered by card then sequence, capped.
    #[test]
    fn an_entity_query_flattens_every_owners_list_ordered_by_parent_then_identity() {
        fn withdrawal(sequence: f64, state: &str) -> Json {
            Json::obj(vec![("sequence", Json::obj(vec![("value", Json::Num(sequence))])), ("state", Json::str(state))])
        }
        let cards = FakeStore {
            domain: "Banking",
            aggregates: vec![(
                "ATMCard",
                vec![
                    ("card-2".to_string(), Json::obj(vec![("withdrawals", Json::Array(vec![withdrawal(2.0, "taken"), withdrawal(1.0, "taken")]))])),
                    ("card-1".to_string(), Json::obj(vec![("withdrawals", Json::Array(vec![withdrawal(1.0, "disputed"), withdrawal(3.0, "taken")]))])),
                ],
            )],
        };
        let def = crate::kernel::named_query::EntityQueryDef {
            verb: "Banking::ATMCard.Withdrawal.Recent",
            aggregate: "Banking::ATMCard",
            list_field: "withdrawals",
            parent_key: "atm_card",
            identity_keys: &["sequence"],
            conditions: &[QueryCondition { field: "state", comparator: query_comparators::QueryComparator::Eq, value: QueryConditionValue::Literal("taken") }],
            order_by: None,
            offset: None,
            limit: Some(query_ordering::Limit::Literal(2)),
        };

        let rows = crate::kernel::named_query::run_entity(&cards, &def, &Json::obj(vec![])).expect("no args needed");
        let keyed: Vec<(String, String)> = rows
            .iter()
            .map(|row| {
                let parent = row.get("atm_card").and_then(Json::as_str).expect("parent key leads every row").to_string();
                let sequence = format!("{:?}", row.dig("sequence.value"));
                (parent, sequence)
            })
            .collect();

        assert_eq!(keyed.len(), 2, "limit 2 over three taken withdrawals: {keyed:?}");
        assert_eq!(keyed[0].0, "card-1");
        assert_eq!(keyed[1].0, "card-2");
        assert!(keyed[1].1.contains('1'), "card-2's lowest sequence comes first: {keyed:?}");
    }

    // A chain: the inner clause picks sponsors, the middle step keeps members sponsored by one,
    // and the head keeps referrals issued by one of those members.
    #[test]
    fn a_hop_chain_folds_inside_out_through_every_step() {
        let chain_store = FakeStore {
            domain: "ReferralChain",
            aggregates: vec![
                (
                    "Sponsor",
                    vec![
                        ("s-good".to_string(), Json::obj(vec![("standing", Json::str("good"))])),
                        ("s-poor".to_string(), Json::obj(vec![("standing", Json::str("poor"))])),
                    ],
                ),
                (
                    "Member",
                    vec![
                        ("m-good".to_string(), Json::obj(vec![("sponsor", Json::str("s-good"))])),
                        ("m-poor".to_string(), Json::obj(vec![("sponsor", Json::str("s-poor"))])),
                    ],
                ),
                (
                    "Referral",
                    vec![
                        ("r-good".to_string(), Json::obj(vec![("member", Json::str("m-good"))])),
                        ("r-poor".to_string(), Json::obj(vec![("member", Json::str("m-poor"))])),
                    ],
                ),
            ],
        };
        let def = crate::kernel::named_query::QueryDef {
            verb: "ReferralChain::Referral.FromGoodSponsors",
            aggregate: "ReferralChain::Referral",
            conditions: &[],
            reference_hop_conditions: &[ReferenceHopCondition {
                via_field: "member",
                target_aggregate: "ReferralChain::Member",
                through: &[HopStep { via_field: "sponsor", target_aggregate: "ReferralChain::Sponsor" }],
                inner_field: "standing",
                inner_comparator: query_comparators::QueryComparator::Eq,
                inner_value: QueryConditionValue::Literal("good"),
            }],
            order_by: None,
            offset: None,
            limit: None,
            authorization: None,
        };

        let rows = crate::kernel::named_query::run(&chain_store, &def, &Json::obj(vec![]), None).expect("no authorization, no args needed");
        let ids: Vec<&str> = rows.iter().map(|(id, _)| id.as_str()).collect();

        assert_eq!(ids, vec!["r-good"]);
    }
}

/// The generic read-model interpreter — the single projected row, one entry per declared
/// head's `as_name`, for exactly the subset this module admits.
///
/// Heads compute root-first regardless of declared `include` order: a non-root head matches
/// against whatever is already computed, so processing it before its own root would always
/// compare against nothing.
pub fn run(store: &impl AggregateScan, def: &ReadModelDef, args: &Json) -> Result<Json, Refusal> {
    let reference_id = match def.reference_name {
        Some(name) => Some(
            args.get(name)
                .and_then(Json::as_str)
                .ok_or_else(|| Refusal::TypeMismatch(format!("{}: missing reference argument {name:?}", def.verb)))?
                .to_string(),
        ),
        // Rootless: no caller-supplied id to require or resolve at all.
        None => None,
    };

    // Checked right after the reference id resolves, before any head is computed.
    if let Some(auth) = &def.authorization {
        if args.get(auth.tenant_field).is_none() {
            return Err(Refusal::Unauthorized(
                UnauthorizedTenantRequiredArgs { query: auth.query_name, field: auth.tenant_field }.render_args(),
            ));
        }
    }

    let (root_heads, other_heads): (Vec<&ReadModelHead>, Vec<&ReadModelHead>) = def.heads.iter().partition(|head| head.is_root);

    // One entry per head already computed, in computation order (root-first): every candidate
    // record is checked against every entry seen so far, not just the immediately-preceding one.
    let mut projected: Vec<(&'static str, Vec<(String, Json)>)> = Vec::new();
    let mut rows_by_as: std::collections::HashMap<&'static str, (bool, Vec<(String, Json)>)> = std::collections::HashMap::new();
    let mut grouped_heads: std::collections::HashSet<&'static str> = std::collections::HashSet::new();

    for head in root_heads.into_iter().chain(other_heads) {
        let mut rows = if reference_id.is_none() {
            // Rootless: each head reads its own aggregate's whole table independently, with no
            // cross-referencing against `projected`. A head with no table reads as empty.
            store.scan(head.aggregate).unwrap_or_default()
        } else if head.is_root {
            vec![fetch_root(store, head, reference_id.as_deref().unwrap())?]
        } else {
            scan_matching(store, head, &projected)?
        };

        // Applied before this head's rows go into `projected`, so any later head's own
        // reference-matching sees the filtered rows, not the pre-filter scan.
        if let Some(filtered) = def.filtered_heads.iter().find(|fh| fh.as_name == head.as_name) {
            rows = apply_filtered_head_options(rows, filtered, args, store)?;
        }

        // Recorded so the output loop below knows not to wrap these rows again — the generated
        // transform already does its own row_json-equivalent wrapping internally.
        if def.group_by.is_some() && head.many {
            grouped_heads.insert(head.as_name);
        }

        projected.push((head.aggregate, rows.clone()));
        rows_by_as.insert(head.as_name, (head.many, rows));
    }

    // Declared order, for the output only — `def.heads` itself, not the root-first order
    // `projected`/`rows_by_as` were just built in. `repository::row_json` wraps every record
    // here, at every level of nesting, since this kernel's generated `to_json()` doesn't carry
    // `id` the way a live Ruby record's `to_h` does.
    let mut out = Vec::with_capacity(def.heads.len());
    for head in def.heads {
        let (many, rows) = rows_by_as
            .remove(head.as_name)
            .expect("every head in def.heads was computed in the loop above — as_name is unique per read model (ReadModelBuilder#add_aggregate_head)");
        let value = if grouped_heads.contains(head.as_name) {
            // Already fully formed by the generated transform — must not be wrapped again the
            // way an ordinary head's rows are.
            (def.group_by.expect("grouped_heads is only ever populated when def.group_by is Some"))(rows)?
        } else if many && def.count {
            Json::Num(rows.len() as f64)
        } else if many && def.median_field.is_some() {
            median(&rows, def.median_field.expect("checked by the branch guard"))
        } else if many {
            Json::Array(rows.into_iter().map(|(id, record)| repository::row_json(id, record)).collect())
        } else {
            rows.into_iter().next().map(|(id, record)| repository::row_json(id, record)).unwrap_or(Json::Null)
        };
        out.push((head.as_name.to_string(), value));
    }

    Ok(Json::Object(out))
}

/// The root head's own single row: find the one instance by id, `NotFound` if it isn't there.
/// Unlike every other head, the root is looked up directly rather than scanned-and-matched.
fn fetch_root(store: &impl AggregateScan, head: &ReadModelHead, reference_id: &str) -> Result<(String, Json), Refusal> {
    let entries = store
        .scan(head.aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", head.aggregate)))?;

    entries
        .into_iter()
        .find(|(id, _)| id == reference_id)
        .ok_or_else(|| {
            // Named by its bare bluebook name; `head.aggregate` is the domain-qualified one.
            let bare = head.aggregate.rsplit("::").next().unwrap_or(head.aggregate);
            Refusal::NotFound(
                NotFoundReadModelReferenceMissingArgs { aggregate: bare, offered: &format!("{reference_id:?}") }
                    .render_args(),
            )
        })
}

/// A non-root head's own rows: every instance of this head's aggregate whose reference field(s)
/// point back at a row already in `projected`, sorted by id ascending.
fn scan_matching(
    store: &impl AggregateScan,
    head: &ReadModelHead,
    projected: &[(&'static str, Vec<(String, Json)>)],
) -> Result<Vec<(String, Json)>, Refusal> {
    // The generator emits a head with no table only when it names a nested entity; that reads
    // as empty here, while the root still refuses in `fetch_root`.
    let Some(entries) = store.scan(head.aggregate) else {
        return Ok(Vec::new());
    };

    let mut matched: Vec<(String, Json)> = entries.into_iter().filter(|(_, record)| record_matches(record, head, projected)).collect();
    matched.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(matched)
}

/// Whether `record` holds one of its precomputed `reference_fields` pointing at a row already
/// in `projected`.
fn record_matches(record: &Json, head: &ReadModelHead, projected: &[(&'static str, Vec<(String, Json)>)]) -> bool {
    head.reference_fields.iter().any(|reference_field| {
        let Some(held_id) = record.get(reference_field.field).and_then(Json::as_str) else { return false };
        projected
            .iter()
            .any(|(aggregate, rows)| *aggregate == reference_field.target_aggregate && rows.iter().any(|(id, _)| id == held_id))
    })
}

/// One targeted head's own where/order_by/offset/limit. Where-filtering chains
/// `repository::filter_entries` per condition; order/limit reuse `query_ordering::apply`
/// rather than reimplementing the identity-sort/declared-order/limit logic a declared
/// aggregate query already needs.
fn apply_filtered_head_options(
    mut rows: Vec<(String, Json)>,
    filtered: &FilteredHead,
    args: &Json,
    store: &impl AggregateScan,
) -> Result<Vec<(String, Json)>, Refusal> {
    for condition in filtered.conditions {
        let want = match condition.value {
            QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
            QueryConditionValue::NumericLiteral(n) => Json::Num(n),
            QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
        };
        rows = repository::filter_entries(rows, condition.field, condition.comparator, &want);
    }

    rows = apply_reference_hops(rows, filtered.reference_hop_conditions, args, store)?;

    Ok(query_ordering::apply(rows, filtered.order_by.as_ref(), filtered.offset.as_ref(), filtered.limit.as_ref(), args))
}

/// Folds a `ReferenceHopCondition` chain: one query against the chain's final target picks
/// matching ids, then each earlier step's `in` filter narrows toward these rows. Shared by a
/// read model's eligible head and a declared query (`named_query::run_cross_domain`).
pub(super) fn apply_reference_hops(
    mut rows: Vec<(String, Json)>,
    hops: &[ReferenceHopCondition],
    args: &Json,
    store: &impl AggregateScan,
) -> Result<Vec<(String, Json)>, Refusal> {
    for hop in hops {
        let inner_want = match hop.inner_value {
            QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
            QueryConditionValue::NumericLiteral(n) => Json::Num(n),
            QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
        };
        let scan = |aggregate: &str| {
            store.scan(aggregate).ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {aggregate:?}")))
        };
        let ids_of = |entries: Vec<(String, Json)>| -> Vec<Json> { entries.into_iter().map(|(id, _)| Json::Str(id)).collect() };

        // The chain, first hop included: `(via_field, target_aggregate)` pairs, each via_field a
        // reference on the previous target.
        let chain: Vec<(&str, &str)> = std::iter::once((hop.via_field, hop.target_aggregate))
            .chain(hop.through.iter().map(|step| (step.via_field, step.target_aggregate)))
            .collect();

        // Inside out: the inner clause picks ids on the last target, and each earlier step keeps
        // the rows of its target whose next via_field points at one of them.
        let (_, last_target) = chain[chain.len() - 1];
        let mut ids = ids_of(repository::filter_entries(scan(last_target)?, hop.inner_field, hop.inner_comparator, &inner_want));
        for step in (1..chain.len()).rev() {
            let (via_field, _) = chain[step];
            let (_, source) = chain[step - 1];
            ids = ids_of(repository::filter_entries(scan(source)?, via_field, query_comparators::QueryComparator::In, &Json::Array(ids)));
        }

        rows = repository::filter_entries(rows, hop.via_field, query_comparators::QueryComparator::In, &Json::Array(ids));
    }
    Ok(rows)
}
