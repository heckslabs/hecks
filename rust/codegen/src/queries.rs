//! Port of the retired Ruby generator's `queries.rb`, mirrored function for function.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::literal::{self, Literal};
use crate::naming;
use crate::skip_reason::{reskip, skip, SkipReason};
use std::collections::HashMap;

const COMPARATORS_NEEDING_NUMERIC_FIDELITY: &[&str] = &["gt", "gte", "lt", "lte"];
const COMPARATORS_EXEMPT_FROM_LITERAL_TYPING: &[&str] = &["in", "contains"];

#[derive(PartialEq, Eq, Clone, Copy, Debug)]
pub enum FieldKind {
    String,
    Number,
    Other,
    Unknown,
}

/// Classifies `field`: its head names an attribute or the lifecycle field, and any
/// later segments walk nested value objects.
pub fn query_field_kind(aggregate: &Json, field: &str, value_objects_by_name: &HashMap<String, &Json>) -> FieldKind {
    let mut segments = field.split('.');
    let head = segments.next().unwrap_or("");
    let rest: Vec<&str> = segments.collect();

    let lifecycle_field = aggregate.get("lifecycle").and_then(|l| l.get("field")).map(Json::to_s);
    if let Some(lf) = &lifecycle_field {
        if lf == head {
            return if rest.is_empty() { FieldKind::String } else { FieldKind::Unknown };
        }
    }

    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let Some(attr) = attrs.iter().find(|a| crate::attr::name(a) == head) else { return FieldKind::Unknown };
    if crate::attr::list(attr) {
        return FieldKind::Other;
    }

    query_type_kind(crate::attr::type_name(attr), &rest, value_objects_by_name)
}

fn query_type_kind(type_name: &str, segments: &[&str], value_objects_by_name: &HashMap<String, &Json>) -> FieldKind {
    if naming::reference_type(type_name) {
        return if segments.is_empty() { FieldKind::String } else { FieldKind::Unknown };
    }

    if segments.is_empty() {
        return query_scalar_or_vo_kind(type_name, value_objects_by_name);
    }

    let Some(vo) = value_objects_by_name.get(type_name) else { return FieldKind::Unknown };
    let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    let Some(member) = attrs.iter().find(|a| crate::attr::name(a) == segments[0]) else { return FieldKind::Unknown };
    if crate::attr::list(member) {
        return FieldKind::Unknown;
    }
    query_type_kind(crate::attr::type_name(member), &segments[1..], value_objects_by_name)
}

fn query_scalar_or_vo_kind(type_name: &str, value_objects_by_name: &HashMap<String, &Json>) -> FieldKind {
    match type_name {
        "String" => FieldKind::String,
        "Integer" | "Float" => FieldKind::Number,
        "TrueClass" | "FalseClass" => FieldKind::Other,
        _ => match value_objects_by_name.get(type_name) {
            Some(vo) => query_vo_collapse_kind(vo, value_objects_by_name),
            None => FieldKind::Unknown,
        },
    }
}

fn query_vo_collapse_kind(vo: &Json, value_objects_by_name: &HashMap<String, &Json>) -> FieldKind {
    let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    if attrs.iter().any(|a| matches!(crate::attr::type_name(a), "Integer" | "Float")) {
        return FieldKind::Number;
    }
    if attrs.len() == 1 {
        return query_type_kind(crate::attr::type_name(&attrs[0]), &[], value_objects_by_name);
    }
    FieldKind::Other
}

/// Whether a field (or dotted path) reduces specifically to a `TrueClass`/`FalseClass` —
/// `any`/`all` need this, distinct from `query_field_kind`'s coarser `Other` bucket (ADR 0078).
pub fn query_field_boolean(aggregate: &Json, field: &str, value_objects_by_name: &HashMap<String, &Json>) -> bool {
    let mut segments = field.split('.');
    let head = segments.next().unwrap_or("");
    let rest: Vec<&str> = segments.collect();

    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let Some(attr) = attrs.iter().find(|a| crate::attr::name(a) == head) else { return false };
    if crate::attr::list(attr) {
        return false;
    }
    query_type_boolean(crate::attr::type_name(attr), &rest, value_objects_by_name)
}

fn query_type_boolean(type_name: &str, segments: &[&str], value_objects_by_name: &HashMap<String, &Json>) -> bool {
    if segments.is_empty() {
        if matches!(type_name, "TrueClass" | "FalseClass") {
            return true;
        }
        if naming::reference_type(type_name) {
            return false;
        }
        let Some(vo) = value_objects_by_name.get(type_name) else { return false };
        let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
        if attrs.len() == 1 {
            return query_type_boolean(crate::attr::type_name(&attrs[0]), &[], value_objects_by_name);
        }
        false
    } else {
        let Some(vo) = value_objects_by_name.get(type_name) else { return false };
        let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
        let Some(member) = attrs.iter().find(|a| crate::attr::name(a) == segments[0]) else { return false };
        if crate::attr::list(member) {
            return false;
        }
        query_type_boolean(crate::attr::type_name(member), &segments[1..], value_objects_by_name)
    }
}

