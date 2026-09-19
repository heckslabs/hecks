// THE CONSOLE'S OWN PRESENTATION CONFIG, WRITTEN — the Rust-native
// counterpart to embryonaut_console's `web/presentation_config.rb`
// `.save!`, serving `PUT /api/presentation`.
//
// It is the same two halves that file has, in the same order, for the
// same reason:
//
//   1. `validate` — PURE Ruby-side checking, ported rule for rule and
//      message for message, run against the LIVE domain IR before a
//      single command is dispatched. This is what keeps `save!`'s own
//      "refuses cleanly, writes nothing" contract: the common mistake
//      (a tone that isn't one of five, a column naming a field the
//      aggregate doesn't declare) never starts a partial multi-command
//      write. It cannot move into ConsoleSettings' own commands —
//      those have no way to see ANOTHER domain's schema, which is
//      exactly what every check here is against.
//
//   2. `save` — real dispatches of real `ConsoleSettings::*` commands
//      through this host's own kernel, so the chapter's own invariants
//      DO run: `tone` is a `one_of` the generated kernel enforces
//      ("Tone admits \"good\", \"warn\", ... — got \"nope\""), and a
//      state that was never `Declare`d refuses with `NotFound` rather
//      than being written behind the aggregate's back.
//
// WHAT CHANGED SINCE `api.rs` REFUSED THIS WITH 501. That refusal's
// premise was "this host has no ConsoleSettings kernel to dispatch
// through: its `.wasm` is the consuming domain's, and ConsoleSettings
// has never been compiled into it." The second half was already false
// when it was written, and is checkable: `uses_framework
// "ConsoleSettings"` in a consuming app's `.hecksagon` pulls that
// chapter into the SAME registry `bin/project_rust` generates from, and
// `merged.rs` folds its three aggregates into the one `Store` the
// single `.wasm` carries — the same mechanism that puts Governance and
// Identity in there. Strings from the real deployed artifact confirm
// it (`ConsoleSettings::StateStyle`, `Tone admits ...`), and
// `spec/fixtures/rust_host/checkout_fixture` now attaches the chapter
// the same way so CI builds a kernel with it in every run.
//
// A DOMAIN WHOSE KERNEL GENUINELY HAS NO SUCH CHAPTER still gets the
// old 501, unchanged, and it is ASKED rather than assumed: `presentation
// ::kernel_rows` runs this chapter's own `ConsoleSettings.Styles` read
// model as a query, and a kernel that has never heard of it answers
// with no query result at all. That is the same "resolve late, refuse
// loudly" rule presentation_config.rb's own header claims — never a
// guess from an environment variable or a file name.

use crate::dispatch;
use crate::lambda_client::LambdaInvoker;
use crate::journal::LineageConfig;
use crate::presentation::{self, KernelRows};
use crate::ui_schema;
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

/// The five tones the console's own CSS supports. Kept here as well as
/// in the chapter's own `one_of` for the reason `presentation_config
/// .rb`'s own copy gives: this check runs FIRST, before any dispatch,
/// so the common mistake refuses without a partial write ever starting.
const VALID_TONES: &[&str] = &["good", "warn", "danger", "muted", "accent"];
const VALID_DISPLAYS: &[&str] = &["simple", "prose", "bullet", "mono", "rows"];
const VALID_FORMATS: &[&str] = &["date", "percent"];
const VALID_FOLDS: &[&str] = &["count", "money_sum"];
const VALID_SORTS: &[&str] = &["asc", "desc"];

/// What a save can answer with other than "saved". Each variant maps to
/// exactly one of the Ruby engine's own responses — `api.rs` does that
/// mapping, so this module never mentions a status code.
pub(crate) enum SaveRefusal {
    /// This host's kernel carries no ConsoleSettings chapter. The 501
    /// `api.rs` has always returned, unchanged.
    NoKernel,
    /// `PresentationConfig::Malformed` — `app.rb`'s own `halt 422,
    /// json({error: "Malformed", message: e.message})`.
    Malformed(String),
    /// A real domain refusal from the kernel, carried whole so
    /// `api::domain_refusal` can read its own `kind`/`error` out of it
    /// the same way every other dispatching route does.
    Domain(Value),
    Internal(String),
}

/// `PresentationConfig.save!` then `.load` — app.rb's `put
/// "/api/presentation"` returns the RELOADED config, never the
/// submitted one, so a caller sees exactly what was stored.
pub(crate) async fn save(
    domain_ir: &Value,
    submitted: &Value,
    client: &Mutex<Client>,
    wasm_path: &Path,
    lineage: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Result<Value, SaveRefusal> {
    // ASKED BEFORE VALIDATED, deliberately. A host with no such chapter
    // cannot honour this request at all, and saying so is more useful
    // than first reporting whichever rule the submitted config happens
    // to break in a runtime that could never have stored it anyway.
    let existing = match presentation::kernel_rows(client, wasm_path).await {
        Ok(Some(rows)) => rows,
        Ok(None) => return Err(SaveRefusal::NoKernel),
        Err(e) => return Err(SaveRefusal::Internal(format!("{e:#}"))),
    };

    validate(submitted, domain_ir).map_err(SaveRefusal::Malformed)?;

    let mut writer = Writer { client, wasm_path, lineage, invoker };
    writer.write_states(section(submitted, "states"), &existing).await?;
    writer.write_collections(section(submitted, "collections"), &existing).await?;
    writer.write_overview(section(submitted, "overview"), &existing).await?;

    presentation::load(client, wasm_path, lineage).await.map_err(|e| SaveRefusal::Internal(format!("{e:#}")))
}

/// `config["states"] || {}` — a missing or null section is the empty
/// one, and a section that isn't an object at all is treated the same
/// way rather than erroring: `validate` has already run every real
/// check against the same value.
fn section<'a>(config: &'a Value, key: &str) -> &'a Value {
    const EMPTY: &Value = &Value::Null;
    config.get(key).filter(|v| v.is_object()).unwrap_or(EMPTY)
}

fn entries(value: &Value) -> Vec<(&String, &Value)> {
    value.as_object().map(|map| map.iter().collect()).unwrap_or_default()
}

/// `Array(...)` — a null, a missing key, or anything that isn't a list
/// is the empty list.
fn list(value: Option<&Value>) -> &[Value] {
    value.and_then(|v| v.as_array()).map(|a| a.as_slice()).unwrap_or(&[])
}

// ---- writing --------------------------------------------------------
//
// NOT DIFFED against what is already stored — every present field is
// re-dispatched on every save, even to an unchanged value, exactly as
// `PresentationConfig.save!` does (some event-log churn on a no-op
// save, accepted there for simplicity and matched here so the two
// engines produce the same history for the same request).
//
// KNOWN LIMITATION, INHERITED ON PURPOSE: a field that was SET and is
// later OMITTED is NOT cleared — every `Set*` command requires a real
// value and the chapter declares no `Clear*`. The Ruby engine has the
// same gap and documents it; diverging here would make the two engines
// disagree about what a second save means.

struct Writer<'a> {
    client: &'a Mutex<Client>,
    wasm_path: &'a Path,
    lineage: &'a LineageConfig,
    invoker: &'a dyn LambdaInvoker,
}

