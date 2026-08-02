use crate::ir::{
    Aggregate, Attribute, AuthorizationSpec, Command, ConsistencySpec, CursorSpec, Direction,
    Domain, Entity, FreshnessSpec, IndexHint, InspectionSpec, Lifecycle, MutationOp,
    NullSemanticsSpec, OffsetSpec, Policy, ProcessManager, ProcessManagerHandler, Query,
    ReadModel, Transition, ValueObject, ValueSpec, WhereClause, WhereOp,
};
use serde_json::{json, Map, Value};

pub fn domain_to_value(domain: &Domain) -> Value {
    let aggregates: Vec<Value> = domain.aggregates.iter().map(aggregate_to_value).collect();
    let read_models: Vec<Value> = domain.read_models.iter().map(|model| {
        let mut value = json!({
            "name": model.name, "description": optional(&model.description),
            "reference_name": model.reference_name, "reference_target": model.reference_target,
            "aggregate_heads": model.aggregate_heads.iter().map(|head| json!({
                "aggregate": head.aggregate, "as": head.r#as, "many": head.many
            })).collect::<Vec<_>>(),
            "query_name": crate::naming::snake(&model.name)
        });
        merge_query_options(value.as_object_mut().expect("read_model value is an object"), model.into());
        value
    }).collect();

    let mut domains = Map::new();
    domains.insert(
        domain.name.clone(),
        json!({
            "name": domain.name,
            "version": optional(&domain.version),
            "vision": optional(&domain.vision),
            "classification": optional(&domain.classification),
            "aggregates": aggregates,
            "read_models": read_models,
            "policies": domain.policies.iter().map(policy_to_value).collect::<Vec<_>>(),
            "process_managers": domain.process_managers.iter()
                .map(process_manager_to_value).collect::<Vec<_>>(),
            "canonical_form": canonical_form_table()
        }),
    );
    Value::Object(domains)
}

fn aggregate_to_value(aggregate: &Aggregate) -> Value {
    json!({
        "name": aggregate.name,
        "description": optional(&aggregate.description),
        // A LIST, matching Ruby's `identity_paths` — the wire format for a
        // declared identity is always a list of parts, empty when nothing is
        // declared. There is no "id" default any more : an aggregate that names
        // no field is an aggregate that names no field, not a hidden mint. The
        // IR holds it as a list too now, so this is a copy, not a widening.
        "identified_by": aggregate.identified_by,
        // References included, already in place — `reference_to` leaves an
        // attribute, and the parser is what put it at the front.
        "attributes": aggregate.attributes.iter().map(attribute_to_value).collect::<Vec<_>>(),
        "value_objects": aggregate.value_objects.iter().map(value_object_to_value).collect::<Vec<_>>(),
        "commands": aggregate.commands.iter().map(command_to_value).collect::<Vec<_>>(),
        "lifecycle": aggregate.lifecycle.as_ref().map(lifecycle_to_value),
        "entities": aggregate.entities.iter().map(entity_to_value).collect::<Vec<_>>(),
        "queries": aggregate.queries.iter().map(query_to_value).collect::<Vec<_>>()

    })
}

fn entity_to_value(entity: &Entity) -> Value {
    json!({
        "name": entity.name,
        "description": optional(&entity.description),
        "identified_by": entity.identified_by,
        "attributes": entity.attributes.iter().map(attribute_to_value).collect::<Vec<_>>(),
        "commands": entity.commands.iter().map(command_to_value).collect::<Vec<_>>(),
        "queries": entity.queries.iter().map(query_to_value).collect::<Vec<_>>(),
        "lifecycle": entity.lifecycle.as_ref().map(lifecycle_to_value)
    })
}

fn query_to_value(query: &Query) -> Value {
    let mut value = json!({
        "name": query.name,
        "description": optional(&query.description),
        "attributes": query.attributes.iter().map(attribute_to_value).collect::<Vec<_>>(),
        "wheres": query.wheres.iter().map(where_to_value).collect::<Vec<_>>(),
        "order_by": query.order_by.as_ref().map(|o| json!({
            "field": o.field,
            "direction": match o.direction { Direction::Desc => "desc", _ => "asc" }
        })),
        "limit": query.limit.as_ref().map(|l| json!({ "value": l.value }))
    });
    merge_query_options(value.as_object_mut().expect("query_to_value builds an object"), query.into());
    value
}

