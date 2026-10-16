//! The real fetch of the issuer's key set, on the HTTP client the host already uses for Google
//! (`reqwest`, as in the Google token exchange).
//!
//! It is bounded on every side: a five second timeout, no redirects (a key set that moves is
//! refused, not followed), a status of exactly 200, and a body cap checked while reading. It also
//! reports how long the issuer allows the answer to be cached, which the cache honours up to its
//! own cap.

use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Duration;

use super::jwks::{FetchFailed, JwksFetcher};

/// How long a fetch may take, connection and body together.
pub const TIMEOUT: Duration = Duration::from_secs(5);
/// The largest key set body accepted, in bytes.
pub const MAX_BODY_BYTES: usize = 64 * 1024;

/// The stored value that means the last answer carried no cache hint.
const NO_HINT: i64 = -1;

/// Fetches a key set over HTTPS from a fixed address.
pub struct HttpJwksFetcher {
    url: String,
    timeout: Duration,
    max_age: AtomicI64,
}

impl HttpJwksFetcher {
    /// Builds a fetcher for `url` with the standard timeout.
    pub fn new(url: &str) -> Self {
        Self::with_timeout(url, TIMEOUT)
    }

    /// Builds a fetcher with an explicit timeout.
    pub fn with_timeout(url: &str, timeout: Duration) -> Self {
        Self {
            url: url.to_string(),
            timeout,
            max_age: AtomicI64::new(NO_HINT),
        }
    }

    async fn get(&self) -> Result<(String, Option<i64>), FetchFailed> {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(self.timeout)
            .build()
            .map_err(|_| FetchFailed)?;
        let mut response = client
            .get(&self.url)
            .send()
            .await
            .map_err(|_| FetchFailed)?;
        if response.status() != reqwest::StatusCode::OK || announced_too_large(&response) {
            return Err(FetchFailed);
        }
        let hint = response
            .headers()
            .get(reqwest::header::CACHE_CONTROL)
            .and_then(|value| value.to_str().ok())
            .and_then(max_age_of);
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| FetchFailed)? {
            if body.len() + chunk.len() > MAX_BODY_BYTES {
                return Err(FetchFailed);
            }
            body.extend_from_slice(&chunk);
        }
        Ok((String::from_utf8(body).map_err(|_| FetchFailed)?, hint))
    }
}

fn announced_too_large(response: &reqwest::Response) -> bool {
    response
        .content_length()
        .is_some_and(|length| length > MAX_BODY_BYTES as u64)
}

/// Reads `max-age` from a `Cache-Control` value; `no-store`, `no-cache` and absence give `None`.
pub fn max_age_of(cache_control: &str) -> Option<i64> {
    let directives: Vec<String> = cache_control
        .split(',')
        .map(|d| d.trim().to_ascii_lowercase())
        .collect();
    if directives
        .iter()
        .any(|d| d == "no-store" || d == "no-cache")
    {
        return None;
    }
    directives
        .iter()
        .find_map(|d| d.strip_prefix("max-age="))
        .and_then(|seconds| seconds.parse::<i64>().ok())
        .filter(|seconds| *seconds >= 0)
}

impl JwksFetcher for HttpJwksFetcher {
    /// Must be called from a blocking thread of the tokio runtime.
    fn fetch(&self) -> Result<String, FetchFailed> {
        let handle = tokio::runtime::Handle::try_current().map_err(|_| FetchFailed)?;
        let outcome = handle.block_on(self.get());
        let hint = outcome.as_ref().ok().and_then(|(_, hint)| *hint);
        self.max_age
            .store(hint.unwrap_or(NO_HINT), Ordering::SeqCst);
        outcome.map(|(body, _)| body)
    }

    fn ttl_hint(&self) -> Option<i64> {
        Some(self.max_age.load(Ordering::SeqCst)).filter(|hint| *hint >= 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    /// Serves `responses` in turn on a loopback port, one connection each, and returns the address.
    fn serve(responses: Vec<Vec<u8>>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for response in responses {
                let Ok((mut stream, _)) = listener.accept() else {
                    return;
                };
                let mut buffer = [0u8; 2048];
                let _ = stream.read(&mut buffer);
                let _ = stream.write_all(&response);
                std::thread::sleep(Duration::from_millis(300));
            }
        });
        format!("http://{address}/jwks.json")
    }

