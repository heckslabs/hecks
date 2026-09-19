// THE WHOLE CONSOLE UI, DERIVED — a Rust port of embryonaut_console's
// `web/ui_schema.rb`, rule for rule: one live domain IR plus the
// presentation config (presentation.rs) in, the exact JSON document
// `GET /api/ui-schema` has always served out — nav, per-collection
// columns, detail fields, field shapes, lifecycle transitions and
// create forms.
//
// WHY A SECOND FIELD-SHAPE WALKER LIVES IN THIS CRATE. web.rs already
// has one (`resolve_field`/`value_object_field`), and it is NOT this
// one: that one mirrors `Hecks::Presentation::FieldShape`, which
// answers "what HTML input collects this attribute" for this host's own
// server-rendered forms. This one mirrors `UiSchema.field`, which
// answers "what SHAPE is this attribute" for a JavaScript client that
// renders its own inputs, its own table cells and its own detail rows.
// They agree where the questions coincide (money is `{cents, currency}`
// in both) and deliberately diverge where they don't: FieldShape
// unwraps a single-attribute value object into a plain text input and
// forgets it was ever wrapped, while UiSchema keeps `field: "value"` on
// the descriptor precisely so the client knows the wire value is
// `{value: ...}` and not a bare scalar. Collapsing them would mean one
// of the two consumers reading a shape that was decided for the other.
//
// EVERY DEVIATION WOULD BE A BUG A PERSON SEES — a column that renders
// "[object Object]", a picker that offers a record the server will
// refuse, a nav item that lands nowhere. So the port is literal: same
// dispatch order, same fallbacks, same key names (`targetKey`,
// `stateFilter`, `sortDefault` — camelCase, because index.html reads
// them), same "degrade, don't break the page" treatment of a config
// mistake that `presentation_config.rb` is the strict gate for.

use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::LazyLock;

use regex::Regex;

/// `Hecks::Bluebook::IR::Attribute::PRIMITIVES`.
const PRIMITIVES: &[&str] = &["String", "Integer", "Float", "TrueClass", "FalseClass"];

/// `UiSchema::DISPLAY_BY_SHAPE` — a detail field's default placement,
/// taken from its own shape; `display:` config overrides it.
const DISPLAY_BY_SHAPE: &[(&str, &str)] = &[("text", "prose"), ("lines", "bullet"), ("rows", "rows"), ("compound", "mono")];

/// Shapes a table column can't carry, so they're left out of the
/// default (unconfigured) column list.
const UNCOLUMNABLE: &[&str] = &["rows", "lines", "compound"];

type KeyFor = HashMap<String, String>;

/// `UiSchema.build` — the whole document.
pub fn build(domain_ir: &Value, config: &Value) -> Value {
    let aggregates = aggregates(domain_ir);
    let key_for = key_for(&aggregates, config);
    let by_name: HashMap<&str, &Value> = aggregates.iter().map(|a| (agg_name(a), *a)).collect();

    let mut collections = Map::new();
    for aggregate in &aggregates {
        let key = key_for.get(agg_name(aggregate)).cloned().unwrap_or_default();
        collections.insert(key, build_collection(aggregate, config, &key_for, &by_name));
    }

    json!({
        "domain": domain_ir.get("name").cloned().unwrap_or(Value::Null),
        "collections": Value::Object(collections),
        "nav": build_nav(&aggregates, config, &key_for),
        "overview": build_overview(config),
    })
}

/// `GET /api/schema`'s own body — every real aggregate, its real
/// lifecycle states and its real declared queries, each query argument
/// shaped through the SAME `field` a create form's own inputs go
/// through (so a reference argument still earns a real picker). A pure
/// structural fact with no presentation opinion in it — except the
/// collection KEYS the argument shapes point at, which is why it still
/// takes the config.
pub fn schema(domain_ir: &Value, config: &Value) -> Value {
    let aggregates = aggregates(domain_ir);
    let key_for = key_for(&aggregates, config);

    let mut schema = Map::new();
    for aggregate in &aggregates {
        let queries: Vec<Value> = array(aggregate, "queries")
            .iter()
            .map(|query| {
                let args: Vec<Value> = array(query, "attributes")
                    .iter()
                    .map(|attribute| field(attribute, aggregate, &key_for, &Value::Null))
                    .collect();
                json!({ "name": query.get("name").cloned().unwrap_or(Value::Null), "args": args })
            })
            .collect();
        schema.insert(
            agg_name(aggregate).to_string(),
            json!({ "states": lifecycle_states(aggregate), "queries": queries }),
        );
    }
    Value::Object(schema)
}

/// `UiSchema.collection_key` — config's own `key:` if it names one,
/// else the pluralized snake_case of the aggregate's own name.
pub fn collection_key(aggregate: &Value, config: &Value) -> String {
    match dig(config, &["collections", agg_name(aggregate), "key"]).and_then(|v| v.as_str()) {
        Some(key) => key.to_string(),
        None => plural(&snake(agg_name(aggregate))),
    }
}

/// Aggregate name -> collection key, for every aggregate in the
/// domain: what a reference field's own `targetKey` resolves through.
pub fn key_for(aggregates: &[&Value], config: &Value) -> KeyFor {
    aggregates.iter().map(|a| (agg_name(a).to_string(), collection_key(a, config))).collect()
}

pub fn aggregates(domain_ir: &Value) -> Vec<&Value> {
    domain_ir.get("aggregates").and_then(|v| v.as_array()).map(|a| a.iter().collect()).unwrap_or_default()
}

// ---- one collection -------------------------------------------------

fn build_collection(aggregate: &Value, config: &Value, key_for: &KeyFor, by_name: &HashMap<&str, &Value>) -> Value {
    let name = agg_name(aggregate);
    let agg_cfg = dig(config, &["collections", name]).cloned().unwrap_or_else(|| json!({}));
    let state_cfg = dig(config, &["states", name]).cloned().unwrap_or_else(|| json!({}));
    let formats = agg_cfg.get("field_formats").cloned().unwrap_or(Value::Null);
    let identity = agg_cfg.get("identity").filter(|v| !v.is_null());
    let creating = commands(aggregate).into_iter().find(|c| creates(c));
    let others: Vec<&Value> = commands(aggregate).into_iter().filter(|c| !creates(c)).collect();
    let noun_sing = match agg_cfg.get("noun_sing").and_then(|v| v.as_str()) {
        Some(noun) => noun.to_string(),
        None => snake(name).replace('_', " "),
    };

    let fields: Vec<Value> = array(aggregate, "attributes").iter().map(|a| field(a, aggregate, key_for, &formats)).collect();

    let mut collection = Map::new();
    collection.insert("aggregate".to_string(), json!(name));
    collection.insert("label".to_string(), json!(string_or(&agg_cfg, "label", &humanize_words(name))));
    collection.insert("nounSing".to_string(), json!(noun_sing));
    collection.insert("navGroup".to_string(), optional(&agg_cfg, "nav_group"));
    collection.insert("primaryField".to_string(), optional(&agg_cfg, "primary_field"));
    collection.insert("listQuery".to_string(), optional(&agg_cfg, "list_query"));
    collection.insert("stateField".to_string(), match lifecycle(aggregate) {
        Some(l) => l.get("field").cloned().unwrap_or(Value::Null),
        None => Value::Null,
    });
    collection.insert("statusLabels".to_string(), state_facet(&state_cfg, "label"));
    collection.insert("statusTone".to_string(), state_facet(&state_cfg, "tone"));
    collection.insert("statusNotes".to_string(), state_facet(&state_cfg, "note"));
    collection.insert("statusAttention".to_string(), status_attention(&state_cfg));
    collection.insert("fields".to_string(), Value::Array(fields.clone()));
    collection.insert(
        "columns".to_string(),
        build_columns(agg_cfg.get("columns"), &fields, aggregate, by_name, key_for),
    );
    collection.insert(
        "detailFields".to_string(),
        build_detail_fields(agg_cfg.get("detail_fields"), &fields, aggregate, by_name, key_for),
    );
    collection.insert("transitions".to_string(), build_transitions(aggregate, &others, key_for, &formats));
    collection.insert("alwaysAvailable".to_string(), build_always_available(aggregate, &others, key_for, &formats));
    collection.insert(
        "create".to_string(),
        match creating {
            None => Value::Null,
            Some(command) => build_create(command, aggregate, &agg_cfg, identity, key_for, &formats, &noun_sing),
        },
    );
    Value::Object(collection)
}

