// THE DIFFERENTIAL-PARITY HARNESS'S RUST-MINTS-IT-TOO SIDE (ADR-0030-
// in-progress step 8) — a small, dedicated binary, the same shape
// `lineage_harness.rs` already established for the READ/WRITE half of
// this proof: no WASM kernel, no Lambda runtime, no RDS/TLS ceremony,
// just the ONE boot-time decision `main.rs`'s own boot gate makes
// (`mint::decide_boot_action`, then whichever of hold_first/mint_era it
// names), run ONCE per invocation — matching a real deployment's own
// "one boot decides, once" shape, not a loop over every possible era.
//
// This is the piece `rust_host_lineage_conformance_spec.rb`'s original
// fixtures never needed: those all mint via REAL RUBY
// (`LineageManager.check!`/`mint!`) and only ever prove Rust READS/
// WRITES an already-minted era correctly. This binary lets the spec
// mint the SAME edge a SECOND, independent way — Rust alone, zero Ruby
// process — against a separate scratch database, so the two `_head`
// views can be diffed byte-for-byte: the actual proof that Rust's own
// mint (schema DDL, translated data, everything) agrees with Ruby's,
// not just that Rust can read what Ruby already produced.
//
// Every module below is pulled in via `#[path]`, the exact same
// no-lib-split convention `lineage_harness.rs`'s own header already
// explains and justifies — `mint.rs`'s own `crate::` references
// resolve correctly once its sibling modules are declared here too,
// since `crate::` means "this binary crate," not "the `bootstrap` one."
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
#[path = "../mint.rs"]
mod mint;

use serde_json::{json, Value};
use std::collections::HashMap;
use tokio_postgres::NoTls;

// CLI: `mint_harness <db_name> <owner_role> <domain> <ir_json_path>` —
// connects as the SCHEMA OWNER (this binary's whole job is DDL/mint,
// never an RLS-fenced app read/write — that stays `lineage_harness`'s
// job), same positional-arg convention (no URL) `lineage_harness.rs`'s
// own header explains and justifies.
//
// `ir_json_path` points at a REAL `ir.json` (or a hand-built fixture
// shaped exactly like one) — this binary reads it exactly as
// `crate::ir::ir()` does inside `bootstrap`, just from a file path
// argument instead of `HECKS_IR_PATH`, so a spec can point two
// successive invocations at two different shapes of the SAME domain
// (v1's ir.json with no `translations`, then v2's with the edge added)
// to exercise era 1 and the drift-mint in two separate, ordinary boots.
//
// STDOUT on success: `{"era": <ordinal>, "label": <label>}`. Any
// refusal (no covering edge, an audit violation, an already-minted
// era) is a non-zero exit with the error on stderr — this binary never
// prints a fabricated "ok" for a boot that didn't actually happen,
// unlike `lineage_harness`'s own per-operation error reporting (there
// is only ONE operation here: boot).
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let [_, db_name, owner_role, domain, ir_path] = args.as_slice() else {
        anyhow::bail!("usage: mint_harness <db_name> <owner_role> <domain> <ir_json_path>");
    };

    let ir_text = std::fs::read_to_string(ir_path).map_err(|e| anyhow::anyhow!("reading {ir_path}: {e}"))?;
    let ir: Value = serde_json::from_str(&ir_text).map_err(|e| anyhow::anyhow!("parsing {ir_path}: {e}"))?;

    let conn_string = format!("host=localhost dbname={db_name} user={owner_role}");
    let (client, connection) = tokio_postgres::connect(&conn_string, NoTls).await?;
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("postgres connection error: {err:#}");
        }
    });

    journal::ensure_schema(&client).await?;
    mint::ensure_base(&client, domain).await?;

    let my_hash = storage_shape::mint_hash(&ir);
    let my_label = storage_shape::mint_label(&ir);

    // `ir.json`'s `aggregates` array, taken whole — a real deployment
    // filters this to lineage-CAPABLE aggregates only (`ir::
    // lineage_capable_aggregates`, `bootstrap`'s own job); this harness
    // is only ever pointed at fixtures built for it, every one of them
    // entirely lineage-capable, so that filter has nothing to do here.
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

            // Approval-gate checking (compute/rekey edges) is deliberately
            // NOT wired into this harness -- `approval.rs`'s own tests
            // already prove that gate in isolation, and no fixture this
            // binary is used with declares a compute/rekey rule. A real
            // one would fail loudly inside `audit_before_mint`/`mint_era`
            // regardless (both still run their own real checks), just
            // without the dedicated approval-gate error wording.
            let raw_edges = ir.get("translations").and_then(Value::as_array).cloned().unwrap_or_default();
            let watermarks: HashMap<i32, Option<i64>> = held.iter().map(|h| (h.ordinal, h.watermark)).collect();
            mint::audit_before_mint(&client, domain, &ir, &aggregates, ordinal, &chain, &raw_edges, &watermarks).await?;

            let held_text = ir.get("source_text").and_then(Value::as_str).unwrap_or("mint_harness fixture source");
            mint::mint_era(&client, domain, ordinal, &my_hash, &my_label, held_text, &aggregates, &chain, None).await?;
            ordinal
        }
    };

    println!("{}", json!({ "era": era, "label": my_label }));
    Ok(())
}
