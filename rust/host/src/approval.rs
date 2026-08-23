// THE APPROVAL-GATE CHECK — ADR-0030-in-progress step 5. `compute`/
// `rekey` are the two migration rule kinds with no in-process reference
// implementation anywhere (`Ports::Persistence::Lineage#translate`'s
// own header: "compute is deliberately not applied here"); their only
// verification is the human-approved sample `bin/translation_audit
// --approve` records. `lineage_manager/minter.rb`'s own gate is what
// this ports — mint refuses outright without a matching, unstale
// approval, and this crate's own mint executor (`crate::mint`) must
// hold itself to the exact same rule before it ever calls `mint_era`.
//
// `edge_digest` is the one genuinely delicate piece: it must reproduce
// `ApprovalDigest.edge_digest`'s own SHA256 byte-for-byte, over the
// SAME digest-relevant shape `Exporter.translation_hash`/
// `translation_aggregate` produce — DELIBERATELY NOT the shape
// `ir.json`'s own `translations` key carries (that one also has
// `compiled_state_expression`/`compiled_id_expression` merged in,
// which must never feed the digest — see `Exporter.
// compiled_translation_aggregate`'s own header for why: a digest bound
// to compiled SQL, not just declared rules, would invalidate a valid
// approval the moment the compiler's own output format changed for
// any reason). Hand-built key order throughout, same reasoning
// `storage_shape.rs`'s own canonical serialization already holds
// itself to — plus, HERE specifically, `renames` is a genuine JSON
// OBJECT whose key order is meaningful domain data (the DSL's own
// declaration order), which is why `rust/host/Cargo.toml` now enables
// `serde_json`'s `preserve_order` feature (see that Cargo.toml comment).

use crate::journal;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio_postgres::GenericClient;

/// The SAME digest `Translation::Audit.edge_digest`/`ApprovalDigest.
/// edge_digest` compute. `edge` is one entry of `ir.json`'s
/// `translations` array (the COMPILED shape) — this function reads
/// only the digest-relevant fields out of it and ignores the two
/// compiled-SQL fields entirely, exactly as `Exporter.translation_
/// hash`/`translation_aggregate` (not `compiled_translation_
/// aggregate`) do on the Ruby side.
pub fn edge_digest(edge: &Value) -> String {
    let digest = Sha256::digest(canonical_edge(edge).as_bytes());
    format!("{digest:x}")
}

/// `edge.aggregates.any? { |declared| !declared.computes.empty? ||
/// !declared.rekeys.empty? }` — minter.rb's own gate condition.
pub fn requires_approval(edge: &Value) -> bool {
    edge.get("aggregates").and_then(Value::as_array).into_iter().flatten().any(|aggregate| {
        let non_empty = |key: &str| aggregate.get(key).and_then(Value::as_array).map(|list| !list.is_empty()).unwrap_or(false);
        non_empty("computes") || non_empty("rekeys")
    })
}

/// The gate itself — `lineage_manager/minter.rb`'s own two-refusal
/// check, verbatim in structure (not just in message wording): no
/// approval / wrong digest is one refusal, a stale (journal-advanced-
/// past-review) approval is the other. A no-op for an edge with no
/// compute/rekey rule at all — the portable rule kinds need no human
/// review, mechanically verified instead (Layers 1+2, `crate::mint`'s
/// own live audit — see that module for the "full parity" decision
/// this crate holds itself to).
pub async fn check<C: GenericClient>(client: &C, domain: &str, edge: &Value, ordinal: i32) -> anyhow::Result<()> {
    if !requires_approval(edge) {
        return Ok(());
    }

    let from = edge.get("from").and_then(Value::as_str).unwrap_or("");
    let to = edge.get("to").and_then(Value::as_str).unwrap_or("");
    let digest = edge_digest(edge);

    let approval = journal::approval_for(client, domain, from, to).await?;
    let approval = match approval {
        Some(approval) if approval.edge_digest == digest => approval,
        _ => anyhow::bail!(
            "cannot mint era {ordinal} of {domain}: this edge carries a compute or rekey rule, and the audit's \
             human-approved sample is its only verification — run bin/translation_audit with --approve, then boot again"
        ),
    };

    let tip = journal::last_ordinal(client, domain).await?;
    if approval.reviewed_ordinal != tip {
        anyhow::bail!(
            "cannot mint era {ordinal} of {domain}: the journal advanced past the approved review (ordinal {} \
             reviewed, {tip} now) — the samples a human approved no longer cover the data; re-run bin/translation_audit with --approve",
            approval.reviewed_ordinal
        );
    }
    Ok(())
}

