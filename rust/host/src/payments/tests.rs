// Route-level tests for payments.rs and the checkout/webhook behavior that
// depends on the tenant's connection. Real Postgres and the compiled
// checkout_fixture wasm (which carries a trimmed PaymentConnection), no
// external network: every Stripe call goes to a recording server on 127.0.0.1
// that answers like Stripe, so the requests the host really sent (bearer key,
// `Stripe-Account` header, form fields) can be asserted on.

use super::*;
use crate::dispatch::tests::{provision_lineage, scratch_db};
use crate::lambda_client::NeverInvoker;
use crate::web;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

const SESSION_SECRET: &str = "s3cret";
const PLATFORM_KEY: &str = "sk_test_PLATFORM_KEY_DO_NOT_LEAK";
const PUBLISHABLE_KEY: &str = "pk_test_PLATFORM_PUBLISHABLE";
const TENANT_ACCESS_TOKEN: &str = "sk_test_TENANT_ACCESS_TOKEN_DO_NOT_STORE";
const TENANT_ACCOUNT: &str = "acct_tenant_1";
const WEBHOOK_SECRET: &str = "whsec_platform_connect";

const OWNER: &str = "owner@example.com";
const ADMIN: &str = "admin@example.com";
const OPERATOR: &str = "operator@example.com";
const DISABLED_OWNER: &str = "gone@example.com";

// ---- a recording Stripe --------------------------------------------------

#[derive(Clone, Debug)]
struct Recorded {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: String,
}

impl Recorded {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name).map(String::as_str)
    }
}

struct FakeState {
    requests: StdMutex<Vec<Recorded>>,
    livemode: AtomicBool,
    refuse_deauthorize: AtomicBool,
    refuse_sessions: AtomicBool,
}

struct FakeStripe {
    base: String,
    state: Arc<FakeState>,
}

impl FakeStripe {
    async fn start() -> Self {
        let state = Arc::new(FakeState { requests: StdMutex::new(Vec::new()), livemode: AtomicBool::new(false), refuse_deauthorize: AtomicBool::new(false), refuse_sessions: AtomicBool::new(false) });
        let app = axum::Router::new().fallback(answer).with_state(state.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("bind a local port");
        let base = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        Self { base, state }
    }

    fn requests(&self) -> Vec<Recorded> {
        self.state.requests.lock().unwrap().clone()
    }

    fn requests_to(&self, path: &str) -> Vec<Recorded> {
        self.requests().into_iter().filter(|r| r.path == path).collect()
    }
}

async fn answer(State(state): State<Arc<FakeState>>, request: axum::extract::Request) -> axum::response::Response {
    let (parts, body) = request.into_parts();
    let bytes = axum::body::to_bytes(body, 1 << 20).await.unwrap();
    let recorded = Recorded {
        method: parts.method.to_string(),
        path: parts.uri.path().to_string(),
        headers: parts.headers.iter().map(|(k, v)| (k.as_str().to_string(), v.to_str().unwrap_or("").to_string())).collect(),
        body: String::from_utf8_lossy(&bytes).to_string(),
    };
    let path = recorded.path.clone();
    let method = recorded.method.clone();
    state.requests.lock().unwrap().push(recorded);

    let (status, reply) = match (method.as_str(), path.as_str()) {
        ("POST", "/oauth/token") => (
            StatusCode::OK,
            json!({"stripe_user_id": TENANT_ACCOUNT, "livemode": state.livemode.load(Ordering::SeqCst),
                   "access_token": TENANT_ACCESS_TOKEN, "refresh_token": "rt_TENANT_REFRESH_TOKEN"}),
        ),
        ("POST", "/oauth/deauthorize") if state.refuse_deauthorize.load(Ordering::SeqCst) => {
            (StatusCode::BAD_REQUEST, json!({"error": "invalid_client", "error_description": "no such client"}))
        }
        ("POST", "/oauth/deauthorize") => (StatusCode::OK, json!({"stripe_user_id": TENANT_ACCOUNT})),
        ("GET", p) if p.starts_with("/v1/accounts/") => (StatusCode::OK, json!({"id": TENANT_ACCOUNT, "business_profile": {"name": "Yoga Collective"}})),
        ("POST", "/v1/checkout/sessions") if state.refuse_sessions.load(Ordering::SeqCst) => {
            (StatusCode::BAD_REQUEST, json!({"error": {"message": "no such price"}}))
        }
        // An embedded session: Stripe answers with a client secret for the
        // browser and no hosted `url`.
        ("POST", "/v1/checkout/sessions") => (StatusCode::OK, json!({"id": "cs_test_1", "ui_mode": "embedded_page", "client_secret": "cs_test_1_secret_CLIENT"})),
        _ => (StatusCode::NOT_FOUND, json!({"error": {"message": "no such fake route"}})),
    };
    (status, axum::Json(reply)).into_response()
}

// ---- a tenant: Postgres, the wasm, and a membership --------------------------

struct Tenant {
    client: Mutex<Client>,
    domain_ir: Value,
    config: LineageConfig,
    wasm: std::path::PathBuf,
    fake: FakeStripe,
    platform: PlatformConfig,
}

async fn tenant(name: &str) -> Tenant {
    let client = scratch_db(name).await;
    {
        let guard = client.lock().await;
        provision_lineage(&guard, "CheckoutFixture", 1, &["Event", "Registration", "Payment", "PaymentConnection"]).await;
        guard
            .batch_execute(
                "CREATE TABLE embryonaut_member_head_snapshot_1 (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL);
                 CREATE VIEW embryonaut_member_head AS SELECT id, state FROM embryonaut_member_head_snapshot_1;
                 CREATE TABLE hecks_journal_embryonaut (
                     ordinal bigserial PRIMARY KEY, era int NOT NULL, aggregate text NOT NULL,
                     aggregate_id text NOT NULL, operation text NOT NULL, state jsonb, mirrors jsonb
                 );",
            )
            .await
            .unwrap();
        let person = |email: &str, role: Option<&str>, disabled: bool| {
            let mut state = json!({"name": {"value": email}, "email": {"value": email}, "role": role.map(|r| json!({"value": r}))});
            if disabled {
                state["disabled"] = json!(true);
            }
            state
        };
        for (email, state) in [
            (OWNER, person(OWNER, Some("Owner"), false)),
            (ADMIN, person(ADMIN, Some("Admin"), false)),
            (OPERATOR, person(OPERATOR, Some("Admin"), false)),
            (DISABLED_OWNER, person(DISABLED_OWNER, Some("Owner"), true)),
        ] {
            guard
                .execute("INSERT INTO embryonaut_member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 0, $2::jsonb)", &[&email, &state])
                .await
                .unwrap();
        }
    }
    let domain_ir = json!({
        "name": "Embryonaut",
        "lineage": {"capable_aggregates": [{"name": "Member", "storage_name": "member"}]},
        "membership": {"provider": "Embryonaut", "aggregate": "Embryonaut::Member"},
    });
    let fake = FakeStripe::start().await;
    let platform = PlatformConfig {
        site_url: "https://site.example".to_string(),
        api_base: fake.base.clone(),
        connect_base: fake.base.clone(),
        test_key: PLATFORM_KEY.to_string(),
        live_key: String::new(),
        test_publishable_key: PUBLISHABLE_KEY.to_string(),
        live_publishable_key: String::new(),
        test_client_id: "ca_test_CLIENT".to_string(),
        live_client_id: String::new(),
        webhook_secret: Some(WEBHOOK_SECRET.to_string()),
        operators: vec![OPERATOR.to_string()],
    };
    Tenant {
        client,
        domain_ir,
        config: LineageConfig { domain: "CheckoutFixture".to_string(), era: Some(1), mirrored: None },
        wasm: std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/checkout_fixture.wasm"),
        fake,
        platform,
    }
}

impl Tenant {
    // One request against the payments routes; `None` means no session cookie.
    async fn call(&self, method: &str, path: &str, body: Value, as_email: Option<&str>) -> (u64, Value) {
        let mut cookies = HashMap::new();
        if let Some(email) = as_email {
            cookies.insert("lifeadelics_session".to_string(), auth::account_token(SESSION_SECRET, email, 60));
        }
        let response = route(method, path, &body.to_string(), &cookies, SESSION_SECRET, &self.domain_ir, &self.platform, &self.client, &self.wasm, &self.config, &NeverInvoker)
            .await
            .expect("a payments path");
        (response["statusCode"].as_u64().unwrap(), serde_json::from_str(response["body"].as_str().unwrap()).unwrap_or(Value::Null))
    }