/// The winning member's own type name for a numeric field ("the sole numeric member wins",
/// mirroring `query_vo_collapse_kind`) — "Integer" or "Float" distinctly, where
/// `query_field_kind`'s own `Number` collapses both. `sum`/`avg` need the distinction
/// (ADR 0078).
pub fn query_field_numeric_type(aggregate: &Json, field: &str, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    let mut segments = field.split('.');
    let head = segments.next().unwrap_or("");
    let rest: Vec<&str> = segments.collect();

    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let attr = attrs.iter().find(|a| crate::attr::name(a) == head)?;
    if crate::attr::list(attr) {
        return None;
    }
    query_type_numeric_type(crate::attr::type_name(attr), &rest, value_objects_by_name)
}

fn query_type_numeric_type(type_name: &str, segments: &[&str], value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    if segments.is_empty() {
        if matches!(type_name, "Integer" | "Float") {
            return Some(type_name.to_string());
        }
        if naming::reference_type(type_name) {
            return None;
        }
        let vo = value_objects_by_name.get(type_name)?;
        let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
        if let Some(numeric_member) = attrs.iter().find(|a| matches!(crate::attr::type_name(a), "Integer" | "Float")) {
            return Some(crate::attr::type_name(numeric_member).to_string());
        }
        if attrs.len() == 1 {
            return query_type_numeric_type(crate::attr::type_name(&attrs[0]), &[], value_objects_by_name);
        }
        None
    } else {
        let vo = value_objects_by_name.get(type_name)?;
        let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
        let member = attrs.iter().find(|a| crate::attr::name(a) == segments[0])?;
        if crate::attr::list(member) {
            return None;
        }
        query_type_numeric_type(crate::attr::type_name(member), &segments[1..], value_objects_by_name)
    }
}

pub fn query_where_skip_reason(where_clause: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<SkipReason> {
    let field = where_clause.get("field").map(Json::to_s).unwrap_or_default();
    let kind = query_field_kind(aggregate, &field, value_objects_by_name);
    if kind == FieldKind::Unknown {
        let construct = if field.contains('/') { "reference_hop_where" } else { "where_unrecognized_field" };
        return Some(skip(
            construct,
            format!(
                "where clause on {} isn't a recognized attribute of this aggregate — a hop through a reference, an entity-scoped field, or simply undeclared here; cross-aggregate joins are read_model territory, not this generator's job",
                naming::ruby_inspect_string(&field)
            ),
        ));
    }

    let raw_value = where_clause.get("value").map(Json::to_s).unwrap_or_default();
    if raw_value.starts_with(':') {
        return None;
    }

    let op = where_clause.get("op").map(Json::to_s).unwrap_or_default();
    if !known_query_comparator(&op) {
        return Some(skip(
            "where_none_in_state",
            format!(
                "where clause on {} uses op {} — Vocabulary::QueryComparator admits it, and rust/src/kernel/query_comparators.rs's own QueryComparator::NoneInState variant now exists and is proven correct (item #9, whole-project table-unification survey) — but no generated domain has any way to hand it a cross-domain search list at the call site (named_query::run's own thin `run_cross_domain([])` wrapper is what every generated QUERIES table actually calls), so generating this condition today would silently answer every row 'true' rather than a real anti-join — deliberately left ungenerated until a real cross-domain-search call site exists, the same honest-refusal-over-silently-wrong choice this generator makes everywhere else",
                naming::ruby_inspect_string(&field),
                naming::ruby_inspect_string(&op)
            ),
        ));
    }
    if COMPARATORS_NEEDING_NUMERIC_FIDELITY.contains(&op.as_str()) {
        if kind == FieldKind::Number {
            return None;
        }
        return Some(skip(
            "where_literal",
            format!(
                "where clause on {} uses op {} against a LITERAL value whose target field doesn't reduce to a plain JSON number (kind: {}) — gt/gte/lt/lte only mean anything against a number (query_comparators.rs's own `ordered?` gate)",
                naming::ruby_inspect_string(&field),
                naming::ruby_inspect_string(&op),
                kind_name(kind)
            ),
        ));
    }
    if COMPARATORS_EXEMPT_FROM_LITERAL_TYPING.contains(&op.as_str()) {
        return None;
    }
    if kind == FieldKind::String {
        return None;
    }
    if kind == FieldKind::Number {
        return None;
    }

    Some(skip(
        "where_literal",
        format!(
            "where clause on {} uses op {} against a LITERAL value whose target field doesn't reduce to a plain JSON string (kind: {}) — its true wire type can't be recovered from the exported IR",
            naming::ruby_inspect_string(&field),
            naming::ruby_inspect_string(&op),
            kind_name(kind)
        ),
    ))
}

fn kind_name(kind: FieldKind) -> &'static str {
    match kind {
        FieldKind::String => "string",
        FieldKind::Number => "number",
        FieldKind::Other => "other",
        FieldKind::Unknown => "unknown",
    }
}

