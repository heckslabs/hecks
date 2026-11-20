// The cases both Stripe adapters are held to, run against a local stand-in for Stripe and no
// database: the requests each call makes, the mapping of each answer, and what the component is
// kept from (a host outside its grant, a call past its deadline, a key in anything it answers).

#![allow(clippy::unwrap_used)]

use super::component::committed;
use super::*;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use serde_json::json;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const KEY: &str = "rk_test_CASES_KEY_DO_NOT_LEAK";
const VERSION: &str = "2026-04-22.dahlia";

/// One request the stand-in received, as far as the two adapters must agree on it.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Seen {
    method: String,
    path: String,
    authorization: Option<String>,
    version: Option<String>,
    content_type: Option<String>,
    body: String,
}

#[derive(Clone)]
struct Script {
    status: u16,
    body: &'static str,
    delay: Duration,
    seen: Arc<Mutex<Vec<Seen>>>,
}

struct Fake {
    base: String,
    seen: Arc<Mutex<Vec<Seen>>>,
}

impl Fake {
    /// A stand-in that answers every request with `status` and `body`.
    async fn answering(status: u16, body: &'static str) -> Self {
        Self::slow(status, body, Duration::ZERO).await
    }

    /// The same, answering only after `delay`.
    async fn slow(status: u16, body: &'static str, delay: Duration) -> Self {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let script = Script {
            status,
            body,
            delay,
            seen: seen.clone(),
        };
        let app = axum::Router::new().fallback(answer).with_state(script);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        Self { base, seen }
    }

    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
}

async fn answer(
    State(script): State<Script>,
    request: axum::extract::Request,
) -> axum::response::Response {
    let (parts, body) = request.into_parts();
    let bytes = axum::body::to_bytes(body, 1 << 20).await.unwrap();
    let header = |name: &str| {
        parts
            .headers
            .get(name)
            .and_then(|value| value.to_str().ok())
            .map(String::from)
    };
    script.seen.lock().unwrap().push(Seen {
        method: parts.method.to_string(),
        path: parts.uri.path().to_string(),
        authorization: header("authorization"),
        version: header("stripe-version"),
        content_type: header("content-type"),
        body: String::from_utf8_lossy(&bytes).to_string(),
    });
    tokio::time::sleep(script.delay).await;
    (
        StatusCode::from_u16(script.status).unwrap(),
        script.body.to_string(),
    )
        .into_response()
}

/// A base URL on this machine that nothing listens on.
fn closed_port() -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    format!("http://{}", listener.local_addr().unwrap())
}

/// Both adapters, the component granted `base`'s host.
fn adapters(base: &str) -> [(&'static str, Stripe); 2] {
    [
        ("native", Stripe::Native),
        ("component", Stripe::committed(base)),
    ]
}

fn account(base: &str) -> Account<'_> {
    Account {
        base_url: base,
        api_key: KEY,
        api_version: Some(VERSION),
    }
}

fn webhook() -> WebhookRequest {
    WebhookRequest {
        url: "https://site.example/webhooks/stripe".to_string(),
        description: "Acme & Sons website".to_string(),
        events: vec![
            "checkout.session.completed".to_string(),
            "charge.refunded".to_string(),
        ],
    }
}

fn session() -> SessionRequest {
    SessionRequest {
        price_cents: 2500,
        currency: "usd".to_string(),
        product_name: "Yoga & Tea (évening) 100%".to_string(),
        registration_id: "REG-1".to_string(),
        expires_at: 1_700_001_860,
    }
}

fn account_word(answer: Result<Option<String>, AccountRefusal>) -> String {
    match answer {
        Ok(Some(name)) => format!("named {name}"),
        Ok(None) => "unnamed".to_string(),
        Err(AccountRefusal::KeyRefused) => "key-refused".to_string(),
        Err(AccountRefusal::Unreachable) => "unreachable".to_string(),
        Err(AccountRefusal::Declined) => "declined".to_string(),
    }
}

fn webhook_word(answer: Result<Endpoint, WebhookRefusal>) -> String {
    match answer {
        Ok(endpoint) => format!("{} {}", endpoint.id, endpoint.secret),
        Err(WebhookRefusal::Permission) => "permission".to_string(),
        Err(WebhookRefusal::Other) => "other".to_string(),
    }
}

