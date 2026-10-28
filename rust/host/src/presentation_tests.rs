//! The presentation config read from a real Postgres head view.

#![allow(unused_imports)]

#[cfg(test)]
mod tests {
    use crate::journal::LineageConfig;
    use crate::store::{Store, StoreFixtures};
    use rust_host_core::presentation::*;
    use serde_json::json;
    use serde_json::Value;

    // Row literals below are copied from the real rows the console
    // app's own database holds, not invented shapes.

    #[test]
    fn a_collections_four_aggregates_read_back_as_one_entry_and_the_newer_rows_win() {
        let rows = vec![
            json!({"agg": {"value": "Invoice"}, "label": {"value": "Invoices"},
                   "columns": [{"field": "stale"}]}),
            json!({"agg": {"value": "Invoice"}, "identity_field": {"value": "number"},
                   "identity_strategy": {"value": "sequence"}}),
            json!({"agg": {"value": "Invoice"}, "columns": [{"field": "number"}]}),
            json!({"agg": {"value": "Invoice"}, "preconditions": [], "field_formats": []}),
        ];

        let entry = &reshape_collections(&rows)["Invoice"];

        assert_eq!(
            (
                &entry["label"],
                &entry["columns"],
                &entry["identity"]["field"]
            ),
            (
                &json!("Invoices"),
                &json!([{"field": "number"}]),
                &json!("number")
            )
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
        let rows = vec![
            json!({"agg": {"value": "Client"}, "state": {"value": "active"}, "attention": {"value": "false"}}),
        ];

        assert_eq!(
            reshape_states(&rows),
            json!({"Client": {"active": {"attention": false}}})
        );
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
        assert_eq!(
            config["Contract"]["identity"],
            json!({"field": "number", "strategy": "sequence", "prefix": "C-", "pad": 3})
        );
    }

    #[test]
    fn a_precondition_with_no_state_keeps_an_explicit_null_state() {
        let rows = vec![json!({
            "agg": {"value": "Payment"}, "columns": [], "detail_fields": [], "detail_field_columns": [],
            "field_formats": [], "preconditions": [{"field": "invoice_id"}]
        })];

        assert_eq!(
            reshape_collections(&rows)["Payment"]["preconditions"],
            json!([{"field": "invoice_id", "state": null}])
        );
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
        assert_eq!(
            entry["columns"],
            json!([{"field": "number", "sortable": false, "sort_default": "desc", "head": "No."}])
        );
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
        assert_eq!(
            reshape(&[], &[], &[]),
            json!({"states": {}, "collections": {}, "overview": {}})
        );
    }

    #[test]
    fn an_explicitly_modelled_field_always_beats_the_same_key_in_the_extras_blob() {
        let rows = vec![
            json!({"agg": {"value": "Client"}, "tone": {"value": "good"},
                               "extra_json": {"value": "{\"tone\":\"danger\",\"note\":\"n\"}"},
                               "state": {"value": "active"}}),
        ];

        assert_eq!(
            reshape_states(&rows),
            json!({"Client": {"active": {"tone": "good", "note": "n"}}})
        );
    }

    // What follows needs a real database: which relation this module
    // reads, and what it does when there isn't one. Same throwaway-db
    // pattern as dispatch.rs's own tests, uniquely named per test so
    // `cargo test`'s parallelism doesn't race two against one table.

    async fn scratch_db(name: &str) -> Store {
        let (admin, conn) =
            tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), tokio_postgres::NoTls)
                .await
                .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        admin
            .batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)"))
            .await
            .unwrap();
        admin
            .batch_execute(&format!("CREATE DATABASE {name}"))
            .await
            .unwrap();

        let (client, conn) =
            tokio_postgres::connect(&crate::test_pg::conninfo(name), tokio_postgres::NoTls)
                .await
                .expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        crate::store::postgres_store(client)
    }

    // A plain table, not a view — this module only ever SELECTs
    // `state`, so a relation's real provenance doesn't matter here.
    /// A domain matching none of these fixtures' relations, so lookup
    /// falls through to whatever each test seeds directly.
    fn relations_only() -> LineageConfig {
        LineageConfig {
            domain: "Fixtures".to_string(),
            era: None,
            mirrored: None,
            seal_every: None,
        }
    }

    async fn seed_head(client: &Store, relation: &str, id: &str, state: Value) {
        let guard = client.lock().await;
        guard
            .batch_execute(&format!(
                "CREATE TABLE IF NOT EXISTS {relation} (id text primary key, state jsonb)"
            ))
            .await
            .unwrap();
        guard
            .execute(
                &format!("INSERT INTO {relation} (id, state) VALUES ($1, $2)"),
                &[&id, &state],
            )
            .await
            .unwrap();
    }

    // Which kind of empty is the one question the instance map alone
    // can't answer; both tests below run against a real compiled
    // kernel, since a fixture can't fake "does this wasm know this read model".

    #[tokio::test]
    async fn a_kernel_that_carries_the_bluebook_but_holds_no_rows_answers_some_empty() {
        let client = crate::dispatch_tests::tests::memory_store();
        let wasm = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../dist/checkout_fixture.wasm");

        let rows = kernel_rows(&client, &wasm)
            .await
            .expect("a read")
            .expect("the bluebook is compiled in");

        assert!(rows.states.is_empty());
        assert!(rows.collections.is_empty());
        assert!(rows.overview.is_empty());
    }

    #[tokio::test]
    async fn a_kernel_without_the_bluebook_answers_none_so_the_relations_are_read_instead() {
        let client = crate::dispatch_tests::tests::memory_store();
        let wasm = crate::dispatch_tests::tests::wasm_path();

        assert!(kernel_rows(&client, &wasm).await.expect("a read").is_none());
    }

    #[tokio::test]
    async fn load_reads_the_pre_0059_unqualified_relation_the_console_still_writes() {
        let client = scratch_db("hecks_host_presentation_legacy_relation").await;
        seed_head(&client, "state_style_head", "Client:active", json!({"agg": {"value": "Client"}, "state": {"value": "active"}, "tone": {"value": "good"}})).await;

        let config = load_from_relations(&client, &relations_only())
            .await
            .expect("a config");

        assert_eq!(
            config["states"],
            json!({"Client": {"active": {"tone": "good"}}})
        );
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

        let config = load_from_relations(&client, &relations_only())
            .await
            .expect("a config");

        assert_eq!(config["states"]["Client"]["active"]["tone"], "good");
    }

    #[tokio::test]
    async fn load_answers_an_empty_config_for_a_domain_with_no_console_settings_relations() {
        let client = scratch_db("hecks_host_presentation_no_relations").await;

        assert_eq!(
            load_from_relations(&client, &relations_only())
                .await
                .expect("a config"),
            json!({"states": {}, "collections": {}, "overview": {}})
        );
    }

    #[test]
    fn a_malformed_extras_blob_is_ignored_rather_than_failing_the_whole_read() {
        let rows = vec![
            json!({"agg": {"value": "Client"}, "state": {"value": "active"},
                               "tone": {"value": "good"}, "extra_json": {"value": "not json at all"}}),
        ];

        assert_eq!(
            reshape_states(&rows),
            json!({"Client": {"active": {"tone": "good"}}})
        );
    }
}