    fn http(status: &str, headers: &str, body: &str) -> Vec<u8> {
        format!(
            "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    async fn fetch(url: String) -> (Result<String, FetchFailed>, Option<i64>) {
        tokio::task::spawn_blocking(move || {
            let fetcher = HttpJwksFetcher::with_timeout(&url, Duration::from_millis(800));
            let result = fetcher.fetch();
            (result, fetcher.ttl_hint())
        })
        .await
        .unwrap()
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_200_answer_is_returned_with_its_cache_hint() {
        let url = serve(vec![http(
            "200 OK",
            "Cache-Control: public, max-age=120\r\n",
            "{\"keys\":[]}",
        )]);
        let (body, hint) = fetch(url).await;
        assert_eq!(body.unwrap(), "{\"keys\":[]}");
        assert_eq!(hint, Some(120));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_answer_without_a_cache_header_gives_no_hint() {
        let (body, hint) = fetch(serve(vec![http("200 OK", "", "{}")])).await;
        assert!(body.is_ok());
        assert_eq!(hint, None);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_redirect_is_refused_not_followed() {
        let target = serve(vec![http("200 OK", "", "{\"keys\":[]}")]);
        let url = serve(vec![http(
            "302 Found",
            &format!("Location: {target}\r\n"),
            "",
        )]);
        assert_eq!(fetch(url).await.0, Err(FetchFailed));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn any_status_but_200_is_a_failure() {
        for status in [
            "204 No Content",
            "404 Not Found",
            "500 Internal Server Error",
            "206 Partial Content",
        ] {
            assert_eq!(
                fetch(serve(vec![http(status, "", "{}")])).await.0,
                Err(FetchFailed),
                "{status}"
            );
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_body_over_the_cap_is_a_failure_by_header_and_by_reading() {
        let big = "a".repeat(MAX_BODY_BYTES + 1);
        assert_eq!(
            fetch(serve(vec![http("200 OK", "", &big)])).await.0,
            Err(FetchFailed)
        );
        let chunked = format!("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:x}\r\n{big}\r\n0\r\n\r\n", big.len());
        assert_eq!(
            fetch(serve(vec![chunked.into_bytes()])).await.0,
            Err(FetchFailed)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_body_exactly_at_the_cap_is_accepted() {
        let exact = "a".repeat(MAX_BODY_BYTES);
        assert_eq!(
            fetch(serve(vec![http("200 OK", "", &exact)]))
                .await
                .0
                .unwrap()
                .len(),
            MAX_BODY_BYTES
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_server_that_never_answers_times_out() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/jwks.json", listener.local_addr().unwrap());
        let started = std::time::Instant::now();
        assert_eq!(fetch(url).await.0, Err(FetchFailed));
        assert!(started.elapsed() < Duration::from_secs(4));
        drop(listener);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_refused_connection_is_a_failure() {
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        assert_eq!(
            fetch(format!("http://127.0.0.1:{port}/x")).await.0,
            Err(FetchFailed)
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_real_fetcher_feeds_the_real_verifier_through_the_handler() {
        use super::super::handler::SigninHandler;
        use super::super::jti::JtiStore;
        use super::super::jwks::JwksCache;
        use super::super::verify::Verifier;
        use super::super::wiring_support::*;
        use std::sync::Arc;

        let doc = vectors();
        let document = doc["jwks"].to_string();
        let url = serve(vec![http(
            "200 OK",
            "Cache-Control: max-age=300\r\n",
            &document,
        )]);
        let pins = &doc["config"];
        let pinned = super::super::config::PlatformSigninConfig::new(
            pins["iss"].as_str().unwrap(),
            &url,
            pins["aud"].as_str().unwrap(),
            pins["env"].as_str().unwrap(),
        );
        let keys = JwksCache::new(HttpJwksFetcher::with_timeout(&url, Duration::from_secs(2)));
        let verifier = Verifier::new(pinned, keys, JtiStore::new());
        let now = doc["now"].as_i64().unwrap();
        let handler = SigninHandler::new(
            settings("alongside"),
            Arc::new(verifier),
            Arc::new(Recorder::default()),
        )
        .with_clock(Box::new(move || now));
        let members = FakeMembers::resolving(Person::new("person@example.test", Some("Admin")));
        let response = handler
            .callback(&request_for(&single(&doc, "valid")), &members)
            .await;
        assert_eq!(response["statusCode"], 302);
    }

    #[test]
    fn the_standard_timeout_is_five_seconds_and_the_cap_64_kib() {
        assert_eq!(TIMEOUT, Duration::from_secs(5));
        assert_eq!(MAX_BODY_BYTES, 65536);
    }

    #[test]
    fn max_age_is_read_from_cache_control() {
        assert_eq!(max_age_of("max-age=300"), Some(300));
        assert_eq!(max_age_of("public, max-age=60, must-revalidate"), Some(60));
        assert_eq!(max_age_of("Max-Age=45"), Some(45));
        assert_eq!(max_age_of("s-maxage=90, max-age=30"), Some(30));
    }

    #[test]
    fn a_hint_that_forbids_caching_or_is_unreadable_is_none() {
        for value in [
            "",
            "no-store",
            "no-cache",
            "max-age=300, no-store",
            "max-age=abc",
            "max-age=-5",
            "max-age=",
            "private",
            "max-age=99999999999999999999",
        ] {
            assert_eq!(max_age_of(value), None, "{value:?}");
        }
    }
}