    async fn status(&self) -> String {
        let read = dispatch::read(&self.client, &self.wasm).await.unwrap();
        connection(&read, &self.config.domain).map(|c| c.status).unwrap_or_else(|| "none".to_string())
    }

    // Owner connects the tenant's test-mode Stripe account end to end.
    async fn connect(&self) {
        let (status, body) = self.call("POST", "/payments/connection/authorize-url", json!({"processor": "stripe", "mode": "test"}), Some(OWNER)).await;
        assert_eq!(status, 200, "{body}");
        let url = reqwest::Url::parse(body["url"].as_str().unwrap()).unwrap();
        let state = url.query_pairs().find(|(k, _)| k == "state").unwrap().1.to_string();
        let (status, body) = self.call("POST", "/payments/connection/callback", json!({"code": "ac_code", "state": state}), Some(OWNER)).await;
        assert_eq!(status, 200, "{body}");
    }

    // Every row of every table in the scratch database, as text.
    async fn dump_database(&self) -> String {
        let guard = self.client.lock().await;
        let tables = guard.query("SELECT tablename FROM pg_tables WHERE schemaname = 'public'", &[]).await.unwrap();
        let mut dump = String::new();
        for table in tables {
            let name: String = table.get(0);
            for row in guard.query(&format!("SELECT t::text FROM \"{name}\" t"), &[]).await.unwrap() {
                dump.push_str(&row.get::<_, String>(0));
                dump.push('\n');
            }
        }
        dump
    }

    async fn enable(&self) {
        let (status, body) = self.call("POST", "/payments/connection/enable", json!({}), Some(OPERATOR)).await;
        assert_eq!(status, 200, "{body}");
    }

    async fn schedule_event(&self, slug: &str) {
        self.schedule_event_with_capacity(slug, 20).await;
    }

    async fn schedule_event_with_capacity(&self, slug: &str, capacity: i64) {
        let args = json!({"slug": {"value": slug}, "name": {"value": "Yogadelics"}, "price": {"cents": 4200}, "capacity": {"value": capacity}});
        let outcome = dispatch::handle(&self.client, &self.wasm, "CheckoutFixture::Event.Schedule", args, None, &self.config, &NeverInvoker).await.unwrap();
        assert!(outcome.accepted, "{:?}", outcome.result);
    }

    // POST /registrations for `slug`; the checkout URL and registration id on success.
    async fn register(&self, slug: &str) -> (u64, Value) {
        let body = json!({"event_slug": slug, "name": "Ada Lovelace", "email": "ada@example.com"}).to_string();
        let response = web::registrations_route(&body, &self.platform, &self.client, &self.wasm, &self.config, &NeverInvoker, &crate::ir::fixture_payments()).await;
        (response["statusCode"].as_u64().unwrap(), serde_json::from_str(response["body"].as_str().unwrap()).unwrap_or(Value::Null))
    }

    async fn webhook(&self, event: Value) -> u64 {
        let payload = event.to_string();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        let header = sign(WEBHOOK_SECRET, now, &payload);
        let response = web::webhook_route(&payload, &header, &self.platform, &self.client, &self.wasm, &self.config, &NeverInvoker, &crate::ir::fixture_payments()).await;
        response["statusCode"].as_u64().unwrap()
    }

