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
    let mut request = http::unredirected_client()
        .request(method, url)
        .timeout(timeout);
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
    let body = read_capped(response, REPLY_BYTES).await?;
    Ok(Reply {
        status,
        headers,
        body,
    })
}

/// The body of `response`, refused as soon as it is known to pass `limit` bytes: by its declared
/// length before any byte is read, else as the chunks arrive, so no more than `limit` is held.
async fn read_capped(mut response: reqwest::Response, limit: usize) -> Result<Vec<u8>, Refusal> {
    let over = || Refusal::Failed(format!("reply passed the {limit} byte cap"));
    if response
        .content_length()
        .is_some_and(|declared| declared > limit as u64)
    {
        return Err(over());
    }
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|err| Refusal::Failed(err.to_string()))?
    {
        if body.len() + chunk.len() > limit {
            return Err(over());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// Runs `work` to completion on a thread and runtime of its own, so it is safe whatever runtime
/// the caller sits in (a blocking thread, or the main future of `block_on`, where the ambient
/// handle would panic). Called from inside an async task, where waiting would stall a worker, it
/// refuses instead.
fn block_on<T: Send>(
    work: impl std::future::Future<Output = Result<T, Refusal>> + Send,
) -> Result<T, Refusal> {
    if tokio::task::try_id().is_some() {
        return Err(Refusal::Failed(
            "a request cannot block an async task; run the component on a blocking thread".into(),
        ));
    }
    let gone = || Refusal::Failed("the request thread ended without an answer".into());
    std::thread::scope(|scope| {
        scope
            .spawn(|| {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .map_err(|err| Refusal::Failed(format!("no runtime to send on: {err}")))?;
                runtime.block_on(work)
            })
            .join()
            .unwrap_or_else(|_| Err(gone()))
    })
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

    /// Serves `head` and then `tail` on a local port, holding the connection open for a second.
    fn serve_raw(head: String, tail: Vec<u8>) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let _ = stream.read(&mut [0u8; 1024]).unwrap();
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(&tail);
            std::thread::sleep(Duration::from_secs(1));
        });
        format!("http://127.0.0.1:{port}/")
    }

    fn capped(url: &str, limit: usize) -> Result<Vec<u8>, Refusal> {
        block_on(async move {
            let response = http::unredirected_client().get(url).send().await.unwrap();
            read_capped(response, limit).await
        })
    }

    #[test]
    fn a_redirect_to_an_undeclared_host_is_not_followed() {
        let other = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        other.set_nonblocking(true).unwrap();
        let target = format!("http://localhost:{}/", other.local_addr().unwrap().port());
        let head = format!("HTTP/1.1 302 Found\r\nLocation: {target}\r\nContent-Length: 0\r\n\r\n");
        let url = serve_raw(head, vec![]);
        let answer = ask(Grants::new([], ["127.0.0.1"]), "fetch", &url).unwrap();
        assert!(answer.starts_with("302"), "{answer}");
        assert!(other.accept().is_err(), "the redirect target was contacted");
    }

    #[test]
    fn a_reply_declaring_more_than_the_cap_is_refused_before_its_body_is_read() {
        let head = "HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n".to_string();
        let started = std::time::Instant::now();
        let err = capped(&serve_raw(head, b"tiny".to_vec()), 10).unwrap_err();
        assert!(
            started.elapsed() < Duration::from_millis(900),
            "waited for the body"
        );
        assert_eq!(err, Refusal::Failed("reply passed the 10 byte cap".into()));
    }

    #[test]
    fn a_reply_of_unknown_length_is_cut_off_at_the_cap() {
        let head = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".to_string();
        let err = capped(&serve_raw(head, vec![b'x'; 50]), 10).unwrap_err();
        assert_eq!(err, Refusal::Failed("reply passed the 10 byte cap".into()));
    }

    #[test]
    fn a_reply_within_the_cap_is_read_whole() {
        let head = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".to_string();
        assert_eq!(
            capped(&serve_raw(head, b"fits".to_vec()), 10).unwrap(),
            b"fits"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_request_made_from_an_async_task_is_refused_not_panicked() {
        tokio::spawn(async { refused_inside_a_task() })
            .await
            .unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_request_made_from_the_main_future_of_a_runtime_is_answered_not_panicked() {
        let url = serve_once("main");
        let answer = Grants::new([], ["127.0.0.1"])
            .request(call_to(&url))
            .unwrap();
        assert_eq!(answer.body, b"main");
    }

    fn call_to(url: &str) -> Call {
        Call {
            method: "GET".into(),
            url: url.into(),
            headers: vec![],
            body: vec![],
            timeout_ms: 1000,
        }
    }

    fn refused_inside_a_task() {
        let grants = Grants::new([], ["127.0.0.1"]);
        let err = grants.request(call_to("http://127.0.0.1:1/")).unwrap_err();
        assert!(
            matches!(err, Refusal::Failed(ref why) if why.contains("async task")),
            "{err:?}"
        );
    }

    #[test]
    fn a_component_given_no_grant_is_refused_by_name() {
        let answer = call_text(&probe(), Arc::new(NoGrants), "read-secret", "ANY").unwrap();
        assert_eq!(answer.unwrap_err(), "undeclared: ANY");
    }
}
