//! The one HTTP client the host's outbound calls share.

use std::sync::LazyLock;

/// Built once: the TLS configuration and its root certificates are the costly part of a client.
///
/// It keeps no idle connections. The tests run each case on its own runtime, and a connection
/// opened under one runtime is dead under the next, so reusing connections would fail them; these
/// calls (sign-in, checkout, receipts, template fetches) are infrequent and go to different
/// hosts, so reuse would not pay anyway.
#[allow(clippy::expect_used)] // reason: a client with default TLS settings always builds
static CLIENT: LazyLock<reqwest::Client> = LazyLock::new(|| {
    reqwest::Client::builder()
        .pool_max_idle_per_host(0)
        .build()
        .expect("a reqwest client with default settings always builds")
});

/// The shared client. Set a per-call timeout on the request, not on the client.
pub(crate) fn client() -> &'static reqwest::Client {
    &CLIENT
}
