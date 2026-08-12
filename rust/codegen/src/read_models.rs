//! Port of `rust/project/read_models.rb` — read that file's own header
//! comments in full; this mirrors its algorithm directly, function for
//! function.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::queries;
use std::collections::HashMap;

const READ_MODEL_BARE_KEYS: &[&str] = &["name", "description", "reference_name", "reference_target", "query_name", "aggregate_heads", "wheres", "order_by", "limit", "freshness", "index_hints", "group_by"];

pub fn read_model_skip_reason(read_model: &Json, aggregates_by_name: &HashMap<String, &Json>, unsupported_names: &[String]) -> Option<String> {
    let keys: Vec<&str> = match read_model {
        Json::Object(pairs) => pairs.iter().filter(|(_, v)| !matches!(v, Json::Null)).map(|(k, _)| k.as_str()).collect(),
        _ => Vec::new(),
    };
    let extra: Vec<&str> = keys.into_iter().filter(|k| !READ_MODEL_BARE_KEYS.contains(k)).collect();
    if !extra.is_empty() {
        return Some(read_model_options_skip_reason(&extra));
    }

    if read_model.get("group_by").map(Json::each).unwrap_or(&[]).iter().any(|_| true) {
        return Some(read_model_options_skip_reason(&["group_by"]));
    }

    let heads = read_model.get("aggregate_heads").map(Json::each).unwrap_or(&[]);
    let reference_target = read_model.get("reference_target").map(Json::to_s).unwrap_or_default();
    let root = heads.iter().find(|h| h.get("aggregate").map(Json::to_s).unwrap_or_default() == reference_target);
    if root.is_none() {
        return Some(format!(
            "declares reference_to {reference_target}, but includes no matching aggregate head — nothing for this generator's own root fetch to key off (every real corpus read model includes its own reference target; this generator refuses rather than guess at a root-less shape it doesn't cover)"
        ));
    }

    for head in heads {
        if let Some(reason) = read_model_head_skip_reason(head, aggregates_by_name, unsupported_names) {
            return Some(reason);
        }
    }

    read_model_options_content_skip_reason(read_model, aggregates_by_name)
}

fn read_model_options_skip_reason(extra: &[&str]) -> String {
    let mut sorted: Vec<&str> = extra.to_vec();
    sorted.sort();
    format!(
        "declares {} — out of scope for this generator: offset/cursor/consistency/authorization(TenantScope)/null_semantics beyond the default/inspection are real capabilities Ports::Query::InMemory/Ports::Query::Ordering/TenantScope implement that this generator does not port (this file's own header has the full argument, the same boundary queries.rb already draws for a declared AGGREGATE query); freshness/use_index are never disqualifying on their own — neither is read by the in-memory interpreter path this kernel matches",
        sorted.join(", ")
    )
}

/// `IR::ReadModel#filtered_head_name`, ported directly.
pub fn read_model_filtered_head_as(read_model: &Json) -> Option<String> {
    let declared = read_model.get("wheres").map(Json::each).unwrap_or(&[]).iter().any(|_| true)
        || read_model.get("order_by").is_some()
        || read_model.get("limit").is_some()
        || read_model.get("offset").is_some()
        || read_model.get("authorization").and_then(|a| a.get("tenant")).is_some();
    if !declared {
        return None;
    }

    let heads = read_model.get("aggregate_heads").map(Json::each).unwrap_or(&[]);
    heads.iter().find(|h| h.get("many").map(Json::as_bool).unwrap_or(false)).and_then(|h| h.get("as")).map(Json::to_s)
}

fn read_model_options_content_skip_reason(read_model: &Json, aggregates_by_name: &HashMap<String, &Json>) -> Option<String> {
    let eligible_as = read_model_filtered_head_as(read_model)?;

    let heads = read_model.get("aggregate_heads").map(Json::each).unwrap_or(&[]);
    let head = heads.iter().find(|h| h.get("as").map(Json::to_s).unwrap_or_default() == eligible_as)?;
    let aggregate_name = head.get("aggregate").map(Json::to_s).unwrap_or_default();
    let aggregate = aggregates_by_name.get(&aggregate_name)?;
    let vos = aggregate.get("value_objects").map(Json::each).unwrap_or(&[]);
    let value_objects_by_name: HashMap<String, &Json> = vos.iter().map(|vo| (vo.get("name").and_then(Json::as_str).unwrap_or("").to_string(), vo)).collect();

    let wheres = read_model.get("wheres").map(Json::each).unwrap_or(&[]);
    for where_clause in wheres {
        if let Some(reason) = queries::query_where_skip_reason(where_clause, aggregate, &value_objects_by_name) {
            return Some(format!("eligible head {aggregate_name}'s own {reason}"));
        }
    }

    if let Some(reason) = queries::declared_order_by_skip_reason(read_model.get("order_by"), aggregate, &value_objects_by_name) {
        return Some(reason);
    }

    queries::declared_limit_skip_reason(read_model.get("limit"))
}