fn build_create(
    command: &Value,
    aggregate: &Value,
    agg_cfg: &Value,
    identity: Option<&Value>,
    key_for: &KeyFor,
    formats: &Value,
    noun_sing: &str,
) -> Value {
    let preconditions = agg_cfg.get("preconditions");
    // An identity-derived field is computed server-side at dispatch
    // (app.rb's `apply_identity!`) — asking a person to type "P-004"
    // by hand would only invite a collision with what the server was
    // about to compute anyway.
    let identity_field = identity.and_then(|i| i.get("field")).and_then(|v| v.as_str());
    let fields: Vec<Value> = array(command, "attributes")
        .iter()
        .map(|attribute| field_with_precondition(attribute, aggregate, key_for, preconditions, formats))
        .filter(|f| identity_field.is_none_or(|name| f.get("key").and_then(|v| v.as_str()) != Some(name)))
        .collect();

    json!({
        "command": snake(command.get("name").and_then(|v| v.as_str()).unwrap_or("")),
        "label": string_or(agg_cfg, "create_label", &format!("Add {noun_sing}")),
        "fields": fields,
    })
}

/// `state_cfg.transform_values { |s| s[facet] }.compact` — only the
/// states that actually declare this facet.
fn state_facet(state_cfg: &Value, facet: &str) -> Value {
    let mut out = Map::new();
    if let Some(states) = state_cfg.as_object() {
        for (state, entry) in states {
            if let Some(value) = entry.get(facet).filter(|v| !v.is_null()) {
                out.insert(state.clone(), value.clone());
            }
        }
    }
    Value::Object(out)
}

/// EXPLICIT OPT-IN, NOT A GUESS FROM TONE — a state earns a place on
/// the Overview's attention list only when config says `attention:`.
fn status_attention(state_cfg: &Value) -> Value {
    let mut out = Vec::new();
    if let Some(states) = state_cfg.as_object() {
        for (state, entry) in states {
            if truthy(entry.get("attention")) {
                out.push(json!(state));
            }
        }
    }
    Value::Array(out)
}

// ---- columns and detail fields --------------------------------------

fn build_columns(configured: Option<&Value>, fields: &[Value], aggregate: &Value, by_name: &HashMap<&str, &Value>, key_for: &KeyFor) -> Value {
    let entries = match configured.filter(|v| !v.is_null()) {
        // A CONFIGURED EMPTY LIST IS A REAL ANSWER, not "unconfigured"
        // — Ruby's `configured || default` only falls through on nil,
        // and `[]` is truthy there.
        Some(list) => list.as_array().cloned().unwrap_or_default(),
        None => {
            let mut default: Vec<Value> = fields
                .iter()
                .filter(|f| !UNCOLUMNABLE.contains(&f.get("shape").and_then(|v| v.as_str()).unwrap_or("")))
                .map(|f| f.get("key").cloned().unwrap_or(Value::Null))
                .collect();
            if lifecycle(aggregate).is_some() {
                default.push(json!("__state__"));
            }
            default
        }
    };
    Value::Array(entries.iter().map(|entry| column_for(entry, fields, aggregate, by_name, key_for)).collect())
}

/// `UiSchema.column_for` — a bare string names an attribute and takes
/// its own derived shape as-is; a hash asks for something that shape
/// can't say by itself (`as:`, `head:`, `hop:`).
fn column_for(entry: &Value, fields: &[Value], aggregate: &Value, by_name: &HashMap<&str, &Value>, key_for: &KeyFor) -> Value {
    let sort = sort_config(entry);

    if entry.as_str() == Some("__state__") {
        // `|| "state"` guards a hand-edited `columns:` naming
        // `__state__` on an aggregate with no lifecycle at all: a
        // config mistake degrades to a generic label, never a 500.
        let field_name = lifecycle(aggregate).and_then(|l| l.get("field")).and_then(|v| v.as_str()).unwrap_or("state");
        return merge(json!({"key": "__state__", "label": humanize_words(field_name), "shape": "pill"}), sort);
    }

    if let Some(name) = entry.as_str() {
        let base = find_field(fields, name)
            .cloned()
            .unwrap_or_else(|| json!({"key": name, "label": humanize(name), "shape": "text_value"}));
        return merge(base, sort);
    }

    if truthy(entry.get("hop")) {
        return merge(hop_column(entry, fields, by_name, key_for), sort);
    }

    let key = entry.get("field").cloned().unwrap_or(Value::Null);
    let key_name = key.as_str().unwrap_or("");
    let base = find_field(fields, key_name).cloned().unwrap_or_else(|| json!({"key": key, "label": humanize(key_name)}));
    let shape = match entry.get("as").filter(|v| !v.is_null()) {
        Some(as_shape) => as_shape.clone(),
        None => base.get("shape").cloned().unwrap_or(Value::Null),
    };
    let label = match entry.get("head").filter(|v| !v.is_null()) {
        Some(head) => head.clone(),
        None => base.get("label").cloned().unwrap_or(Value::Null),
    };
    let overridden = merge(base, json!({"key": key, "shape": shape, "label": label}));
    merge(overridden, sort)
}

/// UNCONFIGURED = SORTABLE, ASCENDING FIRST — only a hash entry has
/// anywhere to carry `sortable:`/`sort_default:` at all, so a plain
/// string column always takes the generous default.
fn sort_config(entry: &Value) -> Value {
    if !entry.is_object() {
        return json!({"sortable": true, "sortDefault": "asc"});
    }
    let sortable = match entry.get("sortable") {
        Some(value) if !value.is_null() => value.clone(),
        _ => json!(true),
    };
    let sort_default = match entry.get("sort_default").filter(|v| !v.is_null()) {
        Some(value) => value.clone(),
        None => json!("asc"),
    };
    json!({"sortable": sortable, "sortDefault": sort_default})
}

fn build_detail_fields(configured: Option<&Value>, fields: &[Value], aggregate: &Value, by_name: &HashMap<&str, &Value>, key_for: &KeyFor) -> Value {
    let entries = match configured.filter(|v| !v.is_null()) {
        Some(list) => list.as_array().cloned().unwrap_or_default(),
        None => fields.iter().map(|f| f.get("key").cloned().unwrap_or(Value::Null)).collect(),
    };
    Value::Array(entries.iter().map(|entry| detail_field_for(entry, fields, aggregate, by_name, key_for)).collect())
}

fn detail_field_for(entry: &Value, fields: &[Value], aggregate: &Value, by_name: &HashMap<&str, &Value>, key_for: &KeyFor) -> Value {
    let mut base = column_for(entry, fields, aggregate, by_name, key_for);
    if base.get("shape").and_then(|v| v.as_str()) == Some("rows") {
        base = apply_row_columns_filter(base, entry);
        base = apply_row_state_filter(base, entry, aggregate);
    }
    let shape = base.get("shape").and_then(|v| v.as_str()).unwrap_or("");
    let display = match entry.get("display").filter(|v| !v.is_null()) {
        Some(display) => display.clone(),
        None => json!(DISPLAY_BY_SHAPE.iter().find(|(s, _)| *s == shape).map(|(_, d)| *d).unwrap_or("simple")),
    };
    merge(base, json!({"display": display}))
}

/// WHICH OF A ROWS FIELD'S OWN SUB-COLUMNS TO SHOW, AND IN WHAT ORDER.
fn apply_row_columns_filter(base: Value, entry: &Value) -> Value {
    let Some(wanted) = entry.get("columns").and_then(|v| v.as_array()) else { return base };
    let existing = base.get("columns").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let kept: Vec<Value> = wanted
        .iter()
        .filter_map(|want| {
            let want = want.as_str()?;
            existing.iter().find(|c| c.get("key").and_then(|v| v.as_str()) == Some(want)).cloned()
        })
        .collect();
    merge(base, json!({"columns": kept}))
}

