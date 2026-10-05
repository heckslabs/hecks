//! Port of the retired Ruby generator's `read_models.rb`, mirrored function for function —
//! read that file's own header for the full algorithm.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::queries;
use crate::skip_reason::{reskip, skip, SkipReason};
use std::collections::HashMap;

const READ_MODEL_BARE_KEYS: &[&str] = &[
    "name", "description", "reference_name", "reference_target", "query_name", "aggregate_heads", "wheres", "order_by", "offset", "limit", "freshness", "index_hints", "group_by", "null_semantics", "authorization", "count", "median_field",
    "sum_field", "avg_field", "min_field", "max_field", "percentile_field", "percentile_at", "any_field", "all_field",
];

// Every reduction beyond `count` (which needs no field) — mirrors
// Runtime::ReadModelInterpreter::REDUCTION_WORD/INTEGER_ONLY_REDUCTIONS/BOOLEAN_REDUCTIONS
// (ADR 0078).
const AGGREGATION_FIELD_KEYS: &[&str] = &["median_field", "sum_field", "avg_field", "min_field", "max_field", "percentile_field", "any_field", "all_field"];
const INTEGER_ONLY_AGGREGATION_FIELDS: &[&str] = &["sum_field", "avg_field"];
const BOOLEAN_AGGREGATION_FIELDS: &[&str] = &["any_field", "all_field"];

pub fn read_model_skip_reason(read_model: &Json, aggregates_by_name: &HashMap<String, &Json>, unsupported_names: &[String]) -> Option<SkipReason> {
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
    // Rootless (no `reference_to`) is generated — `read_models.rb`'s own
    // comment on this check.
    if root.is_none() && !reference_target.is_empty() {
        return Some(skip(
            "missing_root_head",
            format!("declares reference_to {reference_target}, but includes no matching aggregate head — nothing for this generator's own root fetch to key off"),
        ));
    }

    let root_name = root.and_then(|h| h.get("aggregate")).map(Json::to_s).unwrap_or_default();
    if !aggregates_by_name.contains_key(&root_name) && nested_entity_names(aggregates_by_name).contains(&root_name) {
        return Some(entity_head_skip_reason(&root_name, "root", "fetch by id"));
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

fn read_model_options_skip_reason(extra: &[&str]) -> SkipReason {
    let mut sorted: Vec<&str> = extra.to_vec();
    sorted.sort();
    skip(sorted[0], format!(
        "declares {} — out of scope for this generator: cursor/consistency/inspection are real capabilities Ports::Query::InMemory/Ports::Query::Ordering/TenantScope implement that this generator does not port (this file's own header has the full argument, the same boundary queries.rb already draws for a declared AGGREGATE query); freshness/use_index are never disqualifying on their own — neither is read by the in-memory interpreter path this kernel matches",
        sorted.join(", ")
    ))
}

/// Every many-side head this read model declares.
fn read_model_many_heads(read_model: &Json) -> Vec<&Json> {
    read_model.get("aggregate_heads").map(Json::each).unwrap_or(&[]).iter().filter(|h| h.get("many").map(Json::as_bool).unwrap_or(false)).collect()
}

/// Whether one declared option (its own `:target`, or `None` when untargeted) applies to
/// `head`. `target` names the included aggregate by TYPE (ADR 0055), not by its `as:` alias;
/// `None` only ever means "the sole many-side head" — Ruby's own `seal_query_options` refuses
/// an untargeted option whenever a read model declares more than one, so an untargeted option
/// reaching codegen at all is proof there's exactly one to mean.
fn option_target_matches_head(target: Option<&str>, head: &Json, many_heads: &[&Json]) -> bool {
    let head_as = head.get("as").map(Json::to_s).unwrap_or_default();
    match target {
        None => many_heads.len() == 1 && many_heads[0].get("as").map(Json::to_s).unwrap_or_default() == head_as,
        Some(target) => target == head.get("aggregate").map(Json::to_s).unwrap_or_default(),
    }
}

fn json_target(option: &Json) -> Option<String> {
    option.get("target").map(Json::to_s)
}

/// Whether `head` has at least one declared where/order_by/offset/limit (or, for the sole
/// many-side head only, a declared `authorize ..., tenant:` — `on:` doesn't extend to
/// `tenant:`) targeting it.
fn read_model_option_targets_head(read_model: &Json, head: &Json, many_heads: &[&Json]) -> bool {
    let wheres = read_model.get("wheres").map(Json::each).unwrap_or(&[]);
    if wheres.iter().any(|w| option_target_matches_head(json_target(w).as_deref(), head, many_heads)) {
        return true;
    }
    if let Some(order_by) = read_model.get("order_by") {
        if option_target_matches_head(json_target(order_by).as_deref(), head, many_heads) {
            return true;
        }
    }
    if let Some(limit) = read_model.get("limit") {
        if option_target_matches_head(json_target(limit).as_deref(), head, many_heads) {
            return true;
        }
    }
    if let Some(offset) = read_model.get("offset") {
        if option_target_matches_head(json_target(offset).as_deref(), head, many_heads) {
            return true;
        }
    }
    if read_model.get("authorization").and_then(|a| a.get("tenant")).is_some() && many_heads.len() == 1 {
        return many_heads[0].get("as").map(Json::to_s).unwrap_or_default() == head.get("as").map(Json::to_s).unwrap_or_default();
    }
    false
}

/// Every many-side head this read model declares options for, in `aggregate_heads`' own
/// declared order — one entry when there's a single many-side head (the pre-ADR-0055 shape),
/// more than one only when `on:` targets several.
fn read_model_filtered_heads<'a>(read_model: &Json, many_heads: &[&'a Json]) -> Vec<&'a Json> {
    many_heads.iter().copied().filter(|head| read_model_option_targets_head(read_model, head, many_heads)).collect()
}