fn read_model_head_skip_reason(head: &Json, aggregates_by_name: &HashMap<String, &Json>, unsupported_names: &[String]) -> Option<String> {
    let aggregate_name = head.get("aggregate").map(Json::to_s).unwrap_or_default();
    if !aggregates_by_name.contains_key(&aggregate_name) {
        return Some(format!("includes {aggregate_name}, which this domain never declares"));
    }
    if unsupported_names.contains(&aggregate_name) {
        return Some(format!("includes {aggregate_name}, which this generator couldn't itself generate (unsupported attribute type — see this domain's own aggregate-level manifest entry)"));
    }
    None
}

pub struct ReferenceField {
    pub target: String,
    pub field: String,
}

fn read_model_reference_fields(head_aggregate: &Json) -> Vec<ReferenceField> {
    let attrs = head_aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    attrs
        .iter()
        .filter_map(|attr| {
            let target = crate::naming::reference_target(crate::attr::type_name(attr))?;
            Some(ReferenceField { target: target.to_string(), field: crate::attr::name(attr).to_string() })
        })
        .collect()
}

fn emit_reference_field(domain_name: &str, rf: &ReferenceField) -> String {
    let qualified_target = format!("{domain_name}::{}", rf.target);
    format!("crate::kernel::read_model::ReferenceField {{ target_aggregate: {}, field: {} }}", crate::naming::ruby_inspect_string(&qualified_target), crate::naming::ruby_inspect_string(&rf.field))
}

fn emit_read_model_head(domain_name: &str, head: &Json, is_root: bool, aggregates_by_name: &HashMap<String, &Json>) -> String {
    let aggregate_name = head.get("aggregate").map(Json::to_s).unwrap_or_default();
    let reference_fields: Vec<ReferenceField> = if is_root { Vec::new() } else { aggregates_by_name.get(&aggregate_name).map(|a| read_model_reference_fields(a)).unwrap_or_default() };
    let reference_fields_expr = reference_fields.iter().map(|rf| emit_reference_field(domain_name, rf)).collect::<Vec<_>>().join(", ");
    let qualified_aggregate = format!("{domain_name}::{aggregate_name}");
    let as_name = head.get("as").map(Json::to_s).unwrap_or_default();
    let many = head.get("many").map(Json::as_bool).unwrap_or(false);

    format!(
        "crate::kernel::read_model::ReadModelHead {{ aggregate: {}, as_name: {}, many: {many}, is_root: {is_root}, reference_fields: &[{reference_fields_expr}] }}",
        crate::naming::ruby_inspect_string(&qualified_aggregate),
        crate::naming::ruby_inspect_string(&as_name)
    )
}

fn emit_read_model_order_by(order_by: &Json) -> String {
    let descending = order_by.get("direction").map(Json::to_s).unwrap_or_default() == "desc";
    format!("crate::kernel::read_model::ReadModelOrderBy {{ field: {}, descending: {descending} }}", crate::naming::ruby_inspect_string(&order_by.get("field").map(Json::to_s).unwrap_or_default()))
}