/// ONLY THE ROWS CURRENTLY IN SOME STATE — a `list_of(entity)` field
/// otherwise shows every element ever appended, removed ones included
/// (a transition changes the stored element in place, it never drops
/// it). The frontend does the filtering; this only stamps what to
/// check per row.
fn apply_row_state_filter(base: Value, entry: &Value, aggregate: &Value) -> Value {
    let Some(state_filter) = entry.get("state_filter").filter(|v| !v.is_null()) else { return base };
    let key = match entry.get("field").and_then(|v| v.as_str()) {
        Some(field) => field,
        None => entry.as_str().unwrap_or(""),
    };
    let Some(attribute) = find_attribute(aggregate, key) else { return base };
    let Some(entity) = find_entity(aggregate, type_of(attribute)) else { return base };
    let Some(field_name) = lifecycle(entity).and_then(|l| l.get("field")).filter(|v| !v.is_null()) else { return base };
    merge(base, json!({"stateFilter": {"field": field_name, "value": state_filter}}))
}

/// A SECOND HOP, FOR DISPLAY ONLY — resolve this reference, then
/// resolve one of ITS references, and show what that points at
/// (Payment carries `invoice_id` but not `client_id`). Falls back to
/// the plain one-hop field when the config names something that
/// doesn't resolve: degrade, don't break the page over a mistake that
/// `presentation_config.rb` is the strict, save-time gate for.
fn hop_column(entry: &Value, fields: &[Value], by_name: &HashMap<&str, &Value>, key_for: &KeyFor) -> Value {
    let key = entry.get("field").cloned().unwrap_or(Value::Null);
    let key_name = key.as_str().unwrap_or("");
    let hop = entry.get("hop").and_then(|v| v.as_str()).unwrap_or("");
    let head = entry.get("head").filter(|v| !v.is_null());

    let base_field = find_field(fields, key_name).filter(|f| f.get("shape").and_then(|v| v.as_str()) == Some("reference"));
    let Some(base_field) = base_field else {
        let label = head.cloned().unwrap_or_else(|| json!(humanize(key_name)));
        return json!({"key": key, "label": label, "shape": "text_value"});
    };

    let target = base_field.get("target").and_then(|v| v.as_str()).unwrap_or("");
    let hop_attribute = by_name.get(target).and_then(|agg| find_attribute(agg, hop)).filter(|a| is_reference(a));
    let Some(hop_attribute) = hop_attribute else {
        let label = head.cloned().unwrap_or_else(|| base_field.get("label").cloned().unwrap_or(Value::Null));
        return merge(base_field.clone(), json!({"label": label}));
    };

    let hop_target = reference_target(type_of(hop_attribute)).unwrap_or_default();
    json!({
        "key": key,
        "shape": "hop",
        "label": head.cloned().unwrap_or_else(|| json!(humanize(hop))),
        "through": hop,
        "targetKey": base_field.get("targetKey").cloned().unwrap_or(Value::Null),
        "hopTargetKey": key_for.get(&hop_target).map(|k| json!(k)).unwrap_or(Value::Null),
    })
}

// ---- lifecycle ------------------------------------------------------

/// `Lifecycle#states` — the default state, then every state some
/// transition targets, deduplicated in that order.
fn lifecycle_states(aggregate: &Value) -> Vec<String> {
    let Some(lifecycle) = lifecycle(aggregate) else { return Vec::new() };
    let mut states = Vec::new();
    if let Some(default) = lifecycle.get("default").and_then(|v| v.as_str()) {
        states.push(default.to_string());
    }
    for transition in array(lifecycle, "transitions") {
        if let Some(target) = transition.get("to_state").and_then(|v| v.as_str()) {
            if !states.iter().any(|s| s == target) {
                states.push(target.to_string());
            }
        }
    }
    states
}

/// `from: nil` means "no constraint at all" here — which is why an
/// unconstrained transition is offered from EVERY state rather than
/// resolved to one: the honest reading of an edge nothing narrowed.
fn build_transitions(aggregate: &Value, others: &[&Value], key_for: &KeyFor, formats: &Value) -> Value {
    let Some(lifecycle) = lifecycle(aggregate) else { return json!({}) };
    let transitions = array(lifecycle, "transitions");

    let mut by_state = Map::new();
    for state in lifecycle_states(aggregate) {
        let mut available = Vec::new();
        for command in others {
            let name = command.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let candidates: Vec<&Value> =
                transitions.iter().filter(|t| t.get("command").and_then(|v| v.as_str()) == Some(name)).collect();
            if candidates.is_empty() {
                // "Always available" — handled separately below.
                continue;
            }
            let hit = candidates.iter().find(|t| match t.get("from_state") {
                None | Some(Value::Null) => true,
                Some(from) => from.as_str() == Some(state.as_str()),
            });
            let Some(hit) = hit else { continue };
            available.push(json!({
                "command": snake(name),
                "to": hit.get("to_state").cloned().unwrap_or(Value::Null),
                "label": humanize_words(name),
                "inputs": command_inputs(command, aggregate, key_for, formats),
            }));
        }
        by_state.insert(state, Value::Array(available));
    }
    Value::Object(by_state)
}

/// A command with NO lifecycle transition at all isn't stateless by
/// omission (Contract's `Revise`, RecurringPayment's `AdvanceCycle`) —
/// it fires regardless of state. An aggregate with no lifecycle at all
/// has every non-creating command here, by the same reasoning.
fn build_always_available(aggregate: &Value, others: &[&Value], key_for: &KeyFor, formats: &Value) -> Value {
    let transitions = lifecycle(aggregate).map(|l| array(l, "transitions")).unwrap_or(&[]);
    let available: Vec<Value> = others
        .iter()
        .filter(|command| {
            let name = command.get("name").and_then(|v| v.as_str()).unwrap_or("");
            !transitions.iter().any(|t| t.get("command").and_then(|v| v.as_str()) == Some(name))
        })
        .map(|command| {
            let name = command.get("name").and_then(|v| v.as_str()).unwrap_or("");
            json!({
                "command": snake(name),
                "label": humanize_words(name),
                "inputs": command_inputs(command, aggregate, key_for, formats),
            })
        })
        .collect();
    Value::Array(available)
}

fn command_inputs(command: &Value, aggregate: &Value, key_for: &KeyFor, formats: &Value) -> Value {
    Value::Array(array(command, "attributes").iter().map(|a| field(a, aggregate, key_for, formats)).collect())
}

/// A CREATE-FORM REFERENCE FIELD, TOLD WHAT IT MAY POINT AT — config
/// says a field must reference a record currently in some state
/// ("engagement_id must be a demoed Engagement"); this stamps that on
/// the descriptor so the client can filter its picker, while the
/// server refuses a dispatch that names one anyway. One config, both
/// checked.
fn field_with_precondition(attribute: &Value, aggregate: &Value, key_for: &KeyFor, preconditions: Option<&Value>, formats: &Value) -> Value {
    let descriptor = field(attribute, aggregate, key_for, formats);
    if descriptor.get("shape").and_then(|v| v.as_str()) != Some("reference") {
        return descriptor;
    }
    let key = descriptor.get("key").and_then(|v| v.as_str()).unwrap_or("");
    let rule = preconditions
        .and_then(|v| v.as_array())
        .and_then(|rules| rules.iter().find(|r| r.get("field").and_then(|v| v.as_str()) == Some(key)));
    let Some(state) = rule.and_then(|r| r.get("state")).filter(|v| !v.is_null()) else { return descriptor };
    merge(descriptor, json!({"filterState": state}))
}

// ---- nav and overview -----------------------------------------------

