//! The console's presentation config (states, collections, overview),
//! read from the attached kernel or else Ruby's Postgres head views (ADR 0059).

use crate::dispatch;
use crate::journal::LineageConfig;
use crate::store::Store;
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::path::Path;

/// The bluebook the console's config lives in, matching
/// `presentation_config.rb`'s own `registry.bluebook("ConsoleSettings")`.
pub const CONFIG_DOMAIN: &str = "ConsoleSettings";

/// `Naming.snake` of each of that bluebook's three aggregates — the
/// `storage_name` Ruby derives its relation names from.
const STATE_STYLE: &str = "state_style";
const COLLECTION: &str = "collection";
const OVERVIEW: &str = "overview";

/// The whole config, as `PresentationConfig.load` returns it. A domain
/// with no ConsoleSettings rows, or none of its relations, reads back
/// an empty section rather than an error.
pub async fn load(
    store: &Store,
    wasm_path: &Path,
    config: &LineageConfig,
) -> anyhow::Result<Value> {
    if let Some(rows) = kernel_rows(store, wasm_path).await? {
        return Ok(reshape(&rows.states, &rows.collections, &rows.overview));
    }
    load_from_relations(store, config).await
}

/// The Ruby-written relations, split out so the kernel path above reads
/// as the one decision it is, and so tests can drive this half directly.
pub async fn load_from_relations(store: &Store, config: &LineageConfig) -> anyhow::Result<Value> {
    let states = read_head_states(store, &config.domain, STATE_STYLE).await?;
    let collections = read_head_states(store, &config.domain, COLLECTION).await?;
    let overview = read_head_states(store, &config.domain, OVERVIEW).await?;
    Ok(reshape(&states, &collections, &overview))
}

/// The three aggregates' live records, straight off the kernel, or
/// `None` when this kernel does not carry the bluebook at all.
///
/// An empty read is ambiguous — no bluebook, or the bluebook with nothing
/// saved yet — so only then does this probe `ConsoleSettings.Styles` as
/// a query; a kernel that knows it answers, one that doesn't refuses.
/// Keeping the plain read a single SELECT (via `dispatch::read`'s
/// snapshot) matters here: this runs on every first paint, alongside
/// `/api/me` and `/api/ui-schema`.
pub async fn kernel_rows(store: &Store, wasm_path: &Path) -> anyhow::Result<Option<KernelRows>> {
    let state = dispatch::read(store, wasm_path).await?;
    let rows = bucket(state.get("instances"));
    if !rows.is_empty() {
        return Ok(Some(rows));
    }

    // Empty either way — ask the kernel which kind of empty this is.
    let probe = dispatch::query(
        store,
        wasm_path,
        &format!("{CONFIG_DOMAIN}.Styles"),
        json!({}),
    )
    .await?;
    let answered = probe
        .get("queries")
        .and_then(|q| q.as_array())
        .is_some_and(|q| !q.is_empty());
    if answered {
        Ok(Some(rows))
    } else {
        Ok(None)
    }
}

/// Every ConsoleSettings record in an instance map, split by aggregate.
fn bucket(instances: Option<&Value>) -> KernelRows {
    let mut rows = KernelRows::default();
    let Some(instances) = instances.and_then(|i| i.as_object()) else {
        return rows;
    };
    for (key, state) in instances {
        // `Domain::Aggregate#id`, split on the first `#` — a StateStyle
        // id like `Agg:state` has none itself but would be lost to a
        // split on the last one. Ids feed `presentation_write`'s declare-vs-set check.
        let Some((qualified, id)) = key.split_once('#') else {
            continue;
        };
        match qualified {
            _ if qualified == format!("{CONFIG_DOMAIN}::StateStyle") => {
                rows.state_ids.insert(id.to_string());
                rows.states.push(state.clone());
            }
            _ if qualified == format!("{CONFIG_DOMAIN}::Collection") => {
                rows.collection_ids.insert(id.to_string());
                rows.collections.push(state.clone());
            }
            _ if qualified == format!("{CONFIG_DOMAIN}::Overview") => {
                rows.overview.push(state.clone());
            }
            _ => {}
        }
    }
    rows
}

/// Every ConsoleSettings record this kernel holds, bucketed by
/// aggregate, plus the ids `presentation_write` needs to tell a
/// declare from a set.
#[derive(Default)]
pub struct KernelRows {
    pub states: Vec<Value>,
    pub collections: Vec<Value>,
    pub overview: Vec<Value>,
    state_ids: BTreeSet<String>,
    collection_ids: BTreeSet<String>,
}

impl KernelRows {
    /// No row of any of the three kinds — the one answer that cannot
    /// tell a kernel without this bluebook from one nobody has saved to.
    const fn is_empty(&self) -> bool {
        self.states.is_empty() && self.collections.is_empty() && self.overview.is_empty()
    }

    pub fn state_ids(&self) -> BTreeSet<&str> {
        self.state_ids.iter().map(String::as_str).collect()
    }

    pub fn collection_ids(&self) -> BTreeSet<&str> {
        self.collection_ids.iter().map(String::as_str).collect()
    }
}