// THE EIGHT SPECIFICATION OPTIONS, OMITTED WHEN UNSET — not carried as `null`.
// Ruby's `extra_options_to_h` drops a key from the wire entirely when its value
// is nil (or `[]`, or `null_semantics` at its untouched "native" default), so a
// query or read model that never declares `offset` has NO `offset` key at all,
// not one holding `null`. `Query` and `ReadModel` share the same eight fields
// (both inherit `QuerySpecification::Common::Options` on the Ruby side), so this
// one function serves both via the small `QueryOptions` borrow below.
struct QueryOptions<'a> {
    offset: &'a Option<OffsetSpec>,
    cursor: &'a Option<CursorSpec>,
    consistency: &'a Option<ConsistencySpec>,
    freshness: &'a Option<FreshnessSpec>,
    authorization: &'a Option<AuthorizationSpec>,
    null_semantics: &'a Option<NullSemanticsSpec>,
    inspection: &'a Option<InspectionSpec>,
    index_hints: &'a [IndexHint],
}

impl<'a> From<&'a Query> for QueryOptions<'a> {
    fn from(query: &'a Query) -> Self {
        QueryOptions {
            offset: &query.offset,
            cursor: &query.cursor,
            consistency: &query.consistency,
            freshness: &query.freshness,
            authorization: &query.authorization,
            null_semantics: &query.null_semantics,
            inspection: &query.inspection,
            index_hints: &query.index_hints,
        }
    }
}

impl<'a> From<&'a ReadModel> for QueryOptions<'a> {
    fn from(model: &'a ReadModel) -> Self {
        QueryOptions {
            offset: &model.offset,
            cursor: &model.cursor,
            consistency: &model.consistency,
            freshness: &model.freshness,
            authorization: &model.authorization,
            null_semantics: &model.null_semantics,
            inspection: &model.inspection,
            index_hints: &model.index_hints,
        }
    }
}

fn merge_query_options(map: &mut Map<String, Value>, options: QueryOptions) {
    if let Some(offset) = options.offset {
        map.insert("offset".into(), json!({ "value": offset.value }));
    }
    if let Some(cursor) = options.cursor {
        map.insert("cursor".into(), json!({ "value": cursor.value }));
    }
    if let Some(consistency) = options.consistency {
        map.insert(
            "consistency".into(),
            json!({ "mode": consistency.mode, "timeout": consistency.timeout }),
        );
    }
    if let Some(freshness) = options.freshness {
        map.insert(
            "freshness".into(),
            json!({ "mode": freshness.mode, "max_age": freshness.max_age }),
        );
    }
    if let Some(authorization) = options.authorization {
        map.insert(
            "authorization".into(),
            json!({ "policy": authorization.policy, "tenant": authorization.tenant }),
        );
    }
    if let Some(null_semantics) = options.null_semantics {
        map.insert(
            "null_semantics".into(),
            json!({ "mode": null_semantics.mode }),
        );
    }
    if let Some(inspection) = options.inspection {
        map.insert("inspection".into(), json!({ "mode": inspection.mode }));
    }
    if !options.index_hints.is_empty() {
        map.insert(
            "index_hints".into(),
            Value::Array(
                options
                    .index_hints
                    .iter()
                    .map(|hint| json!({ "name": hint.name }))
                    .collect(),
            ),
        );
    }
}

fn where_to_value(clause: &WhereClause) -> Value {
    json!({
        "field": clause.field,
        "op": match clause.op {
            WhereOp::Eq => "eq",
            WhereOp::Ne => "ne",
            WhereOp::Gt => "gt",
            WhereOp::Gte => "gte",
            WhereOp::Lt => "lt",
            WhereOp::Lte => "lte",
            WhereOp::In => "in",
            WhereOp::Contains => "contains"
        },
        "value": clause.value
    })
}

fn policy_to_value(policy: &Policy) -> Value {
    json!({
        "name": policy.name,
        "on_event": policy.on_event,
        "trigger_command": policy.trigger_command,
        "target_domain": optional(&policy.target_domain)
    })
}

fn process_manager_to_value(pm: &ProcessManager) -> Value {
    json!({
        "name": pm.name,
        "correlates_by": pm.correlates_by,
        "starts_on": pm.starts_on,
        "ends_on": optional(&pm.ends_on),
        "states": pm.states,
        "handlers": pm.handlers.iter().map(pm_handler_to_value).collect::<Vec<_>>()
    })
}

fn pm_handler_to_value(handler: &ProcessManagerHandler) -> Value {
    json!({
        "event_type": handler.event_type,
        "from_state": handler.from_state,
        "to_state": handler.to_state,
        "dispatches": handler.dispatches.iter().map(|d| json!({
            "command_name": d.command_name,
            "with_spec": d.with_spec.iter()
                .map(|(key, spec)| json!([key, value_spec_text(spec)]))
                .collect::<Vec<_>>()
        })).collect::<Vec<_>>()
    })
}

fn value_spec_text(spec: &ValueSpec) -> String {
    match spec {
        ValueSpec::Literal { value } => ruby_literal(value),
        ValueSpec::FromEvent { name, .. } => name.clone(),
        ValueSpec::FromPm { name, .. } => name.clone(),
        ValueSpec::FromIter { field } => field.clone(),
    }
}