    // POST /registrations/:id/complete with a successful outcome (the mock
    // walkthrough's "Pay" button).
    async fn settle(&self, reference: &str) -> u64 {
        let response = web::registration_complete_route(reference, r#"{"outcome":"succeeded"}"#, &self.client, &self.wasm, &self.config, &NeverInvoker, &crate::ir::fixture_payments()).await;
        response["statusCode"].as_u64().unwrap()
    }

    async fn payment_status(&self, reference: &str) -> String {
        let read = dispatch::read(&self.client, &self.wasm).await.unwrap();
        read["instances"][format!("Payments::Payment#{reference}")]["status"].as_str().unwrap_or("none").to_string()
    }
}

fn sign(secret: &str, now: i64, payload: &str) -> String {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
    mac.update(format!("{now}.{payload}").as_bytes());
    format!("t={now},v1={}", mac.finalize().into_bytes().iter().map(|b| format!("{b:02x}")).collect::<String>())
}

fn completed(reference: &str, account: Option<&str>) -> Value {
    let mut event = json!({"type": "checkout.session.completed", "data": {"object": {"id": "cs_test_1", "metadata": {"registration_id": reference}}}});
    if let Some(account) = account {
        event["account"] = json!(account);
    }
    event
}

fn expired(reference: &str, account: &str) -> Value {
    json!({"type": "checkout.session.expired", "account": account, "data": {"object": {"id": "cs_test_1", "metadata": {"registration_id": reference}}}})
}

// ---- access: who may see and do what ----------------------------------------

#[tokio::test]
async fn every_route_refuses_a_missing_session_with_a_json_401_and_touches_nothing() {
    let t = tenant("hecks_pay_test_401").await;
    for (method, path) in [
        ("GET", "/payments/connection"),
        ("POST", "/payments/connection/authorize-url"),
        ("POST", "/payments/connection/callback"),
        ("POST", "/payments/connection/disconnect"),
        ("POST", "/payments/connection/enable"),
        ("POST", "/payments/connection/disable"),
    ] {
        let (status, body) = t.call(method, path, json!({}), None).await;
        assert_eq!((status, body["error"].as_str()), (401, Some("not logged in")), "{method} {path}");
    }
    assert!(t.fake.requests().is_empty(), "no Stripe call without a session");
    assert_eq!(t.status().await, "none");
}

#[tokio::test]
async fn a_tampered_or_disabled_session_is_a_401_not_an_owner() {
    let t = tenant("hecks_pay_test_401_disabled").await;
    let mut cookies = HashMap::new();
    cookies.insert("lifeadelics_session".to_string(), "garbage.notasignature".to_string());
    let response = route("GET", "/payments/connection", "", &cookies, SESSION_SECRET, &t.domain_ir, &t.platform, &t.client, &t.wasm, &t.config, &NeverInvoker).await.unwrap();
    assert_eq!(response["statusCode"], 401);

    // An Owner who has since been disabled: the cookie is still validly signed.
    let (status, _) = t.call("GET", "/payments/connection", json!({}), Some(DISABLED_OWNER)).await;
    assert_eq!(status, 401);
    let (status, _) = t.call("POST", "/payments/connection/authorize-url", json!({"processor": "stripe", "mode": "test"}), Some(DISABLED_OWNER)).await;
    assert_eq!(status, 401);
}

#[tokio::test]
async fn only_an_owner_may_connect_or_disconnect_and_only_the_operator_may_enable() {
    let t = tenant("hecks_pay_test_roles").await;

    // A non-Owner admin: read refused, every owner action refused.
    let (status, _) = t.call("GET", "/payments/connection", json!({}), Some(ADMIN)).await;
    assert_eq!(status, 403);
    for path in ["/payments/connection/authorize-url", "/payments/connection/callback", "/payments/connection/disconnect"] {
        let (status, body) = t.call("POST", path, json!({"processor": "stripe", "mode": "test", "code": "c", "state": "s"}), Some(ADMIN)).await;
        assert_eq!((status, body["error"].as_str()), (403, Some("only an Owner can manage payments")), "{path}");
    }

    t.connect().await;
    assert_eq!(t.status().await, "connected");

    // The Owner is not the operator: enable and disable are refused.
    for path in ["/payments/connection/enable", "/payments/connection/disable"] {
        let (status, _) = t.call("POST", path, json!({}), Some(OWNER)).await;
        assert_eq!(status, 403, "{path}");
    }
    // The operator is not an Owner: cannot disconnect.
    let (status, _) = t.call("POST", "/payments/connection/disconnect", json!({}), Some(OPERATOR)).await;
    assert_eq!(status, 403);
    assert_eq!(t.status().await, "connected", "nothing above changed the connection");

    // ...but the operator may read the page state, and enable.
    let (status, body) = t.call("GET", "/payments/connection", json!({}), Some(OPERATOR)).await;
    assert_eq!(status, 200);
    assert_eq!((body["can_manage"].clone(), body["can_enable"].clone()), (json!(false), json!(true)));
    t.enable().await;
    assert_eq!(t.status().await, "enabled");
}

#[tokio::test]
async fn an_admin_granted_owner_passes_the_payments_gate_and_keeps_the_admin_gate() {
    let t = tenant("hecks_pay_test_owner_bootstrap").await;
    let members = LineageConfig { domain: "Embryonaut".to_string(), era: Some(1), mirrored: None };
    let cookies = |email: &str| HashMap::from([("lifeadelics_session".to_string(), auth::account_token(SESSION_SECRET, email, 60))]);

    // An Admin is not an Owner: the payments routes refuse them.
    let (status, _) = t.call("GET", "/payments/connection", json!({}), Some(ADMIN)).await;
    assert_eq!(status, 403);

    // An Admin grants Owner to a new person; that person passes the Payments
    // Owner gate and is still admitted by the members admin gate.
    let body = json!({"email": "boss@example.com", "name": "Boss", "role": "Owner"}).to_string();
    let response = web::add_member_route(&t.domain_ir, &body, &cookies(ADMIN), SESSION_SECRET, &t.client, &t.wasm, &members).await;
    assert_eq!(response["statusCode"], 201, "{response:?}");
    let (status, body) = t.call("GET", "/payments/connection", json!({}), Some("boss@example.com")).await;
    assert_eq!((status, body["can_manage"].clone()), (200, json!(true)), "{body}");
    let response = web::add_member_route(&t.domain_ir, r#"{"email": "next@example.com", "name": "Next"}"#, &cookies("boss@example.com"), SESSION_SECRET, &t.client, &t.wasm, &members).await;
    assert_eq!(response["statusCode"], 201, "{response:?}");

    // Granting Owner to an existing Admin turns them into an Owner too.
    assert!(auth::grant_access(&t.client, &t.wasm, &members, &t.domain_ir, ADMIN, "Owner").await.unwrap());
    let (status, body) = t.call("GET", "/payments/connection", json!({}), Some(ADMIN)).await;
    assert_eq!((status, body["can_manage"].clone()), (200, json!(true)), "{body}");
    assert!(auth::caller_is_admin(&t.client, &t.domain_ir, ADMIN).await.unwrap());
}

// ---- connecting -------------------------------------------------------------

#[tokio::test]
async fn the_status_route_reports_not_connected_and_which_processors_can_be_offered() {
    let t = tenant("hecks_pay_test_status_empty").await;
    let (status, body) = t.call("GET", "/payments/connection", json!({}), Some(OWNER)).await;
    assert_eq!(status, 200);
    assert_eq!(body["status"], "not_connected");
    assert_eq!(body["processor"], Value::Null);
    assert_eq!(body["adapters"], json!([{"processor": "stripe", "label": "Stripe", "modes": ["test"]}]));
    assert_eq!((body["can_manage"].clone(), body["can_enable"].clone()), (json!(true), json!(false)));

    // With no platform credentials at all, nothing is offered.
    let mut bare = tenant("hecks_pay_test_status_bare").await;
    bare.platform.test_key = String::new();
    let (_, body) = bare.call("GET", "/payments/connection", json!({}), Some(OWNER)).await;
    assert_eq!(body["adapters"], json!([]));
}

#[tokio::test]
async fn authorize_url_sends_the_owner_to_stripe_with_a_signed_state_bound_to_them() {
    let t = tenant("hecks_pay_test_authorize").await;
    let (status, body) = t.call("POST", "/payments/connection/authorize-url", json!({"processor": "stripe", "mode": "test"}), Some(OWNER)).await;
    assert_eq!(status, 200, "{body}");
    let url = reqwest::Url::parse(body["url"].as_str().unwrap()).unwrap();
    assert_eq!(url.path(), "/oauth/authorize");
    let query: HashMap<String, String> = url.query_pairs().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    assert_eq!(query["client_id"], "ca_test_CLIENT");
    assert_eq!(query["response_type"], "code");
    assert_eq!(query["scope"], "read_write");
    assert_eq!(query["redirect_uri"], "https://site.example/api/payment-connect-callback");

    let claims = auth::verify_purpose_token(SESSION_SECRET, STATE_PURPOSE, &query["state"]).expect("a valid state");
    assert_eq!((claims["email"].as_str(), claims["mode"].as_str()), (Some(OWNER), Some("test")));
    assert!(auth::verify_account_token(SESSION_SECRET, &query["state"]).is_none(), "a connect state must never pass as a session cookie");
    assert!(!body.to_string().contains(PLATFORM_KEY), "the platform key never appears in a response");
    assert!(t.fake.requests().is_empty(), "building the URL asks Stripe nothing");
}

#[tokio::test]
async fn authorize_url_refuses_an_unknown_processor_an_unconfigured_mode_and_a_missing_field() {
    let t = tenant("hecks_pay_test_authorize_refusals").await;
    let post = |body: Value| t.call("POST", "/payments/connection/authorize-url", body, Some(OWNER));
    assert_eq!(post(json!({"processor": "mock", "mode": "test"})).await.0, 422);
    assert_eq!(post(json!({"processor": "paypal", "mode": "test"})).await.0, 422);
    let (status, body) = post(json!({"processor": "stripe", "mode": "live"})).await;
    assert_eq!((status, body["error"].as_str()), (422, Some("Stripe is not set up for live mode")));
    assert_eq!(post(json!({"mode": "test"})).await.0, 400);
    assert_eq!(post(json!({"processor": "stripe"})).await.0, 400);
}

#[tokio::test]
async fn the_callback_stores_only_public_facts_and_never_a_credential() {
    let t = tenant("hecks_pay_test_callback").await;
    t.connect().await;

    let (status, body) = t.call("GET", "/payments/connection", json!({}), Some(OWNER)).await;
    assert_eq!(status, 200);
    assert_eq!(body["status"], "connected");
    assert_eq!(body["processor"], "stripe");
    assert_eq!(body["label"], "Stripe");
    assert_eq!(body["account_ref"], TENANT_ACCOUNT);
    assert_eq!(body["mode"], "test");
    assert_eq!(body["display_name"], "Yoga Collective");

    // What Stripe was asked: the code traded with the platform's own key, no
    // connected-account header on the platform-level exchange.
    let token = t.fake.requests_to("/oauth/token");
    assert_eq!(token.len(), 1);
    assert_eq!(token[0].header("authorization"), Some(format!("Bearer {PLATFORM_KEY}").as_str()));
    assert!(token[0].body.contains("grant_type=authorization_code") && token[0].body.contains("code=ac_code"), "{}", token[0].body);
    assert_eq!(token[0].header("stripe-account"), None);

    // Neither the platform key nor anything Stripe handed back is anywhere:
    // not in a response, not in the stored aggregate, not in the journal.
    let stored = t.dump_database().await;
    assert!(stored.contains(TENANT_ACCOUNT), "the public account id is what is stored");
    let read = dispatch::read(&t.client, &t.wasm).await.unwrap().to_string();
    for text in [body.to_string(), stored, read] {
        for secret in [PLATFORM_KEY, TENANT_ACCESS_TOKEN, "rt_TENANT_REFRESH_TOKEN", WEBHOOK_SECRET] {
            assert!(!text.contains(secret), "{secret} leaked into {text}");
        }
    }
}

#[tokio::test]
async fn the_callback_refuses_a_bad_expired_or_someone_elses_state() {
    let t = tenant("hecks_pay_test_callback_state").await;
    let call = |state: String| t.call("POST", "/payments/connection/callback", json!({"code": "c", "state": state}), Some(OWNER));

    let (status, body) = call("nonsense".to_string()).await;
    assert_eq!((status, body["error"].as_str()), (400, Some("this connection attempt expired — start again")));

    // A state minted for a different person, and one for a different purpose.
    let other = auth::purpose_token(SESSION_SECRET, STATE_PURPOSE, json!({"email": ADMIN, "processor": "stripe", "mode": "test"}), 60);
    assert_eq!(call(other).await.0, 400);
    let wrong_purpose = auth::purpose_token(SESSION_SECRET, "something_else", json!({"email": OWNER, "processor": "stripe", "mode": "test"}), 60);
    assert_eq!(call(wrong_purpose).await.0, 400);
    let session_as_state = auth::account_token(SESSION_SECRET, OWNER, 60);
    assert_eq!(call(session_as_state).await.0, 400);

    assert!(t.fake.requests().is_empty(), "a refused state never reaches Stripe");
    assert_eq!(t.status().await, "none");
}

#[tokio::test]
async fn the_callback_refuses_an_account_in_the_other_mode_and_a_second_connection() {
    let t = tenant("hecks_pay_test_callback_conflict").await;
    let state = || auth::purpose_token(SESSION_SECRET, STATE_PURPOSE, json!({"email": OWNER, "processor": "stripe", "mode": "test"}), 60);

    t.fake.state.livemode.store(true, Ordering::SeqCst);
    let (status, body) = t.call("POST", "/payments/connection/callback", json!({"code": "c", "state": state()}), Some(OWNER)).await;
    assert_eq!(status, 422);
    assert!(body["error"].as_str().unwrap().contains("authorized a live account but test was requested"), "{body}");
    assert_eq!(t.status().await, "none");

    t.fake.state.livemode.store(false, Ordering::SeqCst);
    t.connect().await;
    let (status, body) = t.call("POST", "/payments/connection/callback", json!({"code": "c", "state": state()}), Some(OWNER)).await;
    assert_eq!((status, body["error"].as_str()), (409, Some("an account is already connected — disconnect it first")));
}

// ---- enabling, disconnecting, reconnecting ------------------------------------

#[tokio::test]
async fn enable_needs_a_connection_and_follows_the_lifecycle() {
    let t = tenant("hecks_pay_test_enable").await;
    let (status, body) = t.call("POST", "/payments/connection/enable", json!({}), Some(OPERATOR)).await;
    assert_eq!((status, body["error"].as_str()), (409, Some("connect an account first")));

    t.connect().await;
    let (status, body) = t.call("POST", "/payments/connection/disable", json!({}), Some(OPERATOR)).await;
    assert_eq!(status, 422, "disable is refused unless payments are enabled: {body}");

    t.enable().await;
    let (status, body) = t.call("GET", "/payments/connection", json!({}), Some(OWNER)).await;
    assert_eq!((status, body["status"].as_str()), (200, Some("enabled")));
    let (status, _) = t.call("POST", "/payments/connection/enable", json!({}), Some(OPERATOR)).await;
    assert_eq!(status, 422, "enable is refused when already enabled");

    let (status, body) = t.call("POST", "/payments/connection/disable", json!({}), Some(OPERATOR)).await;
    assert_eq!((status, body["status"].as_str()), (200, Some("connected")));
}

#[tokio::test]
async fn disconnecting_a_not_yet_enabled_account_unlinks_it_and_it_can_be_reconnected() {
    let t = tenant("hecks_pay_test_disconnect").await;
    let (status, body) = t.call("POST", "/payments/connection/disconnect", json!({}), Some(OWNER)).await;
    assert_eq!((status, body["error"].as_str()), (409, Some("nothing to disconnect")));

    t.connect().await;
    let (status, body) = t.call("POST", "/payments/connection/disconnect", json!({}), Some(OWNER)).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!((body["status"].as_str(), body["remote_disconnected"].clone()), (Some("disconnected"), json!(true)));

    let revoked = t.fake.requests_to("/oauth/deauthorize");
    assert_eq!(revoked.len(), 1);
    assert_eq!(revoked[0].header("authorization"), Some(format!("Bearer {PLATFORM_KEY}").as_str()));
    assert!(revoked[0].body.contains("client_id=ca_test_CLIENT") && revoked[0].body.contains(&format!("stripe_user_id={TENANT_ACCOUNT}")), "{}", revoked[0].body);

    t.connect().await;
    assert_eq!(t.status().await, "connected", "a disconnected link reconnects");
}

#[tokio::test]
async fn disconnecting_while_payments_are_enabled_pauses_them_and_a_dead_stripe_does_not_block_it() {
    let t = tenant("hecks_pay_test_disconnect_enabled").await;
    t.connect().await;
    t.enable().await;

    t.fake.state.refuse_deauthorize.store(true, Ordering::SeqCst);
    let (status, body) = t.call("POST", "/payments/connection/disconnect", json!({}), Some(OWNER)).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!((body["status"].as_str(), body["remote_disconnected"].clone()), (Some("paused"), json!(false)));

    // Paused is not disconnected: it cannot be disconnected again, and a new
    // connection resumes it instead of starting over.
    let (status, _) = t.call("POST", "/payments/connection/disconnect", json!({}), Some(OWNER)).await;
    assert_eq!(status, 409);
    t.fake.state.refuse_deauthorize.store(false, Ordering::SeqCst);
    t.connect().await;
    assert_eq!(t.status().await, "enabled", "reconnecting a paused connection resumes it");
}

// ---- checkout -------------------------------------------------------------------

#[tokio::test]
async fn checkout_stays_on_the_mock_until_payments_are_enabled() {
    let t = tenant("hecks_pay_test_checkout_mock").await;
    t.schedule_event("mock-event").await;

    // No connection at all.
    let (status, body) = t.register("mock-event").await;
    assert_eq!(status, 200, "{body}");
    assert!(body["checkout_url"].as_str().unwrap().starts_with("https://site.example/pay/"), "{body}");

    // Connected but not enabled: still the mock.
    t.connect().await;
    let (status, body) = t.register("mock-event").await;
    assert_eq!(status, 200, "{body}");
    assert!(body["checkout_url"].as_str().unwrap().starts_with("https://site.example/pay/"), "{body}");
    assert!(t.fake.requests_to("/v1/checkout/sessions").is_empty(), "the mock never calls Stripe");

    let read = dispatch::read(&t.client, &t.wasm).await.unwrap();
    let processors: Vec<String> = instances_for(&read, "Payments::Payment#").iter().map(|(_, p)| p["processor"]["value"].as_str().unwrap().to_string()).collect();
    assert_eq!(processors, vec!["mock_stripe", "mock_stripe"]);
}

#[tokio::test]
async fn an_enabled_connection_charges_on_the_tenants_own_account() {
    let t = tenant("hecks_pay_test_checkout_stripe").await;
    t.schedule_event("real-event").await;
    t.connect().await;
    t.enable().await;

    let (status, body) = t.register("real-event").await;
    assert_eq!(status, 200, "{body}");
    // The guest pays in a form embedded in the site: what the browser needs to
    // mount it, and no hosted page to send them to.
    assert_eq!(body.get("checkout_url"), None, "nothing leaves the site: {body}");
    assert_eq!(
        body["embedded_checkout"],
        json!({
            "client_secret": "cs_test_1_secret_CLIENT",
            "publishable_key": PUBLISHABLE_KEY,
            "stripe_account": TENANT_ACCOUNT,
            "session_id": "cs_test_1",
        })
    );
    let reference = body["registration_id"].as_str().unwrap();

    let sent = t.fake.requests_to("/v1/checkout/sessions");
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].header("stripe-account"), Some(TENANT_ACCOUNT), "a direct charge names the tenant's account");
    assert_eq!(sent[0].header("authorization"), Some(format!("Bearer {PLATFORM_KEY}").as_str()), "authenticated with the platform's key");
    assert_eq!(sent[0].header("stripe-version"), Some("2026-04-22.dahlia"), "pinned, not the platform account's default");
    assert!(sent[0].body.contains(&format!("metadata%5Bregistration_id%5D={reference}")), "{}", sent[0].body);
    assert!(sent[0].body.contains("unit_amount%5D=4200"), "{}", sent[0].body);
    assert!(sent[0].body.contains("ui_mode=embedded_page"), "an embedded session, not a hosted one: {}", sent[0].body);
    assert!(sent[0].body.contains("redirect_on_completion=never"), "{}", sent[0].body);
    assert!(!sent[0].body.contains("success_url") && !sent[0].body.contains("cancel_url"), "no return pages exist: {}", sent[0].body);