/// Pure: the three row sets in, `PresentationConfig.load`'s own hash
/// out, kept unit-testable without a live connection.
pub fn reshape(states: &[Value], collections: &[Value], overview: &[Value]) -> Value {
    let mut config = Map::new();
    config.insert("states".to_string(), reshape_states(states));
    config.insert("collections".to_string(), reshape_collections(collections));
    config.insert("overview".to_string(), reshape_overview(overview));
    Value::Object(config)
}

/// Every live `state` document for one ConsoleSettings aggregate, from the host's own heads or
/// else the chapter's (ADR 0059).
async fn read_head_states(
    store: &Store,
    host_domain: &str,
    storage_name: &str,
) -> anyhow::Result<Vec<Value>> {
    Ok(store
        .head_states(&[host_domain, CONFIG_DOMAIN], storage_name)
        .await?)
}

/// `PresentationConfig.unwrap` — every scalar here is a single-attribute
/// value object (`{"value": ...}`); anything else rides through untouched.
fn unwrap(value: &Value) -> Value {
    value
        .get("value")
        .map_or_else(|| value.clone(), Clone::clone)
}

fn unwrap_str(value: Option<&Value>) -> String {
    value
        .map(unwrap)
        .and_then(|v| v.as_str().map(String::from))
        .unwrap_or_default()
}

/// Ruby truthiness for a stored field: absent and JSON `null` are both
/// "not set", matching `if row[:tone]` — `attention` is a "true"/"false"
/// string on the wire, never a real boolean.
fn present(value: Option<&Value>) -> Option<&Value> {
    value.filter(|v| !v.is_null() && v.as_bool() != Some(false))
}

/// `PresentationConfig.merge_extra!` — the opaque `extra_json` blob
/// merged in without overwriting an explicitly-modeled key. Accepts it
/// either wrapped (a head field) or bare (a `list_of` element).
fn merge_extra(entry: &mut Map<String, Value>, extra_json: Option<&Value>) {
    let Some(raw) = present(extra_json).map(unwrap) else {
        return;
    };
    let Some(text) = raw.as_str().filter(|t| !t.is_empty()) else {
        return;
    };
    let Ok(Value::Object(extra)) = serde_json::from_str::<Value>(text) else {
        return;
    };
    for (key, value) in extra {
        entry.entry(key).or_insert(value);
    }
}

/// `reshape_states` — one entry per (aggregate, state) row.
pub fn reshape_states(rows: &[Value]) -> Value {
    let mut memo: Map<String, Value> = Map::new();
    for row in rows {
        let agg = unwrap_str(row.get("agg"));
        let state = unwrap_str(row.get("state"));
        let mut entry = Map::new();
        if let Some(tone) = present(row.get("tone")) {
            entry.insert("tone".to_string(), unwrap(tone));
        }
        if let Some(attention) = present(row.get("attention")) {
            entry.insert(
                "attention".to_string(),
                json!(unwrap(attention).as_str() == Some("true")),
            );
        }
        merge_extra(&mut entry, row.get("extra_json"));

        let bucket = memo.entry(agg).or_insert_with(|| Value::Object(Map::new()));
        if let Some(object) = bucket.as_object_mut() {
            object.insert(state, Value::Object(entry));
        }
    }
    Value::Object(memo)
}

pub fn reshape_collections(rows: &[Value]) -> Value {
    let mut memo = Map::new();
    for row in rows {
        memo.insert(unwrap_str(row.get("agg")), reshape_collection_row(row));
    }
    Value::Object(memo)
}

/// `reshape_collection_row` — the modelled fields in Ruby's own order,
/// each only when set, then the list fields (always present, even
/// empty), then the opaque extras.
fn reshape_collection_row(row: &Value) -> Value {
    let mut entry = Map::new();
    for (key, field) in [
        ("label", "label"),
        ("key", "key"),
        ("nav_order", "nav_order"),
        ("primary_field", "primary_field"),
        ("list_query", "list_query"),
    ] {
        if let Some(value) = present(row.get(field)) {
            entry.insert(key.to_string(), unwrap(value));
        }
    }

    if let Some(identity) = reshape_identity(row) {
        entry.insert("identity".to_string(), identity);
    }

    entry.insert(
        "columns".to_string(),
        Value::Array(
            elements(row, "columns")
                .iter()
                .map(reshape_column)
                .collect(),
        ),
    );
    entry.insert("detail_fields".to_string(), reshape_detail_fields(row));
    entry.insert(
        "preconditions".to_string(),
        Value::Array(
            elements(row, "preconditions")
                .iter()
                .map(reshape_precondition)
                .collect(),
        ),
    );
    entry.insert("field_formats".to_string(), reshape_field_formats(row));
    merge_extra(&mut entry, row.get("extra_json"));
    Value::Object(entry)
}

/// `Array(row[:columns])` — a null/absent list is the empty one.
fn elements<'a>(row: &'a Value, field: &str) -> &'a [Value] {
    row.get(field)
        .and_then(|v| v.as_array())
        .map_or(&[][..], std::vec::Vec::as_slice)
}

