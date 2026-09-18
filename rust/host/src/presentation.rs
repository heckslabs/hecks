// THE CONSOLE'S OWN PRESENTATION CONFIG, READ — the Rust-native
// counterpart to embryonaut_console's `web/presentation_config.rb`
// `.load`, returning the IDENTICAL nested JSON shape that file has
// always returned (`{"states" => {...}, "collections" => {...},
// "overview" => {...}}`), so `ui_schema.rs`, the `/api/*` routes and
// index.html's own readers all see exactly what the Ruby engine
// serves them.
//
// WHY THIS READS RUBY'S OWN POSTGRES TABLES AND NOT THIS CRATE'S
// JOURNAL — the config is real domain data (a `ConsoleSettings`
// chapter: StateStyle, Collection, Overview), dispatched through real
// commands, but it is NOT in `hecks_lambda_journal`. The consuming
// app pins it, permanently and deliberately, to the Ruby "Postgres"
// adapter — embryonautfoundersapp.hecksagon's own comment says why in
// full: with `HECKS_LAMBDA_ROUTING=true` every other chapter routes
// through the dispatch Lambda (this crate's own flat journal), and
// ConsoleSettings followed it there once, into a store no Ruby-side
// write had ever populated, so the console read back "no presentation
// entry for" every real state at once. It has been Postgres-only ever
// since: "PURELY WebFunction's own console-UI data, never read or
// written by any business command".
//
// So the rows live in Ruby's era-aware head views — `state_style_head`,
// `collection_head`, `overview_head` — in the SAME database this crate
// already holds a connection to (the storehouse RDS instance, this
// domain's own schema, already on `search_path` from main.rs). Reading
// a Ruby head view from Rust is not new here either: `auth.rs` has
// always read the membership aggregate's own head view exactly this
// way (`journal::read_lineage_head_all`/`read_lineage_head_by_id`).
// This module is that same read, for three more relations, plus the
// reshaping `presentation_config.rb` does on the way out.
//
// READ-ONLY, ON PURPOSE. `PresentationConfig.save!` dispatches a dozen
// `ConsoleSettings::*` commands through Ruby's own runtime, which is
// what enforces the chapter's own invariants (a tone is `one_of`, a
// state is declared before it is styled). This crate has no kernel for
// that chapter — its `.wasm` module is the CONSUMING domain's, which
// has never contained ConsoleSettings at all — so writing here would
// mean hand-rolling an era-journal append plus a head-snapshot upsert
// with the aggregate's own rules simply not run. See `api.rs`'s
// `PUT /api/presentation` arm for the refusal that says so out loud.

use crate::journal;
use serde_json::{json, Map, Value};
use tokio::sync::Mutex;
use tokio_postgres::{Client, GenericClient};

/// The chapter the console's own config lives in — a literal here for
/// the same reason it is a literal in `presentation_config.rb`
/// (`registry.bluebook("ConsoleSettings")`): the name is part of the
/// console's own contract, not a property of whichever domain this
/// host happens to serve.
pub const CONFIG_DOMAIN: &str = "ConsoleSettings";

/// `Naming.snake` of each of that chapter's three aggregates — the
/// `storage_name` Ruby derives its relation names from.
const STATE_STYLE: &str = "state_style";
const COLLECTION: &str = "collection";
const OVERVIEW: &str = "overview";

/// The whole config, exactly as `PresentationConfig.load` returns it.
///
/// Never an error for a domain that simply has no ConsoleSettings rows
/// — or no ConsoleSettings relations at all, which is every domain but
/// the one console app that uses this. An absent relation reads as an
/// empty section, the same answer Ruby gives for a present-but-empty
/// one, because "this domain configures no presentation" and "this
/// domain has never saved any presentation" are the same fact to every
/// reader downstream (`ui_schema` falls back to derived defaults for
/// both).
pub async fn load(client: &Mutex<Client>) -> anyhow::Result<Value> {
    let guard = client.lock().await;
    let states = read_head_states(&*guard, STATE_STYLE).await?;
    let collections = read_head_states(&*guard, COLLECTION).await?;
    let overview = read_head_states(&*guard, OVERVIEW).await?;
    drop(guard);
    Ok(reshape(&states, &collections, &overview))
}

