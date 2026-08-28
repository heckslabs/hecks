// HAND-WRITTEN, ONCE, GENERIC — the same "compile shapes, interpret
// behavior" split this kernel already holds every OTHER reaction/mutation/
// query table to (`PolicyRule`/orchestrate.rs, `QueryDef`/named_query.rs):
// a declared bluebook `report "X" do ... end` block (`IR::ReadModel` — the
// `read_model` construct; `report` is the language's own word for it, per
// `language/bluebook/syntax.bluebook`'s `was: "read_model"`) compiles down
// to a static `ReadModelDef` row (`rust/project/read_models.rb`'s own
// `read_model_def`/`emit_read_model_table`), and `run` below is the ONE
// hand-written interpreter every generated domain's own `READ_MODELS`
// table is walked through — never bespoke per-read-model Rust control flow.
//
// SCOPE: exactly the subset `rust/project/read_models.rb`'s own
// `read_model_skip_reason` admits — a ROOT aggregate fetched by its own
// reference id, plus one or more OTHER aggregate heads found by scanning
// and matching a reference attribute back to an already-projected
// root/sibling row, PLUS (as of 2026-08-11) a declared `where`/`order_by`/
// `limit` on the ONE eligible many-side head (`filtered_head`, below), PLUS
// (as of Phase 10, equivalence-gap plan) that same head's own `offset` too —
// `IR::ReadModel#to_h` now spells these four on the wire (`read_models.rb`'s
// own header has the history: it didn't used to). Still no `cursor`/
// `consistency`/`authorize`(TenantScope)/`nulls` beyond the
// default/`inspect_query` — real capabilities `Ports::Query::InMemory`/
// `TenantScope` implement that this generator still doesn't port, the SAME
// boundary `rust/project/queries.rb` already draws for a declared AGGREGATE
// query, applied consistently here (`read_models.rb`'s own header has the
// full argument). A declared read model outside that subset simply has no
// row in the generated table at all — `kernel/cli.rs`'s own STRING-shaped
// "query" step refuses it the same clean way an unrouted verb or an
// unrecognized named query already does, never silently wrong.
//
// GROUND TRUTH: `Runtime::ReadModelInterpreter#project`
// (lib/hecks/runtime/read_model_interpreter.rb) for the overall shape;
// `Ports::Query::InMemory.execute`/`Ports::Query::Ordering`/
// `QuerySpecification::Common::NullPolicy` (lib/hecks/ports/query/,
// lib/hecks/query_specification/common/null_policy.rb) for exactly
// what `apply_filtered_head_options` below ports — all read directly.
use super::{named_query, query_comparators, query_ordering, repository, AggregateScan, Json, QueryCondition, QueryConditionValue, Refusal, RefusalSite};

/// ONE `where` clause that HOPS through a reference (`account/status`,
/// the DSL's own `/` operator — `QuerySpecification::HopPath`'s own
/// header: "`.` walks fields inside this record, `/` crosses into
/// another one") on the eligible head's own aggregate — the structural
/// gap `query_comparators.rs`'s own header used to name. Ground truth:
/// `Runtime::ReferenceHop.fold` (lib/hecks/runtime/reference_hop.rb) —
/// a hop folds to a synthetic `via_field IN [ids]` clause, where `ids`
/// comes from running one ordinary query against the hop's TARGET
/// aggregate with the REST of the where clause. `run`'s own
/// `apply_filtered_head_options` below is a direct, single-hop port of
/// that fold: one `filter_entries` call against `target_aggregate` to
/// find matching ids (`inner_field`/`inner_comparator`/`inner_value`,
/// the exact same three-way shape an ordinary `QueryCondition` already
/// carries for its own ground truth's `rest` clause), then one more
/// `filter_entries` call, `QueryComparator::In`, against `via_field` on
/// the eligible head's own rows — which is exactly what `QueryComparator
/// ::In`'s own `members(want).any? { |m| m == to_s(held) }` already
/// computes for any other `in`-shaped condition, so no new comparison
/// logic is needed, only the two-query shape. SINGLE-HOP ONLY,
/// deliberately: `rust/project/queries.rb`'s own `query_hop_plan`
/// refuses (falls through to the ordinary "not generated yet" reason)
/// a chain naming more than one `/` — Ruby's own `HopPath` supports up
/// to `MAX_HOPS` (8), recursing hop-by-hop; porting that recursion is
/// real, separate follow-up work (the equivalence-gap plan's own D2),
/// not attempted here.
#[derive(Debug, Clone, Copy)]
pub struct ReferenceHopCondition {
    /// The eligible head's own Reference-typed attribute this hop
    /// crosses through — `Hop#attribute.name` (hop_path.rb), the SAME
    /// name `Runtime::ReferenceHop::fold`'s own synthetic `WhereClause
    /// .new(field: hop.attribute.name, op: "in", value: ids)` uses.
    pub via_field: &'static str,
    /// The hop's target aggregate, domain-qualified ("Banking::Account")
    /// the same way `ReferenceField::target_aggregate` already is —
    /// `AggregateScan::scan`'s own required prefix.
    pub target_aggregate: &'static str,
    /// The REST of the dotted/hopped field, resolved against the
    /// TARGET aggregate's own shape — `rest` in `ReferenceHop::fold`'s
    /// own `WhereClause.new(field: rest, op: clause.op, value: clause.
    /// value)`, the inner query this hop condition folds through.
    pub inner_field: &'static str,
    pub inner_comparator: query_comparators::QueryComparator,
    pub inner_value: QueryConditionValue,
}

