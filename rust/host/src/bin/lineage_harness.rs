// THE DIFFERENTIAL-PARITY HARNESS'S RUST SIDE (ADR 0029 step 4) — a
// small, dedicated binary, deliberately separate from `bootstrap`
// (src/main.rs), that exercises ONLY the generic lineage read/write
// path (`journal.rs`'s `read_lineage_head_all`/`_by_id`/
// `append_lineage_mutation`) against real Postgres, with no WASM
// kernel, no Lambda runtime, no RDS/TLS ceremony — none of which the
// lineage path depends on (domain_generator.rb's own manifest comment:
// "dispatched OUTSIDE the WASM kernel/InMemoryRepository path
// entirely"). Reusing `bootstrap`'s `main.rs` for this would mean
// standing up a `.wasm` module and Lambda-shaped scaffolding to test
// something that structurally touches neither.
//
// `journal.rs` is pulled in via `#[path]` rather than promoting this
// crate to a lib+bin split — it has zero `crate::` references of its
// own (confirmed: it only imports `tokio_postgres`), so this is a
// faithful reuse of the exact same source `bootstrap` compiles, not a
// fork of it.
//
// CLI: `lineage_harness <db_name> <app_role> <domain> <era>` — same
// positional-arg convention as `tests/fixtures/mint_stale_era.rb`
// (connection identity as plain args, not a URL — this only ever talks
// to local/CI Postgres over trust auth, matching journal.rs's own
// `a_stale_era_write_is_refused_by_postgres_rls_not_this_crate` test).
//
// STDIN: `{"operations": [...]}`, one of three shapes per entry:
//   {"op": "read_all",   "storage_name": "order"}
//   {"op": "read_by_id", "storage_name": "order", "id": "order-1"}
//   {"op": "write", "aggregate": "Pizzas::Order", "id": "order-9",
//    "state": {...}}                        (operation always "save")
//
// STDOUT: `{"results": [...]}`, one entry per operation, SAME ORDER,
// exit 0 unless the connection itself fails to establish — a
// per-operation Postgres error (e.g. an RLS refusal) is reported IN
// that operation's own entry, never a process crash, matching the
// kernel binary's own "clean JSON, exit 0, never a panic" discipline
// (`rust_conformance_spec.rb`'s own comments hold it to this).

// Reusing the whole file pulls in the flat-journal functions this
// binary has no use for (it only ever calls the generic lineage
// functions below) — allowed rather than split, the same call
// ir.rs:39-48 makes for its own unused-but-real seam.
#[allow(dead_code)]
#[path = "../journal.rs"]
mod journal;

use serde_json::{json, Value};
use std::io::Read;
use tokio_postgres::NoTls;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let [_, db_name, app_role, domain, era] = args.as_slice() else {
        anyhow::bail!("usage: lineage_harness <db_name> <app_role> <domain> <era>");
    };
    let era: i32 = era.parse().map_err(|_| anyhow::anyhow!("era must be an integer, got {era:?}"))?;

    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input)?;
    let request: Value = serde_json::from_str(&input)?;
    let operations = request
        .get("operations")
        .and_then(|v| v.as_array())
        .ok_or_else(|| anyhow::anyhow!("stdin JSON missing \"operations\" array"))?;

    let conn_string = format!("host=localhost dbname={db_name} user={app_role}");
    let (client, connection) = tokio_postgres::connect(&conn_string, NoTls).await?;
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("postgres connection error: {err:#}");
        }
    });

    let config = journal::LineageConfig { domain: domain.clone(), era };
    let mut results = Vec::with_capacity(operations.len());

    for operation in operations {
        results.push(run_one(&client, &config, operation).await);
    }

    println!("{}", json!({ "results": results }));
    Ok(())
}

async fn run_one(client: &tokio_postgres::Client, config: &journal::LineageConfig, operation: &Value) -> Value {
    let op = operation.get("op").and_then(|v| v.as_str()).unwrap_or("");

    let outcome = match op {
        "read_all" => read_all(client, operation).await,
        "read_by_id" => read_by_id(client, operation).await,
        "write" => write(client, config, operation).await,
        other => Err(anyhow::anyhow!("unknown op {other:?}")),
    };

    match outcome {
        Ok(mut value) => {
            value["op"] = json!(op);
            value["ok"] = json!(true);
            value
        }
        Err(err) => json!({ "op": op, "ok": false, "error": format!("{err:#}") }),
    }
}

async fn read_all(client: &tokio_postgres::Client, operation: &Value) -> anyhow::Result<Value> {
    let storage_name = require_str(operation, "storage_name")?;
    let rows = journal::read_lineage_head_all(client, storage_name).await?;
    Ok(json!({ "rows": rows.into_iter().map(|(id, state)| json!([id, state])).collect::<Vec<_>>() }))
}

async fn read_by_id(client: &tokio_postgres::Client, operation: &Value) -> anyhow::Result<Value> {
    let storage_name = require_str(operation, "storage_name")?;
    let id = require_str(operation, "id")?;
    let state = journal::read_lineage_head_by_id(client, storage_name, id).await?;
    Ok(json!({ "state": state }))
}

async fn write(client: &tokio_postgres::Client, config: &journal::LineageConfig, operation: &Value) -> anyhow::Result<Value> {
    let aggregate = require_str(operation, "aggregate")?;
    let id = require_str(operation, "id")?;
    let state = operation
        .get("state")
        .ok_or_else(|| anyhow::anyhow!("write operation missing \"state\": {operation}"))?;

    journal::append_lineage_mutation(
        client,
        config,
        &journal::Mutation { aggregate, id, operation: "save", state },
    )
    .await?;
    Ok(json!({}))
}

fn require_str<'a>(operation: &'a Value, field: &str) -> anyhow::Result<&'a str> {
    operation
        .get(field)
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("operation missing {field:?}: {operation}"))
}