fn lifecycle_to_value(lifecycle: &Lifecycle) -> Value {
    json!({
        "field": lifecycle.field,
        "default": lifecycle.default,
        "transitions": lifecycle.transitions.iter().map(transition_to_value).collect::<Vec<_>>()
    })
}

fn transition_to_value(transition: &Transition) -> Value {
    json!({
        "command": transition.command,
        "to_state": transition.to_state,
        "from_state": transition.from_state
    })
}

fn attribute_to_value(attribute: &Attribute) -> Value {
    json!({
        "name": attribute.name,
        "type": attribute.r#type,
        "list": attribute.list,
        "default": literal(attribute.default.as_deref()),
        "optional": attribute.optional,
        "pattern": attribute.pattern,
        "admits": attribute.admits
    })
}

fn value_object_to_value(value_object: &ValueObject) -> Value {
    let invariants: Vec<Value> = value_object
        .invariants
        .iter()
        .map(|invariant| {
            json!({
                "description": invariant.description,
                "canonical": canonicalise(&invariant.canonical)
            })
        })
        .collect();

    let members: Vec<Value> = value_object
        .members
        .iter()
        .map(|member| {
            member
                .iter()
                .map(|(field, value)| json!([field, value]))
                .collect::<Vec<_>>()
        })
        .map(Value::from)
        .collect();

    json!({
        "name": value_object.name,
        "attributes": value_object.attributes.iter().map(attribute_to_value).collect::<Vec<_>>(),
        "invariants": invariants,
        "closed_set": value_object.closed_set,
        "members": members
    })
}

fn command_to_value(command: &Command) -> Value {
    let givens: Vec<Value> = command
        .givens
        .iter()
        .map(|given| {
            json!({
                "description": optional(&given.description),
                "canonical": canonicalise(&given.canonical)
            })
        })
        .collect();

    json!({
        "name": command.name,
        "role": optional(&command.role),
        "goal": optional(&command.goal),
        "references": optional(&command.references),
        "attributes": command.attributes.iter().map(attribute_to_value).collect::<Vec<_>>(),
        "givens": givens,
        "mutations": command.mutations.iter().map(mutation_to_value).collect::<Vec<_>>(),
        "emits": command.emits
    })
}

fn mutation_to_value(mutation: &crate::ir::Mutation) -> Value {
    let target = mutation.target.clone();

    if matches!(mutation.op, MutationOp::Append) {
        let mut fields = Map::new();
        let body = mutation
            .source
            .trim()
            .trim_start_matches('{')
            .trim_end_matches('}');

        for pair in body.split(',') {
            if let Some((field, argument)) = pair.split_once(':') {
                let argument = argument.trim().trim_start_matches(':').trim();
                if !argument.is_empty() {
                    fields.insert(
                        field.trim().to_string(),
                        Value::String(ruby_literal(argument)),
                    );
                }
            }
        }
        return json!({ "target": target, "op": "append", "fields": fields });
    }

    let text = mutation.source.trim();
    let source = if let Some(name) = text.strip_prefix(':') {
        json!({ "kind": "argument", "name": name })
    } else {
        json!({ "kind": "literal", "value": literal(Some(text)) })
    };

    let op = match mutation.op {
        MutationOp::Increment => "increment",
        MutationOp::Decrement => "decrement",
        _ => "set",
    };
    json!({ "target": target, "op": op, "source": source })
}

fn canonicalise(source: &str) -> String {
    let mut rules: Vec<&Rule> = RULES.iter().collect();
    rules.sort_by_key(|rule| rule.position);
    let folded = rules
        .iter()
        .fold(source.to_string(), |text, rule| step(&text, rule));
    ruby_strip(&folded).to_string()
}

struct Rule {
    strategy: &'static str,
    source_token: &'static str,
    replacement: &'static str,
    boundary: &'static str,
    position: u8,
}

const RULES: &[Rule] = &[
    Rule {
        strategy: "collapse_whitespace",
        source_token: "",
        replacement: "",
        boundary: "none",
        position: 1,
    },
    Rule {
        strategy: "replace",
        source_token: ".length",
        replacement: ".size",
        boundary: "word",
        position: 2,
    },
];

pub fn canonical_form_table() -> Value {
    let mut rules: Vec<&Rule> = RULES.iter().collect();
    rules.sort_by_key(|rule| rule.position);
    Value::from(
        rules
            .iter()
            .map(|rule| {
                json!({
                    "strategy": rule.strategy,
                    "source_token": rule.source_token,
                    "replacement": rule.replacement,
                    "boundary": rule.boundary,
                    "position": rule.position.to_string()
                })
            })
            .collect::<Vec<_>>(),
    )
}