impl Writer<'_> {
    /// A creating command — facts only, no identity to route to, the
    /// same `handle_facts` envelope `POST /api/:coll` already uses.
    async fn declare(&mut self, verb: &str, facts: Value) -> Result<(), SaveRefusal> {
        let outcome = dispatch::handle_facts(self.client, self.wasm_path, verb, facts, None, self.lineage, self.invoker)
            .await
            .map_err(|e| SaveRefusal::Internal(format!("{e:#}")))?;
        self.accepted(outcome)
    }

    /// A command acting on an existing row — routed by that row's own
    /// identity, the same `handle_routed` envelope `POST /api/:coll/:id/:command`
    /// uses. `id` is the aggregate's own identity STRING: "Agg:state"
    /// for StateStyle's composite `identified_by :agg, :state`, the
    /// aggregate name for Collection, the literal "overview" for the
    /// singleton — each one exactly what `PresentationConfig` passes as
    /// `id:` today.
    async fn route(&mut self, verb: &str, id: &str, facts: Value) -> Result<(), SaveRefusal> {
        let outcome =
            dispatch::handle_routed(self.client, self.wasm_path, verb, json!(id), facts, None, self.lineage, self.invoker)
                .await
                .map_err(|e| SaveRefusal::Internal(format!("{e:#}")))?;
        self.accepted(outcome)
    }

    /// A refusal stops the whole save where it happened — the same
    /// "several independent dispatches, not one atomic write" risk
    /// `PresentationConfig.save!` documents. `validate` above is what
    /// makes this rare rather than routine.
    fn accepted(&self, outcome: dispatch::Outcome) -> Result<(), SaveRefusal> {
        if outcome.accepted {
            Ok(())
        } else {
            Err(SaveRefusal::Domain(outcome.result))
        }
    }

    async fn write_states(&mut self, states: &Value, existing: &KernelRows) -> Result<(), SaveRefusal> {
        let known: BTreeSet<&str> = existing.state_ids();
        for (agg, per_state) in entries(states) {
            for (state, entry) in entries(per_state) {
                let id = format!("{agg}:{state}");
                if !known.contains(id.as_str()) {
                    self.declare(
                        "ConsoleSettings::StateStyle.Declare",
                        json!({"agg": {"value": agg}, "state": {"value": state}}),
                    )
                    .await?;
                }

                if let Some(tone) = present(entry.get("tone")) {
                    self.route("ConsoleSettings::StateStyle.SetTone", &id, json!({"tone": {"value": tone}})).await?;
                }
                // `entry.key?("attention")` — an explicit `false` is a
                // real answer to store, which is why this asks whether
                // the key is there rather than whether it is truthy.
                if let Some(attention) = entry.get("attention") {
                    let flag = if attention.as_bool() == Some(true) { "true" } else { "false" };
                    self.route("ConsoleSettings::StateStyle.SetAttention", &id, json!({"attention": {"value": flag}}))
                        .await?;
                }

                let extra = extra_fields(entry, KNOWN_STATE_KEYS);
                if !extra.is_empty() {
                    self.route(
                        "ConsoleSettings::StateStyle.SetExtra",
                        &id,
                        json!({"extra_json": {"value": Value::Object(extra).to_string()}}),
                    )
                    .await?;
                }
            }
        }
        Ok(())
    }

    async fn write_collections(&mut self, collections: &Value, existing: &KernelRows) -> Result<(), SaveRefusal> {
        let known: BTreeSet<&str> = existing.collection_ids();
        for (agg, entry) in entries(collections) {
            if !known.contains(agg.as_str()) {
                self.declare("ConsoleSettings::Collection.Declare", json!({"agg": {"value": agg}})).await?;
            }

            for (field, command) in [
                ("label", "SetLabel"),
                ("key", "SetKey"),
                ("nav_order", "SetNavOrder"),
                ("primary_field", "SetPrimaryField"),
                ("list_query", "SetListQuery"),
            ] {
                if let Some(value) = present(entry.get(field)) {
                    let verb = format!("ConsoleSettings::Collection.{command}");
                    self.route(&verb, agg, json!({ field: {"value": value} })).await?;
                }
            }

            if let Some(identity) = entry.get("identity").filter(|v| v.is_object()) {
                self.write_identity(agg, identity).await?;
            }

            // ALWAYS DISPATCHED, even for an absent list — a `Replace*`
            // with nothing in it is the real, meaningful "none
            // configured", the same way it is in Ruby, and is how a
            // column removed from the config actually goes away.
            self.route(
                "ConsoleSettings::Collection.ReplaceColumns",
                agg,
                json!({ "columns": columns_for_dispatch(entry.get("columns")) }),
            )
            .await?;
            self.route(
                "ConsoleSettings::Collection.ReplaceDetailFields",
                agg,
                json!({ "detail_fields": detail_fields_for_dispatch(entry.get("detail_fields")) }),
            )
            .await?;
            self.route(
                "ConsoleSettings::Collection.ReplaceDetailFieldColumns",
                agg,
                json!({ "detail_field_columns": detail_field_columns_for_dispatch(entry.get("detail_fields")) }),
            )
            .await?;
            self.route(
                "ConsoleSettings::Collection.ReplacePreconditions",
                agg,
                json!({ "preconditions": preconditions_for_dispatch(entry.get("preconditions")) }),
            )
            .await?;
            self.route(
                "ConsoleSettings::Collection.ReplaceFieldFormats",
                agg,
                json!({ "field_formats": field_formats_for_dispatch(entry.get("field_formats")) }),
            )
            .await?;

            let extra = extra_fields(entry, KNOWN_COLLECTION_KEYS);
            if !extra.is_empty() {
                self.route(
                    "ConsoleSettings::Collection.SetExtra",
                    agg,
                    json!({"extra_json": {"value": Value::Object(extra).to_string()}}),
                )
                .await?;
            }
        }
        Ok(())
    }

    async fn write_identity(&mut self, agg: &str, identity: &Value) -> Result<(), SaveRefusal> {
        let mut facts = Map::new();
        facts.insert("identity_field".to_string(), json!({"value": identity.get("field")}));
        facts.insert("identity_strategy".to_string(), json!({"value": identity.get("strategy")}));
        if let Some(source) = present(identity.get("source")) {
            facts.insert("identity_source".to_string(), json!({ "value": source }));
        }
        if let Some(prefix) = present(identity.get("prefix")) {
            facts.insert("identity_prefix".to_string(), json!({ "value": prefix }));
        }
        let extra = extra_fields(identity, KNOWN_IDENTITY_KEYS);
        if !extra.is_empty() {
            facts.insert("identity_extra_json".to_string(), json!({"value": Value::Object(extra).to_string()}));
        }
        self.route("ConsoleSettings::Collection.SetIdentity", agg, Value::Object(facts)).await
    }

    /// THE ONE ROW — `Declare`d once, on whichever save first reaches
    /// here, then `ReplaceStats` whole on every save after, INCLUDING
    /// an empty list: "no stats configured" is a real answer.
    async fn write_overview(&mut self, overview: &Value, existing: &KernelRows) -> Result<(), SaveRefusal> {
        if existing.overview.is_empty() {
            self.declare("ConsoleSettings::Overview.Declare", json!({"key": {"value": "overview"}})).await?;
        }
        self.route(
            "ConsoleSettings::Overview.ReplaceStats",
            "overview",
            json!({ "stats": stats_for_dispatch(overview.get("stats")) }),
        )
        .await
    }
}

// ---- the extra_json passthrough, write side -------------------------
//
// Every KNOWN_*_KEYS list below names what this chapter models
// INDIVIDUALLY; whatever a real entry carries beyond that is
// subtracted out here and round-tripped through an `extra_json` field,
// which `presentation.rs`'s own `merge_extra` reads back. The two lists
// are deliberately the same constants Ruby keeps, in the same order, so
// the read side and the write side can never drift on what counts as
// "known".

const KNOWN_STATE_KEYS: &[&str] = &["tone", "attention"];
const KNOWN_COLLECTION_KEYS: &[&str] = &[
    "label",
    "key",
    "nav_order",
    "primary_field",
    "list_query",
    "identity",
    "columns",
    "detail_fields",
    "preconditions",
    "field_formats",
    "after_create",
];
const KNOWN_IDENTITY_KEYS: &[&str] = &["field", "strategy", "source", "prefix"];
const KNOWN_COLUMN_KEYS: &[&str] = &["field", "sortable", "sort_default"];
const KNOWN_DETAIL_FIELD_KEYS: &[&str] = &["field", "display", "state_filter", "columns"];
const KNOWN_PRECONDITION_KEYS: &[&str] = &["field", "state"];

fn extra_fields(entry: &Value, known: &[&str]) -> Map<String, Value> {
    let mut extra = Map::new();
    if let Some(object) = entry.as_object() {
        for (key, value) in object {
            if !known.contains(&key.as_str()) {
                extra.insert(key.clone(), value.clone());
            }
        }
    }
    extra
}

