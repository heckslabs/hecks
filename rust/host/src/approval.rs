//! Approval gate for migration edges with compute or rekey rules; ports `minter.rb`'s check.
//! `edge_digest` must match Ruby's `ApprovalDigest.edge_digest` byte for byte.
//!
//! Two approvals satisfy the gate. One is recorded in the journal and matches the edge's digest and
//! the journal's current tip. The other is committed beside the edge as
//! `translations/<edge>.approval`: it binds to the edge's digest alone, since a production journal
//! keeps writing between the commit and the deploy, and it must record a rehearsal that passed on a host of this release's `major.minor`.
//! A committed approval that applies is written into the journal, which stays the single history.

use crate::journal;
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio_postgres::GenericClient;

/// SHA256 of an edge's declared rules, identical to Ruby's `ApprovalDigest.edge_digest`.
/// The compiled-SQL fields of `ir.json` are ignored so a compiler change cannot void an approval.
pub fn edge_digest(edge: &Value) -> String {
    let digest = Sha256::digest(canonical_edge(edge).as_bytes());
    format!("{digest:x}")
}

/// Whether any aggregate on `edge` declares a compute or rekey rule.
pub fn requires_approval(edge: &Value) -> bool {
    edge.get("aggregates").and_then(Value::as_array).into_iter().flatten().any(|aggregate| {
        let non_empty = |key: &str| aggregate.get(key).and_then(Value::as_array).map(|list| !list.is_empty()).unwrap_or(false);
        non_empty("computes") || non_empty("rekeys")
    })
}

/// The Hecks release this host was built for, from `rust/host/HECKS_RELEASE`. The release step
/// keeps that file equal to `Hecks::VERSION`, and Ruby's `ApprovalFile::HOST_RELEASE` is that
/// constant, so both sides compare against one identity (the crate's own `0.1.0` is not it).
pub const HOST_RELEASE: &str = include_str!("../HECKS_RELEASE");

/// The `(major, minor)` a version names: `major.minor`, an optional patch, an optional
/// pre-release or build suffix, as Ruby's `ApprovalFile::HOST_LINE` reads it.
fn release_line(version: &str) -> Option<(u64, u64)> {
    static SHAPE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let shape = SHAPE.get_or_init(|| regex::Regex::new(r"^(\d+)\.(\d+)(?:\.\d+)?(?:[-+][0-9A-Za-z.+-]+)?$").expect("version pattern"));
    let parts = shape.captures(version)?;
    Some((parts[1].parse().ok()?, parts[2].parse().ok()?))
}

/// The refusal for a rehearsal that ran on another host line; Ruby's `ApprovalFile.host_refusal`
/// words it the same.
pub fn host_refusal(rehearsed_on: &str, host: &str) -> String {
    let line = release_line(host).map(|(major, minor)| format!("{major}.{minor}")).unwrap_or_default();
    format!(
        "the rehearsal ran on Hecks {rehearsed_on}, but this host is Hecks {host}; a rehearsal counts only on a host of the same \
         major.minor ({line}.x) — re-run the rehearsal on this host and approve again"
    )
}

/// The rehearsal a committed approval records: the run a person made against real data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rehearsal {
    pub snapshot: String,
    pub host_version: String,
    pub result: String,
    pub at: String,
}

/// An approval committed as `translations/<edge>.approval`, as `ir.json`'s `approvals` carries it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Committed {
    pub edge: String,
    pub edge_digest: String,
    pub approved_by: String,
    pub approved_at: String,
    pub rehearsal: Option<Rehearsal>,
}

/// Whether `value` is an RFC 3339 time that exists on the calendar, the shape Ruby's
/// `ApprovalFile::TIMESTAMP` accepts: `2026-09-28T12:30:00Z`, with optional fraction and `+HH:MM`.
fn is_timestamp(value: &str) -> bool {
    static SHAPE: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let shape = SHAPE.get_or_init(|| {
        regex::Regex::new(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$").expect("timestamp pattern")
    });
    let Some(parts) = shape.captures(value) else { return false };
    let part = |index: usize| parts[index].parse::<u32>().unwrap_or(u32::MAX);
    let (year, month, day, hour, minute, second) = (part(1), part(2), part(3), part(4), part(5), part(6));
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return false,
    };
    (1..=days).contains(&day) && hour < 24 && minute < 60 && second < 60
}