fn reshape_identity(row: &Value) -> Option<Value> {
    let field = present(row.get("identity_field")).map(unwrap)?;
    let mut identity = Map::new();
    identity.insert("field".to_string(), field);
    identity.insert(
        "strategy".to_string(),
        row.get("identity_strategy").map_or(Value::Null, unwrap),
    );
    if let Some(source) = present(row.get("identity_source")) {
        identity.insert("source".to_string(), unwrap(source));
    }
    if let Some(prefix) = present(row.get("identity_prefix")) {
        identity.insert("prefix".to_string(), unwrap(prefix));
    }
    merge_extra(&mut identity, row.get("identity_extra_json"));
    Some(Value::Object(identity))
}

/// `reshape_column` — `sortable` is a "true"/"false" string on the
/// wire and comes back as a real boolean, as Ruby's own read does.
fn reshape_column(column: &Value) -> Value {
    let mut entry = Map::new();
    entry.insert(
        "field".to_string(),
        column.get("field").cloned().unwrap_or(Value::Null),
    );
    if let Some(sortable) = present(column.get("sortable")) {
        entry.insert(
            "sortable".to_string(),
            json!(unwrap(sortable).as_str() == Some("true")),
        );
    }
    if let Some(sort_default) = present(column.get("sort_default")) {
        entry.insert("sort_default".to_string(), unwrap(sort_default));
    }
    merge_extra(&mut entry, column.get("extra_json"));
    Value::Object(entry)
}

/// `reshape_detail_fields` — `detail_field_columns` is stored flat, one
/// row per (field, column) pair, and is regrouped here under its field.
fn reshape_detail_fields(row: &Value) -> Value {
    let flat = elements(row, "detail_field_columns");
    let entries = elements(row, "detail_fields")
        .iter()
        .map(|field_entry| {
            let field = field_entry.get("field").cloned().unwrap_or(Value::Null);
            let mut entry = Map::new();
            entry.insert("field".to_string(), field.clone());
            if let Some(display) = present(field_entry.get("display")) {
                entry.insert("display".to_string(), unwrap(display));
            }
            if let Some(state_filter) = present(field_entry.get("state_filter")) {
                entry.insert("state_filter".to_string(), unwrap(state_filter));
            }
            let columns: Vec<Value> = flat
                .iter()
                .filter(|c| c.get("field") == Some(&field))
                .map(|c| c.get("column").cloned().unwrap_or(Value::Null))
                .collect();
            if !columns.is_empty() {
                entry.insert("columns".to_string(), Value::Array(columns));
            }
            merge_extra(&mut entry, field_entry.get("extra_json"));
            Value::Object(entry)
        })
        .collect();
    Value::Array(entries)
}

/// `reshape_precondition` — `state` is an explicit null when unset,
/// meaning "the target must merely exist", matching Ruby's own hash.
fn reshape_precondition(precondition: &Value) -> Value {
    let mut entry = Map::new();
    entry.insert(
        "field".to_string(),
        precondition.get("field").cloned().unwrap_or(Value::Null),
    );
    entry.insert(
        "state".to_string(),
        precondition.get("state").cloned().unwrap_or(Value::Null),
    );
    merge_extra(&mut entry, precondition.get("extra_json"));
    Value::Object(entry)
}

fn reshape_field_formats(row: &Value) -> Value {
    let mut formats = Map::new();
    for entry in elements(row, "field_formats") {
        let field = entry
            .get("field")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string();
        formats.insert(field, entry.get("format").cloned().unwrap_or(Value::Null));
    }
    Value::Object(formats)
}

/// `reshape_overview` — a singleton: no row reads as `{}`, never
/// `{"stats": []}`, matching Ruby's "never configured" vs "empty".
pub fn reshape_overview(rows: &[Value]) -> Value {
    let Some(row) = rows.first() else {
        return Value::Object(Map::new());
    };
    let stats: Vec<Value> = elements(row, "stats").iter().map(reshape_stat).collect();
    json!({ "stats": stats })
}

/// `reshape_stat` — `where` is an opaque JSON string on the wire
/// (`where_json`) and is parsed back out here, exactly as Ruby does.
fn reshape_stat(stat: &Value) -> Value {
    let mut entry = Map::new();
    entry.insert(
        "label".to_string(),
        stat.get("label").cloned().unwrap_or(Value::Null),
    );
    entry.insert(
        "collection".to_string(),
        stat.get("collection").cloned().unwrap_or(Value::Null),
    );
    if let Some(as_fold) = present(stat.get("as")) {
        entry.insert("as".to_string(), as_fold.clone());
    }
    if let Some(field) = present(stat.get("field")) {
        entry.insert("field".to_string(), field.clone());
    }
    if let Some(where_json) = present(stat.get("where_json"))
        .and_then(|v| v.as_str())
        .filter(|t| !t.is_empty())
    {
        if let Ok(parsed) = serde_json::from_str::<Value>(where_json) {
            entry.insert("where".to_string(), parsed);
        }
    }
    Value::Object(entry)
}