/// Ruby truthiness for a config field: a missing key and an explicit
/// null are both "not given". `false` is NOT filtered here — the one
/// field that can legitimately be `false` (`attention`) is read by key
/// presence, above, never through this.
fn present(value: Option<&Value>) -> Option<&Value> {
    value.filter(|v| !v.is_null())
}

fn columns_for_dispatch(columns: Option<&Value>) -> Vec<Value> {
    list(columns)
        .iter()
        .map(|column| {
            // A column is EITHER a bare field name or a descriptor
            // hash — the same two shapes `validate_collection!` reads,
            // and `presentation.yml` really did carry both.
            let Some(object) = column.as_object() else { return json!({ "field": column }) };
            let mut row = Map::new();
            row.insert("field".to_string(), object.get("field").cloned().unwrap_or(Value::Null));
            // "true"/"false" as STRINGS — `Column#sortable` is a String
            // attribute, see console_settings.bluebook's own comment on
            // why no bluebook attribute here is a real boolean.
            if let Some(sortable) = object.get("sortable") {
                row.insert("sortable".to_string(), json!(ruby_to_s(sortable)));
            }
            if let Some(sort_default) = present(object.get("sort_default")) {
                row.insert("sort_default".to_string(), sort_default.clone());
            }
            let extra = extra_fields(column, KNOWN_COLUMN_KEYS);
            if !extra.is_empty() {
                row.insert("extra_json".to_string(), json!(Value::Object(extra).to_string()));
            }
            Value::Object(row)
        })
        .collect()
}

fn detail_fields_for_dispatch(detail_fields: Option<&Value>) -> Vec<Value> {
    list(detail_fields)
        .iter()
        .map(|field| {
            let Some(object) = field.as_object() else { return json!({ "field": field }) };
            let mut row = Map::new();
            row.insert("field".to_string(), object.get("field").cloned().unwrap_or(Value::Null));
            if let Some(display) = present(object.get("display")) {
                row.insert("display".to_string(), display.clone());
            }
            if let Some(state_filter) = present(object.get("state_filter")) {
                row.insert("state_filter".to_string(), state_filter.clone());
            }
            let extra = extra_fields(field, KNOWN_DETAIL_FIELD_KEYS);
            if !extra.is_empty() {
                row.insert("extra_json".to_string(), json!(Value::Object(extra).to_string()));
            }
            Value::Object(row)
        })
        .collect()
}

/// FLATTENED to one row per (field, column) pair — see
/// console_settings.bluebook's own comment on why a rows-field's
/// sub-column filter is a separate list on the root rather than nested
/// inside `DetailField`. `presentation.rs` groups it back by field.
fn detail_field_columns_for_dispatch(detail_fields: Option<&Value>) -> Vec<Value> {
    let mut rows = Vec::new();
    for field in list(detail_fields) {
        let Some(object) = field.as_object() else { continue };
        let Some(columns) = object.get("columns") else { continue };
        let name = object.get("field").cloned().unwrap_or(Value::Null);
        for column in list(Some(columns)) {
            rows.push(json!({ "field": name, "column": column }));
        }
    }
    rows
}

fn preconditions_for_dispatch(preconditions: Option<&Value>) -> Vec<Value> {
    list(preconditions)
        .iter()
        .map(|rule| {
            let mut row = Map::new();
            row.insert("field".to_string(), rule.get("field").cloned().unwrap_or(Value::Null));
            row.insert("state".to_string(), rule.get("state").cloned().unwrap_or(Value::Null));
            let extra = extra_fields(rule, KNOWN_PRECONDITION_KEYS);
            if !extra.is_empty() {
                row.insert("extra_json".to_string(), json!(Value::Object(extra).to_string()));
            }
            Value::Object(row)
        })
        .collect()
}

/// `field_formats` is a MAP in the config (`{field => format}`) and a
/// LIST of `{field, format}` rows in the chapter — the same reshaping
/// `presentation.rs`'s own `reshape_field_formats` undoes on the way
/// out.
fn field_formats_for_dispatch(field_formats: Option<&Value>) -> Vec<Value> {
    field_formats
        .and_then(|v| v.as_object())
        .map(|map| map.iter().map(|(field, format)| json!({"field": field, "format": format})).collect())
        .unwrap_or_default()
}

fn stats_for_dispatch(stats: Option<&Value>) -> Vec<Value> {
    list(stats)
        .iter()
        .map(|stat| {
            let mut row = Map::new();
            row.insert("label".to_string(), stat.get("label").cloned().unwrap_or(Value::Null));
            row.insert("collection".to_string(), stat.get("collection").cloned().unwrap_or(Value::Null));
            if let Some(fold) = present(stat.get("as")) {
                row.insert("as".to_string(), fold.clone());
            }
            if let Some(field) = present(stat.get("field")) {
                row.insert("field".to_string(), field.clone());
            }
            // The stat's own recursive `where:` clause, serialized —
            // hecks has no attribute type for "arbitrary nested map",
            // so this is verified-then-opaque storage. `validate_where`
            // below has already walked the real structure.
            if let Some(clause) = present(stat.get("where")) {
                row.insert("where_json".to_string(), json!(clause.to_string()));
            }
            Value::Object(row)
        })
        .collect()
}

/// Ruby's `#to_s` for the values that reach a String-typed field here:
/// a JSON string keeps its own characters (never `"\"true\""`), and
/// anything else prints the way Ruby prints it.
fn ruby_to_s(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

// ---- validation — presentation_config.rb, rule for rule -------------
//
// Every message below is `PresentationConfig`'s own, word for word:
// this route has to refuse the way the Ruby engine refuses, or a
// console that switched runtimes would start explaining the same
// mistake differently. The tests at the bottom of this file pin the
// wording against the strings in that file.

type Refusal = Result<(), String>;

/// `PresentationConfig.validate!` — the whole submitted config against
/// the live domain, in the order Ruby checks it (states, then the
/// both-directions completeness check, then collections, then the
/// overview, then the one deliberate scope boundary).
pub(crate) fn validate(config: &Value, domain_ir: &Value) -> Refusal {
    let aggregates = ui_schema::aggregates(domain_ir);
    let states = section(config, "states");
    let collections = section(config, "collections");

    for (agg_name, per_state) in entries(states) {
        validate_states(agg_name, per_state, &aggregates)?;
    }
    missing_state_entries(states, &aggregates)?;
    for (agg_name, entry) in entries(collections) {
        validate_collection(agg_name, entry, &aggregates, domain_ir)?;
    }
    validate_overview(section(config, "overview"), &aggregates, config)?;
    refuse_unsupported_yet(collections)
}

/// A collection's own `after_create` is validated in full above (its
/// SHAPE-checking never depended on storage), but there is nowhere to
/// PERSIST it yet — refusing here means a caller who tries loses
/// nothing silently. A real, deliberate scope boundary, not a bug.
fn refuse_unsupported_yet(collections: &Value) -> Refusal {
    for (agg_name, entry) in entries(collections) {
        if present(entry.get("after_create")).is_some() {
            return Err(format!(
                "{agg_name}'s after_create isn't stored by ConsoleSettings yet \
                 (see console_settings.bluebook's own header) — remove it before saving"
            ));
        }
    }
    Ok(())
}

fn find_aggregate<'a>(aggregates: &[&'a Value], name: &str) -> Option<&'a Value> {
    aggregates.iter().copied().find(|a| ui_schema::agg_name(a) == name)
}

fn require_aggregate<'a>(aggregates: &[&'a Value], name: &str) -> Result<&'a Value, String> {
    find_aggregate(aggregates, name).ok_or_else(|| format!("{name} is not a real aggregate this domain declares"))
}

fn validate_states(agg_name: &str, per_state: &Value, aggregates: &[&Value]) -> Refusal {
    let aggregate = require_aggregate(aggregates, agg_name)?;
    let known = ui_schema::lifecycle_states(aggregate);
    for (state_name, entry) in entries(per_state) {
        validate_state_entry(agg_name, state_name, entry, &known)?;
    }
    Ok(())
}