/// DECLARATION ORDER, UNLESS TOLD OTHERWISE — `nav_order` is a plain
/// number per aggregate; a nav item earns the LOWEST order among its
/// own members when several share one (`nav_group`), and anything
/// unset keeps its declaration position rather than jumping to either
/// end.
fn build_nav(aggregates: &[&Value], config: &Value, key_for: &KeyFor) -> Value {
    struct Group {
        key: String,
        label: String,
        collections: Vec<String>,
        sort: (f64, usize),
    }

    let mut order: Vec<String> = Vec::new();
    let mut groups: HashMap<String, Group> = HashMap::new();

    for (index, aggregate) in aggregates.iter().enumerate() {
        let name = agg_name(aggregate);
        let agg_cfg = dig(config, &["collections", name]).cloned().unwrap_or_else(|| json!({}));
        let nav_group = agg_cfg.get("nav_group").and_then(|v| v.as_str());
        let collection_key = key_for.get(name).cloned().unwrap_or_default();
        let group_key = nav_group.map(String::from).unwrap_or_else(|| collection_key.clone());
        let nav_order = agg_cfg.get("nav_order").and_then(|v| v.as_f64());

        if !groups.contains_key(&group_key) {
            order.push(group_key.clone());
            let label = match nav_group {
                Some(group) => humanize_words(group),
                None => string_or(&agg_cfg, "label", &humanize_words(name)),
            };
            groups.insert(
                group_key.clone(),
                Group {
                    key: group_key.clone(),
                    label,
                    collections: Vec::new(),
                    sort: (nav_order.unwrap_or(f64::INFINITY), index),
                },
            );
        }

        let group = groups.get_mut(&group_key).expect("just inserted if missing");
        group.collections.push(collection_key);
        if let Some(nav_order) = nav_order {
            if nav_order < group.sort.0 {
                group.sort = (nav_order, index);
            }
        }
    }

    let mut ordered: Vec<&Group> = order.iter().filter_map(|k| groups.get(k)).collect();
    ordered.sort_by(|a, b| a.sort.partial_cmp(&b.sort).expect("nav_order is never NaN"));
    Value::Array(
        ordered
            .into_iter()
            .map(|g| json!({"key": g.key, "label": g.label, "collections": g.collections}))
            .collect(),
    )
}

/// OVERVIEW STATS, AS DATA — a fold over a collection filtered by a
/// `where` clause, evaluated client-side against records the frontend
/// already has: this answers "what does the app look like", never
/// "what does the data say right now".
fn build_overview(config: &Value) -> Value {
    let stats: Vec<Value> = dig(config, &["overview", "stats"])
        .and_then(|v| v.as_array())
        .map(|stats| stats.iter().map(overview_stat).collect())
        .unwrap_or_default();
    json!({ "stats": stats })
}

fn overview_stat(stat: &Value) -> Value {
    json!({
        "label": stat.get("label").cloned().unwrap_or(Value::Null),
        "collection": stat.get("collection").cloned().unwrap_or(Value::Null),
        "where": stat.get("where").filter(|v| !v.is_null()).cloned().unwrap_or_else(|| json!({})),
        "as": stat.get("as").filter(|v| !v.is_null()).cloned().unwrap_or_else(|| json!("count")),
        "field": stat.get("field").cloned().unwrap_or(Value::Null),
    })
}

// ---- one attribute, described ---------------------------------------

/// `UiSchema.field` — the single place an IR attribute becomes a UI
/// field descriptor. Called for an aggregate's own attributes (the
/// detail panel), a command's declared attributes (create form and
/// transition inputs), and recursively for a value object's own
/// attributes when it renders as a table row.
///
/// `formats` is `collections.<Name>.field_formats`, the one place
/// config layers a hint ON TOP OF a derived shape rather than
/// replacing it: nothing in the IR marks a lone String as date-shaped
/// or a lone Float as a percentage the way `{cents, currency}`
/// unambiguously marks money.
pub fn field(attribute: &Value, aggregate: &Value, key_for: &KeyFor, formats: &Value) -> Value {
    let name = attr_name(attribute);
    let ty = type_of(attribute);
    let format = formats.get(name).filter(|v| !v.is_null()).cloned();
    let base = json!({
        "key": name,
        "label": humanize(name),
        "optional": attribute.get("optional").and_then(|v| v.as_bool()).unwrap_or(false),
    });

    // THE WIRE VALUE FOR THIS KEY IS ALREADY DECIDED, whatever the
    // attribute's own declared type — `to_h` ends `state.merge(id:
    // @id)`, and `@id` is always the aggregate's already-reduced
    // scalar identity. Normally that's a NEW key beside the real one;
    // an aggregate that names its OWN identity-bearing attribute
    // literally `id` collides, and the same key that would hold
    // `{value: "..."}` holds a bare string instead. Named `id`
    // SPECIFICALLY — an aggregate identified by some other attribute
    // (Client's own `reference`) has no such collision, and telling
    // the client to expect a bare scalar there rendered a live
    // "[object Object]".
    if name == "id" && identity_heads(aggregate) == ["id"] {
        return merge(base, json!({"shape": "text_value"}));
    }

    if let Some(target) = reference_target(ty) {
        return merge(
            base,
            json!({
                "shape": "reference",
                "target": target,
                "targetKey": key_for.get(&target).map(|k| json!(k)).unwrap_or(Value::Null),
            }),
        );
    }

    if PRIMITIVES.contains(&ty) {
        return merge(base, primitive_shape(ty, format));
    }

    // `aggregate.value_object` is the OWNING aggregate's own table and
    // nothing wider — an attribute typed by a value object declared on
    // some other aggregate falls through here exactly as it does in
    // Ruby (to the entity check, then to the defensive text_value).
    if let Some(value_object) = find_value_object(aggregate, ty) {
        if truthy(value_object.get("closed_set")) {
            return merge(base, enum_shape(value_object));
        }
        if is_list(attribute) {
            return merge(base, list_shape(value_object, aggregate, key_for, formats));
        }
        return merge(base, scalar_vo_shape(value_object, aggregate, key_for, formats, format));
    }

    // AN ENTITY, NOT A VALUE OBJECT — a `list_of` attribute holding
    // pieces rather than plain values. An entity's attributes answer
    // the same shape a value object's do, through the same recursion,
    // so a piece's own `reference_to` earns real reference rendering
    // with no special case here at all.
    if is_list(attribute) {
        if let Some(entity) = find_entity(aggregate, ty) {
            return merge(base, json!({"shape": "rows", "columns": row_columns(entity, aggregate, key_for, formats)}));
        }
    }

    // Defensive only — a resolved bluebook always has one of the above.
    merge(base, json!({"shape": "text_value"}))
}

fn primitive_shape(ty: &str, format: Option<Value>) -> Value {
    let mut shape = Map::new();
    shape.insert("shape".to_string(), json!(if numeric(ty) { "number" } else { "text_value" }));
    if let Some(format) = format {
        shape.insert("format".to_string(), format);
    }
    Value::Object(shape)
}

fn enum_shape(value_object: &Value) -> Value {
    let attributes = array(value_object, "attributes");
    let discriminant = attributes.first().map(|a| attr_name(a)).unwrap_or("value");
    let options: Vec<Value> = array(value_object, "members")
        .iter()
        .filter_map(|member| {
            member.as_array()?.iter().find_map(|pair| {
                let pair = pair.as_array()?;
                (pair.first()?.as_str()? == discriminant).then(|| pair.get(1).cloned())?
            })
        })
        .collect();
    json!({"shape": "enum", "field": discriminant, "options": options})
}

fn scalar_vo_shape(value_object: &Value, aggregate: &Value, key_for: &KeyFor, formats: &Value, format: Option<Value>) -> Value {
    if money_shaped(value_object) {
        return json!({"shape": "money"});
    }
    if let Some(sole) = sole_attribute(value_object) {
        return single_attr_shape(sole, format);
    }
    let fields: Vec<Value> = array(value_object, "attributes").iter().map(|a| field(a, aggregate, key_for, formats)).collect();
    json!({"shape": "compound", "fields": fields})
}

fn list_shape(value_object: &Value, aggregate: &Value, key_for: &KeyFor, formats: &Value) -> Value {
    match sole_attribute(value_object) {
        Some(sole) => json!({"shape": "lines", "field": attr_name(sole)}),
        None => json!({"shape": "rows", "columns": row_columns(value_object, aggregate, key_for, formats)}),
    }
}