/// Pure: the three row sets in, `PresentationConfig.load`'s own hash
/// out. Split from the SQL above so every reshaping rule below is
/// unit-testable against a literal row, the way `auth_gate`'s own
/// decision is (web.rs) — `load` itself needs a live connection.
pub fn reshape(states: &[Value], collections: &[Value], overview: &[Value]) -> Value {
    let mut config = Map::new();
    config.insert("states".to_string(), reshape_states(states));
    config.insert("collections".to_string(), reshape_collections(collections));
    config.insert("overview".to_string(), reshape_overview(overview));
    Value::Object(config)
}

// ---- the relations -------------------------------------------------

/// Every live `state` document for one ConsoleSettings aggregate.
///
/// THREE CANDIDATE NAMES, IN ORDER, because three different Ruby
/// runtimes have written these rows and each derived its own relation
/// name — all three answering the same two columns (`id`, `state`
/// jsonb), which is the only part this module actually depends on.
///
///   1. `console_settings_state_style_head` — the era head view as
///      docs/decisions/0059 qualifies it, what `journal::head_view`
///      derives today.
///   2. `state_style_head` — the same view before that decision, which
///      is where the real live rows are: the console app that wrote
///      them runs its own older copy of the runtime.
///   3. `state_style` — the flat table today's `Adapters::Postgres`
///      creates and reads for a `persisted_by("Postgres")` binding
///      (`table = aggregate.storage_name`), i.e. where a console
///      booted against current hecks would put them.
///
/// First one that exists wins. This is a resolution step, not a
/// fallback that hides an error: a relation that exists but fails to
/// read still errors, and an empty answer is only ever reported for a
/// domain with none of the three.
async fn read_head_states<C: GenericClient>(client: &C, storage_name: &str) -> anyhow::Result<Vec<Value>> {
    for relation in head_view_candidates(CONFIG_DOMAIN, storage_name) {
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

/// Pure, and tested as such. Deduplicated, so a domain whose own
/// qualification happens to be a no-op never probes one relation twice.
fn head_view_candidates(domain: &str, storage_name: &str) -> Vec<String> {
    let mut candidates = vec![journal::head_view(domain, storage_name), format!("{storage_name}_head"), storage_name.to_string()];
    candidates.dedup();
    candidates
}

/// `to_regclass` resolves through the connection's own `search_path`
/// — the same way the unqualified `SELECT ... FROM state_style_head`
/// below resolves — so this asks precisely "would that query find a
/// relation", never "does some same-named relation exist in some other
/// schema".
async fn relation_exists<C: GenericClient>(client: &C, relation: &str) -> anyhow::Result<bool> {
    let row = client.query_one("SELECT to_regclass($1) IS NOT NULL", &[&relation]).await?;
    Ok(row.get(0))
}

// ---- reshaping — presentation_config.rb, rule for rule --------------

/// `PresentationConfig.unwrap` — every scalar this chapter stores is a
/// single-attribute value object (`{"value": ...}`), so one unwrap
/// handles all of them; anything else rides through untouched.
fn unwrap(value: &Value) -> Value {
    match value.get("value") {
        Some(inner) => inner.clone(),
        None => value.clone(),
    }
}

fn unwrap_str(value: Option<&Value>) -> String {
    value.map(unwrap).and_then(|v| v.as_str().map(String::from)).unwrap_or_default()
}

/// Ruby truthiness for a stored field: an absent key and a JSON `null`
/// are both "not set" (`if row[:tone]`), and no field this chapter
/// stores is ever boolean `false` on the wire — `attention` is stored
/// as the STRING "true"/"false", which is why its own read below
/// compares strings rather than trusting a JSON boolean.
fn present(value: Option<&Value>) -> Option<&Value> {
    value.filter(|v| !v.is_null() && v.as_bool() != Some(false))
}

/// `PresentationConfig.merge_extra!` — the opaque passthrough blob
/// (`extra_json`) merged in, never overwriting an explicitly-modeled
/// key that is already present. Accepts the blob either wrapped
/// (`{"value": "{...}"}`, how a head field stores it) or bare (how a
/// `list_of` element stores it), because Ruby's own `unwrap`/`row_field`
/// pair reads it both ways for exactly the same reason.
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
/// each only when set, then the four `Replace*` lists (always present,
/// empty or not — an empty `columns` is a real answer, not a missing
/// one), then the opaque extras.
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

/// `reshape_column` — `sortable` is stored as the string "true"/"false"
/// (a value object holds a String, not a boolean) and comes back as a
/// real boolean, exactly as Ruby's `(sortable == "true")` does.
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

/// `reshape_detail_fields` — `detail_field_columns` is stored FLAT
/// (one row per (field, column) pair, see console_settings.bluebook's
/// own comment on why it isn't nested) and is regrouped here, back
/// under the detail field that owns it.
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

/// `reshape_precondition` — BOTH keys always, `state` included as an
/// explicit null when unset, matching Ruby's own literal hash (a
/// precondition with no state is "the target must merely exist").
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

/// `reshape_overview` — a singleton aggregate: one row or none, and
/// none reads as `{}` (never `{"stats": []}`), the same distinction
/// Ruby draws between "never configured" and "configured empty".
fn reshape_overview(rows: &[Value]) -> Value {
    let Some(row) = rows.first() else { return Value::Object(Map::new()) };
    let stats: Vec<Value> = elements(row, "stats").iter().map(reshape_stat).collect();
    json!({ "stats": stats })
}

/// `reshape_stat` — `where` is stored as an opaque JSON string
/// (`where_json`: hecks has no attribute type for "arbitrary nested
/// map", see presentation_config.rb's own header) and is parsed back
/// out here, at this file's own boundary, exactly as Ruby does.
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

    // Every row literal below is copied from the REAL rows the console
    // app's own database holds (`select state from collection_head`,
    // `state_style_head`, `overview_head`) — not invented shapes. What
    // they pin is that this module reshapes them into exactly what
    // `PresentationConfig.load` builds out of the same rows.

    #[test]
    fn head_view_candidates_cover_every_relation_a_ruby_runtime_has_written_these_rows_to() {
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

    // ---- against a real Postgres --------------------------------
    //
    // The reshaping above is pure and pinned by the tests before this
    // point; what these three add is the half that only a real
    // database can answer — which RELATION this module reads, and what
    // it does when there isn't one. Same throwaway-database-per-test
    // pattern dispatch.rs's own tests use (its own comment: uniquely
    // named "so `cargo test`'s default parallelism doesn't race two
    // tests against the same journal table").

    async fn scratch_db(name: &str) -> Mutex<Client> {
        let (admin, conn) = tokio_postgres::connect("host=localhost dbname=postgres", tokio_postgres::NoTls)
            .await
            .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        admin.batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)")).await.unwrap();
        admin.batch_execute(&format!("CREATE DATABASE {name}")).await.unwrap();

        let (client, conn) = tokio_postgres::connect(&format!("host=localhost dbname={name}"), tokio_postgres::NoTls)
            .await
            .expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        Mutex::new(client)
    }

    // A table, not a view over a snapshot table — this module only
    // ever SELECTs `state`, so the relation's own provenance (Ruby's
    // era view, or anything else answering the same two columns) is
    // exactly the part it has no business knowing.
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

    #[tokio::test]
    async fn load_reads_the_pre_0059_unqualified_relation_the_console_still_writes() {
        let client = scratch_db("hecks_host_presentation_legacy_relation").await;
        seed_head(&client, "state_style_head", "Client:active", json!({"agg": {"value": "Client"}, "state": {"value": "active"}, "tone": {"value": "good"}})).await;

        let config = load(&client).await.expect("a config");

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

        let config = load(&client).await.expect("a config");

        assert_eq!(config["states"]["Client"]["active"]["tone"], "good");
    }

    #[tokio::test]
    async fn load_answers_an_empty_config_for_a_domain_with_no_console_settings_relations() {
        let client = scratch_db("hecks_host_presentation_no_relations").await;

        assert_eq!(load(&client).await.expect("a config"), json!({"states": {}, "collections": {}, "overview": {}}));
    }

    #[test]
    fn a_malformed_extras_blob_is_ignored_rather_than_failing_the_whole_read() {
        let rows = vec![json!({"agg": {"value": "Client"}, "state": {"value": "active"},
                               "tone": {"value": "good"}, "extra_json": {"value": "not json at all"}})];

        assert_eq!(reshape_states(&rows), json!({"Client": {"active": {"tone": "good"}}}));
    }
}