fn session_word(answer: anyhow::Result<EmbeddedSession>) -> String {
    match answer {
        Ok(session) => format!("{} {}", session.session_id, session.client_secret),
        Err(err) => format!("{err:#}"),
    }
}

/// What every call answers against a stand-in that says `status` and `body`, per adapter.
async fn answers(status: u16, body: &'static str) -> Vec<[String; 4]> {
    let fake = Fake::answering(status, body).await;
    answers_at(&fake.base, &fake.base).await
}

/// The same with the component granted `granted`'s host and every call made to `base`.
async fn answers_at(granted: &str, base: &str) -> Vec<[String; 4]> {
    let mut all = Vec::new();
    for (_, stripe) in adapters(granted) {
        let account = account(base);
        all.push([
            account_word(stripe.read_account(&account).await),
            webhook_word(stripe.create_webhook(&account, webhook()).await),
            stripe.delete_webhook(&account, "we_1").await.to_string(),
            session_word(stripe.create_checkout_session(&account, session()).await),
        ]);
    }
    all
}

fn words(account: &str, webhook: &str, deleted: &str, session: &str) -> [String; 4] {
    [account, webhook, deleted, session].map(String::from)
}

#[test]
fn the_committed_component_is_the_one_its_digest_file_names() {
    assert_eq!(committed::digest(), committed::committed_digest());
}

#[tokio::test]
async fn both_adapters_send_the_same_requests() {
    let mut seen = Vec::new();
    for (_, stripe) in adapters("http://127.0.0.1") {
        let fake = Fake::answering(200, "{}").await;
        let account = account(&fake.base);
        let _ = stripe.read_account(&account).await;
        let _ = stripe.create_webhook(&account, webhook()).await;
        let _ = stripe.delete_webhook(&account, "we_9").await;
        let _ = stripe.create_checkout_session(&account, session()).await;
        seen.push(fake.seen());
    }
    assert_eq!(seen[0], seen[1]);
    let paths: Vec<_> = seen[1]
        .iter()
        .map(|r| format!("{} {}", r.method, r.path))
        .collect();
    assert_eq!(
        paths,
        [
            "GET /v1/account",
            "POST /v1/webhook_endpoints",
            "DELETE /v1/webhook_endpoints/we_9",
            "POST /v1/checkout/sessions"
        ]
    );
    for request in &seen[1] {
        assert_eq!(request.authorization, Some(format!("Bearer {KEY}")));
        assert_eq!(request.version.as_deref(), Some(VERSION));
    }
    assert_eq!(
        seen[1][1].body,
        "url=https%3A%2F%2Fsite.example%2Fwebhooks%2Fstripe&description=Acme+%26+Sons+website\
         &enabled_events%5B0%5D=checkout.session.completed&enabled_events%5B1%5D=charge.refunded"
    );
    assert_eq!(
        seen[1][1].content_type.as_deref(),
        Some("application/x-www-form-urlencoded")
    );
}

#[tokio::test]
async fn a_call_that_pins_no_version_sends_no_version_header() {
    for (which, stripe) in adapters("http://127.0.0.1") {
        let fake = Fake::answering(200, "{}").await;
        let unpinned = Account {
            api_version: None,
            ..account(&fake.base)
        };
        let _ = stripe.read_account(&unpinned).await;
        assert_eq!(fake.seen()[0].version, None, "{which}");
    }
}

#[tokio::test]
async fn both_adapters_read_the_same_answers() {
    let body = r#"{"id":"cs_1","client_secret":"cs_secret_1","secret":"whsec_1","email":"studio@example.com"}"#;
    let expected = words(
        "named studio@example.com",
        "cs_1 whsec_1",
        "true",
        "cs_1 cs_secret_1",
    );
    assert_eq!(answers(200, body).await, [expected.clone(), expected]);
}

#[tokio::test]
async fn an_answer_without_the_wanted_fields_is_refused_the_same_way() {
    let expected = words(
        "unnamed",
        "other",
        "true",
        "Stripe's response carried no \"id\" and \"client_secret\" for the embedded session",
    );
    assert_eq!(answers(200, "{}").await, [expected.clone(), expected]);
}