/// ONE reference attribute on a NON-ROOT head's own aggregate — "this
/// aggregate carries a field named `field` that is `Reference<X>`, where
/// `target_aggregate` is `X`'s own bare `AggregateScan::scan` prefix
/// ("Domain::Aggregate")." Ground truth: `Runtime::ReadModelInterpreter#
/// reference_fields`, read directly — `aggregate.attributes.select {
/// attribute.reference? && attribute.type.target_name == target.to_s
/// }.map(&:name)` — baked in at codegen time
/// (`rust/project/read_models.rb`'s own `read_model_reference_fields`)
/// since this compiled kernel has no runtime attribute-type reflection the
/// way Ruby's own live `IR::Attribute` objects give the interpreter.
#[derive(Debug, Clone, Copy)]
pub struct ReferenceField {
    pub target_aggregate: &'static str,
    pub field: &'static str,
}

/// ONE declared `include` — a row of `IR::ReadModel#aggregate_heads`
/// (`{aggregate:, as:, many:}`), plus two facts precomputed at codegen
/// time rather than re-derived on every call: `is_root` (this head's own
/// `aggregate` equals the read model's declared `reference_to` target) and
/// `reference_fields` (see above — always empty for the root head, which
/// is never matched by reference at all; it's fetched directly by the
/// caller's own id argument).
#[derive(Debug, Clone, Copy)]
pub struct ReadModelHead {
    pub aggregate: &'static str,
    pub as_name: &'static str,
    pub many: bool,
    pub is_root: bool,
    pub reference_fields: &'static [ReferenceField],
}

/// A read model's own declared `order_by :field, :direction`, applying to
/// `ReadModelDef::filtered_head` alone — a plain alias, not a distinct
/// shape: this used to be its own hand-written struct (`queries.rb`'s own
/// header, at the time, said "declared-AGGREGATE-query codegen refuses
/// `order_by` outright, so there was nothing sort-shaped to reuse" — true
/// the day it was written), but the moment `named_query.rs` needed the
/// identical field/direction pair for a declared AGGREGATE query's own
/// `order_by` (2026-08-11), keeping two structurally-identical types
/// around would only invite the SAME drift `kernel/query_ordering.rs`'s
/// own extraction exists to prevent one level down, in the functions that
/// consume them. Ground truth: `QuerySpecification::Common::OrderBy`
/// (lib/hecks/query_specification/common/order_by.rb) — `field`/
/// `direction`, read directly; `query_ordering::OrderBy`'s own header has
/// the rest.
pub type ReadModelOrderBy = query_ordering::OrderBy;

/// A read model's own declared `limit N`, applying to `ReadModelDef::
/// filtered_head` alone — an alias for the same reason `ReadModelOrderBy`
/// just above is one now, not a distinct shape: `query_ordering::Limit`'s
/// own header has the full Literal/Arg argument (ground truth: `Ports::
/// Query::InMemory.execute`'s own `resolve(declared.limit.value,
/// args).to_i`, lib/hecks/ports/query/in_memory.rb).
pub type ReadModelLimit = query_ordering::Limit;

/// A read model's own declared `offset N`, applying to `ReadModelDef::
/// filtered_head` alone — same alias reasoning as `ReadModelLimit` just
/// above (`query_ordering::Offset` is itself `pub type Offset = Limit` —
/// see that module's own header): ground truth `Ports::Query::InMemory.
/// execute`'s own `matched.first(resolve(declared.limit.value, args).
/// to_i) if declared.limit` sits right after its own `skipped = declared.
/// offset ? matched.drop(...) : matched` — the SAME two-field shape a
/// declared AGGREGATE query already has (`named_query::QueryDef::offset`,
/// Phase 10 of the equivalence-gap plan), ported here the moment
/// `read_models.rb`'s own eligibility gate stopped refusing it.
pub type ReadModelOffset = query_ordering::Offset;

