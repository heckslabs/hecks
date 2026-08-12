//! Port of `rust/project/queries.rb` — read that file's own header
//! comments in full for what this deliberately does and does not cover;
//! this mirrors its algorithm directly, function for function.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::literal::{self, Literal};
use crate::naming;
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

/// The declared attribute (or synthetic lifecycle field) `field`'s HEAD
/// segment names on `aggregate`, walked through nested value objects for
/// any segments after it.
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

/// One where clause's own eligibility.
pub fn query_where_skip_reason(where_clause: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    let field = where_clause.get("field").map(Json::to_s).unwrap_or_default();
    let kind = query_field_kind(aggregate, &field, value_objects_by_name);
    if kind == FieldKind::Unknown {
        return Some(format!(
            "where clause on {} isn't a recognized attribute of this aggregate — a hop through a reference, an entity-scoped field, or simply undeclared here; cross-aggregate joins are read_model territory, not this generator's job",
            naming::ruby_inspect_string(&field)
        ));
    }

    let raw_value = where_clause.get("value").map(Json::to_s).unwrap_or_default();
    if raw_value.starts_with(':') {
        return None;
    }

    let op = where_clause.get("op").map(Json::to_s).unwrap_or_default();
    if COMPARATORS_NEEDING_NUMERIC_FIDELITY.contains(&op.as_str()) {
        return Some(format!(
            "where clause on {} uses op {} against a LITERAL value — gt/gte/lt/lte need real Json::Num-vs-Json::Str fidelity this generator can't recover from the exported IR (WhereClause#to_h renders every literal through QuerySpecification.render_value's own .to_s)",
            naming::ruby_inspect_string(&field),
            naming::ruby_inspect_string(&op)
        ));
    }
    if COMPARATORS_EXEMPT_FROM_LITERAL_TYPING.contains(&op.as_str()) {
        return None;
    }
    if kind == FieldKind::String {
        return None;
    }

    Some(format!(
        "where clause on {} uses op {} against a LITERAL value whose target field doesn't reduce to a plain JSON string (kind: {}) — its true wire type can't be recovered from the exported IR",
        naming::ruby_inspect_string(&field),
        naming::ruby_inspect_string(&op),
        kind_name(kind)
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

/// A whole declared query's own eligibility.
pub fn query_skip_reason(query: &Json, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    let extra_keys = ["offset", "cursor", "consistency", "freshness", "authorization", "null_semantics", "inspection"];
    let extras: Vec<&str> = extra_keys.iter().filter(|k| query.get(k).is_some()).copied().collect();
    if !extras.is_empty() {
        return Some(format!("declares {} — out of scope for this generator (rust/project/queries.rb's own header has the full argument)", extras.join(", ")));
    }
    if query.get("index_hints").map(Json::each).unwrap_or(&[]).iter().any(|_| true) {
        return Some("declares use_index, out of scope for the same reason the extras above are".to_string());
    }

    let wheres = query.get("wheres").map(Json::each).unwrap_or(&[]);
    if wheres.is_empty() {
        return Some("declares no where clauses at all — nothing for filter_entries to bake in".to_string());
    }

    for where_clause in wheres {
        if let Some(reason) = query_where_skip_reason(where_clause, aggregate, value_objects_by_name) {
            return Some(reason);
        }
    }

    if let Some(reason) = declared_order_by_skip_reason(query.get("order_by"), aggregate, value_objects_by_name) {
        return Some(reason);
    }

    declared_limit_skip_reason(query.get("limit"))
}

pub fn declared_order_by_skip_reason(order_by: Option<&Json>, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    let order_by = order_by?;
    let field = order_by.get("field").map(Json::to_s).unwrap_or_default();
    let kind = query_field_kind(aggregate, &field, value_objects_by_name);
    if matches!(kind, FieldKind::String | FieldKind::Number) {
        return None;
    }

    Some(format!(
        "declares order_by on {} — this generator can only sort a field that reduces to a plain JSON string or number (kind: {}); a hop through a reference, an entity-scoped field, a list_of field, or a multi-member non-numeric value object can't be compared generically",
        naming::ruby_inspect_string(&field),
        kind_name(kind)
    ))
}

pub fn declared_limit_skip_reason(limit: Option<&Json>) -> Option<String> {
    let limit = limit?;
    let raw = limit.get("value").map(Json::to_s).unwrap_or_default();
    if raw.starts_with(':') || is_plain_integer(&raw) {
        return None;
    }

    Some(format!("declares limit {} — not a literal integer or a caller-bound Symbol arg, so this generator can't compile a real limit count from it", naming::ruby_inspect_string(&raw)))
}

fn is_plain_integer(raw: &str) -> bool {
    let s = raw.strip_prefix('-').unwrap_or(raw);
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

pub fn emit_query_order_by(order_by: &Json) -> String {
    let descending = order_by.get("direction").map(Json::to_s).unwrap_or_default() == "desc";
    format!("crate::kernel::query_ordering::OrderBy {{ field: {}, descending: {descending} }}", naming::ruby_inspect_string(&order_by.get("field").map(Json::to_s).unwrap_or_default()))
}

pub fn emit_query_limit(limit: &Json) -> String {
    let raw = limit.get("value").map(Json::to_s).unwrap_or_default();
    if let Some(arg) = raw.strip_prefix(':') {
        return format!("crate::kernel::query_ordering::Limit::Arg({})", naming::ruby_inspect_string(arg));
    }
    format!("crate::kernel::query_ordering::Limit::Literal({})", ruby_to_i(&raw))
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

/// `query_skip_reason` already returned `nil` for this query — every where
/// clause is either Symbol-valued (an `arg:`) or a safely-typed literal.
pub fn query_conditions(query: &Json) -> Vec<Condition> {
    let wheres = query.get("wheres").map(Json::each).unwrap_or(&[]);
    wheres
        .iter()
        .map(|w| {
            let raw_value = w.get("value").map(Json::to_s).unwrap_or_default();
            let symbol = raw_value.starts_with(':');
            Condition {
                field: w.get("field").map(Json::to_s).unwrap_or_default(),
                op: w.get("op").map(Json::to_s).unwrap_or_default(),
                arg: if symbol { Some(raw_value.trim_start_matches(':').to_string()) } else { None },
                literal: if symbol { None } else { Some(literal::read(&raw_value)) },
            }
        })
        .collect()
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
        other => panic!("unknown query comparator {other:?} — query_comparator_variant doesn't cover this shape (grammar-validated at declare time, so this should be unreachable for a real declared query)"),
    }
}

/// `condition[:literal].inspect` — Ruby's own generic `Object#inspect`,
/// called on whatever `Literal.read` returned. In EVERY real corpus query
/// this is a plain String (`query_where_skip_reason` only lets a literal
/// comparator through when `kind == :string`, except `in`/`contains`,
/// which the real corpus never uses with anything but a hand-written
/// string value either) — so only the String case is exercised, but every
/// case is mirrored for fidelity with Ruby's own `.inspect` regardless of
/// comparator, matching what `bin/project_rust` would actually emit if it
/// were ever reached (a bare, unquoted Integer/Float/Bool/nil `.inspect`
/// embedded where `QueryConditionValue::Literal` expects a `&str` would be
/// a pre-existing Ruby-side landmine, not something to "fix" silently
/// here — Ruby is the reference implementation, ADR 0010).
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

/// `Float#inspect` — always carries a decimal point, same rule as
/// `Json::to_s`'s own `format_number`.
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
        None => format!("crate::kernel::QueryConditionValue::Literal({})", literal_inspect(condition.literal.as_ref().unwrap())),
    }
}

pub fn emit_query_condition(condition: &Condition) -> String {
    let comparator_expr = format!("crate::kernel::query_comparators::QueryComparator::{}", query_comparator_variant(&condition.op));
    format!("crate::kernel::QueryCondition {{ field: {}, comparator: {comparator_expr}, value: {} }},", naming::ruby_inspect_string(&condition.field), emit_query_condition_value(condition))
}

pub struct QueryDef {
    pub verb: String,
    pub aggregate: String,
    pub conditions: Vec<Condition>,
    pub order_by: Option<String>,
    pub limit: Option<String>,
}

pub fn emit_query_def(query_def: &QueryDef) -> String {
    let conditions = query_def.conditions.iter().map(|c| format!("        {}", emit_query_condition(c))).collect::<Vec<_>>().join("\n");
    let order_by = match &query_def.order_by {
        Some(o) => format!("Some({o})"),
        None => "None".to_string(),
    };
    let limit = match &query_def.limit {
        Some(l) => format!("Some({l})"),
        None => "None".to_string(),
    };

    format!(
        "crate::kernel::QueryDef {{\n    verb: {},\n    aggregate: {},\n    conditions: &[\n{conditions}\n    ],\n    order_by: {order_by},\n    limit: {limit},\n}},",
        naming::ruby_inspect_string(&query_def.verb),
        naming::ruby_inspect_string(&query_def.aggregate)
    )
}

const QUERY_TABLE_ROW_PLACEHOLDER: &str = "crate::kernel::QueryDef {\n    verb: \"tmpl_verb\",\n    aggregate: \"tmpl_aggregate\",\n    conditions: &[\n        crate::kernel::QueryCondition {\n            field: \"tmpl_field\",\n            comparator: crate::kernel::query_comparators::QueryComparator::Eq,\n            value: crate::kernel::QueryConditionValue::Literal(\"tmpl_literal\"),\n        },\n    ],\n    order_by: Some(crate::kernel::query_ordering::OrderBy { field: \"tmpl_order_field\", descending: true }),\n    limit: Some(crate::kernel::query_ordering::Limit::Literal(5)),\n},";

pub fn emit_query_table(exemplar: &Exemplar, query_defs: &[QueryDef]) -> String {
    let rows: Vec<String> = query_defs.iter().map(emit_query_def).collect();
    exemplar.render("query_table", &[(QUERY_TABLE_ROW_PLACEHOLDER, rows.join("\n"))])
}