fn step(text: &str, rule: &Rule) -> String {
    match rule.strategy {
        "collapse_whitespace" => collapse_whitespace(text),
        "replace" => replace(text, rule),
        other => panic!("{other:?} is not a linked normalisation strategy"),
    }
}

const RUBY_ASCII_SPACE: [char; 6] = [' ', '\t', '\n', '\r', '\u{0B}', '\u{0C}'];

fn collapse_whitespace(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_run = false;
    for character in text.chars() {
        if RUBY_ASCII_SPACE.contains(&character) {
            if !in_run {
                out.push(' ');
                in_run = true;
            }
        } else {
            out.push(character);
            in_run = false;
        }
    }
    out
}

fn ruby_strip(text: &str) -> &str {
    text.trim_matches(|c: char| RUBY_ASCII_SPACE.contains(&c) || c == '\0')
}

fn replace(source: &str, rule: &Rule) -> String {
    let mut out = String::with_capacity(source.len());
    let mut rest = source;

    while let Some(at) = rest.find(rule.source_token) {
        let after = &rest[at + rule.source_token.len()..];
        let applies = rule.boundary == "none"
            || after
                .chars()
                .next()
                .map(|c| !(c.is_alphanumeric() || c == '_'))
                .unwrap_or(true);

        out.push_str(&rest[..at]);
        out.push_str(if applies {
            rule.replacement
        } else {
            rule.source_token
        });
        rest = after;
    }

    out.push_str(rest);
    out
}

fn literal(text: Option<&str>) -> Value {
    let text = match text {
        Some(text) => text.trim(),
        None => return Value::Null,
    };

    if text.len() >= 2 && text.starts_with('"') && text.ends_with('"') {
        return Value::String(text[1..text.len() - 1].to_string());
    }
    if text.starts_with('{') && text.ends_with('}') {
        let mut map = Map::new();
        for entry in text[1..text.len() - 1].split(',') {
            let Some((key, value)) = entry.split_once(':') else { continue };
            let key = key.trim().trim_start_matches(':').trim_matches('"');
            if !key.is_empty() {
                map.insert(key.to_string(), literal(Some(value.trim())));
            }
        }
        return Value::Object(map);
    }
    if let Ok(number) = text.parse::<i64>() {
        return Value::from(number);
    }
    if let Ok(number) = text.parse::<f64>() {
        return Value::from(number);
    }
    match text {
        "true" => Value::Bool(true),
        "false" => Value::Bool(false),
        "nil" | "null" | "" => Value::Null,
        other => Value::String(other.to_string()),
    }
}

fn ruby_literal(text: &str) -> String {
    let text = text.trim();
    if !text.starts_with('{') || !text.ends_with('}') {
        return text.to_string();
    }

    let pairs = text[1..text.len() - 1]
        .split(',')
        .filter_map(|entry| entry.split_once(':'))
        .map(|(key, value)| format!(":{}=>{}", key.trim(), value.trim()))
        .collect::<Vec<_>>();
    format!("{{{}}}", pairs.join(", "))
}

fn optional(text: &Option<String>) -> Value {
    match text {
        Some(text) => Value::String(text.clone()),
        None => Value::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::canonicalise;

    #[test]
    fn folds_the_length_alias() {
        assert_eq!(canonicalise("toppings.length < 10"), "toppings.size < 10");
        assert_eq!(canonicalise("value.length"), "value.size");
    }

    #[test]
    fn leaves_a_length_prefixed_member_alone() {
        assert_eq!(canonicalise("dims.length_cm > 0"), "dims.length_cm > 0");
        assert_eq!(canonicalise("a.lengthy"), "a.lengthy");
        assert_eq!(canonicalise("box.length2"), "box.length2");
    }

    #[test]
    fn folds_every_occurrence_and_only_at_a_boundary() {
        assert_eq!(
            canonicalise("a.length + b.length_cm + c.length"),
            "a.size + b.length_cm + c.size"
        );
    }

    #[test]
    fn still_collapses_whitespace() {
        assert_eq!(canonicalise("  a.length   >   0  "), "a.size > 0");
    }

    #[test]
    fn collapses_tabs_and_newlines_the_same_way() {
        assert_eq!(canonicalise("a\t<\n\nb"), "a < b");
    }

    #[test]
    fn leaves_a_non_breaking_space_alone() {
        assert_eq!(canonicalise("a\u{A0}<\u{A0}b"), "a\u{A0}<\u{A0}b");
    }

    #[test]
    fn does_not_strip_a_leading_non_breaking_space() {
        assert_eq!(canonicalise("\u{A0}a < b"), "\u{A0}a < b");
    }
}