/// A `/` hop chain through Reference-typed attributes to aggregates this domain declares.
pub struct HopPlan<'a> {
    pub via_field: String,
    pub target_aggregate: String,
    /// Further `(via_field, bare target aggregate)` steps of a chain.
    pub through: Vec<(String, String)>,
    pub target: &'a Json,
    pub inner_field: String,
}

// Matches `HopPath::MAX_HOPS`.
const HOP_CHAIN_LIMIT: usize = 8;

pub fn query_hop_plan<'a>(aggregate: &'a Json, field: &str, aggregates_by_name: &HashMap<String, &'a Json>) -> Option<HopPlan<'a>> {
    let segments: Vec<&str> = field.split('/').collect();
    if segments.len() < 2 || segments.len() - 1 > HOP_CHAIN_LIMIT {
        return None;
    }
    let mut steps: Vec<(String, String)> = Vec::new();
    let mut current: &'a Json = aggregate;
    for segment in &segments[..segments.len() - 1] {
        let via = current.get("attributes").map(Json::each).unwrap_or(&[]).iter().find(|a| crate::attr::name(a) == *segment)?;
        let type_name = crate::attr::type_name(via);
        if !naming::reference_type(type_name) {
            return None;
        }
        let target_name = naming::reference_target(type_name)?;
        let target = *aggregates_by_name.get(target_name)?;
        steps.push((segment.to_string(), target_name.to_string()));
        current = target;
    }
    let (via_field, target_aggregate) = steps.remove(0);
    Some(HopPlan { via_field, target_aggregate, through: steps, target: current, inner_field: segments[segments.len() - 1].to_string() })
}

pub fn with_field(where_clause: &Json, field: &str) -> Json {
    match where_clause {
        Json::Object(pairs) => Json::Object(
            pairs
                .iter()
                .map(|(key, value)| if key == "field" { (key.clone(), Json::String(field.to_string())) } else { (key.clone(), value.clone()) })
                .collect(),
        ),
        other => other.clone(),
    }
}

pub fn value_objects_of(aggregate: &Json) -> HashMap<String, &Json> {
    aggregate
        .get("value_objects")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|vo| (vo.get("name").and_then(Json::as_str).unwrap_or("").to_string(), vo))
        .collect()
}

pub fn query_skip_reason(query: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>, aggregates_by_name: &HashMap<String, &Json>) -> Option<SkipReason> {
    let extra_keys = ["cursor", "consistency", "freshness", "inspection"];
    let extras: Vec<&str> = extra_keys.iter().filter(|k| query.get(k).is_some()).copied().collect();
    if !extras.is_empty() {
        return Some(skip(extras[0], format!("declares {} — out of scope for this generator (rust/codegen/src/queries.rs's own header has the full argument)", extras.join(", "))));
    }
    if query.get("index_hints").map(Json::each).unwrap_or(&[]).iter().any(|_| true) {
        return Some(skip("index_hints", "declares use_index, out of scope for the same reason the extras above are"));
    }

    // A declared tenant synthesizes its own where clause (`query_conditions_with_authorization`),
    // so a query with no ordinary wheres but a tenant gate is still generable. The tenant
    // field itself is validated afterward by `declared_authorization_skip_reason`.
    let declared_tenant = query.get("authorization").and_then(|a| a.get("tenant")).is_some();
    let wheres = query.get("wheres").map(Json::each).unwrap_or(&[]);
    if wheres.is_empty() && !declared_tenant {
        return Some(skip("no_wheres", "declares no where clauses at all — nothing for filter_entries to bake in"));
    }

    for where_clause in wheres {
        let field = where_clause.get("field").map(Json::to_s).unwrap_or_default();
        if let Some(plan) = query_hop_plan(aggregate, &field, aggregates_by_name) {
            let target_value_objects_by_name = value_objects_of(plan.target);
            if let Some(reason) = query_where_skip_reason(&with_field(where_clause, &plan.inner_field), plan.target, &target_value_objects_by_name) {
                return Some(reskip(&reason, format!("hop through {} to {}'s own {reason}", plan.via_field, plan.target_aggregate)));
            }
            continue;
        }
        if let Some(reason) = query_where_skip_reason(where_clause, aggregate, value_objects_by_name) {
            return Some(reason);
        }
    }

    if let Some(reason) = declared_authorization_skip_reason(query.get("authorization"), aggregate, value_objects_by_name) {
        return Some(reason);
    }

    if let Some(reason) = declared_order_by_skip_reason(query.get("order_by"), aggregate, value_objects_by_name) {
        return Some(reason);
    }

    if let Some(reason) = declared_offset_skip_reason(query.get("offset")) {
        return Some(reason);
    }

    declared_limit_skip_reason(query.get("limit"))
}