/// BOTH DIRECTIONS, DELIBERATELY. Checking only that `states` never
/// names a state the domain doesn't have would still let a real state
/// go quietly unstyled forever. This closes that half.
fn missing_state_entries(states: &Value, aggregates: &[&Value]) -> Refusal {
    let mut missing = Vec::new();
    for aggregate in aggregates {
        let name = ui_schema::agg_name(aggregate);
        let configured = states.get(name);
        for state in ui_schema::lifecycle_states(aggregate) {
            let styled = configured.and_then(|c| c.get(&state)).is_some();
            if !styled {
                missing.push(format!("{name}.{state}"));
            }
        }
    }
    if missing.is_empty() {
        return Ok(());
    }
    Err(format!("no presentation entry for {} — every real state needs one, even a bare one", missing.join(", ")))
}

fn validate_state_entry(agg_name: &str, state_name: &str, entry: &Value, known: &[String]) -> Refusal {
    if !known.iter().any(|s| s == state_name) {
        return Err(format!(
            "{agg_name} has no state {} — it declares {}",
            inspect(&json!(state_name)),
            known.join(", ")
        ));
    }

    if let Some(tone) = present(entry.get("tone")) {
        if !VALID_TONES.contains(&ruby_to_s(tone).as_str()) {
            return Err(format!(
                "{agg_name}.{state_name}'s tone {} isn't one of {}",
                inspect(tone),
                VALID_TONES.join(", ")
            ));
        }
    }

    match entry.get("attention") {
        None | Some(Value::Null) | Some(Value::Bool(_)) => Ok(()),
        Some(other) => {
            Err(format!("{agg_name}.{state_name}'s attention must be true or false, not {}", inspect(other)))
        }
    }
}

fn validate_collection(agg_name: &str, entry: &Value, aggregates: &[&Value], domain_ir: &Value) -> Refusal {
    let aggregate = require_aggregate(aggregates, agg_name)?;

    validate_columns(agg_name, aggregate, entry.get("columns"))?;

    // `nav_order` is the one place a non-string scalar is meaningful,
    // so it is the one place the check is about the JSON type rather
    // than a vocabulary.
    if let Some(nav_order) = entry.get("nav_order") {
        if !nav_order.is_number() {
            return Err(format!("{agg_name}'s nav_order must be a number, not {}", inspect(nav_order)));
        }
    }

    for rule in list(entry.get("preconditions")) {
        validate_precondition(agg_name, aggregate, rule, aggregates)?;
    }
    validate_field_formats(agg_name, aggregate, entry.get("field_formats"))?;
    if let Some(identity) = present(entry.get("identity")) {
        validate_identity(agg_name, aggregate, identity)?;
    }
    validate_detail_fields(agg_name, aggregate, entry.get("detail_fields"))?;
    if let Some(list_query) = present(entry.get("list_query")) {
        validate_list_query(agg_name, aggregate, list_query)?;
    }
    if let Some(after_create) = present(entry.get("after_create")) {
        validate_after_create(agg_name, after_create, aggregates, domain_ir)?;
    }
    Ok(())
}

/// Looser than state validation on purpose — a column names an
/// attribute (or `"__state__"`, the status pill) rather than a value
/// the console's own CSS has to know how to render, so the check is
/// "does this aggregate actually declare it", not a closed vocabulary.
fn validate_columns(agg_name: &str, aggregate: &Value, columns: Option<&Value>) -> Refusal {
    for column in list(columns) {
        let key = column.get("field").filter(|_| column.is_object()).unwrap_or(column);
        let name = ruby_to_s(key);
        if name != "__state__" && ui_schema::find_attribute(aggregate, &name).is_none() {
            return Err(format!(
                "{agg_name} has no attribute {} to put in its columns — it declares {}",
                inspect(key),
                attribute_names(aggregate)
            ));
        }

        let Some(object) = column.as_object() else { continue };
        if let Some(sortable) = object.get("sortable") {
            if !sortable.is_boolean() {
                return Err(format!(
                    "{agg_name}'s column {} has sortable {}, not true or false",
                    inspect(key),
                    inspect(sortable)
                ));
            }
        }
        if let Some(sort_default) = present(object.get("sort_default")) {
            if !VALID_SORTS.contains(&ruby_to_s(sort_default).as_str()) {
                return Err(format!(
                    "{agg_name}'s column {} has sort_default {}, not asc or desc",
                    inspect(key),
                    inspect(sort_default)
                ));
            }
        }
    }
    Ok(())
}

fn attribute_names(aggregate: &Value) -> String {
    ui_schema::array(aggregate, "attributes").iter().map(ui_schema::attr_name).collect::<Vec<_>>().join(", ")
}

/// A precondition names a reference field on THIS aggregate and a state
/// its target must already be in. Caught here first if the field it
/// names isn't a real reference at all, since that would otherwise fail
/// silently — the check would simply never fire.
fn validate_precondition(agg_name: &str, aggregate: &Value, rule: &Value, aggregates: &[&Value]) -> Refusal {
    let Some(field) = present(rule.get("field")) else {
        return Err(format!("{agg_name} has a precondition with no field named"));
    };
    let name = ruby_to_s(field);
    let attribute = ui_schema::find_attribute(aggregate, &name);
    let is_reference = attribute.map(ui_schema::is_reference).unwrap_or(false);
    if !is_reference {
        return Err(format!("{agg_name}.{name} isn't a reference — a precondition only makes sense against one"));
    }

    let Some(state) = present(rule.get("state")) else { return Ok(()) };
    // A cross-domain or otherwise unresolvable target — nothing more to
    // check here, exactly as Ruby's own `return unless target` says.
    let Some(target_name) = ui_schema::reference_target(ui_schema::type_of(attribute.expect("checked above"))) else {
        return Ok(());
    };
    let Some(target) = find_aggregate(aggregates, &target_name) else { return Ok(()) };

    let known = ui_schema::lifecycle_states(target);
    if known.iter().any(|s| *s == ruby_to_s(state)) {
        return Ok(());
    }
    Err(format!(
        "{agg_name}.{name} points at {target_name}, which has no state {} — it declares {}",
        inspect(state),
        known.join(", ")
    ))
}

/// `field_formats` is keyed by attribute NAME, not path — a nested
/// compound field (a Member's `vesting.commencement_date`) is found
/// this way too, since `ui_schema` threads the same map down through
/// every level of recursion.
fn validate_field_formats(agg_name: &str, aggregate: &Value, formats: Option<&Value>) -> Refusal {
    let Some(map) = formats.and_then(|v| v.as_object()) else { return Ok(()) };
    for (field_name, format) in map {
        if ui_schema::find_attribute(aggregate, field_name).is_none() && !nested_attribute(aggregate, field_name) {
            return Err(format!("{agg_name} has no attribute {} to format", inspect(&json!(field_name))));
        }
        if !VALID_FORMATS.contains(&ruby_to_s(format).as_str()) {
            return Err(format!(
                "{agg_name}.{field_name}'s format {} isn't one of {}",
                inspect(format),
                VALID_FORMATS.join(", ")
            ));
        }
    }
    Ok(())
}

fn nested_attribute(aggregate: &Value, field_name: &str) -> bool {
    ui_schema::array(aggregate, "attributes").iter().any(|attribute| {
        if ui_schema::is_reference(attribute) {
            return false;
        }
        let Some(value_object) = ui_schema::find_value_object(aggregate, ui_schema::type_of(attribute)) else {
            return false;
        };
        ui_schema::array(value_object, "attributes").iter().any(|sub| ui_schema::attr_name(sub) == field_name)
    })
}

