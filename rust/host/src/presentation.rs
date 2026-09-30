//! The console's presentation config (states, collections, overview),
//! read from the attached kernel or else Ruby's Postgres head views (ADR 0059).

use crate::dispatch;
use crate::journal::{self, LineageConfig};
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::{Client, GenericClient};

/// The chapter the console's config lives in, matching
/// `presentation_config.rb`'s own `registry.bluebook("ConsoleSettings")`.
pub const CONFIG_DOMAIN: &str = "ConsoleSettings";

/// `Naming.snake` of each of that chapter's three aggregates — the
/// `storage_name` Ruby derives its relation names from.
const STATE_STYLE: &str = "state_style";
const COLLECTION: &str = "collection";
const OVERVIEW: &str = "overview";

/// The whole config, as `PresentationConfig.load` returns it. A domain
/// with no ConsoleSettings rows, or none of its relations, reads back
/// an empty section rather than an error.
pub async fn load(client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig) -> anyhow::Result<Value> {
    if let Some(rows) = kernel_rows(client, wasm_path).await? {
        return Ok(reshape(&rows.states, &rows.collections, &rows.overview));
    }
    load_from_relations(client, config).await
}

/// The Ruby-written relations, split out so the kernel path above reads
/// as the one decision it is, and so tests can drive this half directly.
async fn load_from_relations(client: &Mutex<Client>, config: &LineageConfig) -> anyhow::Result<Value> {
    let guard = client.lock().await;
    let states = read_head_states(&*guard, &config.domain, STATE_STYLE).await?;
    let collections = read_head_states(&*guard, &config.domain, COLLECTION).await?;
    let overview = read_head_states(&*guard, &config.domain, OVERVIEW).await?;
    drop(guard);
    Ok(reshape(&states, &collections, &overview))
}

/// The three aggregates' live records, straight off the kernel, or
/// `None` when this kernel does not carry the chapter at all.
///
/// An empty read is ambiguous — no chapter, or the chapter with nothing
/// saved yet — so only then does this probe `ConsoleSettings.Styles` as
/// a query; a kernel that knows it answers, one that doesn't refuses.
/// Keeping the plain read a single SELECT (via `dispatch::read`'s
/// snapshot) matters here: this runs on every first paint, alongside
/// `/api/me` and `/api/ui-schema`.
pub(crate) async fn kernel_rows(client: &Mutex<Client>, wasm_path: &Path) -> anyhow::Result<Option<KernelRows>> {
    let state = dispatch::read(client, wasm_path).await?;
    let rows = bucket(state.get("instances"));
    if !rows.is_empty() {
        return Ok(Some(rows));
    }

    // Empty either way — ask the kernel which kind of empty this is.
    let probe = dispatch::query(client, wasm_path, &format!("{CONFIG_DOMAIN}.Styles"), json!({})).await?;
    let answered = probe.get("queries").and_then(|q| q.as_array()).is_some_and(|q| !q.is_empty());
    if answered {
        Ok(Some(rows))
    } else {
        Ok(None)
    }
}

/// Every ConsoleSettings record in an instance map, split by aggregate.
fn bucket(instances: Option<&Value>) -> KernelRows {
    let mut rows = KernelRows::default();
    let Some(instances) = instances.and_then(|i| i.as_object()) else { return rows };
    for (key, state) in instances {
        // `Domain::Aggregate#id`, split on the first `#` — a StateStyle
        // id like `Agg:state` has none itself but would be lost to a
        // split on the last one. Ids feed `presentation_write`'s declare-vs-set check.
        let Some((qualified, id)) = key.split_once('#') else { continue };
        match qualified {
            _ if qualified == format!("{CONFIG_DOMAIN}::StateStyle") => {
                rows.state_ids.insert(id.to_string());
                rows.states.push(state.clone());
            }
            _ if qualified == format!("{CONFIG_DOMAIN}::Collection") => {
                rows.collection_ids.insert(id.to_string());
                rows.collections.push(state.clone());
            }
            _ if qualified == format!("{CONFIG_DOMAIN}::Overview") => rows.overview.push(state.clone()),
            _ => {}
        }
    }
    rows
}

