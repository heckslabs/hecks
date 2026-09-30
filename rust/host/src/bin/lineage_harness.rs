//! Rust side of the differential-parity harness: generic lineage reads and writes on Postgres.
//! Usage: `lineage_harness <db_name> <app_role> <domain> <era>`, JSON on stdin and stdout.
//!
//! stdin is `{"operations": [...]}`, each one of:
//!   {"op": "read_all", "storage_name": "order"}
//!   {"op": "read_by_id", "storage_name": "order", "id": "order-1"}
//!   {"op": "write", "aggregate": "Pizzas::Order", "id": "order-9", "state": {...}}
//! stdout is `{"results": [...]}`, one entry per operation in order. A per-operation Postgres
//! error (such as an RLS refusal) lands in that entry; only a failed connection exits nonzero.

// journal.rs has no `crate::` references, so it is shared with `bootstrap` by path, not a lib
// split.
// The flat-journal functions it also carries are unused here.
#[allow(dead_code)]
#[path = "../journal.rs"]
mod journal;

// journal.rs's Postgres tests connect through `crate::test_pg`, so the harness's own test build
// carries the same connection-string helpers.
#[cfg(test)]
#[path = "../test_pg.rs"]
mod test_pg;

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

    // tokio_postgres ignores libpq's `PGPASSWORD`, so pass it through when the server asks for one.
    let password = std::env::var("PGPASSWORD").ok().filter(|p| !p.is_empty()).map(|p| format!(" password={p}")).unwrap_or_default();
    let conn_string = format!("host=localhost dbname={db_name} user={app_role}{password}");
    let (client, connection) = tokio_postgres::connect(&conn_string, NoTls).await?;
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("postgres connection error: {err:#}");
        }
    });

    let config = journal::LineageConfig { domain: domain.clone(), era: Some(era), mirrored: None };
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
        "read_all" => read_all(client, config, operation).await,
        "read_by_id" => read_by_id(client, config, operation).await,
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

async fn read_all(client: &tokio_postgres::Client, config: &journal::LineageConfig, operation: &Value) -> anyhow::Result<Value> {
    let storage_name = require_str(operation, "storage_name")?;
    let rows = journal::read_lineage_head_all(client, &config.domain, storage_name).await?;
    Ok(json!({ "rows": rows.into_iter().map(|(id, state)| json!([id, state])).collect::<Vec<_>>() }))
}

async fn read_by_id(client: &tokio_postgres::Client, config: &journal::LineageConfig, operation: &Value) -> anyhow::Result<Value> {
    let storage_name = require_str(operation, "storage_name")?;
    let id = require_str(operation, "id")?;
    let state = journal::read_lineage_head_by_id(client, &config.domain, storage_name, id).await?;
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
