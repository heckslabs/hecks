// The outbound side of a newsletter send: one email handed to Resend's REST
// API (https://resend.com/docs/api-reference/emails/send-email). The Ruby
// counterpart is lifeadelics' adapters/resend/resend.rb; both answer the same
// `deliver` question, ok or not with a message id, so the send loop never
// knows which provider it is talking to.
//
// Three states, decided once per send from the environment (`Mailer::from_env`):
//
//   RESEND_API_KEY + RESEND_FROM   live: every email really goes to Resend
//   RESEND_MOCK=1, no key          mock: logged, never sent, synthetic ids
//   neither                        not configured: the route refuses before
//                                  it marks the issue sent
//
// Mock is opt-in, unlike checkout's mock-by-default. Marking an issue sent is
// irreversible, so a deploy that forgot its key must refuse rather than record
// a send nobody received.
//
// Resend's default limit is two requests a second and it answers 429 with a
// `retry-after`; `deliver` waits and retries a few times before giving up on
// one recipient, so a fan-out over a small list stays inside the limit.

use serde_json::{json, Value};
use std::time::Duration;

const API_BASE: &str = "https://api.resend.com";
const TIMEOUT: Duration = Duration::from_secs(15);
const MAX_ATTEMPTS: u32 = 4;
const DEFAULT_RETRY_SECS: u64 = 1;
const MAX_RETRY_SECS: u64 = 5;
const MOCK_BOUNCE_ADDRESS: &str = "bounce@example.com";

/// One email to one recipient.
pub struct Email<'a> {
    pub to: &'a str,
    pub subject: &'a str,
    /// HTML when it opens with a tag (a rendered issue), plain text otherwise.
    pub body: &'a str,
    /// Where the recipient leaves the list; sent as `List-Unsubscribe` so
    /// mail clients can offer their own unsubscribe button.
    pub unsubscribe_url: Option<&'a str>,
}

/// What handing an email to the provider came to. Never an error: a refusal or
/// an outage for one recipient is `ok: false` with a reason, so a fan-out can
/// carry on with the rest.
#[derive(Debug, PartialEq)]
pub struct Delivery {
    pub ok: bool,
    pub message_id: Option<String>,
    pub reason: Option<String>,
}

impl Delivery {
    fn sent(message_id: String) -> Self {
        Delivery { ok: true, message_id: Some(message_id), reason: None }
    }

    fn failed(reason: impl Into<String>) -> Self {
        Delivery { ok: false, message_id: None, reason: Some(reason.into()) }
    }
}

/// How email leaves the host: really, through Resend, or logged and dropped.
pub enum Mailer {
    Live { http: reqwest::Client, api_key: String, from: String, base_url: String },
    Mock,
}

impl Mailer {
    /// `Ok(None)` when nothing is configured, `Err` when a key is set without
    /// the from address that must go with it.
    pub fn from_env() -> Result<Option<Mailer>, String> {
        let var = |name: &str| std::env::var(name).unwrap_or_default();
        Self::configured(&var("RESEND_API_KEY"), &var("RESEND_FROM"), &var("RESEND_MOCK"))
    }

    fn configured(api_key: &str, from: &str, mock: &str) -> Result<Option<Mailer>, String> {
        if !api_key.is_empty() {
            if from.is_empty() {
                return Err("RESEND_API_KEY is set but RESEND_FROM is not — Resend needs a from address on a verified domain".to_string());
            }
            return Ok(Some(Self::live(api_key, from, API_BASE)));
        }
        Ok((mock == "1").then_some(Mailer::Mock))
    }

    /// A mailer that posts to `base_url` (Resend's API, or a stand-in in tests).
    pub fn live(api_key: &str, from: &str, base_url: &str) -> Mailer {
        let http = reqwest::Client::builder().timeout(TIMEOUT).build().expect("a reqwest client with a timeout always builds");
        Mailer::Live { http, api_key: api_key.to_string(), from: from.to_string(), base_url: base_url.to_string() }
    }

    #[cfg(test)]
    pub fn is_mock(&self) -> bool {
        matches!(self, Mailer::Mock)
    }

    pub async fn deliver(&self, email: &Email<'_>) -> Delivery {
        match self {
            Mailer::Mock => mock_deliver(email),
            Mailer::Live { http, api_key, from, base_url } => live_deliver(http, api_key, from, base_url, email).await,
        }
    }
}