/// One targeted head's own where/order_by/offset/limit, pulled out of the read model's full
/// declared set. `authorization` carries `read_model`'s own declared authorization only for the
/// sole many-side head (`on:` doesn't extend to `tenant:`), `None` for every other targeted head.
struct HeadQuery<'a> {
    wheres: Vec<&'a Json>,
    order_by: Option<&'a Json>,
    limit: Option<&'a Json>,
    offset: Option<&'a Json>,
    authorization: Option<&'a Json>,
}

fn read_model_head_query<'a>(read_model: &'a Json, head: &Json, many_heads: &[&Json]) -> HeadQuery<'a> {
    let wheres = read_model.get("wheres").map(Json::each).unwrap_or(&[]).iter().filter(|w| option_target_matches_head(json_target(w).as_deref(), head, many_heads)).collect();
    let order_by = read_model.get("order_by").filter(|ob| option_target_matches_head(json_target(ob).as_deref(), head, many_heads));
    let limit = read_model.get("limit").filter(|l| option_target_matches_head(json_target(l).as_deref(), head, many_heads));
    let offset = read_model.get("offset").filter(|o| option_target_matches_head(json_target(o).as_deref(), head, many_heads));
    let authorization = if many_heads.len() == 1 && many_heads[0].get("as").map(Json::to_s).unwrap_or_default() == head.get("as").map(Json::to_s).unwrap_or_default() {
        read_model.get("authorization")
    } else {
        None
    };
    HeadQuery { wheres, order_by, limit, offset, authorization }
}

