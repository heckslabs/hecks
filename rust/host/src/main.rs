//! Lambda custom-runtime entry point (or a long-lived server under HECKS_SERVE_MODE=1): installs no
//! extensions of its own, so the host runs with its defaults. See `rust_host::boot::run`.

#[tokio::main]
async fn main() -> Result<(), lambda_runtime::Error> {
    rust_host::boot::run().await
}