pub fn declared_order_by_skip_reason(order_by: Option<&Json>, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<SkipReason> {
    let order_by = order_by?;
    let field = order_by.get("field").map(Json::to_s).unwrap_or_default();
    let kind = query_field_kind(aggregate, &field, value_objects_by_name);
    if matches!(kind, FieldKind::String | FieldKind::Number) {
        return None;
    }

    Some(skip(
        "order_by",
        format!(
            "declares order_by on {} — this generator can only sort a field that reduces to a plain JSON string or number (kind: {}); a hop through a reference, an entity-scoped field, a list_of field, or a multi-member non-numeric value object can't be compared generically",
            naming::ruby_inspect_string(&field),
            kind_name(kind)
        ),
    ))
}

pub fn declared_limit_skip_reason(limit: Option<&Json>) -> Option<SkipReason> {
    let limit = limit?;
    let raw = limit.get("value").map(Json::to_s).unwrap_or_default();
    if raw.starts_with(':') || is_plain_integer(&raw) {
        return None;
    }

    Some(skip("limit", format!("declares limit {} — not a literal integer or a caller-bound Symbol arg, so this generator can't compile a real limit count from it", naming::ruby_inspect_string(&raw))))
}

// Same check as `declared_limit_skip_reason`, kept separate so the reason names "offset".
pub fn declared_offset_skip_reason(offset: Option<&Json>) -> Option<SkipReason> {
    let offset = offset?;
    let raw = offset.get("value").map(Json::to_s).unwrap_or_default();
    if raw.starts_with(':') || is_plain_integer(&raw) {
        return None;
    }

    Some(skip("offset", format!("declares offset {} — not a literal integer or a caller-bound Symbol arg, so this generator can't compile a real offset count from it", naming::ruby_inspect_string(&raw))))
}

fn is_plain_integer(raw: &str) -> bool {
    let s = raw.strip_prefix('-').unwrap_or(raw);
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

// A `nil` tenant is a no-op, never disqualifying. A real tenant is checked by running a
// synthetic arg-bound where through `query_where_skip_reason`.
pub fn declared_authorization_skip_reason(authorization: Option<&Json>, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<SkipReason> {
    let tenant = authorization.and_then(|a| a.get("tenant")).map(Json::to_s)?;
    let synthetic_where = Json::Object(vec![
        ("field".to_string(), Json::String(tenant.clone())),
        ("op".to_string(), Json::String("eq".to_string())),
        ("value".to_string(), Json::String(format!(":{tenant}"))),
    ]);
    query_where_skip_reason(&synthetic_where, aggregate, value_objects_by_name).map(|reason| skip("authorization", reason.text))
}

pub fn emit_query_order_by(order_by: &Json, null_semantics: Option<&Json>) -> String {
    let descending = order_by.get("direction").map(Json::to_s).unwrap_or_default() == "desc";
    format!(
        "crate::kernel::query_ordering::OrderBy {{ field: {}, descending: {descending}, nulls: {} }}",
        naming::ruby_inspect_string(&order_by.get("field").map(Json::to_s).unwrap_or_default()),
        null_semantics_variant(null_semantics)
    )
}

// `nulls(mode)` is unvalidated, so an unrecognized mode falls back to `Native`
// like `NullPolicy.order`'s `else` arm.
pub fn null_semantics_variant(null_semantics: Option<&Json>) -> &'static str {
    let mode = null_semantics.and_then(|ns| ns.get("mode")).map(Json::to_s).unwrap_or_default();
    match mode.as_str() {
        "first" => "crate::kernel::query_ordering::NullsMode::First",
        "last" => "crate::kernel::query_ordering::NullsMode::Last",
        _ => "crate::kernel::query_ordering::NullsMode::Native",
    }
}

pub fn emit_query_limit(limit: &Json) -> String {
    let raw = limit.get("value").map(Json::to_s).unwrap_or_default();
    if let Some(arg) = raw.strip_prefix(':') {
        return format!("crate::kernel::query_ordering::Limit::Arg({})", naming::ruby_inspect_string(arg));
    }
    format!("crate::kernel::query_ordering::Limit::Literal({})", ruby_to_i(&raw))
}

// `Offset` aliases `Limit`; only the spelled type name is swapped so a generated
// `offset:` field does not read as a `Limit`.
pub fn emit_query_offset(offset: &Json) -> String {
    emit_query_limit(offset).replace("query_ordering::Limit::", "query_ordering::Offset::")
}

fn ruby_to_i(s: &str) -> i64 {
    let trimmed = s.trim_start();
    let bytes = trimmed.as_bytes();
    let mut end = 0;
    if end < bytes.len() && (bytes[end] == b'-' || bytes[end] == b'+') {
        end += 1;
    }
    let digits_start = end;
    while end < bytes.len() && bytes[end].is_ascii_digit() {
        end += 1;
    }
    if end == digits_start {
        return 0;
    }
    trimmed[..end].parse().unwrap_or(0)
}

pub struct Condition {
    pub field: String,
    pub op: String,
    pub arg: Option<String>,
    pub literal: Option<Literal>,
}

// Assumes `query_skip_reason` already accepted the query.
pub fn query_conditions(query: &Json) -> Vec<Condition> {
    let wheres = query.get("wheres").map(Json::each).unwrap_or(&[]);
    wheres.iter().map(condition_for).collect()
}

fn condition_for(w: &Json) -> Condition {
    let raw_value = w.get("value").map(Json::to_s).unwrap_or_default();
    let symbol = raw_value.starts_with(':');
    Condition {
        field: w.get("field").map(Json::to_s).unwrap_or_default(),
        op: w.get("op").map(Json::to_s).unwrap_or_default(),
        arg: if symbol { Some(raw_value.trim_start_matches(':').to_string()) } else { None },
        literal: if symbol { None } else { Some(literal::read(&raw_value)) },
    }
}

/// One hop where clause, compiled; `condition.field` is the hop's inner field.
pub struct HopCondition {
    pub via_field: String,
    pub target_aggregate: String,
    /// Further `(via_field, qualified target aggregate)` steps.
    pub through: Vec<(String, String)>,
    pub condition: Condition,
}

pub fn query_conditions_and_hops(domain_name: &str, query: &Json, aggregate: &Json, aggregates_by_name: &HashMap<String, &Json>) -> (Vec<Condition>, Vec<HopCondition>) {
    let mut local = Vec::new();
    let mut hops = Vec::new();
    for w in query.get("wheres").map(Json::each).unwrap_or(&[]) {
        let field = w.get("field").map(Json::to_s).unwrap_or_default();
        match query_hop_plan(aggregate, &field, aggregates_by_name) {
            Some(plan) => hops.push(hop_condition(domain_name, plan, w)),
            None => local.push(condition_for(w)),
        }
    }
    if let Some(tenant) = query.get("authorization").and_then(|a| a.get("tenant")).map(Json::to_s) {
        local.push(Condition { field: tenant.clone(), op: "eq".to_string(), arg: Some(tenant), literal: None });
    }
    (local, hops)
}

// Assumes the skip check already confirmed every `hop_wheres` entry resolves.
pub fn read_model_hop_conditions(domain_name: &str, hop_wheres: &[&Json], aggregate: &Json, aggregates_by_name: &HashMap<String, &Json>) -> Vec<HopCondition> {
    hop_wheres
        .iter()
        .filter_map(|w| {
            let plan = query_hop_plan(aggregate, &w.get("field").map(Json::to_s).unwrap_or_default(), aggregates_by_name)?;
            Some(hop_condition(domain_name, plan, w))
        })
        .collect()
}

fn hop_condition(domain_name: &str, plan: HopPlan<'_>, w: &Json) -> HopCondition {
    let mut condition = condition_for(w);
    condition.field = plan.inner_field;
    let through = plan.through.into_iter().map(|(via, target)| (via, format!("{domain_name}::{target}"))).collect();
    HopCondition { via_field: plan.via_field, target_aggregate: format!("{domain_name}::{}", plan.target_aggregate), through, condition }
}

pub fn emit_reference_hop_condition(hop: &HopCondition) -> String {
    let through = hop
        .through
        .iter()
        .map(|(via, target)| format!("crate::kernel::read_model::HopStep {{ via_field: {}, target_aggregate: {} }}", naming::ruby_inspect_string(via), naming::ruby_inspect_string(target)))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "crate::kernel::read_model::ReferenceHopCondition {{ via_field: {}, target_aggregate: {}, through: &[{through}], inner_field: {}, inner_comparator: crate::kernel::query_comparators::QueryComparator::{}, inner_value: {} }},",
        naming::ruby_inspect_string(&hop.via_field),
        naming::ruby_inspect_string(&hop.target_aggregate),
        naming::ruby_inspect_string(&hop.condition.field),
        query_comparator_variant(&hop.condition.op),
        emit_query_condition_value(&hop.condition)
    )
}

// Adds `Runtime::TenantScope.apply`'s synthetic tenant clause at codegen time.
pub fn query_conditions_with_authorization(query: &Json) -> Vec<Condition> {
    let mut conditions = query_conditions(query);
    if let Some(tenant) = query.get("authorization").and_then(|a| a.get("tenant")).map(Json::to_s) {
        conditions.push(Condition { field: tenant.clone(), op: "eq".to_string(), arg: Some(tenant), literal: None });
    }
    conditions
}

// `None` unless a tenant is declared. `policy` is carried on the wire but not enforced,
// matching Ruby's `TenantScope.apply`; an absent policy becomes `""`.
pub fn emit_query_authorization(query_name: &str, authorization: Option<&Json>) -> Option<String> {
    let tenant = authorization.and_then(|a| a.get("tenant")).map(Json::to_s)?;
    let policy = authorization.and_then(|a| a.get("policy")).map(Json::to_s).unwrap_or_default();
    Some(format!(
        "crate::kernel::named_query::TenantAuth {{ query_name: {}, tenant_field: {}, policy: {} }}",
        naming::ruby_inspect_string(query_name),
        naming::ruby_inspect_string(&tenant),
        naming::ruby_inspect_string(&policy)
    ))
}

// `none_in_state` is left out on purpose: no generated call site can supply its
// cross-domain search list, so it would answer every row `true`. `query_where_skip_reason`
// checks this first, making the `panic!` in `query_comparator_variant` a backstop.
fn known_query_comparator(op: &str) -> bool {
    matches!(op, "eq" | "ne" | "gt" | "gte" | "lt" | "lte" | "in" | "contains")
}

fn query_comparator_variant(op: &str) -> &'static str {
    match op {
        "eq" => "Eq",
        "ne" => "Ne",
        "gt" => "Gt",
        "gte" => "Gte",
        "lt" => "Lt",
        "lte" => "Lte",
        "in" => "In",
        "contains" => "Contains",
        other => panic!("unknown query comparator {other:?} — query_comparator_variant doesn't cover this shape (grammar-validated at declare time, so this should be unreachable for a real declared query; query_where_skip_reason should have already skipped it with an honest reason)"),
    }
}