fn mock_deliver(email: &Email<'_>) -> Delivery {
    if email.to == MOCK_BOUNCE_ADDRESS {
        return Delivery::failed("bounced");
    }
    println!("[mock resend] to={} subject={:?}\n{}", email.to, email.subject, email.body);
    Delivery::sent(format!("re_{}", uuid::Uuid::new_v4().simple()))
}

fn payload(from: &str, email: &Email<'_>) -> Value {
    let mut payload = json!({ "from": from, "to": [email.to], "subject": email.subject });
    let content_key = if email.body.trim_start().starts_with('<') { "html" } else { "text" };
    payload[content_key] = json!(email.body);
    if let Some(url) = email.unsubscribe_url {
        payload["headers"] = json!({ "List-Unsubscribe": format!("<{url}>") });
    }
    payload
}

fn retry_delay(response: &reqwest::Response) -> Duration {
    let secs = response
        .headers()
        .get("retry-after")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(DEFAULT_RETRY_SECS);
    Duration::from_secs(secs.min(MAX_RETRY_SECS))
}

async fn live_deliver(http: &reqwest::Client, api_key: &str, from: &str, base_url: &str, email: &Email<'_>) -> Delivery {
    let body = payload(from, email);
    for attempt in 1..=MAX_ATTEMPTS {
        let response = match http.post(format!("{base_url}/emails")).bearer_auth(api_key).json(&body).send().await {
            Ok(r) => r,
            Err(e) => return Delivery::failed(format!("resend unreachable: {}", e.without_url())),
        };
        let status = response.status();
        if status.as_u16() == 429 && attempt < MAX_ATTEMPTS {
            tokio::time::sleep(retry_delay(&response)).await;
            continue;
        }
        let answer: Value = response.json().await.unwrap_or(Value::Null);
        if status.is_success() {
            return match answer.get("id").and_then(|v| v.as_str()) {
                Some(id) => Delivery::sent(id.to_string()),
                None => Delivery::failed("resend accepted the email but returned no id"),
            };
        }
        let message = answer.get("message").and_then(|v| v.as_str()).map(String::from);
        return Delivery::failed(message.unwrap_or_else(|| format!("resend answered {status}")));
    }
    Delivery::failed("resend kept rate limiting this email")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex as StdMutex};

    /// A recording Resend on 127.0.0.1: answers each request with the next
    /// canned `(status line, extra headers, body)` and keeps what it was sent.
    struct FakeResend {
        base: String,
        requests: Arc<StdMutex<Vec<String>>>,
    }

    impl FakeResend {
        fn start(answers: Vec<(&'static str, &'static str, &'static str)>) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind a local port");
            let base = format!("http://{}", listener.local_addr().unwrap());
            let requests = Arc::new(StdMutex::new(Vec::new()));
            let seen = requests.clone();
            std::thread::spawn(move || {
                for (status, headers, body) in answers {
                    let (mut stream, _) = listener.accept().expect("a request");
                    let request = read_request(&mut stream);
                    seen.lock().unwrap().push(request);
                    let response = format!("HTTP/1.1 {status}\r\ncontent-type: application/json\r\n{headers}content-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
                    stream.write_all(response.as_bytes()).unwrap();
                }
            });
            FakeResend { base, requests }
        }

        fn requests(&self) -> Vec<String> {
            self.requests.lock().unwrap().clone()
        }
    }

    fn read_request(stream: &mut std::net::TcpStream) -> String {
        let mut raw = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let n = stream.read(&mut chunk).unwrap();
            raw.extend_from_slice(&chunk[..n]);
            let text = String::from_utf8_lossy(&raw).to_string();
            if let Some((head, body)) = text.split_once("\r\n\r\n") {
                let length = head
                    .lines()
                    .find_map(|l| l.to_lowercase().strip_prefix("content-length:").and_then(|v| v.trim().parse::<usize>().ok()))
                    .unwrap_or(0);
                if body.len() >= length {
                    return text;
                }
            }
            if n == 0 {
                return text;
            }
        }
    }

    fn email<'a>(to: &'a str, body: &'a str) -> Email<'a> {
        Email { to, subject: "Spring news", body, unsubscribe_url: Some("https://example.com/newsletter-unsubscribed.html?email=a%40b.com") }
    }

    #[test]
    fn nothing_configured_is_not_a_mailer() {
        assert!(Mailer::configured("", "", "").unwrap().is_none());
    }

    #[test]
    fn a_key_without_a_from_address_is_refused() {
        assert!(Mailer::configured("re_x", "", "").is_err());
    }

    #[test]
    fn a_key_and_from_is_live_even_when_mock_is_also_set() {
        let mailer = Mailer::configured("re_x", "News <n@mail.example.com>", "1").unwrap().unwrap();
        assert!(!mailer.is_mock());
    }

    #[test]
    fn mock_needs_an_explicit_opt_in_and_no_key() {
        assert!(Mailer::configured("", "", "1").unwrap().unwrap().is_mock());
        assert!(Mailer::configured("", "", "0").unwrap().is_none());
    }

    #[test]
    fn an_html_body_goes_as_html_and_a_plain_one_as_text() {
        assert!(payload("f", &email("a@b.com", "  <p>hi</p>")).get("html").is_some());
        let plain = payload("f", &email("a@b.com", "just a link"));
        assert!(plain.get("text").is_some() && plain.get("html").is_none());
    }

    #[test]
    fn the_unsubscribe_url_rides_as_a_list_unsubscribe_header() {
        let with = payload("f", &email("a@b.com", "x"));
        assert_eq!(with["headers"]["List-Unsubscribe"], "<https://example.com/newsletter-unsubscribed.html?email=a%40b.com>");
        let without = payload("f", &Email { to: "a@b.com", subject: "s", body: "x", unsubscribe_url: None });
        assert!(without.get("headers").is_none());
    }

    #[test]
    fn the_mock_logs_instead_of_sending_and_bounces_the_test_address() {
        let sent = mock_deliver(&email("a@b.com", "x"));
        assert!(sent.ok && sent.message_id.unwrap().starts_with("re_"));
        assert_eq!(mock_deliver(&email(MOCK_BOUNCE_ADDRESS, "x")), Delivery::failed("bounced"));
    }

    #[tokio::test]
    async fn a_live_send_posts_the_email_with_the_bearer_key_and_returns_the_message_id() {
        let fake = FakeResend::start(vec![("200 OK", "", r#"{"id":"em_123"}"#)]);
        let mailer = Mailer::live("re_secret", "News <n@mail.example.com>", &fake.base);

        let delivery = mailer.deliver(&email("a@b.com", "<p>hi</p>")).await;

        assert_eq!(delivery, Delivery::sent("em_123".to_string()));
        let requests = fake.requests();
        assert_eq!(requests.len(), 1);
        let request = requests[0].to_lowercase();
        assert!(request.starts_with("post /emails "), "{request}");
        assert!(request.contains("authorization: bearer re_secret"), "{request}");
        assert!(requests[0].contains(r#""to":["a@b.com"]"#) && requests[0].contains(r#""from":"News <n@mail.example.com>""#), "{}", requests[0]);
    }

    #[tokio::test]
    async fn a_refusal_from_resend_is_a_failed_delivery_carrying_its_message() {
        let fake = FakeResend::start(vec![("403 Forbidden", "", r#"{"message":"The mail.example.com domain is not verified.","name":"validation_error"}"#)]);
        let delivery = Mailer::live("re_x", "n@mail.example.com", &fake.base).deliver(&email("a@b.com", "x")).await;

        assert!(!delivery.ok);
        assert_eq!(delivery.reason.as_deref(), Some("The mail.example.com domain is not verified."));
    }

    #[tokio::test]
    async fn a_rate_limited_send_waits_and_is_retried() {
        let fake = FakeResend::start(vec![
            ("429 Too Many Requests", "retry-after: 0\r\n", r#"{"message":"Too many requests"}"#),
            ("200 OK", "", r#"{"id":"em_after_retry"}"#),
        ]);
        let delivery = Mailer::live("re_x", "n@mail.example.com", &fake.base).deliver(&email("a@b.com", "x")).await;

        assert_eq!(delivery, Delivery::sent("em_after_retry".to_string()));
        assert_eq!(fake.requests().len(), 2);
    }

    #[tokio::test]
    async fn an_unreachable_resend_is_a_failed_delivery_not_a_panic() {
        let unused = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", unused.local_addr().unwrap());
        drop(unused);

        let delivery = Mailer::live("re_x", "n@mail.example.com", &base).deliver(&email("a@b.com", "x")).await;

        assert!(!delivery.ok);
        assert!(delivery.reason.unwrap().starts_with("resend unreachable"));
    }
}