/// An identity rule names one of THIS aggregate's own attributes (never
/// a reference — there is nothing to derive from another aggregate's
/// identity) and how to fill it without asking.
fn validate_identity(agg_name: &str, aggregate: &Value, rule: &Value) -> Refusal {
    let Some(field) = present(rule.get("field")) else {
        return Err(format!("{agg_name} has an identity rule with no field named"));
    };
    let name = ruby_to_s(field);
    let Some(attribute) = ui_schema::find_attribute(aggregate, &name) else {
        return Err(format!("{agg_name} has no attribute {} to auto-derive", inspect(field)));
    };
    if ui_schema::is_reference(attribute) {
        return Err(format!("{agg_name}.{name} is a reference — identity can only derive a plain field"));
    }

    match rule.get("strategy").map(ruby_to_s).unwrap_or_default().as_str() {
        "slug" => {
            let Some(source) = present(rule.get("source")) else {
                return Err(format!("{agg_name}'s identity slug strategy needs a source field"));
            };
            if ui_schema::find_attribute(aggregate, &ruby_to_s(source)).is_none() {
                return Err(format!("{agg_name} has no attribute {} to slug from", inspect(source)));
            }
            Ok(())
        }
        "sequence" => {
            if present(rule.get("prefix")).is_none() {
                return Err(format!("{agg_name}'s identity sequence strategy needs a prefix"));
            }
            Ok(())
        }
        // No further config to check — the domain's own
        // identity_assignment adapter decides everything, and a domain
        // with none wired refuses loudly at dispatch time, not here.
        "port" => Ok(()),
        _ => Err(format!(
            "{agg_name}'s identity strategy {} isn't 'slug', 'sequence', or 'port'",
            inspect(rule.get("strategy").unwrap_or(&Value::Null))
        )),
    }
}

fn validate_detail_fields(agg_name: &str, aggregate: &Value, entries_value: Option<&Value>) -> Refusal {
    for field in list(entries_value) {
        let key = field.get("field").filter(|_| field.is_object()).unwrap_or(field);
        let name = ruby_to_s(key);
        let Some(attribute) = ui_schema::find_attribute(aggregate, &name) else {
            return Err(format!(
                "{agg_name} has no attribute {} to put in its detail fields — it declares {}",
                inspect(key),
                attribute_names(aggregate)
            ));
        };

        let Some(object) = field.as_object() else { continue };

        if let Some(display) = present(object.get("display")) {
            if !VALID_DISPLAYS.contains(&ruby_to_s(display).as_str()) {
                return Err(format!(
                    "{agg_name}'s detail field {} has display {}, not one of {}",
                    inspect(key),
                    inspect(display),
                    VALID_DISPLAYS.join(", ")
                ));
            }
        }
        if let Some(columns) = present(object.get("columns")) {
            validate_row_columns(agg_name, aggregate, &name, attribute, columns)?;
        }
        if let Some(state_filter) = present(object.get("state_filter")) {
            validate_row_state_filter(agg_name, aggregate, &name, attribute, state_filter)?;
        }
    }
    Ok(())
}

/// WHICH OF A `list_of(entity)` FIELD'S OWN ROWS TO SHOW, by the
/// entity's own lifecycle — only meaningful for an ENTITY-backed rows
/// field (a value object has no lifecycle at all).
fn validate_row_state_filter(
    agg_name: &str,
    aggregate: &Value,
    key: &str,
    attribute: &Value,
    state_filter: &Value,
) -> Refusal {
    let type_name = ui_schema::type_of(attribute).to_string();
    let Some(entity) = ui_schema::find_entity(aggregate, &type_name) else {
        return Err(format!(
            "{agg_name}'s detail field {} has state_filter: but isn't an entity-backed rows field",
            inspect(&json!(key))
        ));
    };
    let known = ui_schema::lifecycle_states(entity);
    if known.iter().any(|s| *s == ruby_to_s(state_filter)) {
        return Ok(());
    }
    Err(format!(
        "{agg_name}'s detail field {} has state_filter {}, but {type_name} has no such state — it declares {}",
        inspect(&json!(key)),
        inspect(state_filter),
        known.join(", ")
    ))
}

/// WHICH OF A `list_of` FIELD'S OWN SUB-COLUMNS TO SHOW — checked
/// against whichever rows-shape this field actually holds, a value
/// object or a piece. A `columns:` on a field that is neither is a
/// config mistake this catches by refusing rather than silently doing
/// nothing.
fn validate_row_columns(agg_name: &str, aggregate: &Value, key: &str, attribute: &Value, columns: &Value) -> Refusal {
    let type_name = ui_schema::type_of(attribute).to_string();
    let rows_source = ui_schema::find_value_object(aggregate, &type_name)
        .or_else(|| ui_schema::find_entity(aggregate, &type_name))
        .filter(|_| ui_schema::is_list(attribute));
    let Some(rows_source) = rows_source else {
        return Err(format!(
            "{agg_name}'s detail field {} has columns: but isn't a rows-shaped field",
            inspect(&json!(key))
        ));
    };

    let known: Vec<&str> = ui_schema::array(rows_source, "attributes").iter().map(ui_schema::attr_name).collect();
    for column in list(Some(columns)) {
        if !known.contains(&ruby_to_s(column).as_str()) {
            return Err(format!(
                "{agg_name}'s detail field {} has no row column {} — it has {}",
                inspect(&json!(key)),
                inspect(column),
                known.join(", ")
            ));
        }
    }
    Ok(())
}

/// `list_query` names one of this aggregate's OWN declared queries.
/// No-arg only: a query needing its own arguments has nowhere in a
/// generic table view to get one from.
fn validate_list_query(agg_name: &str, aggregate: &Value, query_name: &Value) -> Refusal {
    let name = ruby_to_s(query_name);
    let Some(query) = find_query(aggregate, &name) else {
        return Err(format!("{agg_name} has no query {} to use as its list_query", inspect(query_name)));
    };
    let arguments = ui_schema::array(query, "attributes");
    if arguments.is_empty() {
        return Ok(());
    }
    Err(format!(
        "{agg_name}'s list_query {} takes its own arguments ({}) — a generic table view has nowhere to get them from",
        inspect(query_name),
        arguments.iter().map(ui_schema::attr_name).collect::<Vec<_>>().join(", ")
    ))
}

fn find_query<'a>(owner: &'a Value, name: &str) -> Option<&'a Value> {
    ui_schema::array(owner, "queries").iter().find(|q| q.get("name").and_then(|v| v.as_str()) == Some(name))
}

/// A CREATING COMMAND THAT ISN'T THE WHOLE STORY — `after_create` names
/// a follow-up verb and how to fill its arguments. Checked against the
/// TARGET command's own declared attributes; the one thing this cannot
/// check is whether a `$field` exists on the SOURCE aggregate, since
/// every one of its own attributes is fair game — a real gap, and the
/// same one Ruby names.
fn validate_after_create(agg_name: &str, after_create: &Value, aggregates: &[&Value], domain_ir: &Value) -> Refusal {
    let Some(dispatch_to) = present(after_create.get("dispatch")) else {
        return Err(format!("{agg_name}'s after_create names no dispatch"));
    };
    let dotted = ruby_to_s(dispatch_to);
    let (target_agg_name, target_command_name) = dotted.split_once('.').unwrap_or((dotted.as_str(), ""));

    let Some(target_agg) = find_aggregate(aggregates, target_agg_name) else {
        return Err(format!(
            "{agg_name}'s after_create dispatches {}, but {} is not a real aggregate this domain declares",
            inspect(dispatch_to),
            inspect(&json!(target_agg_name))
        ));
    };
    let Some(target_command) = find_command(target_agg, target_command_name) else {
        return Err(format!(
            "{agg_name}'s after_create dispatches {}, but {target_agg_name} declares no command {}",
            inspect(dispatch_to),
            inspect(&json!(target_command_name))
        ));
    };

    let Some(args) = after_create.get("args").and_then(|v| v.as_object()) else { return Ok(()) };
    for (key, spec) in args {
        if ui_schema::find_attribute(target_command, key).is_none() {
            return Err(format!(
                "{agg_name}'s after_create names arg {}, but {dotted} declares no such attribute (it declares {})",
                inspect(&json!(key)),
                attribute_names(target_command)
            ));
        }
        validate_after_create_arg_spec(agg_name, key, spec, aggregates, domain_ir)?;
    }
    Ok(())
}