// Ruby's `Object#inspect` for a `Literal`. Numbers never reach here: an unquoted number
// where `QueryConditionValue::Literal` expects a `&str` would not compile, so
// `emit_query_condition_value` emits `NumericLiteral` for them.
fn literal_inspect(lit: &Literal) -> String {
    match lit {
        Literal::Str(s) => naming::ruby_inspect_string(s),
        Literal::Int(n) => n.to_string(),
        Literal::Float(n) => ruby_float_inspect(*n),
        Literal::Bool(b) => b.to_string(),
        Literal::Nil => "nil".to_string(),
        Literal::Symbol(s) => format!(":{s}"),
        Literal::Hash(pairs) => format!("{{{}}}", pairs.iter().map(|(k, v)| format!("{k}: {}", literal_inspect(v))).collect::<Vec<_>>().join(", ")),
        Literal::Array(items) => format!("[{}]", items.iter().map(literal_inspect).collect::<Vec<_>>().join(", ")),
    }
}

/// `Float#inspect`: always carries a decimal point.
fn ruby_float_inspect(n: f64) -> String {
    let text = format!("{n}");
    if text.contains('.') || text.contains('e') || text.contains('E') {
        text
    } else {
        format!("{text}.0")
    }
}

pub fn emit_query_condition_value(condition: &Condition) -> String {
    match &condition.arg {
        Some(arg) => format!("crate::kernel::QueryConditionValue::Arg({})", naming::ruby_inspect_string(arg)),
        None => {
            let lit = condition.literal.as_ref().unwrap();
            // The skip check already proved a numeric literal targets a numeric field.
            match lit {
                Literal::Int(n) => format!("crate::kernel::QueryConditionValue::NumericLiteral({})", ruby_float_inspect(*n as f64)),
                Literal::Float(n) => format!("crate::kernel::QueryConditionValue::NumericLiteral({})", ruby_float_inspect(*n)),
                _ => format!("crate::kernel::QueryConditionValue::Literal({})", literal_inspect(lit)),
            }
        }
    }
}