/// ONE declared `report "X" do ... end` block, compiled — the read-model
/// analogue of `named_query::QueryDef`. `verb` is the "Domain.Name" wire
/// string `kernel::cli.rs`'s STRING-form "query" step matches a read-model
/// ask against — see that file's own header for how it tells this shape
/// apart from a named/declared AGGREGATE query's "Domain::Aggregate.Name"
/// shape (the presence of "::" before the first "."). `reference_name` is
/// the wire ARGUMENT key a caller's own `args` must carry the root id
/// under (`IR::ReadModel#reference_name`; Ruby's own `args.fetch(model.
/// reference_name)`). `heads` is in DECLARED order — `run`'s own header
/// explains why the computation below needs a DIFFERENT order than this
/// array's own.
///
/// `filtered_head`/`conditions`/`order_by`/`limit` are the ONE eligible
/// many-side head's own where/order_by/limit — ground truth: `IR::
/// ReadModel#filtered_head_name` (lib/hecks/bluebook/ir/read_model.rb):
/// "ReadModelBuilder#seal_query_options already refuses ambiguity (zero or
/// several many-heads with options declared)... so any interpreter can ask
/// this directly rather than re-deriving or re-checking it" — this generator
/// trusts the same invariant, the same way `rust/project/read_models.rb`'s
/// own `read_model_filtered_head_as` does. `filtered_head` is `None`, and
/// `conditions` empty/`order_by`/`limit` both `None`, for a read model that
/// declares none of the three — the ordinary case, and the ONLY case before
/// 2026-08-11.
#[derive(Debug, Clone, Copy)]
pub struct ReadModelDef {
    pub verb: &'static str,
    /// `None` for a ROOTLESS read model (`ReadModelInterpreter#project`'s
    /// own `rootless = model.reference_target.nil?`) — no `reference_to`
    /// declared at all, so there is no caller-supplied id argument to
    /// require or resolve; every head reads its own aggregate's WHOLE
    /// table instead (see `run`'s own rootless branch, below).
    pub reference_name: Option<&'static str>,
    pub heads: &'static [ReadModelHead],
    pub filtered_head: Option<&'static str>,
    pub conditions: &'static [QueryCondition],
    /// `where` clauses that hop through a reference, on the SAME
    /// eligible head `conditions` above applies to — `&[]` for every
    /// read model before this field existed, and for every eligible
    /// head's own where clauses that stay local. See
    /// `ReferenceHopCondition`'s own header for the full ground truth.
    pub reference_hop_conditions: &'static [ReferenceHopCondition],
    pub order_by: Option<ReadModelOrderBy>,
    /// `None` for every read model before Phase 10 (equivalence-gap
    /// plan) ported this — `read_models.rb`'s own eligibility gate used
    /// to refuse ANY declared `offset` outright, unconditionally.
    pub offset: Option<ReadModelOffset>,
    pub limit: Option<ReadModelLimit>,
    /// `authorize policy, tenant: :field` — reuses `named_query::
    /// TenantAuth` directly (same struct, no read-model-local type):
    /// `Runtime::TenantScope.apply` is the SAME function for a Query and
    /// a ReadModel (`ReadModelInterpreter#project`'s own `model =
    /// TenantScope.apply(model, args)`, called BEFORE the eligible head's
    /// own conditions/order/limit are applied — matching `run`'s own call
    /// order below, right after `reference_id` resolves). `query_name`
    /// still reads correctly for a read model's own bare declared name
    /// (`IR::ReadModel#name`), the same field `RefusalSite::
    /// UnauthorizedTenantRequired`'s own `{query}` placeholder expects
    /// regardless of which construct declared it. No real corpus read
    /// model declares one yet — ported ahead of a real example existing,
    /// unlike every other Phase 10 item this session shipped, because the
    /// mechanism is otherwise byte-identical to the already-proven query
    /// path; verified against a purpose-built fixture instead (see the
    /// ADR).
    pub authorization: Option<named_query::TenantAuth>,
    /// `group_by :field, ...` — `ReadModelInterpreter#group_by_target`/
    /// `#nest`, read directly: nests the ONE many-side head's own rows,
    /// one level per declared field, unwrapping any single-attribute
    /// value object along the way (`Value.materialize_unwrapped`). This
    /// CANNOT be one more data-driven field the way `offset`/`order_by`
    /// already are — which field is "single-attribute" is a TYPE-LEVEL
    /// fact `run`'s own generic body has no access to once it's holding
    /// already-serialized `Json` — so it's a per-read-model GENERATED
    /// function instead (`rust/project/read_models.rb`'s own
    /// `emit_group_by_transform`), reusing the exact `sole_field_of`
    /// codegen-time type knowledge `bridging.rb` already has for `sets`/
    /// `append`. Applied to whichever head `group_by_target` names — the
    /// one `many`-side head this read model declares (`seal_group_by`'s
    /// own build-time check already refuses more than one).
    pub group_by: Option<fn(Vec<(String, Json)>) -> Json>,
    /// `count` — a bare marker, `true` when declared. UNLIKE `group_by`,
    /// this needs no per-read-model generated function at all: "how many
    /// rows" needs no type-level knowledge to compute, just the already-
    /// materialized, already-`where`/`order_by`/`limit`/`offset`-filtered
    /// row set the SAME `filtered_head`/`apply_filtered_head_options`
    /// machinery `ComplianceDashboard` already exercises today. Applied
    /// to the ONE `many`-side head (`seal_aggregation`'s own build-time
    /// check already refuses more than one, and refuses combining with
    /// `median_field`/`group_by`) — `run`'s own output loop finds it the
    /// same way the `group_by` branch already does, via `head.many`, not
    /// a separately-named target field.
    pub count: bool,
    /// `median :field` — the declared numeric field's own median across
    /// the same one `many`-side head. ALSO no per-read-model generated
    /// function: unlike `group_by`'s own recursive, multi-attribute,
    /// whole-row unwrap (genuinely type-directed), a median only ever
    /// unwraps ONE field, and `query_comparators::comparable` is already
    /// a fully generic, RUNTIME, structural VO-unwrap (numeric-member-
    /// wins-or-sole-member-wins) — the exact same one `where`/`order_by`
    /// already reuse for the identical purpose. `Runtime::
    /// ReadModelInterpreter#median`, ported directly in the `median`
    /// function below.
    pub median_field: Option<&'static str>,
}