fn find_command<'a>(aggregate: &'a Value, name: &str) -> Option<&'a Value> {
    ui_schema::commands(aggregate).into_iter().find(|c| c.get("name").and_then(|v| v.as_str()) == Some(name))
}

fn validate_after_create_arg_spec(
    agg_name: &str,
    key: &str,
    spec: &Value,
    aggregates: &[&Value],
    _domain_ir: &Value,
) -> Refusal {
    let Some(count_query) = spec.get("count_query").filter(|_| spec.is_object()).and_then(|v| present(Some(v))) else {
        return Ok(());
    };
    let dotted = ruby_to_s(count_query);
    let (source_agg_name, rest) = dotted.split_once('.').unwrap_or((dotted.as_str(), ""));
    let Some(source_agg) = find_aggregate(aggregates, source_agg_name) else {
        return Err(format!(
            "{agg_name}'s after_create arg {} counts {}, but {} is not a real aggregate",
            inspect(&json!(key)),
            inspect(count_query),
            inspect(&json!(source_agg_name))
        ));
    };

    if let Some((entity_name, query_name)) = rest.split_once('.') {
        let Some(entity) = ui_schema::find_entity(source_agg, entity_name) else {
            return Err(format!(
                "{agg_name}'s after_create arg {} counts {}, but {source_agg_name} has no piece {}",
                inspect(&json!(key)),
                inspect(count_query),
                inspect(&json!(entity_name))
            ));
        };
        if find_query(entity, query_name).is_none() {
            return Err(format!(
                "{agg_name}'s after_create arg {} counts {}, but {entity_name} declares no query {}",
                inspect(&json!(key)),
                inspect(count_query),
                inspect(&json!(query_name))
            ));
        }
    } else if find_query(source_agg, rest).is_none() {
        return Err(format!(
            "{agg_name}'s after_create arg {} counts {}, but {source_agg_name} declares no query {}",
            inspect(&json!(key)),
            inspect(count_query),
            inspect(&json!(rest))
        ));
    }

    if present(spec.get("count_scope_arg")).is_none() {
        return Err(format!(
            "{agg_name}'s after_create arg {} names count_query but no count_scope_arg",
            inspect(&json!(key))
        ));
    }
    if present(spec.get("count_scope_value")).is_none() {
        return Err(format!(
            "{agg_name}'s after_create arg {} names count_query but no count_scope_value",
            inspect(&json!(key))
        ));
    }
    Ok(())
}

/// `collection` names a real, ACTUAL collection KEY — the one `key:`
/// config can override — since a stat sits above any one aggregate the
/// same way a table does.
fn validate_overview(overview: &Value, aggregates: &[&Value], config: &Value) -> Refusal {
    let by_key: Vec<(String, &Value)> =
        aggregates.iter().map(|a| (ui_schema::collection_key(a, config), *a)).collect();

    for stat in list(overview.get("stats")) {
        validate_stat(stat, &by_key)?;
    }
    Ok(())
}

fn validate_stat(stat: &Value, by_key: &[(String, &Value)]) -> Refusal {
    let Some(collection) = present(stat.get("collection")) else {
        return Err("an overview stat has no collection named".to_string());
    };
    let key = ruby_to_s(collection);
    let Some((_, aggregate)) = by_key.iter().find(|(k, _)| *k == key) else {
        return Err(format!("overview stat names collection {}, which isn't a real collection key", inspect(collection)));
    };

    let label = stat.get("label").cloned().unwrap_or(Value::Null);
    let fold = present(stat.get("as")).map(ruby_to_s).unwrap_or_else(|| "count".to_string());
    if !VALID_FOLDS.contains(&fold.as_str()) {
        return Err(format!(
            "overview stat {}'s as: {} isn't one of {}",
            inspect(&label),
            inspect(&json!(fold)),
            VALID_FOLDS.join(", ")
        ));
    }
    if fold == "money_sum" && present(stat.get("field")).is_none() {
        return Err(format!("overview stat {} folds as money_sum but names no field", inspect(&label)));
    }

    validate_where(stat.get("where").unwrap_or(&Value::Null), aggregate, by_key, &label)
}

/// Recurses through the SAME shape index.html's own `matchesWhere`
/// reads at evaluation time: `not:` wraps another whole where clause,
/// `has_related`/`not_has_related` is a cross-collection existence
/// check, and every other key is read as `state` (a normalized alias
/// for whatever this collection's own lifecycle field is really called)
/// or as a literal attribute name.
fn validate_where(clause: &Value, aggregate: &Value, by_key: &[(String, &Value)], label: &Value) -> Refusal {
    let Some(object) = clause.as_object() else { return Ok(()) };
    if let Some(negated) = object.get("not") {
        return validate_where(negated, aggregate, by_key, label);
    }

    for (key, condition) in object {
        if key == "has_related" || key == "not_has_related" {
            validate_has_related(condition, aggregate, by_key, label)?;
            continue;
        }
        if key != "state" {
            continue;
        }

        let known = ui_schema::lifecycle_states(aggregate);
        let named = match condition {
            Value::Object(map) => map
                .get("eq")
                .or_else(|| map.get("ne"))
                .or_else(|| map.get("in").and_then(|v| v.as_array()).and_then(|a| a.first()))
                .cloned()
                .unwrap_or(Value::Null),
            other => other.clone(),
        };
        if named.is_null() || known.iter().any(|s| *s == ruby_to_s(&named)) {
            continue;
        }
        return Err(format!(
            "overview stat {}'s where: state {} isn't one of {}'s own states ({})",
            inspect(label),
            inspect(&named),
            ui_schema::agg_name(aggregate),
            known.join(", ")
        ));
    }
    Ok(())
}

/// Spelled `field:`, not `on:` — YAML 1.1 reads a bare `on:` as the
/// boolean `true`, so the config key deliberately isn't one a person
/// would type unquoted and get silently wrong.
fn validate_has_related(spec: &Value, aggregate: &Value, by_key: &[(String, &Value)], label: &Value) -> Refusal {
    let Some(target_key) = present(spec.get("collection")) else {
        return Err(format!("overview stat {}'s has_related names no collection", inspect(label)));
    };
    let Some((_, target)) = by_key.iter().find(|(k, _)| *k == ruby_to_s(target_key)) else {
        return Err(format!(
            "overview stat {}'s has_related names collection {}, which isn't real",
            inspect(label),
            inspect(target_key)
        ));
    };

    let Some(field) = present(spec.get("field")) else {
        return Err(format!("overview stat {}'s has_related names no field:", inspect(label)));
    };
    if ui_schema::find_attribute(target, &ruby_to_s(field)).is_none() {
        return Err(format!(
            "overview stat {}'s has_related.field {} isn't a real field on {}",
            inspect(label),
            inspect(field),
            ui_schema::agg_name(target)
        ));
    }

    let equals = present(spec.get("equals")).map(ruby_to_s).unwrap_or_else(|| "id".to_string());
    if equals == "id" || ui_schema::find_attribute(aggregate, &equals).is_some() {
        return Ok(());
    }
    Err(format!(
        "overview stat {}'s has_related.equals {} isn't a real field on {}",
        inspect(label),
        inspect(&json!(equals)),
        ui_schema::agg_name(aggregate)
    ))
}