fn canonical_edge(edge: &Value) -> String {
    let domain = json_string(edge.get("domain").and_then(Value::as_str).unwrap_or(""));
    let from = json_string(edge.get("from").and_then(Value::as_str).unwrap_or(""));
    let to = json_string(edge.get("to").and_then(Value::as_str).unwrap_or(""));
    let retired = join_array(edge.get("retired").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(json_string));
    let aggregates = join_array(edge.get("aggregates").and_then(Value::as_array).into_iter().flatten().map(canonical_aggregate));
    format!("{{\"domain\":{domain},\"from\":{from},\"to\":{to},\"retired\":{retired},\"aggregates\":{aggregates}}}")
}

fn canonical_aggregate(aggregate: &Value) -> String {
    let name = json_string(aggregate.get("name").and_then(Value::as_str).unwrap_or(""));
    let was = aggregate.get("was").and_then(Value::as_str).map(json_string).unwrap_or_else(|| "null".to_string());

    // A genuine JSON OBJECT, order-preserving (see this file's own
    // header on `preserve_order`) — `{old_name: new_name, ...}`,
    // matching `translation_aggregate`'s own `renames.transform_keys(&
    // :to_s).transform_values(&:to_s)` exactly.
    let renames = join_object(
        aggregate
            .get("renames")
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
            .map(|(key, value)| (key.clone(), json_string(value.as_str().unwrap_or("")))),
    );

    let moves = join_array(aggregate.get("moves").and_then(Value::as_array).into_iter().flatten().map(|m| {
        let from = json_string(m.get("from").and_then(Value::as_str).unwrap_or(""));
        let to = json_string(m.get("to").and_then(Value::as_str).unwrap_or(""));
        format!("{{\"from\":{from},\"to\":{to}}}")
    }));

    let converts = join_array(aggregate.get("converts").and_then(Value::as_array).into_iter().flatten().map(|c| {
        let from = json_string(c.get("from").and_then(Value::as_str).unwrap_or(""));
        let to = json_string(c.get("to").and_then(Value::as_str).unwrap_or(""));
        // `values: [[key, value], ...]` -- convert.values.map { |k, v| [k, v] },
        // already an array of 2-element arrays on the wire, order-preserved
        // the same way (an ARRAY, never reordered regardless of the
        // serde_json feature flag).
        let values = join_array(c.get("values").and_then(Value::as_array).into_iter().flatten().map(|pair| {
            let pair_items = pair.as_array().map(|p| p.iter().map(raw_json).collect::<Vec<_>>().join(",")).unwrap_or_default();
            format!("[{pair_items}]")
        }));
        format!("{{\"from\":{from},\"to\":{to},\"values\":{values}}}")
    }));

    let drops = join_array(aggregate.get("drops").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).map(json_string));

    let retypes = join_array(aggregate.get("retypes").and_then(Value::as_array).into_iter().flatten().map(|r| {
        let from = json_string(r.get("from").and_then(Value::as_str).unwrap_or(""));
        let to = json_string(r.get("to").and_then(Value::as_str).unwrap_or(""));
        format!("{{\"from\":{from},\"to\":{to}}}")
    }));

    let computes = join_array(aggregate.get("computes").and_then(Value::as_array).into_iter().flatten().map(|c| {
        let from = json_string(c.get("from").and_then(Value::as_str).unwrap_or(""));
        let to = json_string(c.get("to").and_then(Value::as_str).unwrap_or(""));
        let sql = json_string(c.get("sql").and_then(Value::as_str).unwrap_or(""));
        format!("{{\"from\":{from},\"to\":{to},\"sql\":{sql}}}")
    }));

    let rekeys = join_array(aggregate.get("rekeys").and_then(Value::as_array).into_iter().flatten().map(|r| {
        let sql = json_string(r.get("sql").and_then(Value::as_str).unwrap_or(""));
        format!("{{\"sql\":{sql}}}")
    }));

    let backfills = join_array(aggregate.get("backfills").and_then(Value::as_array).into_iter().flatten().map(|b| {
        let name = json_string(b.get("name").and_then(Value::as_str).unwrap_or(""));
        let default = b.get("default").map(raw_json).unwrap_or_else(|| "null".to_string());
        format!("{{\"name\":{name},\"default\":{default}}}")
    }));

    format!(
        "{{\"name\":{name},\"was\":{was},\"renames\":{renames},\"moves\":{moves},\"converts\":{converts},\
         \"drops\":{drops},\"retypes\":{retypes},\"computes\":{computes},\"rekeys\":{rekeys},\"backfills\":{backfills}}}"
    )
}