pub fn emit_query_condition(condition: &Condition) -> String {
    let comparator_expr = format!("crate::kernel::query_comparators::QueryComparator::{}", query_comparator_variant(&condition.op));
    format!("crate::kernel::QueryCondition {{ field: {}, comparator: {comparator_expr}, value: {} }},", naming::ruby_inspect_string(&condition.field), emit_query_condition_value(condition))
}

pub struct QueryDef {
    pub verb: String,
    pub aggregate: String,
    pub arg_checks: Vec<String>,
    pub conditions: Vec<Condition>,
    pub reference_hop_conditions: Vec<HopCondition>,
    pub order_by: Option<String>,
    pub offset: Option<String>,
    pub limit: Option<String>,
    pub authorization: Option<String>,
    /// True when the chapter's `provides "authorization", assignments:` names this query.
    pub assignments: bool,
    /// `Some` for a declared entity query — emitted into `ENTITY_QUERIES`.
    pub entity: Option<EntityScope>,
}

pub fn provided_assignments(ir: &Json) -> Option<String> {
    ir.get("provides")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .find(|row| {
            row.get("capability").and_then(Json::as_str) == Some("authorization")
                && row.get("key").and_then(Json::as_str) == Some("assignments")
        })
        .and_then(|row| row.get("verb").and_then(Json::as_str))
        .map(str::to_string)
}

