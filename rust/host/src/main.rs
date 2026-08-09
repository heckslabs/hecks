// THE LAMBDA ENTRY POINT — provided.al2023 custom runtime, no
// container (per explicit direction: PackageType Zip, not Image). A
// Lambda event is EITHER a command (`{"verb": "...", "args": {...}}`,
// the same shape a single entry of the kernel's own `{"steps": [...]}`
// array already has — no new request shape invented for that path) OR
// a read (`{"read": true}` — no verb at all, checked first so it can
// never be confused with a command that simply omitted one). Both
// response shapes are the kernel's own `{"instances","events",
// "refusals"}` output, unchanged, so anything that already knows how
// to read bin/rust_conformance's JSON (a human, a test, future
// tooling) reads this Lambda's response either way.
//
// Postgres and wasmtime are BOTH held only here and in the two modules
// this file composes (journal, wasm_runner) — dispatch.rs is the only
// place that sees both at once. The `.wasm` module itself never learns
// either exists.

mod dispatch;
mod journal;
mod wasm_runner;

use lambda_runtime::{service_fn, Error, LambdaEvent};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;

#[tokio::main]
async fn main() -> Result<(), Error> {
    let database_url = std::env::var("DATABASE_URL").map_err(|_| "DATABASE_URL is required")?;
    let wasm_path = PathBuf::from(
        std::env::var("HECKS_WASM_PATH").unwrap_or_else(|_| "banking.wasm".to_string()),
    );

    // RDS Postgres refuses a plain NoTls connection by default (real,
    // live error: "no pg_hba.conf entry ... no encryption") -- and
    // needs AWS's own RDS CA specifically, not a generic public bundle
    // (see Cargo.toml's own comment on both points).
    let mut roots = rustls::RootCertStore::empty();
    for cert in rustls_pemfile::certs(&mut include_bytes!("../rds-ca-bundle.pem").as_slice()) {
        roots.add(cert.map_err(|e| format!("parsing rds-ca-bundle.pem: {e}"))?)?;
    }
    let tls_config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    let tls = tokio_postgres_rustls::MakeRustlsConnect::new(tls_config);
    // Named, operator-facing context on failure -- mirrors postgres.rb's
    // own WiringError wrapping (`cannot bind Postgres at ... for ...`).
    // DATABASE_URL itself is never interpolated into either message
    // (it carries credentials); the underlying error text is the only
    // detail that travels. `{e:#}` (anyhow's alternate/chain format),
    // not `{e}` -- confirmed live (a real "db error" with the actual
    // Postgres message underneath silently dropped) that a bare `{}`
    // Display on a tokio_postgres::Error collapses to a near-useless
    // generic label ("db error") where `{:#}` shows the real server
    // text ("db error: ERROR: relation ... does not exist").
    let (client, connection) = tokio_postgres::connect(&database_url, tls)
        .await
        .map_err(|e| format!("connecting to Postgres via DATABASE_URL: {e:#}"))?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("postgres connection error: {e:#}");
        }
    });
    journal::ensure_schema(&client)
        .await
        .map_err(|e| format!("provisioning hecks_lambda_journal: {e:#}"))?;

    // Which Ruby-shaped lineage journal/era this deployed binary writes
    // as -- operational facts, like Ruby's own settings[:domain]/
    // settings[:era] (journal.rs's own header on why neither is
    // computed here). No default for either: a binary silently writing
    // under the wrong domain or era is exactly the failure mode this
    // whole design exists to prevent.
    let domain = std::env::var("HECKS_DOMAIN").map_err(|_| "HECKS_DOMAIN is required")?;
    // i32, matching Postgres `int` -- hecks_eras.ordinal and every
    // journal's own `era` column are `int` (int4) in Ruby's real DDL
    // (era_store.rb/provisioning.rb), not bigint; tokio_postgres
    // requires the Rust and Postgres types to match exactly, not just
    // be numerically compatible.
    let era: i32 = std::env::var("HECKS_ERA")
        .map_err(|_| "HECKS_ERA is required")?
        .parse()
        .map_err(|e| format!("HECKS_ERA must be an integer era ordinal: {e}"))?;

    // THE BOOT GATE -- refuses to start rather than write into tables
    // that may not exist. rust/host never provisions hecks_eras, the
    // journal partition, or the head-snapshot tables itself; that's
    // Ruby's LineageManager alone (mint_era!/hold_first!). A missing
    // row here means either this domain/era was never minted, or the
    // ordinal is simply wrong -- either way, a clear refusal beats a
    // raw "relation does not exist" the first time a command lands.
    if !journal::era_exists(&client, &domain, era)
        .await
        .map_err(|e| format!("checking hecks_eras for {domain} era {era}: {e:#}"))?
    {
        return Err(format!(
            "cannot boot: {domain} holds no era {era} in hecks_eras -- \
             this domain/era must already be minted by Ruby's own LineageManager \
             (hold_first!/mint_era!) before rust/host can write into it"
        )
        .into());
    }
    let lineage_config = Arc::new(journal::LineageConfig { domain, era });

    // Mutex, not a bare Arc<Client> -- dispatch::handle needs
    // Client::transaction (which takes &mut Client) to hold the
    // advisory lock across the whole rehydrate-then-append sequence.
    // See dispatch.rs's own comment for what that guards against.
    let client = Arc::new(Mutex::new(client));
    let wasm_path = Arc::new(wasm_path);

    lambda_runtime::run(service_fn(move |event: LambdaEvent<serde_json::Value>| {
        let client = Arc::clone(&client);
        let wasm_path = Arc::clone(&wasm_path);
        let lineage_config = Arc::clone(&lineage_config);
        async move {
            let (body, _context) = event.into_parts();

            if body.get("read").and_then(|v| v.as_bool()) == Some(true) {
                let result = dispatch::read(&client, &wasm_path).await?;
                return Ok::<serde_json::Value, Error>(result);
            }

            let verb = body
                .get("verb")
                .and_then(|v| v.as_str())
                .ok_or("event missing \"verb\"")?
                .to_string();
            let args = body
                .get("args")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));

            let outcome = dispatch::handle(&client, &wasm_path, &verb, args, &lineage_config).await?;
            Ok::<serde_json::Value, Error>(outcome.result)
        }
    }))
    .await
}