fn join_array<I: Iterator<Item = String>>(items: I) -> String {
    format!("[{}]", items.collect::<Vec<_>>().join(","))
}

fn join_object<I: Iterator<Item = (String, String)>>(pairs: I) -> String {
    format!("{{{}}}", pairs.map(|(k, v)| format!("{}:{v}", json_string(&k))).collect::<Vec<_>>().join(","))
}

fn json_string(s: &str) -> String {
    serde_json::to_string(s).expect("a plain &str always serializes")
}

// `default:` (a backfill's literal value) is untyped JSON -- any scalar
// or nested structure a bluebook author wrote, not always a string.
// serde_json's own compact serialization of a parsed `Value` is safe to
// use here (unlike the hand-built OBJECT/ARRAY wrapping elsewhere in
// this file): this is a LEAF value with no further key-order question
// underneath it that this crate's own `preserve_order` feature doesn't
// already answer once and for all, structurally, for every Value.
fn raw_json(value: &Value) -> String {
    serde_json::to_string(value).expect("a parsed Value always re-serializes")
}

#[cfg(test)]
mod tests {
    use super::*;

    // THE REAL CROSS-CHECK — not a self-consistent Rust-only fixture
    // like the three tests below it, but Ruby's OWN literal output for
    // a real compute+rekey edge (Hecksagain::Translation::Audit.
    // edge_digest, run for real against a bluebook matching mint_and_
    // seed_lineage_compute.rb's own shape), pasted in verbatim. If
    // Rust's edge_digest ever disagrees with Ruby's for identical
    // input, this is the test that catches it — everything else in
    // this file only proves Rust agrees with ITSELF.
    #[test]
    fn edge_digest_matches_ruby_s_own_output_for_a_real_compute_and_rekey_edge() {
        let edge = serde_json::json!({
            "domain": "LedgerCompute", "from": "aaaaaa", "to": "bbbbbb", "retired": [],
            "aggregates": [{
                "name": "Account", "was": null, "renames": {}, "moves": [], "converts": [], "drops": [], "retypes": [],
                "computes": [{"from": "score", "to": "doubled", "sql": "jsonb_build_object('value', (score::jsonb->>'value')::int * 2)"}],
                "rekeys": [{"sql": "state->>'kind'"}],
                "backfills": [],
                "compiled_state_expression": "(SELECT CASE WHEN __s ? 'score' THEN hecks_tr_insert(__s - 'score', ARRAY['doubled']::text[], to_jsonb((jsonb_build_object('value', (score::jsonb->>'value')::int * 2))), 'compute score to: doubled') ELSE __s END FROM (SELECT (state) AS __s) __outer, LATERAL (SELECT (__s ->> 'score') AS \"score\") __fields)",
                "compiled_id_expression": "(SELECT (state->>'kind') FROM (SELECT (state) AS __s) __outer)"
            }]
        });

        assert_eq!(edge_digest(&edge), "3803f00c11d5c613d2abb4f289a8a668e5885d2f36681134e509ed98408d520c");
    }