/// Checks every targeted head's own where/order_by/limit for generability against ITS
/// aggregate (not the read model's root); `None` means clean.
fn read_model_options_content_skip_reason(read_model: &Json, aggregates_by_name: &HashMap<String, &Json>) -> Option<SkipReason> {
    let many_heads = read_model_many_heads(read_model);

    for head in read_model_filtered_heads(read_model, &many_heads) {
        let aggregate_name = head.get("aggregate").map(Json::to_s).unwrap_or_default();
        let Some(aggregate) = aggregates_by_name.get(&aggregate_name) else {
            return Some(entity_head_skip_reason(&aggregate_name, "filtered head", "filter, order or authorize"));
        };
        let vos = aggregate.get("value_objects").map(Json::each).unwrap_or(&[]);
        let value_objects_by_name: HashMap<String, &Json> = vos.iter().map(|vo| (vo.get("name").and_then(Json::as_str).unwrap_or("").to_string(), vo)).collect();
        let as_name = head.get("as").map(Json::to_s).unwrap_or_default();
        let head_label = format!("head {aggregate_name} (as {as_name})");
        let head_query = read_model_head_query(read_model, head, &many_heads);

        // A hop through a reference is generated when `query_hop_plan` resolves
        // it — `read_models.rb`'s own loop, check for check.
        for where_clause in head_query.wheres.iter().copied() {
            let field = where_clause.get("field").map(Json::to_s).unwrap_or_default();
            let hop = queries::query_hop_plan(aggregate, &field, aggregates_by_name);
            if hop.is_none() && field.contains('/') {
                return Some(skip(
                    "reference_hop_where",
                    format!(
                        "{head_label}'s own where clause on {} hops through a reference this generator can't resolve yet (more than one hop, the head isn't a real reference attribute, or the target aggregate isn't declared in this domain) — not generated yet",
                        crate::naming::ruby_inspect_string(&field)
                    ),
                ));
            }

            if let Some(plan) = hop {
                let target_value_objects_by_name = queries::value_objects_of(plan.target);
                if let Some(reason) = queries::query_where_skip_reason(&queries::with_field(where_clause, &plan.inner_field), plan.target, &target_value_objects_by_name) {
                    return Some(reskip(&reason, format!("{head_label}'s own hop through {} to {}'s own {reason}", plan.via_field, plan.target_aggregate)));
                }
                continue;
            }

            if let Some(reason) = queries::query_where_skip_reason(where_clause, aggregate, &value_objects_by_name) {
                return Some(reskip(&reason, format!("{head_label}'s own {reason}")));
            }
        }

        if let Some(reason) = queries::declared_authorization_skip_reason(head_query.authorization, aggregate, &value_objects_by_name) {
            return Some(reason);
        }

        if let Some(reason) = queries::declared_order_by_skip_reason(head_query.order_by, aggregate, &value_objects_by_name) {
            return Some(reason);
        }

        if let Some(reason) = queries::declared_offset_skip_reason(head_query.offset) {
            return Some(reason);
        }

        if let Some(reason) = queries::declared_limit_skip_reason(head_query.limit) {
            return Some(reason);
        }
    }

    None
}

// `seal_aggregation` (Ruby, build time) already guarantees exactly one
// many-side head and mutual exclusion with `group_by` — only the one declared
// reduction's own field needs checking here (ADR 0078).
fn aggregation_skip_reason(read_model: &Json, aggregates_by_name: &HashMap<String, &Json>) -> Option<SkipReason> {
    let field_key = AGGREGATION_FIELD_KEYS.iter().find(|key| read_model.get(**key).is_some())?;
    let field = Json::to_s(read_model.get(*field_key).expect("checked by find above"));
    let word = field_key.strip_suffix("_field").unwrap_or(field_key);

    let heads = read_model.get("aggregate_heads").map(Json::each).unwrap_or(&[]);
    let target = heads.iter().find(|h| h.get("many").map(Json::as_bool).unwrap_or(false))?;
    let aggregate_name = target.get("aggregate").map(Json::to_s).unwrap_or_default();
    let Some(aggregate) = aggregates_by_name.get(&aggregate_name) else {
        return Some(entity_head_skip_reason(&aggregate_name, &format!("{word} target"), "reduce"));
    };
    let vos = aggregate.get("value_objects").map(Json::each).unwrap_or(&[]);
    let value_objects_by_name: HashMap<String, &Json> = vos.iter().map(|vo| (vo.get("name").and_then(Json::as_str).unwrap_or("").to_string(), vo)).collect();

    let kind = queries::query_field_kind(aggregate, &field, &value_objects_by_name);
    if kind == queries::FieldKind::Unknown {
        return Some(skip(*field_key, format!("{word} names {field:?}, but {aggregate_name} declares no such attribute — not generated yet")));
    }

    if BOOLEAN_AGGREGATION_FIELDS.contains(field_key) {
        return if queries::query_field_boolean(aggregate, &field, &value_objects_by_name) {
            None
        } else {
            Some(skip(*field_key, format!("{word} names {field:?} on {aggregate_name}, which is not boolean — {word} needs a true/false field — not generated yet")))
        };
    }

    if kind != queries::FieldKind::Number {
        return Some(skip(
            *field_key,
            format!("{word} names {field:?} on {aggregate_name}, which is not numeric — {word} needs a numeric field (a bare number, or a value object carrying one) — not generated yet"),
        ));
    }

    if INTEGER_ONLY_AGGREGATION_FIELDS.contains(field_key) {
        if queries::query_field_numeric_type(aggregate, &field, &value_objects_by_name).as_deref() != Some("Integer") {
            return Some(skip(
                *field_key,
                format!("{word} names {field:?} on {aggregate_name}, which is a Float field — {word} admits only an Integer field (summing/averaging Floats cannot be made to agree, byte for byte, between Ruby and Rust) — not generated yet"),
            ));
        }
    }

    None
}

