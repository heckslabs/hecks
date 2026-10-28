//! Operator tool: seals a domain's lineage journal, and walks the seals to check it.
//! Usage: `ledger seal <Domain>` or `ledger verify <Domain>`.
//!
//! A running host seals on its own every `HECKS_SEAL_EVERY` lineage rows (a thousand unless set),
//! so `seal` is for the tail those commits have not reached, before a verify or a deploy.
//!
//! Reads `DATABASE_URL`, and `HECKS_SCHEMA` when the domain keeps its tables in a schema, and
//! connects the way the host does. Its last line of output is one JSON object with the result (the
//! connection logs the lines before it). Exits 0 when the journal was sealed, had nothing new to
//! seal, or every seal held; exits 1 when the chain could not be shown intact or the database
//! could not be reached, so a scheduler or a deploy gate can act on it.

use rust_host::store::journal_sql as journal;
use rust_host::{boot, ledger};
use serde_json::json;
use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let outcome = match args.as_slice() {
        [action, domain] if action == "seal" || action == "verify" => run(action, domain).await,
        _ => Err(anyhow::anyhow!("usage: ledger <seal|verify> <Domain>")),
    };
    match outcome {
        Ok((line, healthy)) => {
            println!("{line}");
            if healthy {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            }
        }
        Err(error) => {
            println!(
                "{}",
                json!({ "status": "error", "reason": format!("{error:#}") })
            );
            ExitCode::FAILURE
        }
    }
}

async fn run(action: &str, domain: &str) -> anyhow::Result<(serde_json::Value, bool)> {
    let url =
        std::env::var("DATABASE_URL").map_err(|_| anyhow::anyhow!("DATABASE_URL is not set"))?;
    let mut client = boot::connect_postgres(&url)
        .await
        .map_err(|error| anyhow::anyhow!("{error}"))?;
    if let Some(schema) = std::env::var("HECKS_SCHEMA").ok().filter(|s| !s.is_empty()) {
        client
            .batch_execute(&format!(
                "SET search_path TO {}",
                journal::quote_ident(&schema)
            ))
            .await?;
    }

    if action == "seal" {
        return Ok(match ledger::seal(&mut client, domain).await? {
            Some(anchor) => (
                json!({
                    "status": "sealed", "through": anchor.through,
                    "head": anchor.head, "previous": anchor.previous
                }),
                true,
            ),
            None => (json!({ "status": "unchanged" }), true),
        });
    }

    Ok(match ledger::verify(&client, domain).await? {
        ledger::Finding::Verified(report) => (
            json!({
                "status": "verified", "seals": report.seals,
                "entries": report.entries, "unsealed": report.unsealed
            }),
            true,
        ),
        ledger::Finding::Unproven(reason) => {
            (json!({ "status": "unproven", "reason": reason }), false)
        }
    })
}