/// Every ConsoleSettings record this kernel holds, bucketed by
/// aggregate, plus the ids `presentation_write` needs to tell a
/// declare from a set.
#[derive(Default)]
pub(crate) struct KernelRows {
    pub(crate) states: Vec<Value>,
    pub(crate) collections: Vec<Value>,
    pub(crate) overview: Vec<Value>,
    state_ids: BTreeSet<String>,
    collection_ids: BTreeSet<String>,
}

impl KernelRows {
    /// No row of any of the three kinds — the one answer that cannot
    /// tell a kernel without this chapter from one nobody has saved to.
    fn is_empty(&self) -> bool {
        self.states.is_empty() && self.collections.is_empty() && self.overview.is_empty()
    }

    pub(crate) fn state_ids(&self) -> BTreeSet<&str> {
        self.state_ids.iter().map(String::as_str).collect()
    }

    pub(crate) fn collection_ids(&self) -> BTreeSet<&str> {
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

/// Every live `state` document for one ConsoleSettings aggregate.
///
/// Tries several relation names in order — host-qualified, then
/// chapter-qualified (ADR 0059), then the plain view or table — because
/// different runtimes have written these rows under different names,
/// all answering the same `id`/`state` columns. First one that exists
/// wins; a relation that exists but fails to read still errors.
async fn read_head_states<C: GenericClient>(
    client: &C,
    host_domain: &str,
    storage_name: &str,
) -> anyhow::Result<Vec<Value>> {
    for relation in head_view_candidates(host_domain, storage_name) {
        if !relation_exists(client, &relation).await? {
            continue;
        }
        let rows = client
            .query(&format!("SELECT state FROM {}", journal::quote_ident(&relation)), &[])
            .await?;
        return Ok(rows.iter().map(|row| row.get(0)).collect());
    }
    Ok(Vec::new())
}

/// Pure, and tested as such. Deduplicated, so a host domain that is
/// ConsoleSettings never probes one relation twice.
fn head_view_candidates(host_domain: &str, storage_name: &str) -> Vec<String> {
    let mut candidates = vec![
        journal::head_view(host_domain, storage_name),
        journal::head_view(CONFIG_DOMAIN, storage_name),
        format!("{storage_name}_head"),
        storage_name.to_string(),
    ];
    candidates.dedup();
    candidates
}

/// `to_regclass` resolves through the connection's own `search_path`,
/// same as the unqualified SELECT below — never a same-named relation
/// in some other schema.
async fn relation_exists<C: GenericClient>(client: &C, relation: &str) -> anyhow::Result<bool> {
    let row = client.query_one("SELECT to_regclass($1) IS NOT NULL", &[&relation]).await?;
    Ok(row.get(0))
}

/// `PresentationConfig.unwrap` — every scalar here is a single-attribute
/// value object (`{"value": ...}`); anything else rides through untouched.
fn unwrap(value: &Value) -> Value {
    match value.get("value") {
        Some(inner) => inner.clone(),
        None => value.clone(),
    }
}

fn unwrap_str(value: Option<&Value>) -> String {
    value.map(unwrap).and_then(|v| v.as_str().map(String::from)).unwrap_or_default()
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
    let Some(raw) = present(extra_json).map(unwrap) else { return };
    let Some(text) = raw.as_str().filter(|t| !t.is_empty()) else { return };
    let Ok(Value::Object(extra)) = serde_json::from_str::<Value>(text) else { return };
    for (key, value) in extra {
        entry.entry(key).or_insert(value);
    }
}

/// `reshape_states` — one entry per (aggregate, state) row.
fn reshape_states(rows: &[Value]) -> Value {
    let mut memo: Map<String, Value> = Map::new();
    for row in rows {
        let agg = unwrap_str(row.get("agg"));
        let state = unwrap_str(row.get("state"));
        let mut entry = Map::new();
        if let Some(tone) = present(row.get("tone")) {
            entry.insert("tone".to_string(), unwrap(tone));
        }
        if let Some(attention) = present(row.get("attention")) {
            entry.insert("attention".to_string(), json!(unwrap(attention).as_str() == Some("true")));
        }
        merge_extra(&mut entry, row.get("extra_json"));

        let bucket = memo.entry(agg).or_insert_with(|| Value::Object(Map::new()));
        if let Some(object) = bucket.as_object_mut() {
            object.insert(state, Value::Object(entry));
        }
    }
    Value::Object(memo)
}

fn reshape_collections(rows: &[Value]) -> Value {
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

    entry.insert("columns".to_string(), Value::Array(elements(row, "columns").iter().map(reshape_column).collect()));
    entry.insert("detail_fields".to_string(), reshape_detail_fields(row));
    entry.insert(
        "preconditions".to_string(),
        Value::Array(elements(row, "preconditions").iter().map(reshape_precondition).collect()),
    );
    entry.insert("field_formats".to_string(), reshape_field_formats(row));
    merge_extra(&mut entry, row.get("extra_json"));
    Value::Object(entry)
}

/// `Array(row[:columns])` — a null/absent list is the empty one.
fn elements<'a>(row: &'a Value, field: &str) -> &'a [Value] {
    row.get(field).and_then(|v| v.as_array()).map(|a| a.as_slice()).unwrap_or(&[])
}