#[tokio::test]
async fn both_adapters_map_stripes_refusals_the_same_way() {
    let message = r#"{"error":{"message":"No such thing"}}"#;
    for (status, account, webhook, line) in [
        (401, "key-refused", "permission", "401 Unauthorized"),
        (403, "declined", "permission", "403 Forbidden"),
        (500, "declined", "other", "500 Internal Server Error"),
    ] {
        let session = format!("Stripe checkout session creation failed ({line}): No such thing");
        let expected = words(account, webhook, "false", &session);
        assert_eq!(
            answers(status, message).await,
            [expected.clone(), expected],
            "{status}"
        );
    }
}

#[tokio::test]
async fn an_unreachable_stripe_is_unreachable_to_both_and_no_answer_names_the_key() {
    let nowhere = closed_port();
    let all = answers_at(&nowhere, &nowhere).await;
    for answer in &all {
        assert_eq!(answer[..3], words("unreachable", "other", "false", "")[..3]);
        assert!(!answer[3].contains(KEY), "{}", answer[3]);
    }
}

#[tokio::test]
async fn the_component_reaches_no_host_but_the_one_it_is_granted() {
    let fake = Fake::answering(200, r#"{"id":"cs_1","client_secret":"s","secret":"w"}"#).await;
    let all = answers_at("http://localhost:1", &fake.base).await;
    assert_eq!(
        all[1],
        words(
            "unreachable",
            "other",
            "false",
            "Stripe unreachable: 127.0.0.1 is not granted"
        )
    );
    // Only the native adapter's four requests arrived.
    assert_eq!(fake.seen().len(), 4);
}

#[tokio::test]
async fn a_component_past_its_deadline_is_stripe_not_reached_and_names_no_key() {
    let fake = Fake::slow(200, "{}", Duration::from_millis(1500)).await;
    let mut wiring = committed::wiring(&fake.base);
    wiring.adapter.limits.deadline = Duration::from_millis(300);
    let stripe = Stripe::Component(wiring);
    let started = std::time::Instant::now();
    let account = account(&fake.base);
    assert_eq!(
        account_word(stripe.read_account(&account).await),
        "unreachable"
    );
    let refused = session_word(stripe.create_checkout_session(&account, session()).await);
    assert!(
        refused.starts_with("stripe component failed: "),
        "{refused}"
    );
    assert!(!refused.contains(KEY), "{refused}");
    assert!(started.elapsed() < Duration::from_secs(10));
}

fn ir(sha256: &str, hosts: &[&str]) -> Value {
    json!({ "components": [{
        "adapter": "Stripe", "port": "payments", "verb": "charged_by", "runs": "stripe.wasm",
        "sha256": sha256, "module": committed::base64_of(committed::MODULE),
        "secrets": [], "imports": ["http_out"], "hosts": hosts,
    }]})
}

#[test]
fn an_ir_that_wires_no_payments_component_is_answered_natively() {
    assert!(matches!(Stripe::wired(None), Ok(Stripe::Native)));
    assert!(matches!(
        Stripe::wired(Some(&json!({"components": []}))),
        Ok(Stripe::Native)
    ));
}

#[test]
fn an_ir_that_wires_the_stripe_component_is_answered_by_it() {
    let ir = ir(&committed::digest(), &["api.stripe.com"]);
    assert!(matches!(Stripe::wired(Some(&ir)), Ok(Stripe::Component(_))));
}

#[test]
fn a_wired_component_the_host_cannot_use_is_refused_by_name() {
    let unreaching = ir(&committed::digest(), &["example.com"]);
    assert_eq!(
        Stripe::wired(Some(&unreaching)).err().as_deref(),
        Some("Stripe's grant does not name api.stripe.com, where Stripe is reached")
    );
    let wrong_digest = ir(&"1".repeat(64), &["api.stripe.com"]);
    assert_eq!(
        Stripe::wired(Some(&wrong_digest)).err().as_deref(),
        Some("Stripe's module does not match its digest")
    );
}