impl Committed {
    /// Whether the approval names who approved it and when, the two things a reviewer signs.
    pub fn attributed(&self) -> bool {
        !self.approved_by.trim().is_empty() && is_timestamp(&self.approved_at)
    }

    /// Whether the rehearsal ran on a host compatible with `host`: equal `major.minor`. A patch
    /// release does not change what a mint does, so a rehearsal survives it; a minor or major one
    /// may, and a newer host's rehearsal proves nothing about an older one.
    pub fn host_compatible(&self, host: &str) -> bool {
        self.rehearsal.as_ref().is_some_and(|r| release_line(&r.host_version).is_some_and(|line| Some(line) == release_line(host)))
    }

    /// Whether the approval records a rehearsal that passed, every field named. Whether it ran on
    /// a compatible host is `host_compatible`'s question.
    pub fn rehearsed(&self) -> bool {
        self.rehearsal.as_ref().is_some_and(|r| {
            [&r.snapshot, &r.host_version, &r.result, &r.at].iter().all(|field| !field.trim().is_empty()) && r.result == "pass"
        })
    }
}

/// Reads the committed approvals out of `ir.json`; an entry with no digest approves nothing and is
/// left out.
pub fn committed(ir: &Value) -> Vec<Committed> {
    let text = |value: &Value, key: &str| value.get(key).and_then(Value::as_str).unwrap_or("").to_string();
    ir.get("approvals")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|approval| approval.get("edge_digest").and_then(Value::as_str).is_some_and(|digest| !digest.is_empty()))
        .map(|approval| Committed {
            edge: text(approval, "edge"),
            edge_digest: text(approval, "edge_digest"),
            approved_by: text(approval, "approved_by"),
            approved_at: text(approval, "approved_at"),
            rehearsal: approval.get("rehearsal").filter(|r| r.is_object()).map(|r| Rehearsal {
                snapshot: text(r, "snapshot"),
                host_version: text(r, "host_version"),
                result: text(r, "result"),
                at: text(r, "at"),
            }),
        })
        .collect()
}

/// The committed approval that lets `edge` mint: its digest is the edge's, it names who approved it
/// and when, and a rehearsal that passed is recorded, since a compute or rekey is verified by
/// nothing else.
pub fn applicable<'a>(committed: &'a [Committed], edge: &Value) -> Option<&'a Committed> {
    applicable_on(committed, edge, HOST_RELEASE.trim())
}

/// `applicable` for a host that reports `host` as its release.
pub fn applicable_on<'a>(committed: &'a [Committed], edge: &Value, host: &str) -> Option<&'a Committed> {
    let digest = edge_digest(edge);
    committed.iter().find(|approval| approval.edge_digest == digest && approval.attributed() && approval.rehearsed() && approval.host_compatible(host))
}

/// Why a committed approval that covers `edge` was still not applied, when the only thing wrong is
/// the host it was rehearsed on.
fn host_mismatch(committed: &[Committed], edge: &Value, host: &str) -> Option<String> {
    let digest = edge_digest(edge);
    committed
        .iter()
        .find(|approval| approval.edge_digest == digest && approval.attributed() && approval.rehearsed() && !approval.host_compatible(host))
        .and_then(|approval| approval.rehearsal.as_ref())
        .map(|rehearsal| host_refusal(&rehearsal.host_version, host))
}