fn emit_read_model_limit(limit: &Json) -> String {
    let raw = limit.get("value").map(Json::to_s).unwrap_or_default();
    if let Some(arg) = raw.strip_prefix(':') {
        return format!("crate::kernel::read_model::ReadModelLimit::Arg({})", crate::naming::ruby_inspect_string(arg));
    }
    format!("crate::kernel::read_model::ReadModelLimit::Literal({})", ruby_to_i(&raw))
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

pub struct ReadModelDef {
    pub verb: String,
    pub reference_name: String,
    pub heads: Vec<String>,
    pub filtered_head: Option<String>,
    pub conditions: Vec<queries::Condition>,
    pub order_by: Option<String>,
    pub limit: Option<String>,
}

pub fn read_model_def(domain_name: &str, read_model: &Json, aggregates_by_name: &HashMap<String, &Json>) -> ReadModelDef {
    let reference_target = read_model.get("reference_target").map(Json::to_s).unwrap_or_default();
    let heads_json = read_model.get("aggregate_heads").map(Json::each).unwrap_or(&[]);
    let heads: Vec<String> = heads_json
        .iter()
        .map(|head| {
            let is_root = head.get("aggregate").map(Json::to_s).unwrap_or_default() == reference_target;
            emit_read_model_head(domain_name, head, is_root, aggregates_by_name)
        })
        .collect();

    let eligible_as = read_model_filtered_head_as(read_model);

    ReadModelDef {
        verb: format!("{domain_name}.{}", read_model.get("name").map(Json::to_s).unwrap_or_default()),
        reference_name: read_model.get("reference_name").map(Json::to_s).unwrap_or_default(),
        heads,
        filtered_head: eligible_as.clone(),
        conditions: if eligible_as.is_some() { queries::query_conditions(read_model) } else { Vec::new() },
        order_by: if eligible_as.is_some() { read_model.get("order_by").map(emit_read_model_order_by) } else { None },
        limit: if eligible_as.is_some() { read_model.get("limit").map(emit_read_model_limit) } else { None },
    }
}

pub fn emit_read_model_def(rmd: &ReadModelDef) -> String {
    let heads = rmd.heads.iter().map(|h| format!("        {h},")).collect::<Vec<_>>().join("\n");
    let conditions = rmd.conditions.iter().map(|c| format!("        {}", queries::emit_query_condition(c))).collect::<Vec<_>>().join("\n");
    let filtered_head = match &rmd.filtered_head {
        Some(f) => format!("Some({})", crate::naming::ruby_inspect_string(f)),
        None => "None".to_string(),
    };
    let order_by = match &rmd.order_by {
        Some(o) => format!("Some({o})"),
        None => "None".to_string(),
    };
    let limit = match &rmd.limit {
        Some(l) => format!("Some({l})"),
        None => "None".to_string(),
    };

    format!(
        "crate::kernel::read_model::ReadModelDef {{\n    verb: {},\n    reference_name: {},\n    heads: &[\n{heads}\n    ],\n    filtered_head: {filtered_head},\n    conditions: &[\n{conditions}\n    ],\n    order_by: {order_by},\n    limit: {limit},\n}},",
        crate::naming::ruby_inspect_string(&rmd.verb),
        crate::naming::ruby_inspect_string(&rmd.reference_name)
    )
}

const READ_MODEL_TABLE_ROW_PLACEHOLDER: &str = "crate::kernel::read_model::ReadModelDef {\n    verb: \"tmpl_verb\",\n    reference_name: \"tmpl_reference_name\",\n    heads: &[\n        crate::kernel::read_model::ReadModelHead {\n            aggregate: \"tmpl_aggregate\",\n            as_name: \"tmpl_as_name\",\n            many: true,\n            is_root: false,\n            reference_fields: &[\n                crate::kernel::read_model::ReferenceField { target_aggregate: \"tmpl_target_aggregate\", field: \"tmpl_field\" },\n            ],\n        },\n    ],\n    filtered_head: Some(\"tmpl_as_name\"),\n    conditions: &[\n        crate::kernel::QueryCondition {\n            field: \"tmpl_field\",\n            comparator: crate::kernel::query_comparators::QueryComparator::Eq,\n            value: crate::kernel::QueryConditionValue::Literal(\"tmpl_literal\"),\n        },\n    ],\n    order_by: Some(crate::kernel::read_model::ReadModelOrderBy { field: \"tmpl_order_field\", descending: true }),\n    limit: Some(crate::kernel::read_model::ReadModelLimit::Literal(5)),\n},";

pub fn emit_read_model_table(exemplar: &Exemplar, read_model_defs: &[ReadModelDef]) -> String {
    let rows: Vec<String> = read_model_defs.iter().map(emit_read_model_def).collect();
    exemplar.render("read_model_table", &[(READ_MODEL_TABLE_ROW_PLACEHOLDER, rows.join("\n"))])
}