/// Ruby's `#inspect`, for the values a presentation config can hold.
/// The refusal messages this module reproduces embed it directly
/// (`#{tone.inspect}`), so a Rust-shaped `Some("warn")` or a bare
/// `warn` would be a visible divergence in the one place the two
/// engines are supposed to read identically.
fn inspect(value: &Value) -> String {
    match value {
        Value::Null => "nil".to_string(),
        Value::Bool(flag) => flag.to_string(),
        // Ruby prints a whole Float with a trailing `.0`; serde_json
        // prints `4.0` for an f64 and `4` for an integer, which is the
        // same distinction, so the number's own JSON spelling is right.
        Value::Number(number) => number.to_string(),
        Value::String(text) => format!("{text:?}"),
        Value::Array(items) => format!("[{}]", items.iter().map(inspect).collect::<Vec<_>>().join(", ")),
        Value::Object(map) => format!(
            "{{{}}}",
            map.iter().map(|(key, value)| format!("{key:?} => {}", inspect(value))).collect::<Vec<_>>().join(", ")
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A domain with two aggregates, one of them lifecycle-less, a
    /// reference, a rows-shaped value-object field and a no-arg query
    /// — enough shape for every rule above to have something real to
    /// check against, the same way `api.rs`'s own `domain()` fixture
    /// does for its routes.
    fn domain() -> Value {
        json!({
            "name": "Console",
            "aggregates": [
                {
                    "name": "Event",
                    "identified_by": ["slug.value"],
                    "attributes": [
                        {"name": "slug", "type": "Slug", "list": false},
                        {"name": "name", "type": "EventName", "list": false},
                        {"name": "price", "type": "Money", "list": false},
                        {"name": "seats", "type": "Seat", "list": true},
                        {"name": "organizer", "type": "Reference<Person>", "list": false}
                    ],
                    "value_objects": [
                        {"name": "Slug", "attributes": [{"name": "value", "type": "String"}]},
                        {"name": "EventName", "attributes": [{"name": "value", "type": "String"}]},
                        {"name": "Money", "attributes": [
                            {"name": "cents", "type": "Integer"}, {"name": "currency", "type": "String"}]},
                        {"name": "Seat", "attributes": [
                            {"name": "row", "type": "String"}, {"name": "number", "type": "Integer"}]}
                    ],
                    "entities": [],
                    "commands": [],
                    "queries": [
                        {"name": "Everywhere", "attributes": []},
                        {"name": "ByOrganizer", "attributes": [{"name": "organizer", "type": "Slug"}]}
                    ],
                    "lifecycle": {"field": "status", "default": "open",
                                  "transitions": [{"command": "Close", "to_state": "closed", "from_state": "open"}]}
                },
                {
                    "name": "Person",
                    "identified_by": ["email.value"],
                    "attributes": [{"name": "email", "type": "Email", "list": false}],
                    "value_objects": [{"name": "Email", "attributes": [{"name": "value", "type": "String"}]}],
                    "entities": [], "commands": [], "queries": [], "lifecycle": null
                }
            ]
        })
    }

    /// The smallest config this domain accepts — every real state
    /// styled, which `missing_state_entries` requires of every save.
    fn complete() -> Value {
        json!({"states": {"Event": {"open": {}, "closed": {}}}})
    }

    fn refusal(config: Value) -> String {
        validate(&config, &domain()).expect_err("this config should have been refused")
    }

    #[test]
    fn a_complete_config_validates() {
        assert!(validate(&complete(), &domain()).is_ok());
    }

    #[test]
    fn every_real_state_needs_an_entry_even_a_bare_one() {
        assert_eq!(
            refusal(json!({"states": {"Event": {"open": {}}}})),
            "no presentation entry for Event.closed — every real state needs one, even a bare one"
        );
    }

    #[test]
    fn a_lifecycle_less_aggregate_is_never_reported_missing() {
        // Person declares no lifecycle at all — styling it is not a
        // thing to be missing, which is what keeps this check from
        // firing on every domain that has one such aggregate.
        assert!(validate(&complete(), &domain()).is_ok());
    }

    #[test]
    fn a_state_section_naming_an_aggregate_this_domain_does_not_declare_refuses() {
        assert_eq!(
            refusal(json!({"states": {"Ghost": {"gone": {}}}})),
            "Ghost is not a real aggregate this domain declares"
        );
    }

    #[test]
    fn a_state_this_aggregate_does_not_declare_refuses_and_names_the_ones_it_does() {
        let mut config = complete();
        config["states"]["Event"]["cancelled"] = json!({});
        assert_eq!(refusal(config), "Event has no state \"cancelled\" — it declares open, closed");
    }

    #[test]
    fn a_tone_outside_the_five_refuses_in_the_consoles_own_words() {
        let mut config = complete();
        config["states"]["Event"]["open"] = json!({"tone": "chartreuse"});
        assert_eq!(
            refusal(config),
            "Event.open's tone \"chartreuse\" isn't one of good, warn, danger, muted, accent"
        );
    }

    #[test]
    fn attention_is_a_real_boolean_not_a_string() {
        let mut config = complete();
        config["states"]["Event"]["open"] = json!({"attention": "yes"});
        assert_eq!(refusal(config), "Event.open's attention must be true or false, not \"yes\"");
    }

    #[test]
    fn a_column_naming_a_field_the_aggregate_does_not_declare_refuses() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"columns": [{"field": "nope"}]}});
        assert_eq!(
            refusal(config),
            "Event has no attribute \"nope\" to put in its columns — it declares slug, name, price, seats, organizer"
        );
    }

    #[test]
    fn the_status_pill_is_a_column_every_aggregate_has() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"columns": ["__state__", "slug"]}});
        assert!(validate(&config, &domain()).is_ok());
    }

    #[test]
    fn a_columns_sortable_is_a_boolean_and_its_sort_default_is_one_of_two_words() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"columns": [{"field": "slug", "sortable": "true"}]}});
        assert_eq!(refusal(config), "Event's column \"slug\" has sortable \"true\", not true or false");

        let mut config = complete();
        config["collections"] = json!({"Event": {"columns": [{"field": "slug", "sort_default": "sideways"}]}});
        assert_eq!(refusal(config), "Event's column \"slug\" has sort_default \"sideways\", not asc or desc");
    }

    #[test]
    fn nav_order_is_a_number() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"nav_order": "3"}});
        assert_eq!(refusal(config), "Event's nav_order must be a number, not \"3\"");
    }

    #[test]
    fn a_precondition_only_makes_sense_against_a_reference() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"preconditions": [{"field": "slug", "state": "open"}]}});
        assert_eq!(refusal(config), "Event.slug isn't a reference — a precondition only makes sense against one");
    }

    #[test]
    fn a_precondition_against_a_lifecycle_less_target_names_the_states_it_has() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"preconditions": [{"field": "organizer", "state": "active"}]}});
        assert_eq!(refusal(config), "Event.organizer points at Person, which has no state \"active\" — it declares ");
    }

    #[test]
    fn a_format_names_a_real_attribute_and_one_of_two_formats() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"field_formats": {"nope": "date"}}});
        assert_eq!(refusal(config), "Event has no attribute \"nope\" to format");

        let mut config = complete();
        config["collections"] = json!({"Event": {"field_formats": {"slug": "shouty"}}});
        assert_eq!(refusal(config), "Event.slug's format \"shouty\" isn't one of date, percent");
    }

    #[test]
    fn a_format_may_name_a_nested_compound_fields_own_attribute() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"field_formats": {"cents": "percent"}}});
        assert!(validate(&config, &domain()).is_ok());
    }

    #[test]
    fn an_identity_rule_names_a_plain_field_and_one_of_three_strategies() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"identity": {"field": "organizer", "strategy": "slug"}}});
        assert_eq!(refusal(config), "Event.organizer is a reference — identity can only derive a plain field");

        let mut config = complete();
        config["collections"] = json!({"Event": {"identity": {"field": "slug", "strategy": "guesswork"}}});
        assert_eq!(refusal(config), "Event's identity strategy \"guesswork\" isn't 'slug', 'sequence', or 'port'");

        let mut config = complete();
        config["collections"] = json!({"Event": {"identity": {"field": "slug", "strategy": "slug"}}});
        assert_eq!(refusal(config), "Event's identity slug strategy needs a source field");

        let mut config = complete();
        config["collections"] = json!({"Event": {"identity": {"field": "slug", "strategy": "sequence"}}});
        assert_eq!(refusal(config), "Event's identity sequence strategy needs a prefix");

        let mut config = complete();
        config["collections"] =
            json!({"Event": {"identity": {"field": "slug", "strategy": "slug", "source": "name"}}});
        assert!(validate(&config, &domain()).is_ok());
    }

    #[test]
    fn a_detail_fields_display_is_one_of_five_placements() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"detail_fields": [{"field": "name", "display": "interpretive"}]}});
        assert_eq!(
            refusal(config),
            "Event's detail field \"name\" has display \"interpretive\", not one of simple, prose, bullet, mono, rows"
        );
    }

    #[test]
    fn row_columns_are_checked_against_the_rows_shape_the_field_actually_holds() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"detail_fields": [{"field": "seats", "columns": ["row"]}]}});
        assert!(validate(&config, &domain()).is_ok());

        let mut config = complete();
        config["collections"] = json!({"Event": {"detail_fields": [{"field": "seats", "columns": ["aisle"]}]}});
        assert_eq!(refusal(config), "Event's detail field \"seats\" has no row column \"aisle\" — it has row, number");

        let mut config = complete();
        config["collections"] = json!({"Event": {"detail_fields": [{"field": "name", "columns": ["row"]}]}});
        assert_eq!(refusal(config), "Event's detail field \"name\" has columns: but isn't a rows-shaped field");
    }

    #[test]
    fn a_state_filter_needs_an_entity_backed_rows_field() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"detail_fields": [{"field": "seats", "state_filter": "taken"}]}});
        assert_eq!(
            refusal(config),
            "Event's detail field \"seats\" has state_filter: but isn't an entity-backed rows field"
        );
    }

    #[test]
    fn a_list_query_is_one_of_this_aggregates_own_no_arg_queries() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"list_query": "Everywhere"}});
        assert!(validate(&config, &domain()).is_ok());

        let mut config = complete();
        config["collections"] = json!({"Event": {"list_query": "Nowhere"}});
        assert_eq!(refusal(config), "Event has no query \"Nowhere\" to use as its list_query");

        let mut config = complete();
        config["collections"] = json!({"Event": {"list_query": "ByOrganizer"}});
        assert_eq!(
            refusal(config),
            "Event's list_query \"ByOrganizer\" takes its own arguments (organizer) — \
             a generic table view has nowhere to get them from"
        );
    }

    #[test]
    fn after_create_is_validated_in_full_and_then_refused_as_unstorable() {
        let mut config = complete();
        config["collections"] = json!({"Event": {"after_create": {"dispatch": "Ghost.Add"}}});
        assert_eq!(
            refusal(config),
            "Event's after_create dispatches \"Ghost.Add\", but \"Ghost\" is not a real aggregate this domain declares"
        );

        // A well-formed one still refuses — with the scope-boundary
        // message, not a shape complaint.
        let mut config = complete();
        config["collections"] = json!({"Event": {"after_create": {"dispatch": "Person.Nope"}}});
        assert_eq!(
            refusal(config),
            "Event's after_create dispatches \"Person.Nope\", but Person declares no command \"Nope\""
        );
    }

    #[test]
    fn a_storable_after_create_still_refuses_because_nothing_stores_it_yet() {
        let mut ir = domain();
        ir["aggregates"][1]["commands"] = json!([{"name": "Note", "references": "Person", "attributes": []}]);
        let mut config = complete();
        config["collections"] = json!({"Event": {"after_create": {"dispatch": "Person.Note"}}});
        assert_eq!(
            validate(&config, &ir).expect_err("still unstorable"),
            "Event's after_create isn't stored by ConsoleSettings yet \
             (see console_settings.bluebook's own header) — remove it before saving"
        );
    }

    #[test]
    fn an_overview_stat_names_a_real_collection_key_and_a_real_fold() {
        let mut config = complete();
        config["overview"] = json!({"stats": [{"label": "Open", "collection": "nowhere"}]});
        assert_eq!(refusal(config), "overview stat names collection \"nowhere\", which isn't a real collection key");

        let mut config = complete();
        config["overview"] = json!({"stats": [{"label": "Open", "collection": "events", "as": "vibes"}]});
        assert_eq!(refusal(config), "overview stat \"Open\"'s as: \"vibes\" isn't one of count, money_sum");

        let mut config = complete();
        config["overview"] = json!({"stats": [{"label": "Take", "collection": "events", "as": "money_sum"}]});
        assert_eq!(refusal(config), "overview stat \"Take\" folds as money_sum but names no field");
    }

    #[test]
    fn a_stats_where_clause_is_walked_including_through_a_negation() {
        let mut config = complete();
        config["overview"] =
            json!({"stats": [{"label": "Live", "collection": "events", "where": {"state": "ajar"}}]});
        assert_eq!(
            refusal(config),
            "overview stat \"Live\"'s where: state \"ajar\" isn't one of Event's own states (open, closed)"
        );

        let mut config = complete();
        config["overview"] =
            json!({"stats": [{"label": "Live", "collection": "events", "where": {"not": {"state": {"eq": "ajar"}}}}]});
        assert_eq!(
            refusal(config),
            "overview stat \"Live\"'s where: state \"ajar\" isn't one of Event's own states (open, closed)"
        );

        let mut config = complete();
        config["overview"] =
            json!({"stats": [{"label": "Live", "collection": "events", "where": {"state": {"in": ["open"]}}}]});
        assert!(validate(&config, &domain()).is_ok());
    }

    #[test]
    fn has_related_names_a_real_collection_and_a_real_field_on_it() {
        let mut config = complete();
        config["overview"] = json!({"stats": [{"label": "Hosted", "collection": "events",
            "where": {"has_related": {"collection": "persons", "field": "nope"}}}]});
        assert_eq!(refusal(config), "overview stat \"Hosted\"'s has_related.field \"nope\" isn't a real field on Person");

        let mut config = complete();
        config["overview"] = json!({"stats": [{"label": "Hosted", "collection": "events",
            "where": {"has_related": {"collection": "persons", "field": "email", "equals": "nope"}}}]});
        assert_eq!(
            refusal(config),
            "overview stat \"Hosted\"'s has_related.equals \"nope\" isn't a real field on Event"
        );

        let mut config = complete();
        config["overview"] = json!({"stats": [{"label": "Hosted", "collection": "events",
            "where": {"has_related": {"collection": "persons", "field": "email", "equals": "slug"}}}]});
        assert!(validate(&config, &domain()).is_ok());
    }

    // ---- the dispatch shapes ----------------------------------------

    #[test]
    fn a_bare_column_name_and_a_descriptor_both_dispatch_as_a_row() {
        assert_eq!(
            columns_for_dispatch(Some(&json!(["slug", {"field": "name", "sortable": true, "head": "Title"}]))),
            vec![
                json!({"field": "slug"}),
                json!({"field": "name", "sortable": "true", "extra_json": "{\"head\":\"Title\"}"})
            ]
        );
    }

    #[test]
    fn a_rows_fields_sub_columns_flatten_to_one_row_per_pair() {
        assert_eq!(
            detail_field_columns_for_dispatch(Some(&json!([
                {"field": "seats", "columns": ["row", "number"]},
                {"field": "name"}
            ]))),
            vec![
                json!({"field": "seats", "column": "row"}),
                json!({"field": "seats", "column": "number"})
            ]
        );
    }

    #[test]
    fn field_formats_go_from_a_map_to_rows_and_back() {
        assert_eq!(
            field_formats_for_dispatch(Some(&json!({"price": "percent"}))),
            vec![json!({"field": "price", "format": "percent"})]
        );
    }

    #[test]
    fn a_stats_where_clause_rides_through_as_opaque_json_text() {
        let stats = stats_for_dispatch(Some(&json!([{"label": "Live", "collection": "events",
            "where": {"state": "open"}}])));
        assert_eq!(stats[0]["where_json"], json!("{\"state\":\"open\"}"));
        assert!(stats[0].get("as").is_none(), "an absent fold is absent, not null: {}", stats[0]);
    }

    #[test]
    fn inspect_prints_the_way_ruby_prints() {
        assert_eq!(inspect(&json!("warn")), "\"warn\"");
        assert_eq!(inspect(&Value::Null), "nil");
        assert_eq!(inspect(&json!(true)), "true");
        assert_eq!(inspect(&json!(3)), "3");
    }
}