    let read = dispatch::read(&t.client, &t.wasm).await.unwrap();
    assert_eq!(read["instances"][format!("Payments::Payment#{reference}")]["processor"]["value"], "stripe");
}

#[tokio::test]
async fn a_stripe_refusal_answers_502_and_leaves_no_payment_or_registration_behind() {
    let t = tenant("hecks_pay_test_checkout_stripe_refuses").await;
    t.schedule_event("refused-event").await;
    t.connect().await;
    t.enable().await;
    t.fake.state.refuse_sessions.store(true, Ordering::SeqCst);

    let (status, body) = t.register("refused-event").await;
    assert_eq!((status, body["error"].as_str()), (502, Some("payments are temporarily unavailable")));
    assert_eq!(body.get("checkout_url"), None);
    assert_eq!(body.get("embedded_checkout"), None);
    assert!(!body.to_string().contains("no such price"), "Stripe's own wording stays in the log: {body}");
    assert_eq!(t.fake.requests_to("/v1/checkout/sessions").len(), 1, "the session was attempted");

    // The session is opened first, so nothing was recorded for the failed try.
    let read = dispatch::read(&t.client, &t.wasm).await.unwrap();
    assert!(instances_for(&read, "Payments::Payment#").is_empty(), "no orphaned Payment");
    assert!(instances_for(&read, "CheckoutFixture::Registration#").is_empty(), "no pending Registration");

    // Once Stripe recovers a retry registers normally.
    t.fake.state.refuse_sessions.store(false, Ordering::SeqCst);
    let (status, body) = t.register("refused-event").await;
    assert_eq!(status, 200, "{body}");
    let read = dispatch::read(&t.client, &t.wasm).await.unwrap();
    assert_eq!(instances_for(&read, "Payments::Payment#").len(), 1);
    assert_eq!(instances_for(&read, "CheckoutFixture::Registration#").len(), 1);
}

// ---- capacity: a full event refuses, an unpaid checkout holds a seat -------------

fn unix_secs() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64
}