/// The lookup `kernel/cli.rs`'s STRING-form "query" step dispatches
/// through for a read-model ask (a bare "Domain.Name" string, no "::") —
/// a linear scan over a generated domain's own `READ_MODELS` table, the
/// same shape `named_query::find` already uses for the SIBLING "Domain::
/// Aggregate.Name" shape.
///
/// R2 FIX (docs/audits/2026-08-11-bug-triage.md) — `ReadModelDef::verb`
/// (`rust/project/read_models.rb`'s own `read_model_def`) only ever spells
/// the read model's DECLARED name ("Banking.CustomerPortfolio"), that
/// file's own header explaining why: the ONE spelling this generator ever
/// needs to emit. But `Runtime::Chapter#read_model` — the ground truth,
/// `lib/hecks/bluebook/behaviour/chapter.rb` — accepts EITHER that spelling
/// OR the snake-cased one (`ReadModel#query_name`, `Naming.snake(@name)`),
/// and a real corpus caller uses the snake_case spelling for exactly this
/// read model (`spec/corpus/banking.json`'s own "Banking.customer_portfolio"
/// query step). A `def.verb == verb` exact match alone made this compiled
/// artifact refuse a read model Ruby answers for real — not a genuine
/// codegen gap (`rust/src/generated/banking/manifest.json` already marks
/// `Banking::CustomerPortfolio` `"generated": true`), just a narrower
/// accepted-spelling set than Ruby's own. `matches_snake_alias` below
/// closes it without touching codegen at all: still one row, one spelling
/// baked in, checked against both of the two spellings Ruby itself accepts.
/// `ReadModelInterpreter#nest`, ported directly — one level of nesting
/// per declared `group_by` field, in DECLARED order; the leaf is the row
/// with every grouped field already stripped, one per level, matching
/// Ruby's own `row.reject { |key, _| key == field }`. ASSUMES the full
/// `group_by` path uniquely identifies one row (Ruby's own comment, same
/// scope limit): `stripped.first`/`group.first` below silently keeps
/// only the first row when several share the same full key path.
///
/// This is HAND-WRITTEN ONCE, HERE — unlike the per-field unwrap
/// (`rust/project/read_models.rb`'s own `emit_group_by_transform`,
/// generated per read model because it needs codegen-time TYPE
/// knowledge), grouping-and-stripping is purely structural: it only
/// ever asks "does this JSON object have a field named X," never what
/// TYPE that field is. `Json`'s own `PartialEq` derive makes the group
/// key comparable directly, no per-type dispatch needed.
///
/// Grouping is a Vec-based linear scan, not a `HashMap`, for two real
/// reasons: `Json` has no `Hash` impl (a nested `Object`/`Array` key
/// isn't hashable the way a bare scalar is, and `group_by :field` can
/// name a VALUE OBJECT field before this transform's own unwrap step
/// ever simplifies it away), and Ruby's own `Hash#group_by` already
/// preserves first-occurrence order — a `HashMap` would need its own
/// separate order-tracking to match that, no simpler than this.
pub fn nest(rows: Vec<Json>, fields: &[&str]) -> Json {
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
    Json::Object(
        groups
            .into_iter()
            .map(|(key, group)| {
                let value = if rest.is_empty() { group.into_iter().next().unwrap_or(Json::Null) } else { nest(group, rest) };
                // `Hash#[]=` implicitly stringifies a non-String key the
                // moment it's used as a JSON object key — `query_
                // comparators::to_s` already does exactly Ruby's own
                // `.to_s` conversion, reused rather than duplicated.
                (super::query_comparators::to_s(&key), value)
            })
            .collect(),
    )
}

/// `Runtime::ReadModelInterpreter#median`, ported directly. THE STANDARD
/// DEFINITION: an ODD count's median is its one true middle value —
/// returned as `comparable` reduced it (whichever `Json` numeric variant
/// that was, `Num` or `Float`, exactly like Ruby's own `values[middle]`,
/// unconverted); an EVEN count's median is the AVERAGE of its two middle
/// values, ALWAYS `Json::Float` — Ruby's own `/2.0` forces float division
/// regardless of whether the two summed values were themselves Integers.
/// An EMPTY collection (every row's own field absent/null, or no rows at
/// all) has no median: `Json::Null`, not zero — a caller cannot mistake
/// "nothing to average" for "the values averaged to zero", matching
/// Ruby's own `nil`.
///
/// Reuses `query_comparators::comparable` — the same one-level VO-unwrap
/// `where`/`order_by` already give a value-object-carrying field, so
/// `median :amount` on an `Amount{cents}` field reads the same scalar an
/// `order_by :amount` comparison already would. `field` is always a bare,
/// top-level attribute name — `aggregation_skip_reason`'s own generator-
/// side check (`rust/project/read_models.rb`) already confirmed it names
/// a real, numeric attribute before this ever runs, the same way `Ruby`'s
/// own `aggregation_target` checks once, at read time, rather than this
/// function re-deriving or re-checking it per row.
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