/// A row is a value object's own attributes laid across a table's
/// width instead of a form's height — the same recursion, just
/// collapsing a cents+currency pair into one "money" column the way a
/// scalar money-shaped value object already collapses at the top
/// level.
fn row_columns(shape: &Value, aggregate: &Value, key_for: &KeyFor, formats: &Value) -> Value {
    let attributes = array(shape, "attributes");
    let names: Vec<&str> = attributes.iter().map(|a| attr_name(a)).collect();
    if !(names.contains(&"cents") && names.contains(&"currency")) {
        return Value::Array(attributes.iter().map(|a| field(a, aggregate, key_for, formats)).collect());
    }
    Value::Array(
        attributes
            .iter()
            .filter(|a| attr_name(a) != "currency")
            .map(|a| {
                if attr_name(a) == "cents" {
                    json!({"key": "cents", "label": "Amount ($)", "shape": "money"})
                } else {
                    field(a, aggregate, key_for, formats)
                }
            })
            .collect(),
    )
}

/// ALWAYS CARRIES `field:` — a scalar value object's wire value is
/// `{<attr name>: ...}`, never the bare scalar (which is what
/// `primitive_shape` is for, and why it carries no `field:` on
/// purpose: the client reads that absence as "the raw value IS the
/// scalar"). "value"/"text"/"address" are the names this domain
/// happens to use; anything else still resolves, because `field:`
/// names it exactly rather than assuming a fixed vocabulary.
fn single_attr_shape(attribute: &Value, format: Option<Value>) -> Value {
    let name = attr_name(attribute);
    let shape = if numeric(type_of(attribute)) {
        "number"
    } else {
        match name {
            "text" => "text",
            "address" => "address",
            _ => "text_value",
        }
    };
    let mut out = Map::new();
    out.insert("shape".to_string(), json!(shape));
    out.insert("field".to_string(), json!(name));
    if let Some(format) = format {
        out.insert("format".to_string(), format);
    }
    Value::Object(out)
}

// ---- IR readers -----------------------------------------------------

pub fn agg_name(aggregate: &Value) -> &str {
    aggregate.get("name").and_then(|v| v.as_str()).unwrap_or("")
}

fn attr_name(attribute: &Value) -> &str {
    attribute.get("name").and_then(|v| v.as_str()).unwrap_or("")
}

fn type_of(attribute: &Value) -> &str {
    attribute.get("type").and_then(|v| v.as_str()).unwrap_or("")
}

fn array<'a>(value: &'a Value, field: &str) -> &'a [Value] {
    value.get(field).and_then(|v| v.as_array()).map(|a| a.as_slice()).unwrap_or(&[])
}

pub fn commands(aggregate: &Value) -> Vec<&Value> {
    array(aggregate, "commands").iter().collect()
}

/// `IR::Command#creates?` — true exactly when the command declares no
/// `references`.
pub fn creates(command: &Value) -> bool {
    command.get("references").map(|r| r.is_null()).unwrap_or(true)
}

fn lifecycle(aggregate: &Value) -> Option<&Value> {
    aggregate.get("lifecycle").filter(|v| !v.is_null())
}

pub fn find_attribute<'a>(aggregate: &'a Value, name: &str) -> Option<&'a Value> {
    array(aggregate, "attributes").iter().find(|a| attr_name(a) == name)
}

fn find_value_object<'a>(aggregate: &'a Value, name: &str) -> Option<&'a Value> {
    array(aggregate, "value_objects").iter().find(|v| v.get("name").and_then(|n| n.as_str()) == Some(name))
}

fn find_entity<'a>(aggregate: &'a Value, name: &str) -> Option<&'a Value> {
    array(aggregate, "entities").iter().find(|e| e.get("name").and_then(|n| n.as_str()) == Some(name))
}

fn find_field<'a>(fields: &'a [Value], key: &str) -> Option<&'a Value> {
    fields.iter().find(|f| f.get("key").and_then(|v| v.as_str()) == Some(key))
}

/// `Reference<X>` -> `X`, the export's pinned spelling (IR::Reference
/// #to_s) — the same prefix convention web.rs's own `reference_target`
/// reads.
pub fn reference_target(ty: &str) -> Option<String> {
    ty.strip_prefix("Reference<")?.strip_suffix('>').map(String::from)
}

fn is_reference(attribute: &Value) -> bool {
    reference_target(type_of(attribute)).is_some()
}

fn is_list(attribute: &Value) -> bool {
    attribute.get("list").and_then(|v| v.as_bool()).unwrap_or(false)
}

/// `identity_heads` — the first segment of each declared identity
/// path ("name.value" -> "name").
fn identity_heads(aggregate: &Value) -> Vec<&str> {
    array(aggregate, "identified_by")
        .iter()
        .filter_map(|p| p.as_str())
        .map(|p| p.split('.').next().unwrap_or(p))
        .collect()
}

/// `Presentation::ValueObjectShape.money?` — exactly `{cents,
/// currency}`, sorted, and nothing else.
fn money_shaped(value_object: &Value) -> bool {
    let mut names: Vec<&str> = array(value_object, "attributes").iter().map(|a| attr_name(a)).collect();
    names.sort_unstable();
    names == ["cents", "currency"]
}

/// `Presentation::ValueObjectShape.sole_attribute` — a value object
/// with exactly one attribute is a NAME for a scalar, not a group.
fn sole_attribute(value_object: &Value) -> Option<&Value> {
    let attributes = array(value_object, "attributes");
    (attributes.len() == 1).then(|| &attributes[0])
}

fn numeric(ty: &str) -> bool {
    ty == "Integer" || ty == "Float"
}

// ---- small helpers ---------------------------------------------------

/// `config.dig(...)` with Ruby's own truthiness: a missing key and an
/// explicit null are both "not configured". An empty array or object
/// is NOT — it is a real, configured answer, which is what keeps a
/// deliberately-empty `columns:` from falling back to the derived
/// default.
fn dig<'a>(config: &'a Value, path: &[&str]) -> Option<&'a Value> {
    let mut node = config;
    for segment in path {
        node = node.get(segment)?;
    }
    (!node.is_null()).then_some(node)
}

fn truthy(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(_) => true,
    }
}

fn optional(config: &Value, key: &str) -> Value {
    config.get(key).cloned().unwrap_or(Value::Null)
}

fn string_or(config: &Value, key: &str, fallback: &str) -> String {
    config.get(key).and_then(|v| v.as_str()).map(String::from).unwrap_or_else(|| fallback.to_string())
}

/// Ruby's `Hash#merge`: a key already present keeps its POSITION and
/// takes the new value; a new key lands at the end. serde_json's
/// `preserve_order` (IndexMap) gives exactly that, which is what keeps
/// a column descriptor's own key order identical to Ruby's.
fn merge(base: Value, extra: Value) -> Value {
    let mut out = match base {
        Value::Object(map) => map,
        _ => Map::new(),
    };
    if let Value::Object(extra) = extra {
        for (key, value) in extra {
            out.insert(key, value);
        }
    }
    Value::Object(out)
}

// ---- naming — Hecks::Naming, ported ---------------------------------

static SNAKE_ACRONYM: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"([A-Z]+)([A-Z][a-z])").expect("a literal pattern must compile"));
static SNAKE_BOUNDARY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"([a-z\d])([A-Z])").expect("a literal pattern must compile"));
static PLURAL_Y: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[^aeiou]y$").expect("a literal pattern must compile"));
static PLURAL_ES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(s|x|z|ch|sh)$").expect("a literal pattern must compile"));

/// `Naming.snake` — the same two word-boundary substitutions, then
/// downcase.
pub fn snake(text: &str) -> String {
    let once = SNAKE_ACRONYM.replace_all(text, "${1}_${2}");
    let twice = SNAKE_BOUNDARY.replace_all(&once, "${1}_${2}");
    twice.to_lowercase()
}