pub fn emit_authorization_assignments(query_defs: &[QueryDef]) -> String {
    let value = match query_defs.iter().find(|q| q.assignments) {
        Some(q) => format!("Some({})", naming::ruby_inspect_string(&q.verb)),
        None => "None".to_string(),
    };
    format!(
        "/// `provides \"authorization\", assignments:` — the query `kernel::check_role_via` reads; `None` when no chapter here declares one.\npub const AUTHORIZATION_ASSIGNMENTS: Option<&str> = {value};\n"
    )
}

pub struct EntityScope {
    pub list_field: String,
    pub parent_key: String,
    pub identity_keys: Vec<String>,
}

pub fn emit_entity_query_table(entity_defs: &[&QueryDef]) -> String {
    let rows: String = entity_defs.iter().map(|q| format!("{}\n", emit_entity_query_def(q))).collect();
    format!(
        "/// Declared entity queries (`Aggregate.Entity.Query`) — `kernel::named_query::run_entity`.\npub const ENTITY_QUERIES: &[crate::kernel::named_query::EntityQueryDef] = &[\n{rows}];\n"
    )
}

fn emit_entity_query_def(query_def: &QueryDef) -> String {
    let entity = query_def.entity.as_ref().expect("an entity query def carries its scope");
    let conditions = query_def.conditions.iter().map(|c| format!("        {}", emit_query_condition(c))).collect::<Vec<_>>().join("\n");
    let keys = entity.identity_keys.iter().map(|key| naming::ruby_inspect_string(key)).collect::<Vec<_>>().join(", ");
    let wrap = |value: &Option<String>| match value {
        Some(v) => format!("Some({v})"),
        None => "None".to_string(),
    };
    format!(
        "crate::kernel::named_query::EntityQueryDef {{\n    verb: {},\n    aggregate: {},\n    list_field: {},\n    parent_key: {},\n    identity_keys: &[{keys}],\n    conditions: &[\n{conditions}\n    ],\n    order_by: {},\n    offset: {},\n    limit: {},\n}},",
        naming::ruby_inspect_string(&query_def.verb),
        naming::ruby_inspect_string(&query_def.aggregate),
        naming::ruby_inspect_string(&entity.list_field),
        naming::ruby_inspect_string(&entity.parent_key),
        wrap(&query_def.order_by),
        wrap(&query_def.offset),
        wrap(&query_def.limit)
    )
}

pub fn entity_query_skip_reason(query: &Json, entity: &Json, holds_list: bool, value_objects_by_name: &HashMap<String, &Json>) -> Option<SkipReason> {
    let entity_name = entity.get("name").map(Json::to_s).unwrap_or_default();
    if !holds_list {
        return Some(skip("entity_query", format!("{entity_name} is held in no list attribute on its aggregate — nothing to flatten")));
    }
    if query.get("authorization").is_some() {
        return Some(skip("entity_query_authorization", "declares authorize — an entity query's tenant scope is not generated yet"));
    }
    query_skip_reason(query, entity, value_objects_by_name, &HashMap::new())
}

pub fn emit_query_def(query_def: &QueryDef) -> String {
    let conditions = query_def.conditions.iter().map(|c| format!("        {}", emit_query_condition(c))).collect::<Vec<_>>().join("\n");
    let reference_hop_conditions = query_def.reference_hop_conditions.iter().map(|h| format!("        {}", emit_reference_hop_condition(h))).collect::<Vec<_>>().join("\n");
    let order_by = match &query_def.order_by {
        Some(o) => format!("Some({o})"),
        None => "None".to_string(),
    };
    let offset = match &query_def.offset {
        Some(o) => format!("Some({o})"),
        None => "None".to_string(),
    };
    let limit = match &query_def.limit {
        Some(l) => format!("Some({l})"),
        None => "None".to_string(),
    };
    let authorization = match &query_def.authorization {
        Some(a) => format!("Some({a})"),
        None => "None".to_string(),
    };

    format!(
        "crate::kernel::QueryDef {{\n    verb: {},\n    aggregate: {},\n    conditions: &[\n{conditions}\n    ],\n    reference_hop_conditions: &[\n{reference_hop_conditions}\n    ],\n    order_by: {order_by},\n    offset: {offset},\n    limit: {limit},\n    authorization: {authorization},\n}},",
        naming::ruby_inspect_string(&query_def.verb),
        naming::ruby_inspect_string(&query_def.aggregate)
    )
}

