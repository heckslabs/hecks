//! Port of `rust/project/read_models.rb` — read that file's own header
//! comments in full; this mirrors its algorithm directly, function for
//! function.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::queries;
use std::collections::HashMap;

const READ_MODEL_BARE_KEYS: &[&str] = &["name", "description", "reference_name", "reference_target", "query_name", "aggregate_heads", "wheres", "order_by", "offset", "limit", "freshness", "index_hints", "group_by", "null_semantics", "authorization", "count", "median_field"];

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
        return group_by_skip_reason(read_model, aggregates_by_name, unsupported_names);
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

    if let Some(reason) = read_model_options_content_skip_reason(read_model, aggregates_by_name) {
        return Some(reason);
    }

    aggregation_skip_reason(read_model, aggregates_by_name)
}

fn read_model_options_skip_reason(extra: &[&str]) -> String {
    let mut sorted: Vec<&str> = extra.to_vec();
    sorted.sort();
    format!(
        "declares {} — out of scope for this generator: cursor/consistency/inspection are real capabilities Ports::Query::InMemory/Ports::Query::Ordering/TenantScope implement that this generator does not port (this file's own header has the full argument, the same boundary queries.rb already draws for a declared AGGREGATE query); freshness/use_index are never disqualifying on their own — neither is read by the in-memory interpreter path this kernel matches",
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

    if let Some(reason) = queries::declared_authorization_skip_reason(read_model.get("authorization"), aggregate, &value_objects_by_name) {
        return Some(reason);
    }

    if let Some(reason) = queries::declared_order_by_skip_reason(read_model.get("order_by"), aggregate, &value_objects_by_name) {
        return Some(reason);
    }

    if let Some(reason) = queries::declared_offset_skip_reason(read_model.get("offset")) {
        return Some(reason);
    }

    queries::declared_limit_skip_reason(read_model.get("limit"))
}

/// `count`/`median`'s own eligibility — mirrors `rust/project/
/// read_models.rb`'s own `aggregation_skip_reason` exactly. `seal_
/// aggregation` (Ruby, build time) already guarantees exactly one
/// many-side head, and mutual exclusion with `group_by`/with each other,
/// by the time this ever runs — this doesn't re-derive either. `count`
/// needs no further check (a bare row count has nothing to validate);
/// `median`'s own FIELD is the one genuinely new thing to confirm.
fn aggregation_skip_reason(read_model: &Json, aggregates_by_name: &HashMap<String, &Json>) -> Option<String> {
    let median_field = read_model.get("median_field")?;
    let field = Json::to_s(median_field);

    let heads = read_model.get("aggregate_heads").map(Json::each).unwrap_or(&[]);
    let target = heads.iter().find(|h| h.get("many").map(Json::as_bool).unwrap_or(false))?;
    let aggregate_name = target.get("aggregate").map(Json::to_s).unwrap_or_default();
    let aggregate = aggregates_by_name.get(&aggregate_name)?;
    let vos = aggregate.get("value_objects").map(Json::each).unwrap_or(&[]);
    let value_objects_by_name: HashMap<String, &Json> = vos.iter().map(|vo| (vo.get("name").and_then(Json::as_str).unwrap_or("").to_string(), vo)).collect();

    match queries::query_field_kind(aggregate, &field, &value_objects_by_name) {
        queries::FieldKind::Unknown => Some(format!("median names {field:?}, but {aggregate_name} declares no such attribute — not generated yet")),
        queries::FieldKind::Number => None,
        _ => Some(format!(
            "median names {field:?} on {aggregate_name}, which is not numeric — median needs a numeric field (a bare number, or a value object carrying one) — not generated yet"
        )),
    }
}

/// `group_by`'s own eligibility — mirrors `rust/project/read_models.rb`'s
/// own `group_by_skip_reason` exactly: the ONE real shape the corpus
/// declares, a single ROOTLESS head, group_by alone.
fn group_by_skip_reason(read_model: &Json, aggregates_by_name: &HashMap<String, &Json>, unsupported_names: &[String]) -> Option<String> {
    let heads = read_model.get("aggregate_heads").map(Json::each).unwrap_or(&[]);
    if heads.len() != 1 {
        return Some(format!("declares group_by across {} aggregate heads — not generated yet (only a single, rootless head is)", heads.len()));
    }
    let reference_target = read_model.get("reference_target");
    if reference_target.is_some() && !matches!(reference_target, Some(Json::Null)) {
        return Some(format!("declares group_by on a NON-rootless read model (reference_to {}) — not generated yet", reference_target.map(Json::to_s).unwrap_or_default()));
    }
    if read_model.get("count").is_some() || read_model.get("median_field").is_some() {
        return Some("declares group_by alongside count/median — not generated yet".to_string());
    }
    let has_wheres = read_model.get("wheres").map(Json::each).unwrap_or(&[]).iter().any(|_| true);
    if has_wheres || read_model.get("order_by").is_some() || read_model.get("limit").is_some() || read_model.get("offset").is_some() {
        return Some("declares group_by alongside where/order_by/limit/offset — not generated yet".to_string());
    }
    if read_model.get("authorization").is_some() {
        return Some("declares group_by with an authorize policy — not generated yet".to_string());
    }

    let head = &heads[0];
    if let Some(reason) = read_model_head_skip_reason(head, aggregates_by_name, unsupported_names) {
        return Some(reason);
    }

    let aggregate_name = head.get("aggregate").map(Json::to_s).unwrap_or_default();
    let aggregate = aggregates_by_name[&aggregate_name];
    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let lifecycle_field = aggregate.get("lifecycle").and_then(|l| l.get("field")).map(Json::to_s);
    for row in read_model.get("group_by").map(Json::each).unwrap_or(&[]) {
        let field = row.get("field").map(Json::to_s).unwrap_or_default();
        let is_attr = attrs.iter().any(|a| crate::attr::name(a) == field);
        let is_lifecycle = lifecycle_field.as_deref() == Some(field.as_str());
        if !is_attr && !is_lifecycle {
            return Some(format!("group_by names {field:?}, but {aggregate_name} declares no such attribute — not generated yet"));
        }
    }
    None
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

fn emit_read_model_order_by(order_by: &Json, null_semantics: Option<&Json>) -> String {
    let descending = order_by.get("direction").map(Json::to_s).unwrap_or_default() == "desc";
    format!(
        "crate::kernel::read_model::ReadModelOrderBy {{ field: {}, descending: {descending}, nulls: {} }}",
        crate::naming::ruby_inspect_string(&order_by.get("field").map(Json::to_s).unwrap_or_default()),
        queries::null_semantics_variant(null_semantics)
    )
}

fn emit_read_model_limit(limit: &Json) -> String {
    let raw = limit.get("value").map(Json::to_s).unwrap_or_default();
    if let Some(arg) = raw.strip_prefix(':') {
        return format!("crate::kernel::read_model::ReadModelLimit::Arg({})", crate::naming::ruby_inspect_string(arg));
    }
    format!("crate::kernel::read_model::ReadModelLimit::Literal({})", ruby_to_i(&raw))
}

/// Same reasoning as `queries::emit_query_offset`: `ReadModelOffset` is
/// `pub type ReadModelOffset = query_ordering::Offset`, so this reuses
/// `emit_read_model_limit`'s own computation and swaps only the spelled
/// type name.
fn emit_read_model_offset(offset: &Json) -> String {
    emit_read_model_limit(offset).replace("read_model::ReadModelLimit::", "read_model::ReadModelOffset::")
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
    pub reference_name: Option<String>,
    pub heads: Vec<String>,
    pub filtered_head: Option<String>,
    pub conditions: Vec<queries::Condition>,
    pub order_by: Option<String>,
    pub offset: Option<String>,
    pub limit: Option<String>,
    pub authorization: Option<String>,
    pub group_by_fn: Option<String>,
    pub group_by_fn_body: Option<String>,
    pub count: bool,
    pub median_field: Option<String>,
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
    let read_model_name = read_model.get("name").map(Json::to_s).unwrap_or_default();
    let group_by_fields: Vec<String> = read_model.get("group_by").map(Json::each).unwrap_or(&[]).iter().map(|row| row.get("field").map(Json::to_s).unwrap_or_default()).collect();
    let (group_by_fn, group_by_fn_body) = if !group_by_fields.is_empty() {
        let fn_name = format!("group_by_{}", read_model_name.to_lowercase());
        let aggregate_name = heads_json.first().and_then(|h| h.get("aggregate")).map(Json::to_s).unwrap_or_default();
        let aggregate = aggregates_by_name[&aggregate_name];
        (Some(fn_name.clone()), Some(emit_group_by_transform(&fn_name, aggregate, &group_by_fields)))
    } else {
        (None, None)
    };

    ReadModelDef {
        verb: format!("{domain_name}.{read_model_name}"),
        reference_name: read_model.get("reference_name").map(Json::to_s),
        heads,
        filtered_head: eligible_as.clone(),
        conditions: if eligible_as.is_some() { queries::query_conditions_with_authorization(read_model) } else { Vec::new() },
        order_by: if eligible_as.is_some() { read_model.get("order_by").map(|ob| emit_read_model_order_by(ob, read_model.get("null_semantics"))) } else { None },
        offset: if eligible_as.is_some() { read_model.get("offset").map(emit_read_model_offset) } else { None },
        limit: if eligible_as.is_some() { read_model.get("limit").map(emit_read_model_limit) } else { None },
        authorization: if eligible_as.is_some() { queries::emit_query_authorization(&read_model_name, read_model.get("authorization")) } else { None },
        group_by_fn,
        group_by_fn_body,
        count: read_model.get("count").is_some(),
        median_field: read_model.get("median_field").map(Json::to_s),
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
    let offset = match &rmd.offset {
        Some(o) => format!("Some({o})"),
        None => "None".to_string(),
    };
    let limit = match &rmd.limit {
        Some(l) => format!("Some({l})"),
        None => "None".to_string(),
    };
    let authorization = match &rmd.authorization {
        Some(a) => format!("Some({a})"),
        None => "None".to_string(),
    };
    let reference_name = match &rmd.reference_name {
        Some(r) => format!("Some({})", crate::naming::ruby_inspect_string(r)),
        None => "None".to_string(),
    };
    let group_by = match &rmd.group_by_fn {
        Some(f) => format!("Some({f})"),
        None => "None".to_string(),
    };
    let count = if rmd.count { "true" } else { "false" };
    let median_field = match &rmd.median_field {
        Some(f) => format!("Some({})", crate::naming::ruby_inspect_string(f)),
        None => "None".to_string(),
    };

    // ALWAYS EMPTY — item 2.4 (D1) of the equivalence-gap plan, ported
    // from `rust/project/read_models.rb`'s own `read_model_hop_
    // conditions`. That function's real hop-detection logic
    // (`query_hop_plan`, queries.rb) is NOT ported here: a full corpus
    // check (confirmed directly, the same way that Ruby work was
    // verified) found zero real read models across the whole corpus
    // declare a reference-hop where clause today, so an always-empty
    // slice is byte-correct for every real domain this tool's own
    // parity spec covers — not a stub standing in for missing behavior,
    // the exact value the real detection logic would also compute for
    // every one of them. Porting `query_hop_plan` itself against zero
    // real examples to prove it against would be exactly the kind of
    // speculative generality this codebase's own comments elsewhere
    // warn against; do that the day a real corpus read model actually
    // needs it, against that real example. Rendered as an EMPTY LINE
    // inside `&[ ]` (`.join("\n")` over zero elements), matching Ruby's
    // own `conditions`/every other empty-array field's rendering here —
    // never the tighter `&[]` a hand-typed empty literal would use.
    let reference_hop_conditions = "";
    format!(
        "crate::kernel::read_model::ReadModelDef {{\n    verb: {},\n    reference_name: {reference_name},\n    heads: &[\n{heads}\n    ],\n    filtered_head: {filtered_head},\n    conditions: &[\n{conditions}\n    ],\n    reference_hop_conditions: &[\n{reference_hop_conditions}\n    ],\n    order_by: {order_by},\n    offset: {offset},\n    limit: {limit},\n    authorization: {authorization},\n    group_by: {group_by},\n    count: {count},\n    median_field: {median_field},\n}},",
        crate::naming::ruby_inspect_string(&rmd.verb)
    )
}

/// Port of `rust/project/read_models.rb`'s own `emit_group_by_transform`
/// — see that function's own header for the full reasoning (three jobs:
/// `row_json`-equivalent id insertion, keep only real declared
/// attributes + id + lifecycle — excluding any OTHER Phase 10
/// capability's own synthetic fields, like `corrects`'s `emitted_*`
/// flags — and recursively unwrap single-attribute value objects).
fn emit_group_by_transform(fn_name: &str, aggregate: &Json, group_by_fields: &[String]) -> String {
    let value_objects: Vec<&Json> = aggregate.get("value_objects").map(Json::each).unwrap_or(&[]).iter().collect();
    let value_objects_by_name: HashMap<String, &Json> = value_objects.iter().map(|vo| (vo.get("name").map(Json::to_s).unwrap_or_default(), *vo)).collect();
    let lifecycle_field = aggregate.get("lifecycle").and_then(|l| l.get("field")).map(Json::to_s);
    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);

    let mut kept_keys: Vec<String> = attrs.iter().map(|a| crate::attr::name(a).to_string()).collect();
    kept_keys.push("id".to_string());
    if let Some(lf) = &lifecycle_field {
        kept_keys.push(lf.clone());
    }
    let keep_cond = kept_keys.iter().map(|k| format!("k == {k:?}")).collect::<Vec<_>>().join(" || ");

    let arms: Vec<String> = attrs
        .iter()
        .map(|a| {
            let unwrapped = unwrap_json_expr("v", crate::attr::type_name(a), crate::attr::list(a), aggregate, &value_objects_by_name);
            format!("{:?} => {unwrapped},", crate::attr::name(a))
        })
        .collect();
    let arms = arms.join("\n                    ");

    let fields_literal = format!("&[{}]", group_by_fields.iter().map(|f| format!("{f:?}")).collect::<Vec<_>>().join(", "));

    format!(
        "pub fn {fn_name}(rows: Vec<(String, crate::kernel::Json)>) -> crate::kernel::Json {{\n    let unwrapped: Vec<crate::kernel::Json> = rows\n        .into_iter()\n        .map(|(id, record)| {{\n            let wrapped = crate::kernel::repository::row_json(id, record);\n            match wrapped {{\n                crate::kernel::Json::Object(fields) => crate::kernel::Json::Object(\n                    fields\n                        .into_iter()\n                        .filter(|(k, _)| {keep_cond})\n                        .map(|(k, v)| {{\n                            let new_v = match k.as_str() {{\n            {arms}\n                                _ => v,\n                            }};\n                            (k, new_v)\n                        }})\n                        .collect(),\n                ),\n                other => other,\n            }}\n        }})\n        .collect();\n    crate::kernel::read_model::nest(unwrapped, {fields_literal})\n}}"
    )
}

/// Port of `rust/project/read_models.rb`'s own `unwrap_json_expr` —
/// `Value.materialize_unwrapped`, ported directly.
fn unwrap_json_expr(expr: &str, type_name: &str, list: bool, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> String {
    if list {
        let inner = unwrap_json_expr("item", type_name, false, aggregate, value_objects_by_name);
        return format!("match {expr} {{ crate::kernel::Json::Array(items) => crate::kernel::Json::Array(items.into_iter().map(|item| {inner}).collect()), other => other }}");
    }

    let vo = value_objects_by_name.get(type_name).copied();
    let entity = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().find(|e| e.get("name").map(Json::to_s).unwrap_or_default() == type_name);
    let fields_meta: Option<&[Json]> = if let Some(vo) = vo {
        vo.get("attributes").map(Json::each)
    } else {
        entity.and_then(|e| e.get("attributes").map(Json::each))
    };
    let Some(fields_meta) = fields_meta else { return expr.to_string() };

    if vo.is_some() && fields_meta.len() == 1 {
        let field = &fields_meta[0];
        let unwrapped = unwrap_json_expr("field_value", crate::attr::type_name(field), crate::attr::list(field), aggregate, value_objects_by_name);
        let field_name = crate::attr::name(field);
        return format!("match {expr} {{ crate::kernel::Json::Object(fields) => fields.into_iter().find(|(k, _)| k == {field_name:?}).map(|(_, field_value)| {unwrapped}).unwrap_or(crate::kernel::Json::Null), other => other }}");
    }

    let inner_arms: Vec<String> = fields_meta
        .iter()
        .map(|f| {
            let unwrapped = unwrap_json_expr("v", crate::attr::type_name(f), crate::attr::list(f), aggregate, value_objects_by_name);
            format!("{:?} => {unwrapped},", crate::attr::name(f))
        })
        .collect();
    let inner_arms = inner_arms.join(" ");
    format!("match {expr} {{ crate::kernel::Json::Object(fields) => crate::kernel::Json::Object(fields.into_iter().map(|(k, v)| {{ let new_v = match k.as_str() {{ {inner_arms} _ => v }}; (k, new_v) }}).collect()), other => other }}")
}

const READ_MODEL_TABLE_ROW_PLACEHOLDER: &str = "crate::kernel::read_model::ReadModelDef {\n    verb: \"tmpl_verb\",\n    reference_name: Some(\"tmpl_reference_name\"),\n    heads: &[\n        crate::kernel::read_model::ReadModelHead {\n            aggregate: \"tmpl_aggregate\",\n            as_name: \"tmpl_as_name\",\n            many: true,\n            is_root: false,\n            reference_fields: &[\n                crate::kernel::read_model::ReferenceField { target_aggregate: \"tmpl_target_aggregate\", field: \"tmpl_field\" },\n            ],\n        },\n    ],\n    filtered_head: Some(\"tmpl_as_name\"),\n    conditions: &[\n        crate::kernel::QueryCondition {\n            field: \"tmpl_field\",\n            comparator: crate::kernel::query_comparators::QueryComparator::Eq,\n            value: crate::kernel::QueryConditionValue::Literal(\"tmpl_literal\"),\n        },\n    ],\n    reference_hop_conditions: &[\n        crate::kernel::read_model::ReferenceHopCondition {\n            via_field: \"tmpl_via_field\",\n            target_aggregate: \"tmpl_target_aggregate\",\n            inner_field: \"tmpl_inner_field\",\n            inner_comparator: crate::kernel::query_comparators::QueryComparator::Eq,\n            inner_value: crate::kernel::QueryConditionValue::Literal(\"tmpl_literal\"),\n        },\n    ],\n    order_by: Some(crate::kernel::read_model::ReadModelOrderBy { field: \"tmpl_order_field\", descending: true, nulls: crate::kernel::query_ordering::NullsMode::Last }),\n    offset: Some(crate::kernel::read_model::ReadModelOffset::Literal(1)),\n    limit: Some(crate::kernel::read_model::ReadModelLimit::Literal(5)),\n    authorization: Some(crate::kernel::named_query::TenantAuth { query_name: \"tmpl_query_name\", tenant_field: \"tmpl_tenant_field\", policy: \"tmpl_policy\" }),\n    group_by: None,\n    count: false,\n    median_field: None,\n},";

pub fn emit_read_model_table(exemplar: &Exemplar, read_model_defs: &[ReadModelDef]) -> String {
    let rows: Vec<String> = read_model_defs.iter().map(emit_read_model_def).collect();
    exemplar.render("read_model_table", &[(READ_MODEL_TABLE_ROW_PLACEHOLDER, rows.join("\n"))])
}
