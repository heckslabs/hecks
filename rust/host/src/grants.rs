//! What a Wasm adapter component is allowed to reach: the secret names and host names its grant
//! declares, answered over the process's secrets and the shared outbound client.
//!
//! A component imports `secrets` and `http-out` (`rust/host/wit`); the runner in
//! `rust_host_core::component_runner` hands each ask to [`Grants`], which answers only what the
//! grant names and refuses the rest with the name asked.

use crate::{http, secrets};
use rust_host_core::component_imports::{Call, Imports, Refusal, Reply};
use std::time::Duration;

/// The most a reply body may hold before the host refuses to hand it to a component.
const REPLY_BYTES: usize = 16 * 1024 * 1024;

/// The longest a component may ask one request to take.
const LONGEST_TIMEOUT: Duration = Duration::from_secs(30);

/// The secret names and host names one component declared. Nothing else is reachable.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Grants {
    secrets: Vec<String>,
    hosts: Vec<String>,
}

impl Grants {
    /// A grant of `secrets` (environment variable names) and `hosts` (bare host names, no port).
    pub fn new<S: Into<String>>(
        secrets: impl IntoIterator<Item = S>,
        hosts: impl IntoIterator<Item = S>,
    ) -> Self {
        Self {
            secrets: secrets.into_iter().map(Into::into).collect(),
            hosts: hosts
                .into_iter()
                .map(|host| host.into().to_ascii_lowercase())
                .collect(),
        }
    }

    /// The host of `url` when the grant names it, else the refusal naming what was asked.
    fn granted_host(&self, url: &reqwest::Url) -> Result<(), Refusal> {
        let host = url.host_str().unwrap_or_default().to_ascii_lowercase();
        if self.hosts.contains(&host) {
            return Ok(());
        }
        Err(Refusal::Undeclared(host))
    }
}

impl Imports for Grants {
    fn secret(&self, name: &str) -> Result<Option<String>, Refusal> {
        if !self.secrets.iter().any(|granted| granted == name) {
            return Err(Refusal::Undeclared(name.to_string()));
        }
        match secrets::var(name) {
            Ok(value) => Ok(Some(value)),
            Err(std::env::VarError::NotPresent) => Ok(None),
            Err(err) => Err(Refusal::Failed(format!("secret {name}: {err}"))),
        }
    }

    fn request(&self, call: Call) -> Result<Reply, Refusal> {
        let url = reqwest::Url::parse(&call.url)
            .map_err(|err| Refusal::Failed(format!("url {:?}: {err}", call.url)))?;
        self.granted_host(&url)?;
        block_on(send(url, call))
    }
}

/// Makes the request and reads the whole reply, within the component's timeout.
async fn send(url: reqwest::Url, call: Call) -> Result<Reply, Refusal> {
    let failed = |err: reqwest::Error| Refusal::Failed(err.to_string());
    let method = reqwest::Method::from_bytes(call.method.as_bytes())
        .map_err(|err| Refusal::Failed(format!("method {:?}: {err}", call.method)))?;
    let timeout = Duration::from_millis(u64::from(call.timeout_ms)).min(LONGEST_TIMEOUT);
    let mut request = http::client().request(method, url).timeout(timeout);
    for (name, value) in &call.headers {
        request = request.header(name, value);
    }
    let response = request.body(call.body).send().await.map_err(failed)?;
    let status = response.status().as_u16();
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| {
            (
                name.to_string(),
                String::from_utf8_lossy(value.as_bytes()).into(),
            )
        })
        .collect();
    let body = response.bytes().await.map_err(failed)?;
    if body.len() > REPLY_BYTES {
        return Err(Refusal::Failed(format!(
            "reply passed the {REPLY_BYTES} byte cap"
        )));
    }
    Ok(Reply {
        status,
        headers,
        body: body.to_vec(),
    })
}

/// Runs `work` to completion from a blocking thread: on the ambient runtime when there is one
/// (the component runs under `spawn_blocking`), else on a runtime of its own.
fn block_on<T>(work: impl std::future::Future<Output = Result<T, Refusal>>) -> Result<T, Refusal> {
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        return handle.block_on(work);
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|err| Refusal::Failed(format!("no runtime to send on: {err}")))?;
    runtime.block_on(work)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
    use super::*;
    use rust_host_core::component_imports::NoGrants;
    use rust_host_core::component_runner::call_text;
    use std::io::{Read, Write};
    use std::path::PathBuf;
    use std::sync::Arc;

    fn probe() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../spec/fixtures/wasm_component/grant_probe.wasm")
    }

    fn ask(grants: Grants, export: &str, argument: &str) -> Result<String, String> {
        call_text(&probe(), Arc::new(grants), export, argument).unwrap()
    }

    /// Serves one fixed reply on a local port and returns the URL to ask.
    fn serve_once(body: &'static str) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut seen = [0u8; 1024];
            let _ = stream.read(&mut seen).unwrap();
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(reply.as_bytes()).unwrap();
        });
        format!("http://127.0.0.1:{port}/")
    }

    #[test]
    fn an_undeclared_secret_is_refused_by_name() {
        secrets::provide("GRANTS_TEST_UNDECLARED", "hidden".into());
        let err = ask(Grants::default(), "read-secret", "GRANTS_TEST_UNDECLARED").unwrap_err();
        assert_eq!(err, "undeclared: GRANTS_TEST_UNDECLARED");
    }

    #[test]
    fn a_declared_secret_gives_its_value() {
        secrets::provide("GRANTS_TEST_DECLARED", "s3cret".into());
        let grants = Grants::new(["GRANTS_TEST_DECLARED"], []);
        assert_eq!(
            ask(grants, "read-secret", "GRANTS_TEST_DECLARED").unwrap(),
            "s3cret"
        );
    }

    #[test]
    fn a_declared_secret_the_host_does_not_hold_is_unset_not_refused() {
        let grants = Grants::new(["GRANTS_TEST_NEVER_SET"], []);
        let err = ask(grants, "read-secret", "GRANTS_TEST_NEVER_SET").unwrap_err();
        assert_eq!(err, "unset: GRANTS_TEST_NEVER_SET");
    }

    #[test]
    fn an_undeclared_host_is_refused_by_name_and_never_contacted() {
        let url = serve_once("never");
        let err = ask(Grants::new([], ["example.com"]), "fetch", &url).unwrap_err();
        assert_eq!(err, "undeclared: 127.0.0.1");
    }

    #[test]
    fn a_declared_host_answers() {
        let url = serve_once("pong");
        let answer = ask(Grants::new([], ["127.0.0.1"]), "fetch", &url).unwrap();
        assert_eq!(answer, "200 pong");
    }

    #[test]
    fn a_component_given_no_grant_is_refused_by_name() {
        let answer = call_text(&probe(), Arc::new(NoGrants), "read-secret", "ANY").unwrap();
        assert_eq!(answer.unwrap_err(), "undeclared: ANY");
    }
}