const QUERY_TABLE_ROW_PLACEHOLDER: &str = "crate::kernel::QueryDef {\n    verb: \"tmpl_verb\",\n    aggregate: \"tmpl_aggregate\",\n    conditions: &[\n        crate::kernel::QueryCondition {\n            field: \"tmpl_field\",\n            comparator: crate::kernel::query_comparators::QueryComparator::Eq,\n            value: crate::kernel::QueryConditionValue::Literal(\"tmpl_literal\"),\n        },\n    ],\n    reference_hop_conditions: &[\n        crate::kernel::read_model::ReferenceHopCondition {\n            via_field: \"tmpl_via_field\",\n            target_aggregate: \"tmpl_target_aggregate\",\n            through: &[crate::kernel::read_model::HopStep { via_field: \"tmpl_via_field\", target_aggregate: \"tmpl_target_aggregate\" }],\n            inner_field: \"tmpl_inner_field\",\n            inner_comparator: crate::kernel::query_comparators::QueryComparator::Eq,\n            inner_value: crate::kernel::QueryConditionValue::Literal(\"tmpl_literal\"),\n        },\n    ],\n    order_by: Some(crate::kernel::query_ordering::OrderBy { field: \"tmpl_order_field\", descending: true, nulls: crate::kernel::query_ordering::NullsMode::Last }),\n    offset: Some(crate::kernel::query_ordering::Offset::Literal(1)),\n    limit: Some(crate::kernel::query_ordering::Limit::Literal(5)),\n    authorization: Some(crate::kernel::named_query::TenantAuth { query_name: \"tmpl_query_name\", tenant_field: \"tmpl_tenant_field\", policy: \"tmpl_policy\" }),\n},";

pub fn emit_query_table(exemplar: &Exemplar, query_defs: &[QueryDef]) -> String {
    let (entity_defs, aggregate_defs): (Vec<&QueryDef>, Vec<&QueryDef>) = query_defs.iter().partition(|q| q.entity.is_some());
    let rows: Vec<String> = aggregate_defs.into_iter().map(emit_query_def).collect();
    format!(
        "{}\n{}{}",
        exemplar.render("query_table", &[(QUERY_TABLE_ROW_PLACEHOLDER, rows.join("\n"))]),
        emit_authorization_assignments(query_defs),
        emit_entity_query_table(&entity_defs)
    )
}

// One `if let` per value-object argument: built and invariant-checked, then dropped (ADR 0037).
pub fn query_arg_checks(query: &Json, mod_path: &str, value_objects_by_name: &HashMap<String, &Json>) -> Vec<String> {
    query
        .get("attributes")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .filter_map(|attr| {
            if crate::attr::list(attr) || !matches!(attr.get("relationship"), None | Some(Json::Null)) {
                return None;
            }
            let vo = value_objects_by_name.get(crate::attr::type_name(attr))?;
            let key = naming::rust_field(crate::attr::name(attr));
            let build = crate::json_codec::composite_from_json_expr(attr, value_objects_by_name, "x");
            let check = if vo.get("closed_set").map(Json::as_bool).unwrap_or(false) { "" } else { ".check_invariants()?" };
            Some(format!("if let Some(x) = args.get({}) {{ {mod_path}::{build}{check}; }}", naming::ruby_inspect_string(&key)))
        })
        .collect()
}

// The gate `kernel/cli.rs` runs before `named_query::run`.
pub fn emit_query_arg_check_table(query_defs: &[QueryDef]) -> String {
    let arms: Vec<String> = query_defs
        .iter()
        .filter(|q| !q.arg_checks.is_empty())
        .map(|q| {
            let lines = q.arg_checks.iter().map(|line| format!("            {line}")).collect::<Vec<_>>().join("\n");
            format!("        {} => {{\n{lines}\n            Ok(())\n        }}", naming::ruby_inspect_string(&q.verb))
        })
        .collect();
    format!(
        "/// C3.7 for a named query's own arguments — `query_arg_checks`\n/// (rust/codegen/src/queries.rs) has the full story.\npub fn check_query_args(verb: &str, args: &crate::kernel::Json) -> Result<(), crate::kernel::Refusal> {{\n    match verb {{\n{}\n        _ => Ok(()),\n    }}\n}}\n",
        arms.join("\n")
    )
}