// Mirrors the retired Ruby generator's `read_models.rb`'s `group_by_skip_reason`: the one
// shape the corpus declares — a single rootless head, group_by alone.
fn group_by_skip_reason(read_model: &Json, aggregates_by_name: &HashMap<String, &Json>, unsupported_names: &[String]) -> Option<SkipReason> {
    let heads = read_model.get("aggregate_heads").map(Json::each).unwrap_or(&[]);
    if heads.len() != 1 {
        return Some(skip("group_by", format!("declares group_by across {} aggregate heads — not generated yet (only a single, rootless head is)", heads.len())));
    }
    let reference_target = read_model.get("reference_target");
    if reference_target.is_some() && !matches!(reference_target, Some(Json::Null)) {
        return Some(skip("group_by", format!("declares group_by on a NON-rootless read model (reference_to {}) — not generated yet", reference_target.map(Json::to_s).unwrap_or_default())));
    }
    if read_model.get("count").is_some() || AGGREGATION_FIELD_KEYS.iter().any(|key| read_model.get(*key).is_some()) {
        return Some(skip("group_by", "declares group_by alongside a reduction — not generated yet"));
    }
    let has_wheres = read_model.get("wheres").map(Json::each).unwrap_or(&[]).iter().any(|_| true);
    if has_wheres || read_model.get("order_by").is_some() || read_model.get("limit").is_some() || read_model.get("offset").is_some() {
        return Some(skip("group_by", "declares group_by alongside where/order_by/limit/offset — not generated yet"));
    }
    if read_model.get("authorization").is_some() {
        return Some(skip("group_by", "declares group_by with an authorize policy — not generated yet"));
    }

    let head = &heads[0];
    if let Some(reason) = read_model_head_skip_reason(head, aggregates_by_name, unsupported_names) {
        return Some(reason);
    }

    let aggregate_name = head.get("aggregate").map(Json::to_s).unwrap_or_default();
    let Some(aggregate) = aggregates_by_name.get(&aggregate_name) else {
        return Some(entity_head_skip_reason(&aggregate_name, "group_by head", "group"));
    };
    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let lifecycle_field = aggregate.get("lifecycle").and_then(|l| l.get("field")).map(Json::to_s);
    for row in read_model.get("group_by").map(Json::each).unwrap_or(&[]) {
        let field = row.get("field").map(Json::to_s).unwrap_or_default();
        let is_attr = attrs.iter().any(|a| crate::attr::name(a) == field);
        let is_lifecycle = lifecycle_field.as_deref() == Some(field.as_str());
        if !is_attr && !is_lifecycle {
            return Some(skip("group_by", format!("group_by names {field:?}, but {aggregate_name} declares no such attribute — not generated yet")));
        }
    }
    None
}

// Every entity name nested at any depth under a declared aggregate.
fn nested_entity_names(aggregates_by_name: &HashMap<String, &Json>) -> Vec<String> {
    fn collect(owner: &Json, out: &mut Vec<String>) {
        for entity in owner.get("entities").map(Json::each).unwrap_or(&[]) {
            out.push(entity.get("name").map(Json::to_s).unwrap_or_default());
            collect(entity, out);
        }
    }
    let mut out = Vec::new();
    for aggregate in aggregates_by_name.values() {
        collect(aggregate, &mut out);
    }
    out
}