/// `Naming.plural` — three suffix rules, exactly as declared; getting
/// a collection name wrong reads as a typo forever.
pub fn plural(word: &str) -> String {
    if PLURAL_Y.is_match(word) {
        return format!("{}ies", &word[..word.len() - 1]);
    }
    if PLURAL_ES.is_match(word) {
        return format!("{word}es");
    }
    format!("{word}s")
}

/// `UiSchema.humanize_words` — snake_case, then each word capitalized.
/// NOT `Naming.words` (which preserves acronyms): this is the
/// console's own spelling, and "ATMCard" reads "Atm Card" here exactly
/// as it does in Ruby.
fn humanize_words(text: &str) -> String {
    // RUBY'S `String#split("_")` DROPS TRAILING EMPTY SEGMENTS AND KEEPS
    // LEADING ONES — not a detail worth mirroring in the abstract, but
    // it is load-bearing here: the state column arrives from stored
    // config as `{"field": "__state__"}` (a hash, never a bare string),
    // which misses `column_for`'s own `__state__` branch and gets
    // humanized literally. Ruby renders that `"  State"`; splitting
    // Rust's way instead renders `"  State  "`, a visible difference in
    // every table header in the app. Found by diffing this module's
    // output against the Ruby engine's for the real Embryonaut domain,
    // where it was the ONLY disagreement.
    let snaked = snake(text);
    let mut words: Vec<&str> = snaked.split('_').collect();
    while words.last() == Some(&"") {
        words.pop();
    }
    words
        .into_iter()
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<String>>()
        .join(" ")
}

/// `UiSchema.humanize` — a trailing `_id` is scaffolding, not a word a
/// person reads ("client_id" is the Client column).
fn humanize(key: &str) -> String {
    humanize_words(key.strip_suffix("_id").unwrap_or(key))
}

#[cfg(test)]
mod tests {
    use super::*;

    // The fixture is Embryonaut-shaped because that is the domain the
    // Ruby engine actually serves — a Client with a slugged reference,
    // a Proposal with a real lifecycle and money-shaped line items, an
    // Invoice that hops through its own client. Each test pins one
    // rule of ui_schema.rb against it.

    fn domain() -> Value {
        json!({
            "name": "EmbryonautFoundersApp",
            "aggregates": [
                {
                    "name": "Client",
                    "identified_by": ["reference.value"],
                    "attributes": [
                        {"name": "reference", "type": "ClientReference", "list": false, "optional": false},
                        {"name": "name", "type": "ClientName", "list": false, "optional": false},
                        {"name": "contact_email", "type": "EmailAddress", "list": false, "optional": true},
                        {"name": "notes", "type": "Note", "list": true, "optional": true}
                    ],
                    "value_objects": [
                        {"name": "ClientReference", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []},
                        {"name": "ClientName", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []},
                        {"name": "EmailAddress", "attributes": [{"name": "address", "type": "String"}], "closed_set": false, "members": []},
                        {"name": "Note", "attributes": [{"name": "text", "type": "String"}], "closed_set": false, "members": []}
                    ],
                    "entities": [],
                    "queries": [
                        {"name": "Active", "attributes": []},
                        {"name": "ByName", "attributes": [{"name": "name", "type": "ClientName", "list": false, "optional": false}]}
                    ],
                    "commands": [
                        {"name": "Register", "references": null, "attributes": [
                            {"name": "reference", "type": "ClientReference", "list": false, "optional": false},
                            {"name": "name", "type": "ClientName", "list": false, "optional": false}
                        ]},
                        {"name": "Activate", "references": "Client", "attributes": []},
                        {"name": "Note", "references": "Client", "attributes": [
                            {"name": "note", "type": "Note", "list": false, "optional": false}
                        ]}
                    ],
                    "lifecycle": {"field": "status", "default": "prospect",
                                  "transitions": [{"command": "Activate", "to_state": "active", "from_state": "prospect"}]}
                },
                {
                    "name": "Proposal",
                    "identified_by": ["number.value"],
                    "attributes": [
                        {"name": "number", "type": "ProposalNumber", "list": false, "optional": false},
                        {"name": "client", "type": "Reference<Client>", "list": false, "optional": false},
                        {"name": "line_items", "type": "LineItem", "list": true, "optional": false},
                        {"name": "kind", "type": "ProposalKind", "list": false, "optional": true},
                        {"name": "value", "type": "Money", "list": false, "optional": true}
                    ],
                    "value_objects": [
                        {"name": "ProposalNumber", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []},
                        {"name": "Money", "attributes": [{"name": "cents", "type": "Integer"}, {"name": "currency", "type": "String"}],
                         "closed_set": false, "members": []},
                        {"name": "LineItem", "attributes": [
                            {"name": "description", "type": "String"},
                            {"name": "cents", "type": "Integer"},
                            {"name": "currency", "type": "String"}
                        ], "closed_set": false, "members": []},
                        {"name": "ProposalKind", "attributes": [{"name": "value", "type": "String"}], "closed_set": true,
                         "members": [[["value", "fixed"]], [["value", "retainer"]]]}
                    ],
                    "entities": [],
                    "queries": [],
                    "commands": [
                        {"name": "Draft", "references": null, "attributes": [
                            {"name": "number", "type": "ProposalNumber", "list": false, "optional": false},
                            {"name": "client", "type": "Reference<Client>", "list": false, "optional": false}
                        ]},
                        {"name": "Send", "references": "Proposal", "attributes": []},
                        {"name": "Accept", "references": "Proposal", "attributes": []},
                        {"name": "Revise", "references": "Proposal", "attributes": [
                            {"name": "note", "type": "ProposalNumber", "list": false, "optional": true}
                        ]}
                    ],
                    "lifecycle": {"field": "status", "default": "drafted", "transitions": [
                        {"command": "Send", "to_state": "sent", "from_state": "drafted"},
                        {"command": "Accept", "to_state": "accepted", "from_state": "sent"}
                    ]}
                },
                {
                    "name": "Invoice",
                    "identified_by": ["number.value"],
                    "attributes": [
                        {"name": "number", "type": "InvoiceNumber", "list": false, "optional": false},
                        {"name": "proposal_id", "type": "Reference<Proposal>", "list": false, "optional": false}
                    ],
                    "value_objects": [
                        {"name": "InvoiceNumber", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []}
                    ],
                    "entities": [], "queries": [], "commands": [],
                    "lifecycle": null
                }
            ]
        })
    }

    fn client() -> Value {
        domain()["aggregates"][0].clone()
    }

    fn proposal() -> Value {
        domain()["aggregates"][1].clone()
    }

    fn keys() -> KeyFor {
        let domain = domain();
        let aggregates = aggregates(&domain);
        key_for(&aggregates, &json!({}))
    }

    fn field_named(aggregate: &Value, name: &str) -> Value {
        let attribute = find_attribute(aggregate, name).expect("a declared attribute").clone();
        field(&attribute, aggregate, &keys(), &Value::Null)
    }

    // ---- naming ----------------------------------------------------

    #[test]
    fn a_collection_key_is_the_pluralized_snake_name_unless_config_renames_it() {
        assert_eq!(collection_key(&client(), &json!({})), "clients");
        assert_eq!(collection_key(&proposal(), &json!({})), "proposals");
        assert_eq!(
            collection_key(&proposal(), &json!({"collections": {"Proposal": {"key": "pipeline"}}})),
            "pipeline"
        );
    }

    #[test]
    fn plural_follows_namings_own_three_rules() {
        assert_eq!(plural("client"), "clients");
        assert_eq!(plural("company"), "companies");
        assert_eq!(plural("address"), "addresses");
        assert_eq!(plural("box"), "boxes");
        // A VOWEL before the y takes a plain "s" — "days", not "daies".
        assert_eq!(plural("day"), "days");
    }

    #[test]
    fn humanize_drops_a_trailing_id_the_way_the_console_does() {
        assert_eq!(humanize("client_id"), "Client");
        assert_eq!(humanize("contact_email"), "Contact Email");
        assert_eq!(humanize_words("RecurringPayment"), "Recurring Payment");
    }