pub fn find<'a>(table: &'a [ReadModelDef], verb: &str) -> Option<&'a ReadModelDef> {
    table.iter().find(|def| def.verb == verb || matches_snake_alias(def.verb, verb))
}

/// `declared_verb` is `def.verb`, "Domain.Name" (the read model's own
/// declared, PascalCase-or-whatever-was-written name); `asked` is the wire
/// string a caller actually sent. True when they name the same domain and
/// `asked`'s own name half is `declared_verb`'s own name half run through
/// `to_snake` — the compiled-in port of `Hecks::Naming.snake`, below.
fn matches_snake_alias(declared_verb: &str, asked: &str) -> bool {
    let Some((domain, name)) = declared_verb.split_once('.') else { return false };
    let Some((asked_domain, asked_name)) = asked.split_once('.') else { return false };

    domain == asked_domain && to_snake(name) == asked_name
}

/// A direct port of `Hecks::Naming.snake` (lib/hecks/naming.rb):
///
/// ```ruby
/// text.to_s
///     .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
///     .gsub(/([a-z\d])([A-Z])/, '\1_\2')
///     .downcase
/// ```
///
/// Both `gsub`s only ever insert an underscore at a CASE BOUNDARY; neither
/// one's own match consumes more than the two characters straddling that
/// boundary (the first pass leaves the run-of-uppercase's own LAST letter
/// glued to the lowercase word that follows it, same as the second pass's
/// single preceding lowercase/digit character), so both collapse into one
/// single left-to-right scan of adjacent-character pairs here: no
/// dependency exists between one inserted `_` and the NEXT character pair's
/// own decision, in either the Ruby original or this port, so running the
/// two passes' conditions as one pass changes nothing observable. No regex
/// engine in this dependency-free kernel (`rust/Cargo.toml` carries no
/// crate at all) — every declared read-model/query name this needs to
/// snake-case is plain ASCII, so `is_ascii_*` suffices.
fn to_snake(name: &str) -> String {
    let chars: Vec<char> = name.chars().collect();
    let mut out = String::with_capacity(name.len() + 4);

    for (i, &c) in chars.iter().enumerate() {
        if i > 0 {
            let prev = chars[i - 1];
            // Rule 1 (`([A-Z]+)([A-Z][a-z])`): the boundary between the
            // last two letters of a >=2 run of uppercase, when the second
            // of those two is itself followed by a lowercase letter —
            // "HTTPServer" splits before the "S" of "Server", not before
            // the "H" of "HTTP".
            let rule1 = prev.is_ascii_uppercase() && c.is_ascii_uppercase() && chars.get(i + 1).is_some_and(char::is_ascii_lowercase);
            // Rule 2 (`([a-z\d])([A-Z])`): a plain lowercase-or-digit to
            // uppercase boundary — "customerPortfolio" splits before "P".
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

    // Ground truth: `Hecks::Naming.snake` — every case here was checked
    // against the real Ruby method, not merely against this port of it.
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
            filtered_head: None,
            conditions: &[],
            reference_hop_conditions: &[],
            order_by: None,
            offset: None,
            limit: None,
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

/// D1 (`2.4` in the equivalence-gap plan) — `ReferenceHopCondition`'s own
/// fold, exercised end-to-end through `run` (not just the isolated
/// `apply_filtered_head_options` helper) so a wiring mistake at either
/// call site would fail this the same way it would fail a real caller.
/// The fixture mirrors the ONE real corpus hop today —
/// `Banking::Account.OpenForSuspendedCustomers`'s own `where(:"customer/
/// status" => "suspended")` (`examples/banking/bluebook/
/// deposit_accounts.bluebook`) — except as a READ MODEL's `filtered_head`
/// rather than a named query, since D2 (named queries) stays deferred; no
/// real corpus read model declares a hop yet, so this is the closest
/// analog available for a direct, isolated proof.
#[cfg(test)]
mod reference_hop_tests {
    use super::*;
    use crate::kernel::AggregateScan;

    /// Same `FakeStore` shape as `query_comparators.rs`'s own
    /// `none_in_state_tests` — `domain` plus `(bare aggregate name,
    /// entries)` pairs, searched the same domain-qualified way a real
    /// generated `Store::scan` is.
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

    /// A rootless read model — no `reference_to`, matching this fixture's
    /// own `Account.OpenForSuspendedCustomers` analog, itself a bare
    /// (non-reference-scoped) named query — with ONE `many` head
    /// (`Account`) carrying both an ordinary local condition (`status ==
    /// "open"`) and one hop condition (`customer/status == "suspended"`).
    fn open_for_suspended_customers_def() -> ReadModelDef {
        ReadModelDef {
            verb: "Banking.OpenForSuspendedCustomers",
            reference_name: None,
            heads: &[ReadModelHead { aggregate: "Banking::Account", as_name: "accounts", many: true, is_root: false, reference_fields: &[] }],
            filtered_head: Some("accounts"),
            conditions: &[QueryCondition { field: "status", comparator: query_comparators::QueryComparator::Eq, value: QueryConditionValue::Literal("open") }],
            reference_hop_conditions: &[ReferenceHopCondition {
                via_field: "customer",
                target_aggregate: "Banking::Customer",
                inner_field: "status",
                inner_comparator: query_comparators::QueryComparator::Eq,
                inner_value: QueryConditionValue::Literal("suspended"),
            }],
            order_by: None,
            offset: None,
            limit: None,
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

        // Open AND belongs to a suspended customer — the only row that
        // survives BOTH the ordinary local condition and the hop.
        assert_eq!(ids, vec!["acc-suspended-open"]);
        // Not excluded here as a redundant assertion — spelled out so a
        // regression that accidentally widens either condition (e.g. the
        // hop silently degrading to "any status") fails loudly on the
        // SPECIFIC wrong row it would wrongly admit, not just a count.
        assert!(!ids.contains(&"acc-active-open"), "open but NOT suspended — the hop condition alone should have excluded this");
        assert!(!ids.contains(&"acc-suspended-closed"), "suspended customer but NOT open — the ordinary local condition alone should have excluded this");
    }

    #[test]
    fn a_hop_against_an_unscannable_target_aggregate_refuses_cleanly() {
        let mut def = open_for_suspended_customers_def();
        def.reference_hop_conditions = &[ReferenceHopCondition {
            via_field: "customer",
            target_aggregate: "Banking::NoSuchAggregate",
            inner_field: "status",
            inner_comparator: query_comparators::QueryComparator::Eq,
            inner_value: QueryConditionValue::Literal("suspended"),
        }];

        let err = run(&store(), &def, &Json::obj(vec![])).expect_err("scanning an aggregate this store doesn't declare must refuse, not silently answer empty");
        assert!(matches!(err, Refusal::TypeMismatch(_)));
    }
}

/// THE GENERIC INTERPRETER — `Runtime::ReadModelInterpreter#project`,
/// ported directly, for exactly the subset this module's own header
/// describes. Returns the SINGLE projected row (a JSON object, one entry
/// per declared head's own `as_name`) — never an array; `kernel/cli.rs`'s
/// own caller wraps it in a one-element `Json::Array`, matching Ruby's own
/// `[heads.transform_values { ... }]` return shape (an array of exactly
/// one hash — one root instance in, one grouped row out, always).
///
/// ROOT-FIRST COMPUTATION, DECLARED-ORDER OUTPUT — load-bearing, not a
/// style choice, and not this kernel's own invention: it is `Runtime::
/// ReadModelInterpreter#project`'s own documented correctness property
/// (a newer `read_model_interpreter.rb` than this branch otherwise
/// carries states it in so many words: "ROOT FIRST, ALWAYS — regardless
/// of `include` order in the bluebook... this loop used to run heads in
/// their literal declared order and match each 'many' head against
/// whatever was ALREADY in `projected` — empty, the very first time
/// through, if a many-side head happened to be declared before the root.
/// A real, live bug (not a guess)... silently returned an empty array...
/// no error, just a wrong, too-small answer"). Every non-root head is
/// matched against whichever OTHER heads are already computed at the
/// moment it's processed (`projected`, below) — so a many-side head
/// processed before its own root would always compare against an EMPTY
/// `projected` and come back wrong regardless of what this kernel does,
/// unless the root is guaranteed to go first. Partitioning `def.heads`
/// into root-first for COMPUTATION — while walking `def.heads` in its own
/// original array order for the OUTPUT below — closes that regardless of
/// what order a bluebook author happened to write `include`s in, mirroring
/// Ruby's own `root_heads, other_heads = model.aggregate_heads.partition
/// { ... }` / `(root_heads + other_heads).each` exactly. For every real
/// corpus read model this generator admits, the root already IS the first
/// `include` (so this reordering is a no-op in practice today) — but
/// computing it for real, rather than trusting declared order to always
/// happen to be right, is what makes THAT a fact about today's corpus, not
/// a silent assumption this interpreter depends on.
pub fn run(store: &impl AggregateScan, def: &ReadModelDef, args: &Json) -> Result<Json, Refusal> {
    let reference_id = match def.reference_name {
        Some(name) => Some(
            args.get(name)
                .and_then(Json::as_str)
                .ok_or_else(|| Refusal::TypeMismatch(format!("{}: missing reference argument {name:?}", def.verb)))?
                .to_string(),
        ),
        // ROOTLESS (`ReadModelInterpreter#project`'s own `rootless =
        // model.reference_target.nil?`) — no caller-supplied id to
        // require or resolve at all.
        None => None,
    };

    // Same check, same position (right after the reference id resolves,
    // before any head is computed), as `ReadModelInterpreter#project`'s
    // own `model = TenantScope.apply(model, args)` — see `named_query::
    // run_cross_domain`'s own identical check for the full reasoning.
    if let Some(auth) = &def.authorization {
        if args.get(auth.tenant_field).is_none() {
            return Err(Refusal::Unauthorized(RefusalSite::UnauthorizedTenantRequired.render(&[
                ("query", auth.query_name),
                ("field", auth.tenant_field),
            ])));
        }
    }

    let (root_heads, other_heads): (Vec<&ReadModelHead>, Vec<&ReadModelHead>) = def.heads.iter().partition(|head| head.is_root);

    // One entry per head ALREADY computed, in COMPUTATION order
    // (root-first) — exactly Ruby's own `projected`, read the same way:
    // every candidate record is checked against EVERY entry seen so far,
    // never just the immediately-preceding one.
    let mut projected: Vec<(&'static str, Vec<(String, Json)>)> = Vec::new();
    let mut rows_by_as: std::collections::HashMap<&'static str, (bool, Vec<(String, Json)>)> = std::collections::HashMap::new();
    let mut grouped_heads: std::collections::HashSet<&'static str> = std::collections::HashSet::new();

    for head in root_heads.into_iter().chain(other_heads) {
        let mut rows = if reference_id.is_none() {
            // ROOTLESS — `ReadModelInterpreter#project`'s own `elsif
            // rootless ... records(bluebook, domain, head[:aggregate])`:
            // each head reads its own aggregate's WHOLE table,
            // independently — no cross-referencing against `projected`
            // at all (`is_root` is meaningless here; a rootless model
            // declares no reference_to target for any head to equal).
            store.scan(head.aggregate).ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", head.aggregate)))?
        } else if head.is_root {
            vec![fetch_root(store, head, reference_id.as_deref().unwrap())?]
        } else {
            scan_matching(store, head, &projected)?
        };

        // `Ports::Query::InMemory.execute(rows, model, args) if head[:as] ==
        // eligible`, ported directly — applied BEFORE this head's rows go
        // into `projected`, so any LATER head's own reference-matching sees
        // the FILTERED rows, exactly like Ruby's own `projected << { ...,
        // rows: rows }` (assigned to the post-`execute` `rows`, not the
        // pre-filter scan). The root is never `filtered_head` — options only
        // ever apply to a many-side head (`seal_query_options`) — so this
        // never fires before `reference_id` above has already resolved it.
        if def.filtered_head == Some(head.as_name) {
            rows = apply_filtered_head_options(rows, def, args, store)?;
        }

        // `group_by :field, ...` — applies to the ONE many-side head this
        // read model declares (`ReadModelInterpreter#group_by_target`'s
        // own `target = model.aggregate_heads.find { |head| head[:many] }`
        // — `seal_group_by`'s build-time check already refuses more than
        // one many-side head existing at all when `group_by` is
        // declared, so "the first `many` head" and "the only eligible
        // one" are the same fact). Recorded in `grouped_heads` — the
        // generated transform does its OWN `row_json`-equivalent
        // wrapping internally (matching Ruby's own `row(record) =
        // record.to_h`), so the output loop below must NOT wrap it
        // again, unlike an ordinary head's own rows.
        if def.group_by.is_some() && head.many {
            grouped_heads.insert(head.as_name);
        }

        projected.push((head.aggregate, rows.clone()));
        rows_by_as.insert(head.as_name, (head.many, rows));
    }

    // DECLARED order, for the OUTPUT ONLY — `def.heads` itself, not the
    // root-first order `projected`/`rows_by_as` were just built in.
    //
    // `repository::row_json` wraps EVERY record here, at every level of
    // nesting — the root row AND every reference-matched sibling row —
    // matching Ruby's own `Value.materialize(row(record))`, where `row`
    // is plain `record.to_h` and a live Ruby aggregate record's `to_h`
    // already carries `id` alongside every other attribute. This
    // kernel's own generated `to_json()` does not (see `row_json`'s own
    // header in repository.rs), so it has to be added back explicitly
    // here — unlike a named query or an ad hoc filter, whose OWN row_json
    // wrapping only ever needs to happen once, at the single top-level
    // row `kernel/cli.rs` builds, a read model's own answer nests a
    // record at every head, so the wrapping has to happen at every head
    // too.
    let mut out = Vec::with_capacity(def.heads.len());
    for head in def.heads {
        let (many, rows) = rows_by_as
            .remove(head.as_name)
            .expect("every head in def.heads was computed in the loop above — as_name is unique per read model (ReadModelBuilder#add_aggregate_head)");
        let value = if grouped_heads.contains(head.as_name) {
            // Already fully formed by the generated transform (its own
            // `row_json`-equivalent wrapping done internally) — must NOT
            // be wrapped again the way an ordinary head's rows are.
            (def.group_by.expect("grouped_heads is only ever populated when def.group_by is Some"))(rows)
        } else if many && def.count {
            // `value.length`, ported directly — `rows` here is already
            // the SAME post-`apply_filtered_head_options` set `group_by`
            // would nest, or (when no where/order_by/limit/offset is
            // declared alongside `count` at all) the plain scan-matched
            // set — either way, exactly the rows `seal_aggregation`
            // guarantees this is the one eligible `many`-side head for.
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

/// The root head's own single row — `ReadModelInterpreter#fetch`, ported
/// directly: find the one instance by id, `NotFound` if it isn't there.
/// Unlike every other head, the root is never scanned-and-matched; it's
/// looked up directly by the caller's own reference argument.
fn fetch_root(store: &impl AggregateScan, head: &ReadModelHead, reference_id: &str) -> Result<(String, Json), Refusal> {
    let entries = store
        .scan(head.aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", head.aggregate)))?;

    entries
        .into_iter()
        .find(|(id, _)| id == reference_id)
        .ok_or_else(|| Refusal::NotFound(format!("no {} with id {reference_id:?}", head.aggregate)))
}

/// A NON-ROOT head's own rows — `ReadModelInterpreter#matching`, ported
/// directly: every instance of this head's own aggregate whose reference
/// field(s) point back at a row ALREADY in `projected`, sorted by id
/// ascending (Ruby's own `matching(records) { ... }.sort_by(&:id)`).
fn scan_matching(
    store: &impl AggregateScan,
    head: &ReadModelHead,
    projected: &[(&'static str, Vec<(String, Json)>)],
) -> Result<Vec<(String, Json)>, Refusal> {
    let entries = store
        .scan(head.aggregate)
        .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", head.aggregate)))?;

    let mut matched: Vec<(String, Json)> = entries.into_iter().filter(|(_, record)| record_matches(record, head, projected)).collect();
    matched.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(matched)
}

/// `projected.any? { |source| reference_fields(...).any? { |field|
/// source[:rows].any? { |parent| reference(record[field]) == parent.id }
/// } }`, ported directly — reorganized to iterate this HEAD's own
/// (precomputed) `reference_fields` on the outside and `projected` on the
/// inside, rather than Ruby's own outside-in order, which changes nothing
/// observable: both are a plain existential over the same "does some
/// (field, already-projected source) pair match" question, so which side
/// is the outer loop only affects short-circuit order, never the answer.
fn record_matches(record: &Json, head: &ReadModelHead, projected: &[(&'static str, Vec<(String, Json)>)]) -> bool {
    head.reference_fields.iter().any(|reference_field| {
        let Some(held_id) = record.get(reference_field.field).and_then(Json::as_str) else { return false };
        projected
            .iter()
            .any(|(aggregate, rows)| *aggregate == reference_field.target_aggregate && rows.iter().any(|(id, _)| id == held_id))
    })
}

/// THE ELIGIBLE HEAD'S OWN where/order_by/offset/limit — `Ports::Query::
/// InMemory.execute`, ported for exactly the subset `read_models.rb`'s own
/// eligibility gate admits. Where-
/// filtering reuses `repository::filter_entries` chained per condition —
/// exactly `named_query::run`'s own AND, never reimplemented. Order/limit
/// are `query_ordering::apply` (kernel/query_ordering.rs) — EXTRACTED from
/// this very function (2026-08-11), not reused from anywhere new: this
/// module's identity-sort/declared-order/limit tail used to live here
/// directly, until `named_query.rs` needed the identical logic for a
/// declared AGGREGATE query's own `order_by`/`limit` and duplicating it a
/// second time would have been exactly the drift this whole codebase's
/// "compile shapes, interpret behavior" split exists to avoid. See that
/// module's own header for the full ground-truth citation and the one
/// real structural difference between this caller and `named_query::run`
/// (a read model's `filtered_head` selection, which happens ABOVE this
/// function, in `run`, not inside it).
fn apply_filtered_head_options(
    mut rows: Vec<(String, Json)>,
    def: &ReadModelDef,
    args: &Json,
    store: &impl AggregateScan,
) -> Result<Vec<(String, Json)>, Refusal> {
    for condition in def.conditions {
        let want = match condition.value {
            QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
            QueryConditionValue::NumericLiteral(n) => Json::Num(n),
            QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
        };
        rows = repository::filter_entries(rows, condition.field, condition.comparator, &want);
    }

    // `Runtime::ReferenceHop::fold`, ported directly — see
    // `ReferenceHopCondition`'s own header for the full ground truth.
    // ONE ordinary query against the hop's own target aggregate (the
    // inner clause), folded into ONE more ordinary `in` filter against
    // this head's own rows (the outer clause) — the exact two-step shape
    // Ruby's own `fold`/`matching_ids` already use, just without the
    // recursion a multi-hop chain would need (single-hop only, this
    // struct's own header has the reasoning).
    for hop in def.reference_hop_conditions {
        let inner_want = match hop.inner_value {
            QueryConditionValue::Literal(text) => Json::Str(text.to_string()),
            QueryConditionValue::NumericLiteral(n) => Json::Num(n),
            QueryConditionValue::Arg(name) => args.get(name).cloned().unwrap_or(Json::Null),
        };
        let target_rows = store
            .scan(hop.target_aggregate)
            .ok_or_else(|| Refusal::TypeMismatch(format!("unknown aggregate {:?}", hop.target_aggregate)))?;
        let matching = repository::filter_entries(target_rows, hop.inner_field, hop.inner_comparator, &inner_want);
        let ids: Vec<Json> = matching.into_iter().map(|(id, _)| Json::Str(id)).collect();
        rows = repository::filter_entries(rows, hop.via_field, query_comparators::QueryComparator::In, &Json::Array(ids));
    }

    Ok(query_ordering::apply(rows, def.order_by.as_ref(), def.offset.as_ref(), def.limit.as_ref(), args))
}