fn reshape_identity(row: &Value) -> Option<Value> {
    let field = present(row.get("identity_field")).map(unwrap)?;
    let mut identity = Map::new();
    identity.insert("field".to_string(), field);
    identity.insert("strategy".to_string(), row.get("identity_strategy").map(unwrap).unwrap_or(Value::Null));
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
    entry.insert("field".to_string(), column.get("field").cloned().unwrap_or(Value::Null));
    if let Some(sortable) = present(column.get("sortable")) {
        entry.insert("sortable".to_string(), json!(unwrap(sortable).as_str() == Some("true")));
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
    entry.insert("field".to_string(), precondition.get("field").cloned().unwrap_or(Value::Null));
    entry.insert("state".to_string(), precondition.get("state").cloned().unwrap_or(Value::Null));
    merge_extra(&mut entry, precondition.get("extra_json"));
    Value::Object(entry)
}

fn reshape_field_formats(row: &Value) -> Value {
    let mut formats = Map::new();
    for entry in elements(row, "field_formats") {
        let field = entry.get("field").and_then(|v| v.as_str()).unwrap_or_default().to_string();
        formats.insert(field, entry.get("format").cloned().unwrap_or(Value::Null));
    }
    Value::Object(formats)
}

/// `reshape_overview` — a singleton: no row reads as `{}`, never
/// `{"stats": []}`, matching Ruby's "never configured" vs "empty".
fn reshape_overview(rows: &[Value]) -> Value {
    let Some(row) = rows.first() else { return Value::Object(Map::new()) };
    let stats: Vec<Value> = elements(row, "stats").iter().map(reshape_stat).collect();
    json!({ "stats": stats })
}

/// `reshape_stat` — `where` is an opaque JSON string on the wire
/// (`where_json`) and is parsed back out here, exactly as Ruby does.
fn reshape_stat(stat: &Value) -> Value {
    let mut entry = Map::new();
    entry.insert("label".to_string(), stat.get("label").cloned().unwrap_or(Value::Null));
    entry.insert("collection".to_string(), stat.get("collection").cloned().unwrap_or(Value::Null));
    if let Some(as_fold) = present(stat.get("as")) {
        entry.insert("as".to_string(), as_fold.clone());
    }
    if let Some(field) = present(stat.get("field")) {
        entry.insert("field".to_string(), field.clone());
    }
    if let Some(where_json) = present(stat.get("where_json")).and_then(|v| v.as_str()).filter(|t| !t.is_empty()) {
        if let Ok(parsed) = serde_json::from_str::<Value>(where_json) {
            entry.insert("where".to_string(), parsed);
        }
    }
    Value::Object(entry)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Row literals below are copied from the real rows the console
    // app's own database holds, not invented shapes.

    #[test]
    fn head_view_candidates_cover_every_relation_a_runtime_has_written_these_rows_to() {
        assert_eq!(
            head_view_candidates("SampleApp", "state_style"),
            vec![
                "sample_app_state_style_head".to_string(),
                "console_settings_state_style_head".to_string(),
                "state_style_head".to_string(),
                "state_style".to_string()
            ]
        );
    }

    #[test]
    fn a_host_whose_own_domain_is_the_chapter_never_probes_one_relation_twice() {
        assert_eq!(
            head_view_candidates("ConsoleSettings", "state_style"),
            vec![
                "console_settings_state_style_head".to_string(),
                "state_style_head".to_string(),
                "state_style".to_string()
            ]
        );
    }

    #[test]
    fn a_state_row_becomes_a_tone_an_attention_flag_and_its_extras() {
        let rows = vec![
            json!({"agg": {"value": "Invoice"}, "tone": {"value": "muted"}, "state": {"value": "void"},
                   "attention": null, "extra_json": {"value": "{\"label\":\"Voided\"}"}}),
            json!({"agg": {"value": "Invoice"}, "tone": {"value": "danger"}, "state": {"value": "overdue"},
                   "attention": {"value": "true"}, "extra_json": null}),
        ];

        assert_eq!(
            reshape_states(&rows),
            json!({
                "Invoice": {
                    "void": {"tone": "muted", "label": "Voided"},
                    "overdue": {"tone": "danger", "attention": true}
                }
            })
        );
    }

    #[test]
    fn attention_stored_as_the_string_false_reads_back_as_the_boolean_false() {
        let rows = vec![json!({"agg": {"value": "Client"}, "state": {"value": "active"}, "attention": {"value": "false"}})];

        assert_eq!(reshape_states(&rows), json!({"Client": {"active": {"attention": false}}}));
    }

    #[test]
    fn a_collection_row_becomes_the_whole_entry_ui_schema_reads() {
        let rows = vec![json!({
            "agg": {"value": "Client"}, "key": {"value": "clients"}, "label": {"value": "Clients"},
            "columns": [{"field": "reference"}, {"field": "name"}, {"field": "__state__"}],
            "nav_order": {"value": 1},
            "extra_json": {"value": "{\"noun_sing\":\"client\",\"create_label\":\"Add client\"}"},
            "list_query": null,
            "detail_fields": [{"field": "contact_email"}, {"field": "name"}],
            "field_formats": [], "preconditions": [],
            "primary_field": {"value": "name"},
            "identity_field": {"value": "reference"}, "identity_prefix": null,
            "identity_source": {"value": "name"}, "identity_strategy": {"value": "slug"},
            "identity_extra_json": null, "detail_field_columns": []
        })];

        assert_eq!(
            reshape_collections(&rows),
            json!({
                "Client": {
                    "label": "Clients",
                    "key": "clients",
                    "nav_order": 1,
                    "primary_field": "name",
                    "identity": {"field": "reference", "strategy": "slug", "source": "name"},
                    "columns": [{"field": "reference"}, {"field": "name"}, {"field": "__state__"}],
                    "detail_fields": [{"field": "contact_email"}, {"field": "name"}],
                    "preconditions": [],
                    "field_formats": {},
                    "noun_sing": "client",
                    "create_label": "Add client"
                }
            })
        );
    }

    #[test]
    fn a_precondition_carries_its_state_and_its_extra_message() {
        let rows = vec![json!({
            "agg": {"value": "Contract"},
            "columns": [], "detail_fields": [], "detail_field_columns": [], "field_formats": [],
            "preconditions": [{"field": "proposal_id", "state": "accepted",
                               "extra_json": "{\"message\":\"the proposal hasn't been accepted yet\"}"}],
            "identity_field": {"value": "number"}, "identity_strategy": {"value": "sequence"},
            "identity_prefix": {"value": "C-"}, "identity_extra_json": {"value": "{\"pad\":3}"}
        })];

        let config = reshape_collections(&rows);
        assert_eq!(
            config["Contract"]["preconditions"],
            json!([{"field": "proposal_id", "state": "accepted", "message": "the proposal hasn't been accepted yet"}])
        );
        // `pad` is not modelled as its own attribute — it rides through
        // the identity rule's own opaque blob and has to land inside
        // the identity entry, not beside it.
        assert_eq!(config["Contract"]["identity"], json!({"field": "number", "strategy": "sequence", "prefix": "C-", "pad": 3}));
    }

    #[test]
    fn a_precondition_with_no_state_keeps_an_explicit_null_state() {
        let rows = vec![json!({
            "agg": {"value": "Payment"}, "columns": [], "detail_fields": [], "detail_field_columns": [],
            "field_formats": [], "preconditions": [{"field": "invoice_id"}]
        })];

        assert_eq!(reshape_collections(&rows)["Payment"]["preconditions"], json!([{"field": "invoice_id", "state": null}]));
    }

    #[test]
    fn detail_field_columns_regroup_under_the_field_that_owns_them() {
        let rows = vec![json!({
            "agg": {"value": "CampingList"}, "columns": [], "field_formats": [], "preconditions": [],
            "detail_fields": [
                {"field": "placements", "display": "rows", "state_filter": "placed"},
                {"field": "name"}
            ],
            "detail_field_columns": [
                {"field": "placements", "column": "item_id"},
                {"field": "placements", "column": "position"}
            ]
        })];

        assert_eq!(
            reshape_collections(&rows)["CampingList"]["detail_fields"],
            json!([
                {"field": "placements", "display": "rows", "state_filter": "placed", "columns": ["item_id", "position"]},
                {"field": "name"}
            ])
        );
    }

    #[test]
    fn a_column_entry_reads_its_sortable_string_back_as_a_boolean_and_keeps_its_head() {
        let rows = vec![json!({
            "agg": {"value": "Invoice"}, "detail_fields": [], "detail_field_columns": [],
            "field_formats": [{"field": "issued_on", "format": "date"}], "preconditions": [],
            "columns": [{"field": "number", "sortable": "false", "sort_default": "desc", "extra_json": "{\"head\":\"No.\"}"}]
        })];

        let entry = &reshape_collections(&rows)["Invoice"];
        assert_eq!(entry["columns"], json!([{"field": "number", "sortable": false, "sort_default": "desc", "head": "No."}]));
        assert_eq!(entry["field_formats"], json!({"issued_on": "date"}));
    }

    #[test]
    fn the_overview_singleton_becomes_stats_with_their_where_clauses_parsed() {
        let rows = vec![json!({
            "key": {"value": "overview"},
            "stats": [
                {"as": "count", "label": "Active clients", "collection": "clients", "where_json": "{\"state\":\"active\"}"},
                {"as": "money_sum", "field": "line_items", "label": "Outstanding", "collection": "invoices",
                 "where_json": "{\"state\":{\"in\":[\"sent\",\"overdue\"]}}"}
            ]
        })];

        assert_eq!(
            reshape_overview(&rows),
            json!({"stats": [
                {"label": "Active clients", "collection": "clients", "as": "count", "where": {"state": "active"}},
                {"label": "Outstanding", "collection": "invoices", "as": "money_sum", "field": "line_items",
                 "where": {"state": {"in": ["sent", "overdue"]}}}
            ]})
        );
    }

    #[test]
    fn a_domain_that_has_never_saved_an_overview_reads_back_an_empty_section() {
        assert_eq!(reshape_overview(&[]), json!({}));
        assert_eq!(reshape(&[], &[], &[]), json!({"states": {}, "collections": {}, "overview": {}}));
    }

    #[test]
    fn an_explicitly_modelled_field_always_beats_the_same_key_in_the_extras_blob() {
        let rows = vec![json!({"agg": {"value": "Client"}, "tone": {"value": "good"},
                               "extra_json": {"value": "{\"tone\":\"danger\",\"note\":\"n\"}"},
                               "state": {"value": "active"}})];

        assert_eq!(reshape_states(&rows), json!({"Client": {"active": {"tone": "good", "note": "n"}}}));
    }

    // What follows needs a real database: which relation this module
    // reads, and what it does when there isn't one. Same throwaway-db
    // pattern as dispatch.rs's own tests, uniquely named per test so
    // `cargo test`'s parallelism doesn't race two against one table.

    async fn scratch_db(name: &str) -> Mutex<Client> {
        let (admin, conn) = tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), tokio_postgres::NoTls)
            .await
            .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        admin.batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)")).await.unwrap();
        admin.batch_execute(&format!("CREATE DATABASE {name}")).await.unwrap();

        let (client, conn) = tokio_postgres::connect(&crate::test_pg::conninfo(&name), tokio_postgres::NoTls)
            .await
            .expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        Mutex::new(client)
    }

    // A plain table, not a view — this module only ever SELECTs
    // `state`, so a relation's real provenance doesn't matter here.
    /// A domain matching none of these fixtures' relations, so lookup
    /// falls through to whatever each test seeds directly.
    fn relations_only() -> LineageConfig {
        LineageConfig { domain: "Fixtures".to_string(), era: None, mirrored: None }
    }

    async fn seed_head(client: &Mutex<Client>, relation: &str, id: &str, state: Value) {
        let guard = client.lock().await;
        guard
            .batch_execute(&format!("CREATE TABLE IF NOT EXISTS {relation} (id text primary key, state jsonb)"))
            .await
            .unwrap();
        guard
            .execute(&format!("INSERT INTO {relation} (id, state) VALUES ($1, $2)"), &[&id, &state])
            .await
            .unwrap();
    }

    // Which kind of empty is the one question the instance map alone
    // can't answer; both tests below run against a real compiled
    // kernel, since a fixture can't fake "does this wasm know this read model".

    #[tokio::test]
    async fn a_kernel_that_carries_the_chapter_but_holds_no_rows_answers_some_empty() {
        let client = crate::dispatch::tests::scratch_db("hecks_host_presentation_chapter_no_rows").await;
        let wasm = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/checkout_fixture.wasm");

        let rows = kernel_rows(&client, &wasm).await.expect("a read").expect("the chapter is compiled in");

        assert!(rows.states.is_empty());
        assert!(rows.collections.is_empty());
        assert!(rows.overview.is_empty());
    }

    #[tokio::test]
    async fn a_kernel_without_the_chapter_answers_none_so_the_relations_are_read_instead() {
        let client = crate::dispatch::tests::scratch_db("hecks_host_presentation_no_chapter").await;
        let wasm = crate::dispatch::tests::wasm_path();

        assert!(kernel_rows(&client, &wasm).await.expect("a read").is_none());
    }

    #[tokio::test]
    async fn load_reads_the_pre_0059_unqualified_relation_the_console_still_writes() {
        let client = scratch_db("hecks_host_presentation_legacy_relation").await;
        seed_head(&client, "state_style_head", "Client:active", json!({"agg": {"value": "Client"}, "state": {"value": "active"}, "tone": {"value": "good"}})).await;

        let config = load_from_relations(&client, &relations_only()).await.expect("a config");

        assert_eq!(config["states"], json!({"Client": {"active": {"tone": "good"}}}));
        assert_eq!(config["collections"], json!({}));
        assert_eq!(config["overview"], json!({}));
    }

    #[tokio::test]
    async fn load_prefers_the_domain_qualified_relation_when_both_exist() {
        let client = scratch_db("hecks_host_presentation_qualified_wins").await;
        seed_head(&client, "state_style_head", "Client:active", json!({"agg": {"value": "Client"}, "state": {"value": "active"}, "tone": {"value": "muted"}})).await;
        seed_head(
            &client,
            "console_settings_state_style_head",
            "Client:active",
            json!({"agg": {"value": "Client"}, "state": {"value": "active"}, "tone": {"value": "good"}}),
        )
        .await;

        let config = load_from_relations(&client, &relations_only()).await.expect("a config");

        assert_eq!(config["states"]["Client"]["active"]["tone"], "good");
    }

    #[tokio::test]
    async fn load_answers_an_empty_config_for_a_domain_with_no_console_settings_relations() {
        let client = scratch_db("hecks_host_presentation_no_relations").await;

        assert_eq!(
            load_from_relations(&client, &relations_only()).await.expect("a config"),
            json!({"states": {}, "collections": {}, "overview": {}})
        );
    }

    #[test]
    fn a_malformed_extras_blob_is_ignored_rather_than_failing_the_whole_read() {
        let rows = vec![json!({"agg": {"value": "Client"}, "state": {"value": "active"},
                               "tone": {"value": "good"}, "extra_json": {"value": "not json at all"}})];

        assert_eq!(reshape_states(&rows), json!({"Client": {"active": {"tone": "good"}}}));
    }
}
