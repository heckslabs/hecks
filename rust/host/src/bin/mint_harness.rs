//! Rust-mints-it-too side of the differential-parity harness: one boot decision per invocation.
//! Lets the spec mint an edge with no Ruby process so the two `_head` views can be diffed.

// Modules are shared with `bootstrap` by path, not a lib split, so `crate::` in mint.rs resolves
// here.
#[allow(dead_code)]
#[path = "../log.rs"]
mod log;
#[allow(dead_code)]
#[path = "../journal.rs"]
mod journal;
#[allow(dead_code)]
#[path = "../storage_shape.rs"]
mod storage_shape;
#[allow(dead_code)]
#[path = "../reference_transform.rs"]
mod reference_transform;
#[allow(dead_code)]
#[path = "../expr_json.rs"]
mod expr_json;
#[allow(dead_code)]
#[path = "../reference_validate.rs"]
mod reference_validate;
#[allow(dead_code)]
#[path = "../approval.rs"]
mod approval;
#[allow(dead_code)]
#[path = "../mint.rs"]
mod mint;

use serde_json::{json, Value};
use std::collections::HashMap;
use tokio_postgres::NoTls;

// Usage: `mint_harness <db_name> <owner_role> <domain> <ir_json_path>`, as the schema owner.
// `ir_json_path` is read like `ir::ir()` reads `HECKS_IR_PATH`, so two runs can boot two shapes.
// Prints `{"era": <ordinal>, "label": <label>}`; a refusal exits nonzero with the error on stderr.
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let [_, db_name, owner_role, domain, ir_path] = args.as_slice() else {
        anyhow::bail!("usage: mint_harness <db_name> <owner_role> <domain> <ir_json_path>");
    };

    let ir_text = std::fs::read_to_string(ir_path).map_err(|e| anyhow::anyhow!("reading {ir_path}: {e}"))?;
    let ir: Value = serde_json::from_str(&ir_text).map_err(|e| anyhow::anyhow!("parsing {ir_path}: {e}"))?;

    // A server that wants a password over TCP gets it from PGPASSWORD, as libpq would read it.
    // Built field by field, not spliced into a connection string, so a password with a space,
    // quote or backslash reaches the server as typed.
    let mut config = tokio_postgres::Config::new();
    config.host("localhost").dbname(db_name).user(owner_role);
    if let Ok(password) = std::env::var("PGPASSWORD") {
        config.password(password);
    }
    let (client, connection) = config.connect(NoTls).await?;
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("postgres connection error: {err:#}");
        }
    });

    journal::ensure_schema(&client).await?;
    mint::ensure_base(&client, domain).await?;

    let my_hash = storage_shape::mint_hash(&ir);
    let my_label = storage_shape::mint_label(&ir);

    // Every fixture is fully lineage-capable, so the `lineage_capable_aggregates` filter is
    // skipped.
    let aggregates: Vec<mint::Aggregate> = ir
        .get("aggregates")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default()
        .iter()
        .map(|agg| {
            let name = agg.get("name").and_then(Value::as_str).unwrap_or("").to_string();
            let storage_name = journal::snake(&name);
            mint::Aggregate { name, storage_name }
        })
        .collect();

    let held = journal::held_eras(&client, domain).await?;

    let era = match mint::decide_boot_action(&held, &my_label) {
        mint::BootDecision::UseExisting { ordinal } => ordinal,
        mint::BootDecision::HoldFirst => {
            let source_text = ir.get("source_text").and_then(Value::as_str).unwrap_or("mint_harness fixture source");
            mint::hold_first(&client, domain, source_text, &ir, &aggregates, None).await?;
            1
        }
        mint::BootDecision::LatestUnnamed { ordinal } => {
            anyhow::bail!("latest held era {ordinal} has no label -- mint_harness has no bluebook parser to name it with");
        }
        mint::BootDecision::Mint { ordinal, from_ordinal, from_label } => {
            let mut labels: Vec<String> = held.iter().map(|h| h.label.clone().unwrap_or_default()).collect();
            labels.push(my_label.clone());
            let edges = mint::parse_edges(&ir, domain);
            let chain = mint::edge_chain(&edges, &labels)
                .map_err(|e| anyhow::anyhow!("drifted from era {from_ordinal} ({from_label}) to {my_label} with no covering edge -- {e}"))?;

            // The same gate the host runs: a compute/rekey edge mints only on an approval, from the
            // journal or committed in ir.json's `approvals`.
            let raw_edges = ir.get("translations").and_then(Value::as_array).cloned().unwrap_or_default();
            let committed_approvals = approval::committed(&ir);
            for edge in &chain {
                // An edge with no raw entry fails closed, as the host does, and never skips the gate.
                let Some(raw_edge) = raw_edges.iter().find(|candidate| {
                    candidate.get("domain").and_then(Value::as_str) == Some(domain.as_str())
                        && candidate.get("from").and_then(Value::as_str) == Some(edge.from.as_str())
                        && candidate.get("to").and_then(Value::as_str) == Some(edge.to.as_str())
                }) else {
                    anyhow::bail!("cannot boot: {domain}'s edge {} -> {} vanished between parsing and approval-checking it", edge.from, edge.to);
                };
                approval::check(&client, domain, raw_edge, ordinal, &committed_approvals).await?;
            }
            let watermarks: HashMap<i32, Option<i64>> = held.iter().map(|h| (h.ordinal, h.watermark)).collect();
            mint::audit_before_mint(&client, domain, &ir, &aggregates, ordinal, &chain, &raw_edges, &watermarks).await?;

            let held_text = ir.get("source_text").and_then(Value::as_str).unwrap_or("mint_harness fixture source");
            mint::mint_era(&client, domain, ordinal, &my_hash, &my_label, held_text, &aggregates, &chain, None, &mint::lifecycle_defaults(&ir)).await?;
            ordinal
        }
    };

    println!("{}", json!({ "era": era, "label": my_label }));
    Ok(())
}