    #[test]
    fn edge_digest_ignores_the_compiled_sql_fields() {
        let edge = serde_json::json!({
            "domain": "D", "from": "aaa", "to": "bbb", "retired": [],
            "aggregates": [{
                "name": "Widget", "was": null, "renames": {"cost": "amount"},
                "moves": [], "converts": [], "drops": [], "retypes": [], "computes": [], "rekeys": [], "backfills": [],
                "compiled_state_expression": "hecks_tr_rename(state, 'cost', 'amount')",
                "compiled_id_expression": null
            }]
        });
        let mut without_compiled = edge.clone();
        without_compiled["aggregates"][0].as_object_mut().unwrap().remove("compiled_state_expression");
        without_compiled["aggregates"][0].as_object_mut().unwrap().remove("compiled_id_expression");

        assert_eq!(edge_digest(&edge), edge_digest(&without_compiled));
    }

    #[test]
    fn edge_digest_is_sensitive_to_a_rekey_s_own_sql() {
        let base = serde_json::json!({
            "domain": "D", "from": "aaa", "to": "bbb", "retired": [],
            "aggregates": [{
                "name": "Widget", "was": null, "renames": {}, "moves": [], "converts": [], "drops": [], "retypes": [], "computes": [],
                "rekeys": [{"sql": "state->>'a'"}], "backfills": []
            }]
        });
        let mut different_rekey = base.clone();
        different_rekey["aggregates"][0]["rekeys"][0]["sql"] = serde_json::json!("state->>'b'");

        assert_ne!(edge_digest(&base), edge_digest(&different_rekey), "the fix this file exists for: a rekey's own SQL must be load-bearing in the digest");
    }

    #[test]
    fn edge_digest_respects_renames_declaration_order_not_alphabetical() {
        let ordered = serde_json::json!({
            "domain": "D", "from": "aaa", "to": "bbb", "retired": [],
            "aggregates": [{"name": "W", "was": null, "renames": {"zeta": "1", "alpha": "2"}, "moves": [], "converts": [], "drops": [], "retypes": [], "computes": [], "rekeys": [], "backfills": []}]
        });
        // A hand-swapped copy with the SAME pairs, declared in the
        // OPPOSITE order -- if preserve_order weren't wired correctly,
        // both would parse into the same (alphabetized) map and this
        // assertion would pass for the wrong reason (order not actually
        // load-bearing). Constructing via serde_json::from_str (not
        // json!{}, whose own macro-expansion order this test wants to
        // stay independent of) proves the ACTUAL parse path preserves it.
        let reordered_text = r#"{"domain":"D","from":"aaa","to":"bbb","retired":[],"aggregates":[{"name":"W","was":null,"renames":{"alpha":"2","zeta":"1"},"moves":[],"converts":[],"drops":[],"retypes":[],"computes":[],"rekeys":[],"backfills":[]}]}"#;
        let reordered: Value = serde_json::from_str(reordered_text).unwrap();

        assert_ne!(edge_digest(&ordered), edge_digest(&reordered), "declaration order is meaningful data, not a cosmetic detail a digest may ignore");
    }