#[tokio::test]
async fn a_full_event_answers_409_and_writes_nothing_and_calls_no_stripe() {
    let t = tenant("hecks_pay_test_capacity_full").await;
    t.schedule_event_with_capacity("one-seat", 1).await;
    t.connect().await;
    t.enable().await;

    let (status, body) = t.register("one-seat").await;
    assert_eq!(status, 200, "{body}");
    let sessions = t.fake.requests_to("/v1/checkout/sessions").len();

    let (status, body) = t.register("one-seat").await;
    assert_eq!((status, body["error"].as_str()), (409, Some("this event is full")));
    assert_eq!(body.get("embedded_checkout"), None);
    assert_eq!(t.fake.requests_to("/v1/checkout/sessions").len(), sessions, "no session is opened for a full event");
    let read = dispatch::read(&t.client, &t.wasm).await.unwrap();
    assert_eq!(instances_for(&read, "Payments::Payment#").len(), 1, "no second Payment");
    assert_eq!(instances_for(&read, "CheckoutFixture::Registration#").len(), 1, "no second Registration");
}

#[tokio::test]
async fn the_last_seat_goes_through_the_mock_walkthrough_and_the_next_attempt_is_409() {
    let t = tenant("hecks_pay_test_capacity_mock").await;
    t.schedule_event_with_capacity("two-seats", 2).await;

    let mut references = Vec::new();
    for _ in 0..2 {
        let (status, body) = t.register("two-seats").await;
        assert_eq!(status, 200, "{body}");
        assert!(body["checkout_url"].is_string(), "the mock plan still answers a checkout_url: {body}");
        references.push(body["registration_id"].as_str().unwrap().to_string());
    }
    for reference in &references {
        assert_eq!(t.settle(reference).await, 200);
        assert_eq!(t.payment_status(reference).await, "succeeded");
    }

    let (status, body) = t.register("two-seats").await;
    assert_eq!((status, body["error"].as_str()), (409, Some("this event is full")));
    assert!(t.fake.requests().is_empty(), "the mock walkthrough never calls Stripe");
}

