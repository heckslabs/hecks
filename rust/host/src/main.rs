// THE LAMBDA ENTRY POINT — provided.al2023 custom runtime, no
// container (per explicit direction: PackageType Zip, not Image). One
// Lambda event IS one command: `{"verb": "...", "args": {...}}`, the
// same shape a single entry of the kernel's own `{"steps": [...]}`
// array already has — no new request shape invented. The response is
// the kernel's own `{"instances","events","refusals"}` output,
// unchanged, so anything that already knows how to read
// bin/rust_conformance's JSON (a human, a test, future tooling) reads
// this Lambda's response the same way.
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
    // detail that travels.
    let (client, connection) = tokio_postgres::connect(&database_url, tls)
        .await
        .map_err(|e| format!("connecting to Postgres via DATABASE_URL: {e}"))?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("postgres connection error: {e}");
        }
    });
    journal::ensure_schema(&client)
        .await
        .map_err(|e| format!("provisioning hecks_lambda_journal: {e}"))?;
    // Mutex, not a bare Arc<Client> -- dispatch::handle needs
    // Client::transaction (which takes &mut Client) to hold the
    // advisory lock across the whole rehydrate-then-append sequence.
    // See dispatch.rs's own comment for what that guards against.
    let client = Arc::new(Mutex::new(client));
    let wasm_path = Arc::new(wasm_path);

    lambda_runtime::run(service_fn(move |event: LambdaEvent<serde_json::Value>| {
        let client = Arc::clone(&client);
        let wasm_path = Arc::clone(&wasm_path);
        async move {
            let (body, _context) = event.into_parts();
            let verb = body
                .get("verb")
                .and_then(|v| v.as_str())
                .ok_or("event missing \"verb\"")?
                .to_string();
            let args = body
                .get("args")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));

            let outcome = dispatch::handle(&client, &wasm_path, &verb, args).await?;
            Ok::<serde_json::Value, Error>(outcome.result)
        }
    }))
    .await
}