/// Port of `read_models.rb#entity_head_skip_reason`.
fn entity_head_skip_reason(aggregate_name: &str, role: &str, purpose: &str) -> SkipReason {
    skip(
        "include_entity_head",
        format!("includes {aggregate_name}, a nested entity, as the {role} — an entity has no rows of its own (ReadModelInterpreter#records reads it as empty), so there is nothing to {purpose} — not generated yet"),
    )
}

fn read_model_head_skip_reason(head: &Json, aggregates_by_name: &HashMap<String, &Json>, unsupported_names: &[String]) -> Option<SkipReason> {
    let aggregate_name = head.get("aggregate").map(Json::to_s).unwrap_or_default();
    if !aggregates_by_name.contains_key(&aggregate_name) {
        if nested_entity_names(aggregates_by_name).contains(&aggregate_name) {
            return None;
        }
        return Some(skip("include_undeclared_aggregate", format!("includes {aggregate_name}, which this domain never declares")));
    }
    if unsupported_names.contains(&aggregate_name) {
        return Some(skip(
            "include_unsupported_aggregate",
            format!("includes {aggregate_name}, which this generator couldn't itself generate (unsupported attribute type — see this domain's own aggregate-level manifest entry)"),
        ));
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

// `ReadModelOffset` is a type alias for `ReadModelLimit`'s own type, so this
// reuses `emit_read_model_limit`'s computation and swaps the type name.
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

/// One targeted many-side head's own where/order_by/offset/limit — the per-head analogue of
/// `ReadModelDef` itself. At most one when there's a single many-side head (the pre-ADR-0055
/// shape); more than one only when `on:` targets several.
pub struct FilteredHeadDef {
    pub as_name: String,
    pub conditions: Vec<queries::Condition>,
    pub reference_hop_conditions: Vec<queries::HopCondition>,
    pub order_by: Option<String>,
    pub offset: Option<String>,
    pub limit: Option<String>,
}

pub struct ReadModelDef {
    pub verb: String,
    pub reference_name: Option<String>,
    pub heads: Vec<String>,
    pub filtered_heads: Vec<FilteredHeadDef>,
    pub authorization: Option<String>,
    pub group_by_fn: Option<String>,
    pub group_by_fn_body: Option<String>,
    pub count: bool,
    pub median_field: Option<String>,
    pub sum_field: Option<String>,
    pub avg_field: Option<String>,
    pub min_field: Option<String>,
    pub max_field: Option<String>,
    pub percentile_field: Option<String>,
    pub percentile_at: Option<String>,
    pub any_field: Option<String>,
    pub all_field: Option<String>,
}

/// `local_wheres, hop_wheres` compiled for one targeted head, mirroring
/// `read_models.rb#filtered_head_def`.
fn filtered_head_def(domain_name: &str, read_model: &Json, head: &Json, many_heads: &[&Json], aggregates_by_name: &HashMap<String, &Json>) -> FilteredHeadDef {
    let aggregate_name = head.get("aggregate").map(Json::to_s).unwrap_or_default();
    let aggregate = aggregates_by_name[&aggregate_name];
    let head_query = read_model_head_query(read_model, head, many_heads);
    let (local_wheres, hop_wheres): (Vec<&Json>, Vec<&Json>) =
        head_query.wheres.iter().copied().partition(|w| queries::query_hop_plan(aggregate, &w.get("field").map(Json::to_s).unwrap_or_default(), aggregates_by_name).is_none());
    let synthetic = with_wheres_and_authorization(&local_wheres, head_query.authorization);
    let conditions = if head_query.authorization.is_some() { queries::query_conditions_with_authorization(&synthetic) } else { queries::query_conditions(&synthetic) };

    FilteredHeadDef {
        as_name: head.get("as").map(Json::to_s).unwrap_or_default(),
        conditions,
        reference_hop_conditions: queries::read_model_hop_conditions(domain_name, &hop_wheres, aggregate, aggregates_by_name),
        order_by: head_query.order_by.map(|ob| emit_read_model_order_by(ob, read_model.get("null_semantics"))),
        offset: head_query.offset.map(emit_read_model_offset),
        limit: head_query.limit.map(emit_read_model_limit),
    }
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

    let many_heads = read_model_many_heads(read_model);
    let filtered_heads: Vec<FilteredHeadDef> =
        read_model_filtered_heads(read_model, &many_heads).into_iter().map(|head| filtered_head_def(domain_name, read_model, head, &many_heads, aggregates_by_name)).collect();
    let sole_head_as: bool = many_heads.len() == 1;

    let read_model_name = read_model.get("name").map(Json::to_s).unwrap_or_default();
    let group_by_fields: Vec<String> = read_model.get("group_by").map(Json::each).unwrap_or(&[]).iter().map(|row| row.get("field").map(Json::to_s).unwrap_or_default()).collect();
    let (group_by_fn, group_by_fn_body) = if !group_by_fields.is_empty() {
        let fn_name = format!("group_by_{}", read_model_name.to_lowercase());
        let aggregate_name = heads_json.first().and_then(|h| h.get("aggregate")).map(Json::to_s).unwrap_or_default();
        let aggregate = aggregates_by_name[&aggregate_name];
        (Some(fn_name.clone()), Some(emit_group_by_transform(&fn_name, &read_model_name, aggregate, &group_by_fields)))
    } else {
        (None, None)
    };

    ReadModelDef {
        verb: format!("{domain_name}.{read_model_name}"),
        reference_name: read_model.get("reference_name").map(Json::to_s),
        heads,
        filtered_heads,
        authorization: if sole_head_as { queries::emit_query_authorization(&read_model_name, read_model.get("authorization")) } else { None },
        group_by_fn,
        group_by_fn_body,
        count: read_model.get("count").is_some(),
        median_field: read_model.get("median_field").map(Json::to_s),
        sum_field: read_model.get("sum_field").map(Json::to_s),
        avg_field: read_model.get("avg_field").map(Json::to_s),
        min_field: read_model.get("min_field").map(Json::to_s),
        max_field: read_model.get("max_field").map(Json::to_s),
        percentile_field: read_model.get("percentile_field").map(Json::to_s),
        percentile_at: if read_model.get("percentile_field").is_some() { read_model.get("percentile_at").map(Json::to_s) } else { None },
        any_field: read_model.get("any_field").map(Json::to_s),
        all_field: read_model.get("all_field").map(Json::to_s),
    }
}

/// A minimal `{wheres:, authorization:}` object — everything `query_conditions`/
/// `query_conditions_with_authorization` actually read — for one targeted head's own local
/// (non-hop) where clauses.
fn with_wheres_and_authorization(wheres: &[&Json], authorization: Option<&Json>) -> Json {
    let wheres_json = Json::Array(wheres.iter().map(|w| (*w).clone()).collect());
    let mut pairs = vec![("wheres".to_string(), wheres_json)];
    if let Some(auth) = authorization {
        pairs.push(("authorization".to_string(), auth.clone()));
    }
    Json::Object(pairs)
}

pub fn emit_read_model_def(rmd: &ReadModelDef) -> String {
    let heads = rmd.heads.iter().map(|h| format!("        {h},")).collect::<Vec<_>>().join("\n");
    let filtered_heads = rmd.filtered_heads.iter().map(|fh| format!("        {}", emit_filtered_head(fh))).collect::<Vec<_>>().join("\n");
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
    let field_some = |f: &Option<String>| match f {
        Some(v) => format!("Some({})", crate::naming::ruby_inspect_string(v)),
        None => "None".to_string(),
    };
    let median_field = field_some(&rmd.median_field);
    let sum_field = field_some(&rmd.sum_field);
    let avg_field = field_some(&rmd.avg_field);
    let min_field = field_some(&rmd.min_field);
    let max_field = field_some(&rmd.max_field);
    let percentile_field = field_some(&rmd.percentile_field);
    let percentile_at = match &rmd.percentile_at {
        Some(at) => format!("Some({at}_f64)"),
        None => "None".to_string(),
    };
    let any_field = field_some(&rmd.any_field);
    let all_field = field_some(&rmd.all_field);

    format!(
        "crate::kernel::read_model::ReadModelDef {{\n    verb: {},\n    reference_name: {reference_name},\n    heads: &[\n{heads}\n    ],\n    filtered_heads: &[\n{filtered_heads}\n    ],\n    authorization: {authorization},\n    group_by: {group_by},\n    count: {count},\n    median_field: {median_field},\n    sum_field: {sum_field},\n    avg_field: {avg_field},\n    min_field: {min_field},\n    max_field: {max_field},\n    percentile_field: {percentile_field},\n    percentile_at: {percentile_at},\n    any_field: {any_field},\n    all_field: {all_field},\n}},",
        crate::naming::ruby_inspect_string(&rmd.verb)
    )
}

/// One `FilteredHead` entry, always emitted as a single line — matching this generator's own
/// established idiom for every OTHER leaf struct (`ReadModelHead`, `ReferenceField`,
/// `ReferenceHopCondition`, `QueryCondition` are all single-line too; only the top-level
/// `ReadModelDef`/`QueryDef` get pretty multi-line formatting with their arrays broken apart).
fn emit_filtered_head(fh: &FilteredHeadDef) -> String {
    let conditions = fh.conditions.iter().map(queries::emit_query_condition).collect::<Vec<_>>().join(" ");
    let reference_hop_conditions = fh.reference_hop_conditions.iter().map(queries::emit_reference_hop_condition).collect::<Vec<_>>().join(" ");
    let order_by = match &fh.order_by {
        Some(o) => format!("Some({o})"),
        None => "None".to_string(),
    };
    let offset = match &fh.offset {
        Some(o) => format!("Some({o})"),
        None => "None".to_string(),
    };
    let limit = match &fh.limit {
        Some(l) => format!("Some({l})"),
        None => "None".to_string(),
    };

    format!(
        "crate::kernel::read_model::FilteredHead {{ as_name: {}, conditions: &[{conditions}], reference_hop_conditions: &[{reference_hop_conditions}], order_by: {order_by}, offset: {offset}, limit: {limit} }},",
        crate::naming::ruby_inspect_string(&fh.as_name)
    )
}

// Keeps this aggregate's declared attributes plus any `projects` field, id
// and lifecycle field, excluding other capabilities' synthetic fields (like
// `corrects`'s `emitted_*` flags), and unwraps value objects recursively.
fn emit_group_by_transform(fn_name: &str, read_model_name: &str, aggregate: &Json, group_by_fields: &[String]) -> String {
    let value_objects: Vec<&Json> = aggregate.get("value_objects").map(Json::each).unwrap_or(&[]).iter().collect();
    let value_objects_by_name: HashMap<String, &Json> = value_objects.iter().map(|vo| (vo.get("name").map(Json::to_s).unwrap_or_default(), *vo)).collect();
    let lifecycle_field = aggregate.get("lifecycle").and_then(|l| l.get("field")).map(Json::to_s);
    let mut fields: Vec<Json> = aggregate.get("attributes").map(Json::each).unwrap_or(&[]).to_vec();
    fields.extend(crate::types::projected_field_pseudo_attributes(aggregate));

    let mut kept_keys: Vec<String> = fields.iter().map(|a| crate::attr::name(a).to_string()).collect();
    kept_keys.push("id".to_string());
    if let Some(lf) = &lifecycle_field {
        kept_keys.push(lf.clone());
    }
    let keep_cond = kept_keys.iter().map(|k| format!("k == {k:?}")).collect::<Vec<_>>().join(" || ");

    let arms: Vec<String> = fields
        .iter()
        .map(|a| {
            let unwrapped = unwrap_json_expr("v", crate::attr::type_name(a), crate::attr::list(a), aggregate, &value_objects_by_name);
            format!("{:?} => {unwrapped},", crate::attr::name(a))
        })
        .collect();
    let arms = arms.join("\n                    ");

    let fields_literal = format!("&[{}]", group_by_fields.iter().map(|f| format!("{f:?}")).collect::<Vec<_>>().join(", "));
    let leaf_check = group_by_leaf_check(read_model_name, aggregate, group_by_fields);

    format!(
        "pub fn {fn_name}(rows: Vec<(String, crate::kernel::Json)>) -> Result<crate::kernel::Json, crate::kernel::Refusal> {{\n    let unwrapped: Vec<crate::kernel::Json> = rows\n        .into_iter()\n        .map(|(id, record)| {{\n            let wrapped = crate::kernel::repository::row_json(id, record);\n            match wrapped {{\n                crate::kernel::Json::Object(fields) => crate::kernel::Json::Object(\n                    fields\n                        .into_iter()\n                        .filter(|(k, _)| {keep_cond})\n                        .map(|(k, v)| {{\n                            let new_v = match k.as_str() {{\n            {arms}\n                                _ => v,\n                            }};\n                            (k, new_v)\n                        }})\n                        .collect(),\n                ),\n                other => other,\n            }}\n        }})\n        .collect();\n    crate::kernel::read_model::nest(unwrapped, {fields_literal}, {leaf_check})\n}}"
    )
}

// A key path naming every identity head cannot collide, so its leaves go
// unchecked; any other refuses a second row (ADR 0061).
fn group_by_leaf_check(read_model_name: &str, aggregate: &Json, group_by_fields: &[String]) -> String {
    let mut identity: Vec<String> = Vec::new();
    for path in aggregate.get("identified_by").map(Json::each).unwrap_or(&[]) {
        let head = path.to_s().split('.').next().unwrap_or_default().to_string();
        if !identity.contains(&head) {
            identity.push(head);
        }
    }
    if !identity.is_empty() && identity.iter().all(|head| group_by_fields.contains(head)) {
        return "crate::kernel::read_model::LeafCheck::IdentityCovered".to_string();
    }
    format!("crate::kernel::read_model::LeafCheck::RefuseCollision({})", crate::naming::ruby_inspect_string(read_model_name))
}

// Port of `Value.materialize_unwrapped` (Ruby).
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

const READ_MODEL_TABLE_ROW_PLACEHOLDER: &str = "crate::kernel::read_model::ReadModelDef {\n    verb: \"tmpl_verb\",\n    reference_name: Some(\"tmpl_reference_name\"),\n    heads: &[\n        crate::kernel::read_model::ReadModelHead {\n            aggregate: \"tmpl_aggregate\",\n            as_name: \"tmpl_as_name\",\n            many: true,\n            is_root: false,\n            reference_fields: &[\n                crate::kernel::read_model::ReferenceField { target_aggregate: \"tmpl_target_aggregate\", field: \"tmpl_field\" },\n            ],\n        },\n    ],\n    filtered_heads: &[\n        crate::kernel::read_model::FilteredHead { as_name: \"tmpl_as_name\", conditions: &[crate::kernel::QueryCondition { field: \"tmpl_field\", comparator: crate::kernel::query_comparators::QueryComparator::Eq, value: crate::kernel::QueryConditionValue::Literal(\"tmpl_literal\") },], reference_hop_conditions: &[crate::kernel::read_model::ReferenceHopCondition { via_field: \"tmpl_via_field\", target_aggregate: \"tmpl_target_aggregate\", through: &[crate::kernel::read_model::HopStep { via_field: \"tmpl_via_field\", target_aggregate: \"tmpl_target_aggregate\" }], inner_field: \"tmpl_inner_field\", inner_comparator: crate::kernel::query_comparators::QueryComparator::Eq, inner_value: crate::kernel::QueryConditionValue::Literal(\"tmpl_literal\") },], order_by: Some(crate::kernel::read_model::ReadModelOrderBy { field: \"tmpl_order_field\", descending: true, nulls: crate::kernel::query_ordering::NullsMode::Last }), offset: Some(crate::kernel::read_model::ReadModelOffset::Literal(1)), limit: Some(crate::kernel::read_model::ReadModelLimit::Literal(5)) },\n    ],\n    authorization: Some(crate::kernel::named_query::TenantAuth { query_name: \"tmpl_query_name\", tenant_field: \"tmpl_tenant_field\", policy: \"tmpl_policy\" }),\n    group_by: None,\n    count: false,\n    median_field: None,\n    sum_field: None,\n    avg_field: None,\n    min_field: None,\n    max_field: None,\n    percentile_field: None,\n    percentile_at: None,\n    any_field: None,\n    all_field: None,\n},";

pub fn emit_read_model_table(exemplar: &Exemplar, read_model_defs: &[ReadModelDef]) -> String {
    let rows: Vec<String> = read_model_defs.iter().map(emit_read_model_def).collect();
    exemplar.render("read_model_table", &[(READ_MODEL_TABLE_ROW_PLACEHOLDER, rows.join("\n"))])
}