    // THE GATE ITSELF, against real Postgres, real hecks_approvals rows
    // — no approval refuses; a matching one at the CURRENT journal tip
    // succeeds; a journal write AFTER the approval was reviewed makes
    // it stale again, refusing exactly as minter.rb's own second
    // check does.
    #[tokio::test]
    async fn check_refuses_without_approval_succeeds_with_one_and_refuses_again_once_stale() {
        use tokio_postgres::NoTls;

        let db = "rust_host_approval_gate_test";
        let owner = "rust_host_approval_gate_owner";

        let admin = tokio_postgres::connect("host=localhost dbname=postgres", NoTls).await.expect("connect to postgres as admin");
        tokio::spawn(async move {
            let _ = admin.1.await;
        });
        let _ = admin.0.batch_execute(&format!("DROP DATABASE IF EXISTS {db} WITH (FORCE)")).await;
        admin.0.batch_execute(&format!("CREATE DATABASE {db}")).await.expect("create scratch db");
        let _ = admin.0.batch_execute(&format!("DROP ROLE IF EXISTS {owner}")).await;
        admin.0.batch_execute(&format!("CREATE ROLE {owner} LOGIN")).await.expect("create owner role");
        admin.0.batch_execute(&format!("GRANT CONNECT ON DATABASE {db} TO {owner}")).await.expect("grant connect");

        let grant = tokio_postgres::connect(&format!("host=localhost dbname={db}"), NoTls).await.expect("connect to scratch db as superuser");
        tokio::spawn(async move {
            let _ = grant.1.await;
        });
        grant.0.batch_execute(&format!("ALTER DATABASE {db} OWNER TO {owner}")).await.expect("make owner the db owner");
        grant.0.batch_execute(&format!("GRANT USAGE, CREATE ON SCHEMA public TO {owner}")).await.expect("grant schema rights");

        let (client, connection) = tokio_postgres::connect(&format!("host=localhost dbname={db} user={owner}"), NoTls).await.expect("connect as owner");
        tokio::spawn(async move {
            let _ = connection.await;
        });

        let domain = "ApprovalGateTest";
        crate::mint::ensure_base(&client, domain).await.expect("ensure_base");
        // ensure_base enables FORCE ROW LEVEL SECURITY but creates no
        // permitting policy at all (that's advance_era's own job,
        // normally called from hold_first/mint_era) -- with RLS forced
        // and zero policies, Postgres denies every insert outright,
        // even the table owner's. This test writes directly to the
        // journal (not through a real mint) purely to advance last_
        // ordinal, so it needs the SAME policy a real era-1 hold would
        // already have created.
        crate::mint::advance_era(&client, domain, 1).await.expect("advance_era");

        let edge = serde_json::json!({
            "domain": domain, "from": "aaaaaa", "to": "bbbbbb", "retired": [],
            "aggregates": [{
                "name": "Widget", "was": null, "renames": {}, "moves": [], "converts": [], "drops": [], "retypes": [], "computes": [],
                "rekeys": [{"sql": "state->>'kind'"}], "backfills": []
            }]
        });

        // ── no approval at all: refused ──
        let refused = check(&client, domain, &edge, 2).await;
        assert!(refused.is_err(), "an unapproved compute/rekey edge must refuse to mint");
        assert!(format!("{:#}", refused.unwrap_err()).contains("bin/translation_audit"), "the refusal should name the tool that fixes it");

        // ── record a real, matching approval at the current tip (0, an
        // empty journal) ──
        let digest = edge_digest(&edge);
        client
            .execute(
                "INSERT INTO hecks_approvals (domain, from_label, to_label, edge_digest, reviewed_ordinal) VALUES ($1, $2, $3, $4, $5)",
                &[&domain, &"aaaaaa", &"bbbbbb", &digest, &0i64],
            )
            .await
            .expect("record approval");

        let allowed = check(&client, domain, &edge, 2).await;
        assert!(allowed.is_ok(), "a real, matching, unstale approval must let the mint proceed: {allowed:?}");

        // ── the journal advances past the reviewed ordinal: stale again ──
        client
            .execute(
                "INSERT INTO hecks_journal_approval_gate_test (era, aggregate, aggregate_id, operation, state) VALUES (1, 'widget', 'w1', 'save', '{}'::jsonb)",
                &[],
            )
            .await
            .expect("write a journal row, advancing last_ordinal past the approval's own reviewed_ordinal");

        let stale = check(&client, domain, &edge, 2).await;
        assert!(stale.is_err(), "an approval reviewed against an EARLIER journal position must refuse once the journal has moved on");
        assert!(format!("{:#}", stale.unwrap_err()).contains("advanced past"), "the refusal should name staleness specifically, not \"no approval\"");
    }
}