#[tokio::test]
async fn an_unpaid_checkout_holds_the_seat_until_its_session_expires() {
    let t = tenant("hecks_pay_test_capacity_hold").await;
    t.schedule_event_with_capacity("held", 1).await;
    t.connect().await;
    t.enable().await;

    let (status, body) = t.register("held").await;
    assert_eq!(status, 200, "{body}");
    let reference = body["registration_id"].as_str().unwrap().to_string();
    assert_eq!(t.payment_status(&reference).await, "pending");

    let (status, _) = t.register("held").await;
    assert_eq!(status, 409, "a pending checkout holds the seat");

    assert_eq!(t.webhook(expired(&reference, TENANT_ACCOUNT)).await, 200);
    assert_eq!(t.payment_status(&reference).await, "failed");
    let (status, body) = t.register("held").await;
    assert_eq!(status, 200, "an expired checkout gives the seat back: {body}");
}

#[tokio::test]
async fn a_declined_payment_frees_the_seat_and_a_paid_one_keeps_it() {
    let t = tenant("hecks_pay_test_capacity_declined").await;
    t.schedule_event_with_capacity("declined", 1).await;

    let (_, body) = t.register("declined").await;
    let first = body["registration_id"].as_str().unwrap().to_string();
    let response = web::registration_complete_route(&first, r#"{"outcome":"failed"}"#, &t.client, &t.wasm, &t.config, &NeverInvoker, &crate::ir::fixture_payments()).await;
    assert_eq!(response["statusCode"].as_u64(), Some(200));
    assert_eq!(t.payment_status(&first).await, "failed");

    let (status, body) = t.register("declined").await;
    assert_eq!(status, 200, "a declined payment gives the seat back: {body}");
    let second = body["registration_id"].as_str().unwrap().to_string();
    assert_eq!(t.settle(&second).await, 200);

    let (status, _) = t.register("declined").await;
    assert_eq!(status, 409, "a paid registration keeps its seat");
}

#[tokio::test]
async fn a_stripe_session_expires_about_thirty_one_minutes_after_it_is_created() {
    let t = tenant("hecks_pay_test_capacity_expiry").await;
    t.schedule_event("expiring").await;
    t.connect().await;
    t.enable().await;

    let before = unix_secs();
    let (status, body) = t.register("expiring").await;
    let after = unix_secs();
    assert_eq!(status, 200, "{body}");

    let sent = t.fake.requests_to("/v1/checkout/sessions");
    assert_eq!(sent.len(), 1);
    let expires_at: i64 = sent[0].body.split('&').find_map(|pair| pair.strip_prefix("expires_at=")).expect("an expires_at form field").parse().unwrap();
    let hold = crate::checkout::SESSION_HOLD_SECONDS;
    assert!((before + hold..=after + hold).contains(&expires_at), "expires_at {expires_at} is not {hold}s after creation ({before}..{after})");
    assert!((30 * 60..=35 * 60).contains(&hold), "Stripe's minimum is 30 minutes, and the hold should stay close to it");
}

#[tokio::test]
async fn an_enabled_connection_without_a_publishable_key_is_paused_before_anything_is_written() {
    let mut t = tenant("hecks_pay_test_checkout_no_publishable").await;
    t.schedule_event("nopk-event").await;
    t.connect().await;
    t.enable().await;

    // The secret key alone cannot mount the form in the browser, and the
    // answer must be neither the mock nor a hosted page.
    t.platform.test_publishable_key = String::new();
    let (status, body) = t.register("nopk-event").await;
    assert_eq!((status, body["error"].as_str()), (503, Some("payments are temporarily unavailable")));
    assert_eq!(body.get("checkout_url"), None);
    assert_eq!(body.get("embedded_checkout"), None);

    let read = dispatch::read(&t.client, &t.wasm).await.unwrap();
    assert!(instances_for(&read, "Payments::Payment#").is_empty(), "no orphaned Payment");
    assert!(instances_for(&read, "CheckoutFixture::Registration#").is_empty());
    assert!(t.fake.requests_to("/v1/checkout/sessions").is_empty(), "Stripe is never called");
}

#[tokio::test]
async fn a_paused_connection_refuses_registrations_with_a_503_and_never_falls_back_to_the_mock() {
    let t = tenant("hecks_pay_test_checkout_paused").await;
    t.schedule_event("paused-event").await;
    t.connect().await;
    t.enable().await;
    let (status, _) = t.call("POST", "/payments/connection/disconnect", json!({}), Some(OWNER)).await;
    assert_eq!(status, 200);
    assert_eq!(t.status().await, "paused");

    let (status, body) = t.register("paused-event").await;
    assert_eq!((status, body["error"].as_str()), (503, Some("payments are temporarily unavailable")));
    assert_eq!(body.get("checkout_url"), None);

    // Nothing was written: no Payment, no Registration, no Stripe call.
    let read = dispatch::read(&t.client, &t.wasm).await.unwrap();
    assert!(instances_for(&read, "Payments::Payment#").is_empty());
    assert!(instances_for(&read, "CheckoutFixture::Registration#").is_empty());
    assert!(t.fake.requests_to("/v1/checkout/sessions").is_empty());
}

#[tokio::test]
async fn an_enabled_connection_whose_platform_key_is_missing_is_paused_not_mock() {
    let mut t = tenant("hecks_pay_test_checkout_no_key").await;
    t.schedule_event("nokey-event").await;
    t.connect().await;
    t.enable().await;

    t.platform.test_key = String::new();
    let (status, body) = t.register("nokey-event").await;
    assert_eq!((status, body["error"].as_str()), (503, Some("payments are temporarily unavailable")));
}

#[tokio::test]
async fn only_a_mock_payment_can_be_settled_by_hand() {
    let t = tenant("hecks_pay_test_complete").await;
    t.schedule_event("hand-event").await;

    let (_, mock) = t.register("hand-event").await;
    let mock_ref = mock["registration_id"].as_str().unwrap().to_string();
    t.connect().await;
    t.enable().await;
    let (_, real) = t.register("hand-event").await;
    let real_ref = real["registration_id"].as_str().unwrap().to_string();

    assert_eq!(t.settle(&real_ref).await, 403, "a real processor's payment is settled only by its webhook");
    assert_eq!(t.payment_status(&real_ref).await, "pending");
    assert_eq!(t.settle(&mock_ref).await, 200);
    assert_eq!(t.payment_status(&mock_ref).await, "succeeded");
}

// ---- webhooks -------------------------------------------------------------------

#[tokio::test]
async fn an_event_for_another_connected_account_is_acknowledged_and_ignored() {
    let t = tenant("hecks_pay_test_webhook_other").await;
    t.schedule_event("hook-event").await;
    t.connect().await;
    t.enable().await;
    let (_, body) = t.register("hook-event").await;
    let reference = body["registration_id"].as_str().unwrap().to_string();

    assert_eq!(t.webhook(completed(&reference, Some("acct_someone_else"))).await, 200);
    assert_eq!(t.payment_status(&reference).await, "pending", "another tenant's event settles nothing here");

    // Control: the same event on this tenant's own account does settle it.
    assert_eq!(t.webhook(completed(&reference, Some(TENANT_ACCOUNT))).await, 200);
    assert_eq!(t.payment_status(&reference).await, "succeeded");
}

#[tokio::test]
async fn an_account_event_with_no_connection_at_all_is_ignored() {
    let t = tenant("hecks_pay_test_webhook_no_connection").await;
    let event = json!({"type": "account.application.deauthorized", "account": TENANT_ACCOUNT, "data": {"object": {"id": "ca_test_CLIENT"}}});
    assert_eq!(t.webhook(event).await, 200);
    assert_eq!(t.status().await, "none");
}

#[tokio::test]
async fn deauthorization_pauses_enabled_payments_and_unlinks_an_enabled_less_connection() {
    let deauthorized = |account: &str| json!({"type": "account.application.deauthorized", "account": account, "data": {"object": {"id": "ca_test_CLIENT"}}});

    let enabled = tenant("hecks_pay_test_deauth_enabled").await;
    enabled.connect().await;
    enabled.enable().await;
    assert_eq!(enabled.webhook(deauthorized("acct_someone_else")).await, 200);
    assert_eq!(enabled.status().await, "enabled", "another account's deauthorization changes nothing");
    assert_eq!(enabled.webhook(deauthorized(TENANT_ACCOUNT)).await, 200);
    assert_eq!(enabled.status().await, "paused");
    assert_eq!(enabled.webhook(deauthorized(TENANT_ACCOUNT)).await, 200, "a redelivery is a no-op");
    assert_eq!(enabled.status().await, "paused");

    let connected = tenant("hecks_pay_test_deauth_connected").await;
    connected.connect().await;
    assert_eq!(connected.webhook(deauthorized(TENANT_ACCOUNT)).await, 200);
    assert_eq!(connected.status().await, "disconnected");
}

#[tokio::test]
async fn an_account_event_verified_only_by_the_public_mock_secret_is_refused() {
    let mut t = tenant("hecks_pay_test_webhook_fallback").await;
    t.connect().await;
    t.enable().await;
    t.schedule_event("fallback-event").await;
    let (_, body) = t.register("fallback-event").await;
    let reference = body["registration_id"].as_str().unwrap().to_string();

    // STRIPE_WEBHOOK_SECRET unset: events verify against the public mock secret.
    t.platform.webhook_secret = None;
    let sign_with_mock = |event: &Value| {
        let payload = event.to_string();
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64;
        (payload.clone(), sign(web::MOCK_STRIPE_WEBHOOK_SECRET, now, &payload))
    };
    for event in [
        json!({"type": "account.application.deauthorized", "account": TENANT_ACCOUNT, "data": {"object": {}}}),
        completed(&reference, None),
    ] {
        let (payload, header) = sign_with_mock(&event);
        let response = web::webhook_route(&payload, &header, &t.platform, &t.client, &t.wasm, &t.config, &NeverInvoker, &crate::ir::fixture_payments()).await;
        assert_eq!(response["statusCode"], 500, "{event}");
    }
    assert_eq!(t.status().await, "enabled", "a forged deauthorization must not pause payments");
    assert_eq!(t.payment_status(&reference).await, "pending", "a forged completion must not settle a real payment");
}

// ---- pure decisions ---------------------------------------------------------------

#[test]
fn checkout_plan_is_decided_from_the_connection_lifecycle() {
    let platform = PlatformConfig { test_key: "sk_test_x".to_string(), test_publishable_key: "pk_test_x".to_string(), ..test_platform() };
    let with = |status: &str, processor: &str, mode: &str| Connection {
        status: status.to_string(),
        processor: processor.to_string(),
        account_ref: "acct_1".to_string(),
        mode: mode.to_string(),
        display_name: "Name".to_string(),
    };
    assert!(matches!(checkout_plan(None, &platform), CheckoutPlan::Mock));
    for status in ["connected", "disconnected"] {
        assert!(matches!(checkout_plan(Some(&with(status, "stripe", "test")), &platform), CheckoutPlan::Mock), "{status}");
    }
    assert!(matches!(checkout_plan(Some(&with("paused", "stripe", "test")), &platform), CheckoutPlan::Paused));
    assert!(matches!(
        checkout_plan(Some(&with("enabled", "stripe", "test")), &platform),
        CheckoutPlan::Stripe { ref api_key, ref publishable_key, ref account } if api_key == "sk_test_x" && publishable_key == "pk_test_x" && account == "acct_1"
    ));
    assert!(matches!(checkout_plan(Some(&with("enabled", "stripe", "live")), &platform), CheckoutPlan::Paused), "no live key configured");
    let secret_only = PlatformConfig { live_key: "sk_live_x".to_string(), ..test_platform() };
    assert!(
        matches!(checkout_plan(Some(&with("enabled", "stripe", "live")), &secret_only), CheckoutPlan::Paused),
        "a secret key without its publishable key cannot mount the embedded form"
    );
    assert!(matches!(checkout_plan(Some(&with("enabled", "paypal", "test")), &platform), CheckoutPlan::Paused), "a processor this host cannot charge");
}

#[test]
fn purpose_tokens_only_verify_for_their_own_purpose_and_secret() {
    let token = auth::purpose_token("k", "one", json!({"email": "a@b.c"}), 60);
    assert_eq!(auth::verify_purpose_token("k", "one", &token).unwrap()["email"], "a@b.c");
    assert!(auth::verify_purpose_token("k", "two", &token).is_none());
    assert!(auth::verify_purpose_token("other", "one", &token).is_none());
    assert!(auth::verify_account_token("k", &token).is_none(), "not a session cookie");
}
