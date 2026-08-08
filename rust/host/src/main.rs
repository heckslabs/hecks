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
use tokio_postgres::NoTls;

#[tokio::main]
async fn main() -> Result<(), Error> {
    let database_url = std::env::var("DATABASE_URL").map_err(|_| "DATABASE_URL is required")?;
    let wasm_path = PathBuf::from(
        std::env::var("HECKS_WASM_PATH").unwrap_or_else(|_| "banking.wasm".to_string()),
    );

    let (client, connection) = tokio_postgres::connect(&database_url, NoTls).await?;
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("postgres connection error: {e}");
        }
    });
    journal::ensure_schema(&client).await?;
    let client = Arc::new(client);
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