/// Refuses to mint unless a compute/rekey edge has an approval: one from the journal whose digest
/// matches and whose reviewed ordinal is the current journal tip, or a committed one that applies
/// (which is then written into the journal). A no-op for edges with neither rule.
///
/// # Errors
/// Fails when no approval applies: none is recorded, its digest differs, or the journal has moved
/// past a journal approval and no committed one covers the edge.
pub async fn check<C: GenericClient>(client: &C, domain: &str, edge: &Value, ordinal: i32, committed: &[Committed]) -> anyhow::Result<()> {
    if !requires_approval(edge) {
        return Ok(());
    }

    let from = edge.get("from").and_then(Value::as_str).unwrap_or("");
    let to = edge.get("to").and_then(Value::as_str).unwrap_or("");
    let digest = edge_digest(edge);

    let approval = journal::approval_for(client, domain, from, to).await?;
    let tip = journal::last_ordinal(client, domain).await?;
    if let Some(approval) = approval.as_ref().filter(|approval| approval.edge_digest == digest) {
        if approval.reviewed_ordinal == tip {
            return Ok(());
        }
    }

    if applicable(committed, edge).is_some() {
        journal::record_approval(client, domain, from, to, &digest).await?;
        return Ok(());
    }

    let approval = match approval {
        Some(approval) if approval.edge_digest == digest => approval,
        _ if host_mismatch(committed, edge, HOST_RELEASE.trim()).is_some() => anyhow::bail!(
            "cannot mint era {ordinal} of {domain}: the committed approval does not apply — {}",
            host_mismatch(committed, edge, HOST_RELEASE.trim()).unwrap_or_default()
        ),
        _ => anyhow::bail!(
            "cannot mint era {ordinal} of {domain}: this edge carries a compute or rekey rule, and the audit's \
             human-approved sample is its only verification — run bin/translation_audit with --approve, then boot again"
        ),
    };

    anyhow::bail!(
        "cannot mint era {ordinal} of {domain}: the journal advanced past the approved review (ordinal {} \
         reviewed, {tip} now) — the samples a human approved no longer cover the data; re-run bin/translation_audit with --approve",
        approval.reviewed_ordinal
    )
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

    // `renames` key order is declaration order and part of the digest (needs `preserve_order`).
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

// A backfill `default` is untyped JSON; serde_json's compact form of a `Value` is safe here.
fn raw_json(value: &Value) -> String {
    serde_json::to_string(value).expect("a parsed Value always re-serializes")
}

#[cfg(test)]
mod tests {
    use super::*;

    // Pins Ruby's literal output for a real compute+rekey edge; the tests below only prove Rust
    // agrees with itself.
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

    // A backfill default or convert value is untyped JSON, and Ruby digests the text `JSON.generate`
    // wrote for it: `1.0e+20`, `1.0e-05`, `1.0`, and integers past u64. The literals below are
    // Ruby's own ir.json output for that edge and 0afbe95b... is Ruby's `edge_digest` of it.
    #[test]
    fn edge_digest_matches_ruby_for_floats_and_integers_beyond_u64_in_untyped_json() {
        let ir: Value = serde_json::from_str(
            r#"{"translations":[{"domain":"F","from":"aaaaaa","to":"bbbbbb","retired":[],"aggregates":[{"name":"Account","was":null,"renames":{},"moves":[],"converts":[{"from":"k","to":"k2","values":[[1.0e+20,12345678901234567890]]}],"drops":[],"retypes":[],"computes":[],"rekeys":[],"backfills":[{"name":"a","default":1.0e+20},{"name":"b","default":100000000000000000000},{"name":"c","default":1.0e-05},{"name":"d","default":1.0}]}]}]}"#,
        )
        .expect("Ruby's export is JSON");

        assert_eq!(edge_digest(&ir["translations"][0]), "0afbe95b13fc8dbdab470acda48184eca6f898c4b736dd72b77a41977d7c0077");
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
        // Parsed from text, not json!{}, so a map that alphabetizes keys fails here instead of
        // passing vacuously.
        let reordered_text = r#"{"domain":"D","from":"aaa","to":"bbb","retired":[],"aggregates":[{"name":"W","was":null,"renames":{"alpha":"2","zeta":"1"},"moves":[],"converts":[],"drops":[],"retypes":[],"computes":[],"rekeys":[],"backfills":[]}]}"#;
        let reordered: Value = serde_json::from_str(reordered_text).unwrap();

        assert_ne!(edge_digest(&ordered), edge_digest(&reordered), "declaration order is meaningful data, not a cosmetic detail a digest may ignore");
    }

    // Against real Postgres: no approval refuses, a matching one at the tip passes, and a later
    // journal write makes it stale again.
    #[tokio::test]
    async fn check_refuses_without_approval_succeeds_with_one_and_refuses_again_once_stale() {
        let client = scratch_client("rust_host_approval_gate_test", "rust_host_approval_gate_owner").await;

        let domain = "ApprovalGateTest";
        crate::mint::ensure_base(&client, domain).await.expect("ensure_base");
        // ensure_base forces RLS without a policy; advance_era adds the one the direct journal
        // write below needs.
        crate::mint::advance_era(&client, domain, 1).await.expect("advance_era");

        let edge = serde_json::json!({
            "domain": domain, "from": "aaaaaa", "to": "bbbbbb", "retired": [],
            "aggregates": [{
                "name": "Widget", "was": null, "renames": {}, "moves": [], "converts": [], "drops": [], "retypes": [], "computes": [],
                "rekeys": [{"sql": "state->>'kind'"}], "backfills": []
            }]
        });

        let refused = check(&client, domain, &edge, 2, &[]).await;
        assert!(refused.is_err(), "an unapproved compute/rekey edge must refuse to mint");
        assert!(format!("{:#}", refused.unwrap_err()).contains("bin/translation_audit"), "the refusal should name the tool that fixes it");

        let digest = edge_digest(&edge);
        client
            .execute(
                "INSERT INTO hecks_approvals (domain, from_label, to_label, edge_digest, reviewed_ordinal) VALUES ($1, $2, $3, $4, $5)",
                &[&domain, &"aaaaaa", &"bbbbbb", &digest, &0i64],
            )
            .await
            .expect("record approval");

        let allowed = check(&client, domain, &edge, 2, &[]).await;
        assert!(allowed.is_ok(), "a real, matching, unstale approval must let the mint proceed: {allowed:?}");

        client
            .execute(
                "INSERT INTO hecks_journal_approval_gate_test (era, aggregate, aggregate_id, operation, state) VALUES (1, 'widget', 'w1', 'save', '{}'::jsonb)",
                &[],
            )
            .await
            .expect("write a journal row, advancing last_ordinal past the approval's own reviewed_ordinal");

        let stale = check(&client, domain, &edge, 2, &[]).await;
        assert!(stale.is_err(), "an approval reviewed against an EARLIER journal position must refuse once the journal has moved on");
        assert!(format!("{:#}", stale.unwrap_err()).contains("advanced past"), "the refusal should name staleness specifically, not \"no approval\"");
    }

    // A scratch database owned by an ordinary role, as the host boots against a real one.
    async fn scratch_client(db: &str, owner: &str) -> tokio_postgres::Client {
        use tokio_postgres::NoTls;

        let admin = tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), NoTls).await.expect("connect to postgres as admin");
        tokio::spawn(async move {
            let _ = admin.1.await;
        });
        let _ = admin.0.batch_execute(&format!("DROP DATABASE IF EXISTS {db} WITH (FORCE)")).await;
        admin.0.batch_execute(&format!("CREATE DATABASE {db}")).await.expect("create scratch db");
        let _ = admin.0.batch_execute(&format!("DROP ROLE IF EXISTS {owner}")).await;
        admin.0.batch_execute(&format!("CREATE ROLE {owner} {}", crate::test_pg::login_clause())).await.expect("create owner role");
        admin.0.batch_execute(&format!("GRANT CONNECT ON DATABASE {db} TO {owner}")).await.expect("grant connect");

        let grant = tokio_postgres::connect(&crate::test_pg::conninfo(&db), NoTls).await.expect("connect to scratch db as superuser");
        tokio::spawn(async move {
            let _ = grant.1.await;
        });
        grant.0.batch_execute(&format!("ALTER DATABASE {db} OWNER TO {owner}")).await.expect("make owner the db owner");
        grant.0.batch_execute(&format!("GRANT USAGE, CREATE ON SCHEMA public TO {owner}")).await.expect("grant schema rights");

        let (client, connection) = tokio_postgres::connect(&crate::test_pg::conninfo_as(&db, &owner), NoTls).await.expect("connect as owner");
        tokio::spawn(async move {
            let _ = connection.await;
        });
        client
    }

    fn compute_rekey_edge(domain: &str) -> Value {
        serde_json::json!({
            "domain": domain, "from": "aaaaaa", "to": "bbbbbb", "retired": [],
            "aggregates": [{
                "name": "Widget", "was": null, "renames": {}, "moves": [], "converts": [], "drops": [], "retypes": [], "computes": [],
                "rekeys": [{"sql": "state->>'kind'"}], "backfills": []
            }]
        })
    }

    fn committed_for(edge: &Value, rehearsal: Value) -> Committed {
        let ir = serde_json::json!({ "approvals": [{
            "edge": "aaaaaa-bbbbbb", "edge_digest": edge_digest(edge), "approved_by": "Ada <ada@example.com>",
            "approved_at": "2026-09-28T12:30:00Z", "rehearsal": rehearsal
        }]});
        committed(&ir).remove(0)
    }

    fn passed() -> Value {
        serde_json::json!({ "snapshot": "rds:ledger", "host_version": "3.0.0", "result": "pass", "at": "2026-09-28T12:00:00Z" })
    }

    // A rehearsal that passed on this very host.
    fn passed_here() -> Value {
        serde_json::json!({ "snapshot": "rds:ledger", "host_version": HOST_RELEASE.trim(), "result": "pass", "at": "2026-09-28T12:00:00Z" })
    }

    #[test]
    fn the_host_release_is_a_version_and_not_the_crates_own() {
        assert!(release_line(HOST_RELEASE.trim()).is_some(), "HECKS_RELEASE must hold a version: {HOST_RELEASE:?}");
        assert_ne!(HOST_RELEASE.trim(), env!("CARGO_PKG_VERSION"));
    }

    // Ruby's `ApprovalFile.host_compatible?` is equal `major.minor`: a patch differs freely, an
    // older or newer minor or major does not, and a name that is not a version is refused.
    #[test]
    fn a_rehearsal_counts_only_on_the_same_major_minor() {
        let edge = compute_rekey_edge("D");
        let on = |version: &str| {
            let rehearsal = serde_json::json!({ "snapshot": "s", "host_version": version, "result": "pass", "at": "2026-09-28T12:00:00Z" });
            applicable_on(&[committed_for(&edge, rehearsal)], &edge, "3.0.4").is_some()
        };
        assert!(on("3.0.0") && on("3.0.4") && on("3.0.9") && on("3.0.1-rc.1") && on("3.0"));
        assert!(!on("2.9.0") && !on("3.1.0") && !on("4.0.0") && !on("3.10.0") && !on("") && !on("three") && !on("3"));
    }

    #[test]
    fn the_refusal_names_both_versions() {
        assert_eq!(
            host_refusal("2.9.0", "3.0.4"),
            "the rehearsal ran on Hecks 2.9.0, but this host is Hecks 3.0.4; a rehearsal counts only on a host of the same \
             major.minor (3.0.x) — re-run the rehearsal on this host and approve again"
        );
    }

    async fn journal_approvals(client: &tokio_postgres::Client, domain: &str) -> i64 {
        client.query_one("SELECT count(*) AS n FROM hecks_approvals WHERE domain = $1", &[&domain]).await.expect("count approvals").get("n")
    }

    // Reads the parity fixture the Ruby spec writes from Ruby's own export of a compute+rekey edge and
    // the approval Ruby writes for it: Rust must reach the digest Ruby recorded, from the same JSON.
    #[test]
    fn a_committed_approval_ruby_wrote_applies_to_the_edge_ruby_exported() {
        let ir: Value = serde_json::from_str(include_str!("../../../spec/fixtures/approval_parity/ir.json")).expect("parity fixture is JSON");
        let edge = &ir["translations"][0];
        let approvals = committed(&ir);

        assert_eq!(approvals.len(), 1);
        assert_eq!(approvals[0].edge_digest, edge_digest(edge), "Ruby's approval digest and Rust's digest of Ruby's export must agree");
        assert_eq!(approvals[0].edge, "aaaaaa-bbbbbb");
        assert_eq!(approvals[0].approved_by, "Ada <ada@example.com>");
        assert!(approvals[0].rehearsed());
        assert_eq!(applicable_on(&approvals, edge, "3.0.7"), Some(&approvals[0]));
        assert!(applicable_on(&approvals, edge, "3.1.0").is_none());
    }

    #[test]
    fn a_committed_approval_applies_only_with_a_rehearsal_that_passed() {
        let edge = compute_rekey_edge("D");
        for rehearsal in [
            Value::Null,
            serde_json::json!({}),
            serde_json::json!({ "snapshot": "s", "host_version": "3.0.0", "result": "fail", "at": "2026-09-28T12:00:00Z" }),
            serde_json::json!({ "snapshot": " ", "host_version": "3.0.0", "result": "pass", "at": "2026-09-28T12:00:00Z" }),
        ] {
            let approval = committed_for(&edge, rehearsal);
            assert!(applicable_on(&[approval], &edge, "3.0.0").is_none());
        }
        assert!(applicable_on(&[committed_for(&edge, passed())], &edge, "3.0.0").is_some());
    }

    // Ruby's `ApprovalFile` refuses the same: a non-String rehearsal field, a blank approver, an
    // approved_at that is not a time on the calendar.
    #[test]
    fn a_committed_approval_needs_a_string_rehearsal_and_a_named_approver_and_time() {
        let edge = compute_rekey_edge("D");
        for rehearsal in [
            serde_json::json!({ "snapshot": 42, "host_version": "3.0.0", "result": "pass", "at": "2026-09-28T12:00:00Z" }),
            serde_json::json!({ "snapshot": "s", "host_version": 3.0, "result": "pass", "at": "2026-09-28T12:00:00Z" }),
            serde_json::json!({ "snapshot": "s", "host_version": "3.0.0", "result": "pass", "at": null }),
        ] {
            assert!(applicable_on(&[committed_for(&edge, rehearsal)], &edge, "3.0.0").is_none());
        }

        let mut approval = committed_for(&edge, passed());
        assert!(applicable_on(std::slice::from_ref(&approval), &edge, "3.0.0").is_some());
        for who in ["", "  "] {
            approval.approved_by = who.to_string();
            assert!(applicable_on(std::slice::from_ref(&approval), &edge, "3.0.0").is_none(), "blank approver {who:?}");
        }
        approval.approved_by = "Ada".to_string();
        for at in ["", "yesterday", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "2025-02-29T00:00:00Z", "2026-09-28T25:00:00Z", "2026-09-28"] {
            approval.approved_at = at.to_string();
            assert!(applicable_on(std::slice::from_ref(&approval), &edge, "3.0.0").is_none(), "approved_at {at:?}");
        }
        for at in ["2026-09-28T12:30:00.5+02:00", "2024-02-29T00:00:00Z"] {
            approval.approved_at = at.to_string();
            assert!(applicable_on(std::slice::from_ref(&approval), &edge, "3.0.0").is_some(), "approved_at {at:?}");
        }
    }

    #[test]
    fn a_committed_approval_binds_to_the_edge_digest_not_the_journal_tip() {
        let edge = compute_rekey_edge("D");
        let approval = committed_for(&edge, passed());
        let mut changed = edge.clone();
        changed["aggregates"][0]["rekeys"][0]["sql"] = serde_json::json!("state->>'other'");

        assert!(applicable_on(std::slice::from_ref(&approval), &edge, "3.0.0").is_some());
        assert!(applicable_on(&[approval], &changed, "3.0.0").is_none());
    }

    #[test]
    fn committed_reads_nothing_from_ir_without_approvals_and_skips_an_entry_with_no_digest() {
        assert!(committed(&serde_json::json!({})).is_empty());
        assert!(committed(&serde_json::json!({ "approvals": [{ "edge": "a-b" }] })).is_empty());
    }

    // Against real Postgres: a committed approval satisfies the gate with no journal approval, is
    // written into the journal when it applies, keeps applying after the journal moves on, and a
    // journal approval at the tip still works alone.
    #[tokio::test]
    async fn a_committed_approval_lets_the_mint_through_and_joins_the_journal() {
        let client = scratch_client("rust_host_committed_approval_test", "rust_host_committed_approval_owner").await;
        let domain = "CommittedApprovalTest";
        crate::mint::ensure_base(&client, domain).await.expect("ensure_base");
        crate::mint::advance_era(&client, domain, 1).await.expect("advance_era");
        let edge = compute_rekey_edge(domain);

        let refused = check(&client, domain, &edge, 2, &[]).await;
        assert!(refused.is_err(), "no approval at all still refuses");
        assert_eq!(journal_approvals(&client, domain).await, 0);

        let without_rehearsal = committed_for(&edge, Value::Null);
        assert!(check(&client, domain, &edge, 2, &[without_rehearsal]).await.is_err(), "a committed approval with no passed rehearsal is no approval");
        assert_eq!(journal_approvals(&client, domain).await, 0);

        let approval = committed_for(&edge, passed_here());
        check(&client, domain, &edge, 2, std::slice::from_ref(&approval)).await.expect("a committed approval applies");
        assert_eq!(journal_approvals(&client, domain).await, 1, "applying it writes it into the journal");
        assert_eq!(journal::approval_for(&client, domain, "aaaaaa", "bbbbbb").await.unwrap().unwrap().edge_digest, edge_digest(&edge));

        // The journal now holds the approval at the tip, so it satisfies the gate alone.
        check(&client, domain, &edge, 2, &[]).await.expect("the journal's own approval, at the tip, still works");

        client
            .execute(
                "INSERT INTO hecks_journal_committed_approval_test (era, aggregate, aggregate_id, operation, state) VALUES (1, 'widget', 'w1', 'save', '{}'::jsonb)",
                &[],
            )
            .await
            .expect("the journal moves on");
        assert!(check(&client, domain, &edge, 2, &[]).await.is_err(), "the journal's approval is stale now");
        check(&client, domain, &edge, 2, &[approval]).await.expect("the committed approval is not tied to the tip");
    }

    #[tokio::test]
    async fn a_committed_approval_rehearsed_on_another_release_refuses_naming_both_versions() {
        let client = scratch_client("rust_host_committed_approval_host_test", "rust_host_committed_approval_host_owner").await;
        let domain = "CommittedApprovalHostTest";
        crate::mint::ensure_base(&client, domain).await.expect("ensure_base");
        crate::mint::advance_era(&client, domain, 1).await.expect("advance_era");
        let edge = compute_rekey_edge(domain);
        let stale = committed_for(
            &edge,
            serde_json::json!({ "snapshot": "s", "host_version": "1.0.0", "result": "pass", "at": "2026-09-28T12:00:00Z" }),
        );

        let message = format!("{:#}", check(&client, domain, &edge, 2, &[stale]).await.unwrap_err());
        assert!(message.contains("Hecks 1.0.0") && message.contains(HOST_RELEASE.trim()), "{message}");
        assert_eq!(journal_approvals(&client, domain).await, 0);
    }
}