    // THE ONE DISAGREEMENT a full diff against the Ruby engine turned
    // up, and the reason `humanize_words` drops trailing empty
    // segments: Ruby's `String#split("_")` drops them, Rust's does
    // not, and `"__state__"` is humanized literally often enough to
    // matter (see the test below for why it reaches here at all).
    #[test]
    fn humanize_words_splits_the_way_ruby_splits_leading_gaps_kept_trailing_dropped() {
        assert_eq!(humanize_words("__state__"), "  State");
        assert_eq!(humanize_words("a__b"), "A  B");
        assert_eq!(humanize_words(""), "");
    }

    // A FAITHFUL PORT OF A REAL QUIRK. `column_for`'s own `__state__`
    // branch fires for a BARE STRING entry — which is what an
    // unconfigured collection's derived column list produces. Stored
    // config never produces one: `presentation_config.rb` reshapes
    // every column into `{"field": ...}`, so a configured state column
    // takes the hash branch instead, finds no field descriptor named
    // `__state__`, and comes out humanized literally with a null
    // shape. That is what the Ruby engine serves today and what
    // index.html (which keys off `key === "__state__"`, never the
    // shape) renders correctly, so this pins the quirk rather than
    // quietly improving on it — a "fix" here would be a divergence.
    #[test]
    fn a_state_column_configured_as_a_hash_keeps_the_ruby_engines_own_literal_label() {
        let config = json!({"collections": {"Client": {"columns": [{"field": "name"}, {"field": "__state__"}]}}});
        let schema = build(&domain(), &config);

        assert_eq!(
            schema["collections"]["clients"]["columns"][1],
            json!({"key": "__state__", "label": "  State", "shape": null, "sortable": true, "sortDefault": "asc"})
        );
    }

    // ---- field shapes ----------------------------------------------

    #[test]
    fn a_single_attribute_value_object_keeps_the_field_its_wire_value_is_wrapped_in() {
        assert_eq!(
            field_named(&client(), "name"),
            json!({"key": "name", "label": "Name", "optional": false, "shape": "text_value", "field": "value"})
        );
    }

    #[test]
    fn an_address_named_scalar_earns_the_address_shape_and_a_text_named_one_earns_prose() {
        assert_eq!(field_named(&client(), "contact_email")["shape"], "address");
        assert_eq!(field_named(&client(), "contact_email")["field"], "address");
        // `notes` is a LIST of a sole-attribute VO — lines, not rows.
        assert_eq!(field_named(&client(), "notes"), json!({"key": "notes", "label": "Notes", "optional": true, "shape": "lines", "field": "text"}));
    }

    #[test]
    fn a_reference_carries_both_the_target_and_the_collection_key_it_lives_under() {
        assert_eq!(
            field_named(&proposal(), "client"),
            json!({"key": "client", "label": "Client", "optional": false, "shape": "reference",
                   "target": "Client", "targetKey": "clients"})
        );
    }

    #[test]
    fn a_cents_currency_value_object_is_money_and_a_list_of_them_is_rows_with_one_money_column() {
        assert_eq!(field_named(&proposal(), "value")["shape"], "money");
        assert_eq!(
            field_named(&proposal(), "line_items"),
            json!({"key": "line_items", "label": "Line Items", "optional": false, "shape": "rows", "columns": [
                {"key": "description", "label": "Description", "optional": false, "shape": "text_value"},
                {"key": "cents", "label": "Amount ($)", "shape": "money"}
            ]})
        );
    }

    #[test]
    fn a_closed_set_becomes_an_enum_with_its_declared_members_as_options() {
        assert_eq!(
            field_named(&proposal(), "kind"),
            json!({"key": "kind", "label": "Kind", "optional": true, "shape": "enum", "field": "value",
                   "options": ["fixed", "retainer"]})
        );
    }

    #[test]
    fn a_field_format_rides_on_top_of_the_derived_shape_rather_than_replacing_it() {
        let aggregate = client();
        let attribute = find_attribute(&aggregate, "name").expect("declared").clone();
        let shaped = field(&attribute, &aggregate, &keys(), &json!({"name": "date"}));

        assert_eq!(shaped["shape"], "text_value");
        assert_eq!(shaped["format"], "date");
    }

    // An aggregate whose own identity-bearing attribute is literally
    // named `id` collides with the `id` key `to_h` merges in — the
    // descriptor has to say "bare scalar", not "{value: ...}".
    #[test]
    fn an_aggregate_identified_by_its_own_id_attribute_reads_as_a_bare_scalar() {
        let aggregate = json!({
            "name": "Item", "identified_by": ["id.value"],
            "attributes": [{"name": "id", "type": "ItemId", "list": false, "optional": false}],
            "value_objects": [{"name": "ItemId", "attributes": [{"name": "value", "type": "String"}], "closed_set": false, "members": []}],
            "entities": [], "commands": [], "queries": [], "lifecycle": null
        });

        assert_eq!(field_named(&aggregate, "id"), json!({"key": "id", "label": "Id", "optional": false, "shape": "text_value"}));
        // …while an aggregate identified by any OTHER attribute keeps
        // its real wrapped shape, `field: "value"` and all.
        assert_eq!(field_named(&client(), "reference")["field"], "value");
    }

    // ---- collections ------------------------------------------------

    #[test]
    fn an_unconfigured_collection_derives_every_column_plus_the_state_pill() {
        let schema = build(&domain(), &json!({}));
        let columns = &schema["collections"]["clients"]["columns"];

        // `notes` is lines-shaped, so it is left out of the default
        // column list; `__state__` is appended because Client has a
        // lifecycle.
        assert_eq!(
            columns.as_array().expect("columns").iter().map(|c| c["key"].clone()).collect::<Vec<Value>>(),
            vec![json!("reference"), json!("name"), json!("contact_email"), json!("__state__")]
        );
        assert_eq!(columns[3], json!({"key": "__state__", "label": "Status", "shape": "pill", "sortable": true, "sortDefault": "asc"}));
        assert_eq!(schema["collections"]["clients"]["stateField"], "status");
    }

    #[test]
    fn an_aggregate_with_no_lifecycle_gets_no_state_column_and_a_null_state_field() {
        let schema = build(&domain(), &json!({}));
        let invoices = &schema["collections"]["invoices"];

        assert_eq!(invoices["stateField"], Value::Null);
        assert_eq!(invoices["transitions"], json!({}));
        assert!(
            !invoices["columns"].as_array().expect("columns").iter().any(|c| c["key"] == "__state__"),
            "{invoices}"
        );
    }

    #[test]
    fn a_configured_column_can_rename_its_head_and_opt_out_of_sorting() {
        let config = json!({"collections": {"Client": {"columns": [
            {"field": "name", "head": "Who", "sortable": false, "sort_default": "desc"}
        ]}}});
        let schema = build(&domain(), &config);

        assert_eq!(
            schema["collections"]["clients"]["columns"],
            json!([{"key": "name", "label": "Who", "optional": false, "shape": "text_value", "field": "value",
                    "sortable": false, "sortDefault": "desc"}])
        );
    }

    #[test]
    fn a_hop_column_reaches_through_one_reference_to_the_next() {
        let config = json!({"collections": {"Invoice": {"columns": [{"field": "proposal_id", "hop": "client"}]}}});
        let schema = build(&domain(), &config);

        assert_eq!(
            schema["collections"]["invoices"]["columns"][0],
            json!({"key": "proposal_id", "shape": "hop", "label": "Client", "through": "client",
                   "targetKey": "proposals", "hopTargetKey": "clients", "sortable": true, "sortDefault": "asc"})
        );
    }

    #[test]
    fn a_hop_that_does_not_resolve_degrades_to_the_plain_reference_column() {
        let config = json!({"collections": {"Invoice": {"columns": [{"field": "proposal_id", "hop": "not_a_field"}]}}});
        let schema = build(&domain(), &config);
        let column = &schema["collections"]["invoices"]["columns"][0];

        assert_eq!(column["shape"], "reference");
        assert_eq!(column["targetKey"], "proposals");
    }

    #[test]
    fn detail_fields_take_their_display_from_their_own_shape_unless_config_says_otherwise() {
        let schema = build(&domain(), &json!({}));
        let detail: HashMap<String, Value> = schema["collections"]["proposals"]["detailFields"]
            .as_array()
            .expect("detail fields")
            .iter()
            .map(|f| (f["key"].as_str().unwrap_or("").to_string(), f["display"].clone()))
            .collect();

        assert_eq!(detail["line_items"], "rows");
        assert_eq!(detail["number"], "simple");

        let config = json!({"collections": {"Proposal": {"detail_fields": [{"field": "number", "display": "mono"}]}}});
        let configured = build(&domain(), &config);
        assert_eq!(configured["collections"]["proposals"]["detailFields"][0]["display"], "mono");
    }

    // ---- lifecycle --------------------------------------------------

    #[test]
    fn transitions_are_grouped_by_the_state_they_can_fire_from() {
        let schema = build(&domain(), &json!({}));
        let transitions = &schema["collections"]["proposals"]["transitions"];

        assert_eq!(transitions["drafted"], json!([{"command": "send", "to": "sent", "label": "Send", "inputs": []}]));
        assert_eq!(transitions["sent"], json!([{"command": "accept", "to": "accepted", "label": "Accept", "inputs": []}]));
        assert_eq!(transitions["accepted"], json!([]));
    }

    #[test]
    fn a_command_with_no_transition_at_all_is_always_available_rather_than_dropped() {
        let schema = build(&domain(), &json!({}));

        assert_eq!(
            schema["collections"]["proposals"]["alwaysAvailable"],
            json!([{"command": "revise", "label": "Revise", "inputs": [
                {"key": "note", "label": "Note", "optional": true, "shape": "text_value", "field": "value"}
            ]}])
        );
    }

    #[test]
    fn every_non_creating_command_is_always_available_when_there_is_no_lifecycle() {
        let aggregate = json!({
            "name": "Ledger", "identified_by": ["id"], "attributes": [], "value_objects": [], "entities": [],
            "queries": [], "lifecycle": null,
            "commands": [{"name": "Open", "references": null, "attributes": []},
                         {"name": "Post", "references": "Ledger", "attributes": []}]
        });
        let domain = json!({"name": "Books", "aggregates": [aggregate]});
        let schema = build(&domain, &json!({}));

        assert_eq!(schema["collections"]["ledgers"]["transitions"], json!({}));
        assert_eq!(schema["collections"]["ledgers"]["alwaysAvailable"][0]["command"], "post");
    }

    // ---- create forms -----------------------------------------------

    #[test]
    fn a_create_form_leaves_out_the_field_the_server_mints_for_itself() {
        let config = json!({"collections": {"Client": {
            "identity": {"field": "reference", "strategy": "slug", "source": "name"},
            "create_label": "Add a client"
        }}});
        let schema = build(&domain(), &config);
        let create = &schema["collections"]["clients"]["create"];

        assert_eq!(create["command"], "register");
        assert_eq!(create["label"], "Add a client");
        assert_eq!(
            create["fields"].as_array().expect("fields").iter().map(|f| f["key"].clone()).collect::<Vec<Value>>(),
            vec![json!("name")]
        );
    }

    #[test]
    fn a_create_form_with_no_identity_rule_keeps_every_declared_field_and_a_derived_label() {
        let schema = build(&domain(), &json!({}));
        let create = &schema["collections"]["clients"]["create"];

        assert_eq!(create["label"], "Add client");
        assert_eq!(create["fields"].as_array().expect("fields").len(), 2);
    }

    #[test]
    fn a_precondition_tells_a_reference_picker_which_records_it_may_offer() {
        let config = json!({"collections": {"Proposal": {"preconditions": [{"field": "client", "state": "active"}]}}});
        let schema = build(&domain(), &config);
        let fields = schema["collections"]["proposals"]["create"]["fields"].clone();

        assert_eq!(fields[1]["key"], "client");
        assert_eq!(fields[1]["filterState"], "active");
    }

    // ---- nav and overview -------------------------------------------

    #[test]
    fn nav_keeps_declaration_order_until_nav_order_says_otherwise() {
        let schema = build(&domain(), &json!({}));
        assert_eq!(
            schema["nav"].as_array().expect("nav").iter().map(|g| g["key"].clone()).collect::<Vec<Value>>(),
            vec![json!("clients"), json!("proposals"), json!("invoices")]
        );

        let config = json!({"collections": {"Invoice": {"nav_order": 1}, "Client": {"nav_order": 2}}});
        let ordered = build(&domain(), &config);
        assert_eq!(
            ordered["nav"].as_array().expect("nav").iter().map(|g| g["key"].clone()).collect::<Vec<Value>>(),
            vec![json!("invoices"), json!("clients"), json!("proposals")]
        );
    }

    #[test]
    fn two_aggregates_sharing_a_nav_group_become_one_item_at_the_lowest_order_among_them() {
        let config = json!({"collections": {
            "Proposal": {"nav_group": "paperwork", "nav_order": 3},
            "Invoice": {"nav_group": "paperwork", "nav_order": 1}
        }});
        let schema = build(&domain(), &config);
        let nav = schema["nav"].as_array().expect("nav");

        assert_eq!(nav.len(), 2);
        assert_eq!(nav[0], json!({"key": "paperwork", "label": "Paperwork", "collections": ["proposals", "invoices"]}));
        assert_eq!(nav[1]["key"], "clients");
    }

    #[test]
    fn overview_stats_carry_their_fold_and_their_where_clause_through_unchanged() {
        let config = json!({"overview": {"stats": [
            {"label": "Active clients", "collection": "clients", "where": {"state": "active"}},
            {"label": "Outstanding", "collection": "invoices", "as": "money_sum", "field": "line_items"}
        ]}});
        let schema = build(&domain(), &config);

        assert_eq!(
            schema["overview"],
            json!({"stats": [
                {"label": "Active clients", "collection": "clients", "where": {"state": "active"}, "as": "count", "field": null},
                {"label": "Outstanding", "collection": "invoices", "where": {}, "as": "money_sum", "field": "line_items"}
            ]})
        );
    }

    #[test]
    fn a_domain_with_no_config_at_all_still_builds_a_whole_schema() {
        let schema = build(&domain(), &json!({}));

        assert_eq!(schema["domain"], "EmbryonautFoundersApp");
        assert_eq!(schema["overview"], json!({"stats": []}));
        assert_eq!(schema["collections"]["clients"]["label"], "Client");
        assert_eq!(schema["collections"]["clients"]["nounSing"], "client");
        assert_eq!(schema["collections"]["clients"]["statusLabels"], json!({}));
    }

    #[test]
    fn state_styling_rides_through_per_facet_and_attention_is_opt_in() {
        let config = json!({"states": {"Client": {
            "prospect": {"tone": "warn", "label": "Prospect"},
            "active": {"tone": "good", "attention": true, "note": "paying"}
        }}});
        let schema = build(&domain(), &config);
        let clients = &schema["collections"]["clients"];

        assert_eq!(clients["statusLabels"], json!({"prospect": "Prospect"}));
        assert_eq!(clients["statusTone"], json!({"prospect": "warn", "active": "good"}));
        assert_eq!(clients["statusNotes"], json!({"active": "paying"}));
        assert_eq!(clients["statusAttention"], json!(["active"]));
    }

    // ---- /api/schema -------------------------------------------------

    #[test]
    fn the_structural_schema_lists_every_state_and_every_query_with_shaped_arguments() {
        let schema = schema(&domain(), &json!({}));

        assert_eq!(schema["Client"]["states"], json!(["prospect", "active"]));
        assert_eq!(schema["Invoice"]["states"], json!([]));
        assert_eq!(
            schema["Client"]["queries"],
            json!([
                {"name": "Active", "args": []},
                {"name": "ByName", "args": [
                    {"key": "name", "label": "Name", "optional": false, "shape": "text_value", "field": "value"}
                ]}
            ])
        );
    }
}

