use super::{instances_for, last_refusal, respond};
use crate::auth;
use crate::connect::{Adapter, StripeCreds};
use crate::dispatch;
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

// ---- per-tenant payment connection --------------------------------------
// A tenant links its own processor account through the processor's
// authorization screen; the site stores only the public account reference
// on the domain's `PaymentConnection` aggregate (one row, slug "payments").
// This module holds the JSON routes the admin's Payments page drives and
// the per-request checkout decision that reads the connection. The
// aggregate itself lives in the deployed domain (Ruby and Rust share its
// bluebook), so every state change dispatches its commands and the domain
// enforces the lifecycle.

/// Identity of the one connection row every tenant domain holds.
pub(super) const SLUG: &str = "payments";

const CONNECT_STATE_PURPOSE: &str = "payment_connect";
const CONNECT_STATE_TTL_SECS: u64 = 600;
const UNAVAILABLE: &str = "payments are temporarily unavailable";

/// The public facts of a tenant's link to its processor account.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Connection {
    pub status: String,
    pub processor: String,
    pub account_ref: String,
    pub mode: String,
    pub display_name: String,
}

/// Reads the tenant's connection out of a `dispatch::read` result, or
/// `None` when the domain has no such row (never connected, or a domain
/// that has no `PaymentConnection` aggregate at all).
pub(super) fn connection_in(read: &Value, domain: &str) -> Option<Connection> {
    let rows = instances_for(read, &format!("{domain}::PaymentConnection#"));
    let (_, state) = rows.iter().find(|(id, _)| id == SLUG)?;
    let text = |field: &str| state.get(field).and_then(|v| v.get("value")).and_then(|v| v.as_str()).unwrap_or("").to_string();
    Some(Connection {
        status: state.get("status").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        processor: text("processor"),
        account_ref: text("account_ref"),
        mode: text("mode"),
        display_name: text("display_name"),
    })
}

/// How a registration's checkout is run, decided per request from the
/// tenant's connection.
#[derive(Debug, PartialEq)]
pub(super) enum Checkout {
    /// Create a session through the processor. `stripe_account` is the
    /// connected account the charge lands in; an empty `api_key` means the
    /// local mock checkout page.
    Run { processor: String, api_key: String, stripe_account: Option<String> },
    /// The tenant's payments are paused: registrations are refused rather
    /// than falling back to the mock page.
    Paused,
}

/// Decides how a registration's checkout runs.
///
/// Only an `enabled` connection takes real payments. A connection that is
/// merely `connected`, or `disconnected`, keeps checkout on the mock, and
/// `paused` refuses. A domain with no connection row at all keeps the
/// single-account behaviour its own environment already configured
/// (`legacy_key` / `legacy_processor`), so a deploy that never adopts
/// Connect is unchanged.
pub(super) fn resolve_checkout(connection: Option<&Connection>, legacy_key: &str, legacy_processor: &str, creds: &StripeCreds) -> Checkout {
    let Some(connection) = connection else {
        return Checkout::Run { processor: legacy_processor.to_string(), api_key: legacy_key.to_string(), stripe_account: None };
    };
    match connection.status.as_str() {
        "enabled" => match Adapter::from_processor(&connection.processor) {
            Some(Adapter::Mock) => Checkout::Run { processor: Adapter::Mock.payment_processor().to_string(), api_key: String::new(), stripe_account: None },
            Some(adapter) => match creds.key(&connection.mode) {
                Some(key) => Checkout::Run {
                    processor: adapter.payment_processor().to_string(),
                    api_key: key.to_string(),
                    stripe_account: Some(connection.account_ref.clone()),
                },
                None => Checkout::Paused,
            },
            None => Checkout::Paused,
        },
        "paused" => Checkout::Paused,
        _ => Checkout::Run { processor: Adapter::Mock.payment_processor().to_string(), api_key: String::new(), stripe_account: None },
    }
}

/// The response a paused checkout answers registrations with.
pub(super) fn paused_response() -> Value {
    respond(503, "application/json", &json!({"error": UNAVAILABLE}).to_string())
}

/// What a processor's webhook means for the tenant's connection.
#[derive(Debug, PartialEq)]
pub(super) enum WebhookEffect {
    /// Not for this tenant's account; acknowledge and do nothing.
    Ignore,
    /// The tenant revoked access at the processor; run this command.
    Revoked(&'static str),
    /// A payment event; settle it as usual.
    Payment,
}

/// Classifies a verified webhook event against the tenant's connection.
///
/// An event carrying an `account` that is not the tenant's connected one
/// is ignored, so one tenant never settles another's payments. A
/// revocation pauses an enabled connection and unlinks a merely connected
/// one.
pub(super) fn webhook_effect(event: &Value, connection: Option<&Connection>) -> WebhookEffect {
    if let Some(account) = event.get("account").and_then(|v| v.as_str()) {
        if connection.map(|c| c.account_ref.as_str()) != Some(account) {
            return WebhookEffect::Ignore;
        }
    }
    if event.get("type").and_then(|v| v.as_str()) == Some("account.application.deauthorized") {
        return match connection.map(|c| c.status.as_str()) {
            Some("enabled") => WebhookEffect::Revoked("Suspend"),
            Some("connected") => WebhookEffect::Revoked("Disconnect"),
            _ => WebhookEffect::Ignore,
        };
    }
    WebhookEffect::Payment
}

/// Dispatches a lifecycle command on the tenant's connection row.
///
/// # Errors
///
/// Returns the response to send when the kernel faults or refuses.
pub(super) async fn run_command(
    verb: &str,
    args: Value,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Result<(), Value> {
    let full = format!("{}::PaymentConnection.{verb}", config.domain);
    match dispatch::handle(client, wasm_path, &full, args, None, config, invoker).await {
        Ok(outcome) if outcome.accepted => Ok(()),
        Ok(outcome) => Err(respond(422, "application/json", &last_refusal(&outcome.result).to_string())),
        Err(e) => Err(respond(500, "text/plain", &format!("{e:#}"))),
    }
}

// ---- /payments/connection/* ---------------------------------------------

/// Who is asking, and what they may do.
#[derive(Clone, Debug)]
pub(super) struct Caller {
    pub email: String,
    /// May connect and disconnect the tenant's account.
    pub owner: bool,
    /// May switch real payments on and off (the platform operator).
    pub operator: bool,
}

/// Site-level settings the routes need.
pub(super) struct ConnectEnv {
    pub secret: String,
    pub creds: StripeCreds,
    pub site_url: String,
    /// Whether the local mock processor is offered as a choice.
    pub allow_mock: bool,
}

impl ConnectEnv {
    /// Reads the settings from the environment.
    ///
    /// `PAYMENTS_ALLOW_MOCK_CONNECT=1` offers the mock processor, for local
    /// development and CI; a real deploy never sets it.
    pub fn from_env(secret: &str) -> Self {
        Self {
            secret: secret.to_string(),
            creds: StripeCreds::from_env(),
            site_url: std::env::var("SITE_URL").unwrap_or_else(|_| "http://localhost:4321".to_string()),
            allow_mock: std::env::var("PAYMENTS_ALLOW_MOCK_CONNECT").is_ok_and(|v| v == "1"),
        }
    }
}

fn json_error(status: u16, message: &str) -> Value {
    respond(status, "application/json", &json!({"error": message}).to_string())
}

fn json_ok(body: &Value) -> Value {
    respond(200, "application/json", &body.to_string())
}

/// Lower-cased emails from a comma-separated allowlist.
pub(super) fn operators_from(list: &str) -> Vec<String> {
    list.split(',').map(|e| e.trim().to_lowercase()).filter(|e| !e.is_empty()).collect()
}

/// Whether `email` belongs to a member holding the `Owner` role.
pub(super) fn owner_among(people: &[Value], email: &str) -> bool {
    people.iter().any(|p| {
        p.get("email").and_then(|v| v.as_str()).is_some_and(|e| e.eq_ignore_ascii_case(email))
            && p.get("role").and_then(|v| v.as_str()) == Some("Owner")
    })
}

/// Serves `/payments/connection/*` for the signed-in admin, or `None` for
/// any other path.
///
/// Authenticates from the `lifeadelics_session` cookie. Owner is a
/// member's own `Owner` role; operator is the `PAYMENTS_OPERATOR_EMAILS`
/// allowlist. The domain does not enforce roles, so these checks are the
/// enforcement.
#[allow(clippy::too_many_arguments)]
pub(super) async fn payments_route(
    domain_ir: &Value,
    method: &str,
    path: &str,
    raw_body: &str,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    let sub = path.strip_prefix("/payments/connection")?;
    if !(sub.is_empty() || sub.starts_with('/')) {
        return None;
    }
    let Some(email) = cookies.get("lifeadelics_session").and_then(|t| auth::verify_account_token(secret, t)) else {
        return Some(json_error(401, "not logged in"));
    };
    let people = match auth::all_people(client, domain_ir).await {
        Ok(people) => people,
        Err(e) => {
            eprintln!("payments_route: could not read members: {e:#}");
            Vec::new()
        }
    };
    let operators = operators_from(&std::env::var("PAYMENTS_OPERATOR_EMAILS").unwrap_or_default());
    let caller = Caller { owner: owner_among(&people, &email), operator: operators.contains(&email.to_lowercase()), email };
    let env = ConnectEnv::from_env(secret);
    Some(handle(&caller, &env, &reqwest::Client::new(), method, sub, raw_body, client, wasm_path, config, invoker).await)
}

/// The routes' logic, given an already-authenticated caller.
#[allow(clippy::too_many_arguments)]
pub(super) async fn handle(
    caller: &Caller,
    env: &ConnectEnv,
    http: &reqwest::Client,
    method: &str,
    sub: &str,
    raw_body: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let need_owner = || (!caller.owner).then(|| json_error(403, "only an Owner can manage payments"));
    let need_operator = || (!caller.operator).then(|| json_error(403, "only the platform operator can change whether payments are enabled"));
    let body: Value = serde_json::from_str(raw_body).unwrap_or(Value::Null);

    match (method, sub) {
        ("GET", "") => {
            if !caller.owner && !caller.operator {
                return json_error(403, "not permitted");
            }
            connection_body(caller, env, client, wasm_path, config, None).await
        }
        ("POST", "/authorize-url") => {
            if let Some(refusal) = need_owner() {
                return refusal;
            }
            authorize_url(caller, env, &body)
        }
        ("POST", "/callback") => {
            if let Some(refusal) = need_owner() {
                return refusal;
            }
            callback(caller, env, http, &body, client, wasm_path, config, invoker).await
        }
        ("POST", "/disconnect") => {
            if let Some(refusal) = need_owner() {
                return refusal;
            }
            disconnect(caller, env, http, client, wasm_path, config, invoker).await
        }
        ("POST", "/enable") | ("POST", "/disable") => {
            if let Some(refusal) = need_operator() {
                return refusal;
            }
            switch(sub == "/enable", caller, env, client, wasm_path, config, invoker).await
        }
        _ => respond(404, "text/plain", &format!("no route for {method} /payments/connection{sub}")),
    }
}

async fn current(client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig) -> Result<Option<Connection>, Value> {
    match dispatch::read(client, wasm_path).await {
        Ok(read) => Ok(connection_in(&read, &config.domain)),
        Err(e) => Err(respond(500, "text/plain", &format!("{e:#}"))),
    }
}

async fn connection_body(caller: &Caller, env: &ConnectEnv, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, extra: Option<(&str, Value)>) -> Value {
    let connection = match current(client, wasm_path, config).await {
        Ok(c) => c,
        Err(response) => return response,
    };
    let adapters: Vec<Value> = Adapter::offered(!env.allow_mock)
        .into_iter()
        .filter(|a| !a.modes(&env.creds).is_empty())
        .map(|a| json!({"processor": a.processor(), "label": a.label(), "modes": a.modes(&env.creds)}))
        .collect();
    let label = connection.as_ref().and_then(|c| Adapter::from_processor(&c.processor)).map(|a| a.label());
    let mut body = json!({
        "status": connection.as_ref().map(|c| c.status.as_str()).unwrap_or("not_connected"),
        "processor": connection.as_ref().map(|c| c.processor.as_str()),
        "label": label,
        "account_ref": connection.as_ref().map(|c| c.account_ref.as_str()),
        "mode": connection.as_ref().map(|c| c.mode.as_str()),
        "display_name": connection.as_ref().map(|c| c.display_name.as_str()),
        "adapters": adapters,
        "can_manage": caller.owner,
        "can_enable": caller.operator,
    });
    if let Some((key, value)) = extra {
        body[key] = value;
    }
    json_ok(&body)
}

fn offered_adapter(env: &ConnectEnv, processor: &str) -> Option<Adapter> {
    Adapter::from_processor(processor).filter(|a| Adapter::offered(!env.allow_mock).contains(a))
}

fn authorize_url(caller: &Caller, env: &ConnectEnv, body: &Value) -> Value {
    let (Some(processor), Some(mode)) = (body.get("processor").and_then(|v| v.as_str()), body.get("mode").and_then(|v| v.as_str())) else {
        return json_error(400, "processor and mode are required");
    };
    let Some(adapter) = offered_adapter(env, processor) else {
        return json_error(422, "unknown payment processor");
    };
    if !adapter.modes(&env.creds).contains(&mode) {
        return json_error(422, &format!("{} is not set up for {mode} mode", adapter.label()));
    }
    let state = auth::signed_claims(
        &env.secret,
        json!({"purpose": CONNECT_STATE_PURPOSE, "email": caller.email, "processor": processor, "mode": mode}),
        CONNECT_STATE_TTL_SECS,
    );
    let redirect_uri = format!("{}/api/payment-connect-callback", env.site_url);
    match adapter.authorize_url(&env.creds, mode, &state, &redirect_uri) {
        Ok(url) => json_ok(&json!({"url": url})),
        Err(message) => json_error(422, &message),
    }
}

#[allow(clippy::too_many_arguments)]
async fn callback(
    caller: &Caller,
    env: &ConnectEnv,
    http: &reqwest::Client,
    body: &Value,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let (Some(state), Some(code)) = (body.get("state").and_then(|v| v.as_str()), body.get("code").and_then(|v| v.as_str())) else {
        return json_error(400, "state and code are required");
    };
    let expired = || json_error(400, "this connection attempt expired — start again");
    let Some(claims) = auth::verify_signed_claims(&env.secret, state) else { return expired() };
    let claim = |field: &str| claims.get(field).and_then(|v| v.as_str()).unwrap_or("").to_string();
    if claim("purpose") != CONNECT_STATE_PURPOSE || !claim("email").eq_ignore_ascii_case(&caller.email) {
        return expired();
    }
    let Some(adapter) = offered_adapter(env, &claim("processor")) else {
        return json_error(422, "unknown payment processor");
    };
    let mode = claim("mode");

    let existing = match current(client, wasm_path, config).await {
        Ok(c) => c,
        Err(response) => return response,
    };
    if matches!(existing.as_ref().map(|c| c.status.as_str()), Some("connected") | Some("enabled")) {
        return json_error(409, "an account is already connected — disconnect it first");
    }

    let connected = match adapter.complete(http, &env.creds, &mode, code).await {
        Ok(c) => c,
        Err(message) => return json_error(422, &format!("{} could not connect that account: {message}", adapter.label())),
    };
    let facts = json!({
        "processor": {"value": adapter.processor()},
        "account_ref": {"value": connected.account_ref},
        "mode": {"value": connected.mode},
        "display_name": {"value": connected.display_name},
    });
    let (verb, args) = match existing.as_ref().map(|c| c.status.as_str()) {
        None => {
            let mut args = facts;
            args["slug"] = json!({"value": SLUG});
            ("Connect", args)
        }
        Some("disconnected") => ("Reconnect", with_id(facts)),
        Some("paused") => ("Resume", with_id(facts)),
        Some(other) => return json_error(409, &format!("cannot connect from a {other} link")),
    };
    if let Err(response) = run_command(verb, args, client, wasm_path, config, invoker).await {
        return response;
    }
    connection_body(caller, env, client, wasm_path, config, None).await
}

fn with_id(mut facts: Value) -> Value {
    facts["id"] = json!(SLUG);
    facts
}

async fn disconnect(
    caller: &Caller,
    env: &ConnectEnv,
    http: &reqwest::Client,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let connection = match current(client, wasm_path, config).await {
        Ok(c) => c,
        Err(response) => return response,
    };
    let Some(connection) = connection.filter(|c| c.status == "connected" || c.status == "enabled") else {
        return json_error(409, "nothing to disconnect");
    };
    // Revoke at the processor first, best effort: the local unlink happens
    // either way, so a failed revocation never strands the tenant.
    let remote = match Adapter::from_processor(&connection.processor) {
        Some(adapter) => adapter.disconnect(http, &env.creds, &connection.account_ref, &connection.mode).await,
        None => false,
    };
    // Disconnecting while payments are enabled pauses registrations; it
    // never falls back to the mock page, because real guests have paid.
    let verb = if connection.status == "enabled" { "Suspend" } else { "Disconnect" };
    if let Err(response) = run_command(verb, json!({"id": SLUG}), client, wasm_path, config, invoker).await {
        return response;
    }
    connection_body(caller, env, client, wasm_path, config, Some(("remote_disconnected", json!(remote)))).await
}

async fn switch(
    enable: bool,
    caller: &Caller,
    env: &ConnectEnv,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    match current(client, wasm_path, config).await {
        Ok(Some(_)) => {}
        Ok(None) => return json_error(409, "connect an account first"),
        Err(response) => return response,
    }
    let verb = if enable { "EnablePayments" } else { "DisablePayments" };
    if let Err(response) = run_command(verb, json!({"id": SLUG}), client, wasm_path, config, invoker).await {
        return response;
    }
    connection_body(caller, env, client, wasm_path, config, None).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lambda_client;
    use crate::web::tests::{provision_lineage, scratch_db};

    fn connection(status: &str) -> Connection {
        Connection {
            status: status.to_string(),
            processor: "stripe".to_string(),
            account_ref: "acct_tenant1".to_string(),
            mode: "test".to_string(),
            display_name: "Lifeadelics".to_string(),
        }
    }

    fn creds() -> StripeCreds {
        StripeCreds { test_key: "sk_test_platform".into(), live_key: String::new(), test_client_id: "ca_test".into(), live_client_id: String::new() }
    }

    fn run(processor: &str, key: &str, account: Option<&str>) -> Checkout {
        Checkout::Run { processor: processor.to_string(), api_key: key.to_string(), stripe_account: account.map(String::from) }
    }

    // ---- resolve_checkout: pure ---

    #[test]
    fn no_connection_keeps_the_environments_own_single_account_behaviour() {
        assert_eq!(resolve_checkout(None, "", "mock_stripe", &creds()), run("mock_stripe", "", None));
        assert_eq!(resolve_checkout(None, "sk_env", "stripe", &creds()), run("stripe", "sk_env", None));
    }

    #[test]
    fn an_enabled_stripe_connection_creates_sessions_on_the_connected_account() {
        assert_eq!(resolve_checkout(Some(&connection("enabled")), "", "mock_stripe", &creds()), run("stripe", "sk_test_platform", Some("acct_tenant1")));
    }

    #[test]
    fn a_connected_but_not_enabled_link_keeps_checkout_on_the_mock() {
        assert_eq!(resolve_checkout(Some(&connection("connected")), "sk_env", "stripe", &creds()), run("mock_stripe", "", None));
        assert_eq!(resolve_checkout(Some(&connection("disconnected")), "sk_env", "stripe", &creds()), run("mock_stripe", "", None));
    }

    #[test]
    fn a_paused_connection_refuses_instead_of_falling_back_to_the_mock() {
        assert_eq!(resolve_checkout(Some(&connection("paused")), "", "mock_stripe", &creds()), Checkout::Paused);
    }

    #[test]
    fn an_enabled_connection_with_no_platform_key_or_unknown_processor_pauses() {
        assert_eq!(resolve_checkout(Some(&connection("enabled")), "", "mock_stripe", &StripeCreds::default()), Checkout::Paused);
        let mut unknown = connection("enabled");
        unknown.processor = "paypal".into();
        assert_eq!(resolve_checkout(Some(&unknown), "", "mock_stripe", &creds()), Checkout::Paused);
    }

    #[test]
    fn an_enabled_mock_connection_uses_the_mock_checkout_page() {
        let mut mock = connection("enabled");
        mock.processor = "mock".into();
        assert_eq!(resolve_checkout(Some(&mock), "", "stripe", &creds()), run("mock_stripe", "", None));
    }

    // ---- webhook_effect: pure ---

    #[test]
    fn an_event_for_another_account_is_ignored() {
        let event = json!({"type": "checkout.session.completed", "account": "acct_other"});
        assert_eq!(webhook_effect(&event, Some(&connection("enabled"))), WebhookEffect::Ignore);
        assert_eq!(webhook_effect(&event, None), WebhookEffect::Ignore);
    }

    #[test]
    fn an_event_for_the_tenants_own_account_or_no_account_settles_normally() {
        let own = json!({"type": "checkout.session.completed", "account": "acct_tenant1"});
        assert_eq!(webhook_effect(&own, Some(&connection("enabled"))), WebhookEffect::Payment);
        let plain = json!({"type": "checkout.session.completed"});
        assert_eq!(webhook_effect(&plain, None), WebhookEffect::Payment);
    }

    #[test]
    fn a_revocation_pauses_an_enabled_link_and_unlinks_a_connected_one() {
        let event = json!({"type": "account.application.deauthorized", "account": "acct_tenant1"});
        assert_eq!(webhook_effect(&event, Some(&connection("enabled"))), WebhookEffect::Revoked("Suspend"));
        assert_eq!(webhook_effect(&event, Some(&connection("connected"))), WebhookEffect::Revoked("Disconnect"));
        assert_eq!(webhook_effect(&event, Some(&connection("paused"))), WebhookEffect::Ignore);
    }

    #[test]
    fn a_revocation_for_another_account_is_ignored() {
        let event = json!({"type": "account.application.deauthorized", "account": "acct_other"});
        assert_eq!(webhook_effect(&event, Some(&connection("enabled"))), WebhookEffect::Ignore);
    }

    // ---- roles: pure ---

    #[test]
    fn operators_are_a_trimmed_lowercased_allowlist() {
        assert_eq!(operators_from(" Ops@X.co , ,b@y.co"), vec!["ops@x.co", "b@y.co"]);
        assert!(operators_from("").is_empty());
    }

    #[test]
    fn only_a_member_holding_the_owner_role_is_an_owner() {
        let people = vec![json!({"email": "Chris@x.co", "role": "Owner"}), json!({"email": "amy@x.co", "role": "Admin"})];
        assert!(owner_among(&people, "chris@x.co"));
        assert!(!owner_among(&people, "amy@x.co"));
        assert!(!owner_among(&people, "nobody@x.co"));
    }

    // ---- routes: real Postgres + the checkout fixture's PaymentConnection ---

    fn config() -> LineageConfig {
        LineageConfig { domain: "CheckoutFixture".to_string(), era: Some(1), mirrored: None }
    }

    fn wasm() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/checkout_fixture.wasm")
    }

    fn env_with_mock() -> ConnectEnv {
        ConnectEnv { secret: "s3cret".into(), creds: creds(), site_url: "https://site.test".into(), allow_mock: true }
    }

    fn owner() -> Caller {
        Caller { email: "chris@x.co".into(), owner: true, operator: false }
    }

    fn operator() -> Caller {
        Caller { email: "ops@x.co".into(), owner: false, operator: true }
    }

    async fn call(caller: &Caller, env: &ConnectEnv, client: &Mutex<Client>, method: &str, sub: &str, body: Value) -> Value {
        handle(caller, env, &reqwest::Client::new(), method, sub, &body.to_string(), client, &wasm(), &config(), &lambda_client::NeverInvoker).await
    }

    fn parsed(response: &Value) -> Value {
        serde_json::from_str(response["body"].as_str().unwrap()).unwrap()
    }

    async fn scratch(name: &str) -> Mutex<Client> {
        let client = scratch_db(name).await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment", "PaymentConnection"]).await;
        client
    }

    // Runs the mock connect handshake through the real routes, returning
    // the connected-state body.
    async fn connect_with_mock(client: &Mutex<Client>, env: &ConnectEnv) -> Value {
        let started = call(&owner(), env, client, "POST", "/authorize-url", json!({"processor": "mock", "mode": "test"})).await;
        assert_eq!(started["statusCode"], 200, "{started:?}");
        let url = reqwest::Url::parse(parsed(&started)["url"].as_str().unwrap()).unwrap();
        let query: HashMap<String, String> = url.query_pairs().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        let done = call(&owner(), env, client, "POST", "/callback", json!({"code": query["code"], "state": query["state"]})).await;
        assert_eq!(done["statusCode"], 200, "{done:?}");
        parsed(&done)
    }

    #[tokio::test]
    async fn an_unconnected_site_reports_not_connected_and_who_may_act() {
        let client = scratch("hecks_host_web_test_payments_unconnected").await;
        let response = call(&owner(), &env_with_mock(), &client, "GET", "", Value::Null).await;
        assert_eq!(response["statusCode"], 200);
        let body = parsed(&response);
        assert_eq!(body["status"], "not_connected");
        assert_eq!(body["can_manage"], true);
        assert_eq!(body["can_enable"], false);
        let processors: Vec<&str> = body["adapters"].as_array().unwrap().iter().map(|a| a["processor"].as_str().unwrap()).collect();
        assert_eq!(processors, vec!["stripe", "mock"]);
    }

    #[tokio::test]
    async fn the_mock_is_not_offered_unless_explicitly_allowed() {
        let client = scratch("hecks_host_web_test_payments_no_mock").await;
        let mut env = env_with_mock();
        env.allow_mock = false;
        let body = parsed(&call(&owner(), &env, &client, "GET", "", Value::Null).await);
        let processors: Vec<&str> = body["adapters"].as_array().unwrap().iter().map(|a| a["processor"].as_str().unwrap()).collect();
        assert_eq!(processors, vec!["stripe"]);
        let refused = call(&owner(), &env, &client, "POST", "/authorize-url", json!({"processor": "mock", "mode": "test"})).await;
        assert_eq!(refused["statusCode"], 422);
    }

    #[tokio::test]
    async fn a_plain_admin_can_neither_read_nor_change_the_connection() {
        let client = scratch("hecks_host_web_test_payments_plain_admin").await;
        let plain = Caller { email: "amy@x.co".into(), owner: false, operator: false };
        assert_eq!(call(&plain, &env_with_mock(), &client, "GET", "", Value::Null).await["statusCode"], 403);
        assert_eq!(call(&plain, &env_with_mock(), &client, "POST", "/disconnect", Value::Null).await["statusCode"], 403);
    }

    #[tokio::test]
    async fn connecting_through_the_mock_handshake_records_only_public_facts() {
        let client = scratch("hecks_host_web_test_payments_connect").await;
        let body = connect_with_mock(&client, &env_with_mock()).await;
        assert_eq!(body["status"], "connected");
        assert_eq!(body["processor"], "mock");
        assert_eq!(body["display_name"], "Mock Business");
        assert!(body["account_ref"].as_str().unwrap().starts_with("acct_mock_"));
        let text = body.to_string().to_lowercase();
        assert!(!text.contains("secret") && !text.contains("sk_"), "no secret-like value in {text}");
    }

    #[tokio::test]
    async fn a_callback_with_a_tampered_or_foreign_state_is_refused() {
        let client = scratch("hecks_host_web_test_payments_bad_state").await;
        let env = env_with_mock();
        let started = call(&owner(), &env, &client, "POST", "/authorize-url", json!({"processor": "mock", "mode": "test"})).await;
        let url = reqwest::Url::parse(parsed(&started)["url"].as_str().unwrap()).unwrap();
        let query: HashMap<String, String> = url.query_pairs().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        // Another Owner replaying the first Owner's state.
        let other = Caller { email: "other@x.co".into(), owner: true, operator: false };
        let replay = call(&other, &env, &client, "POST", "/callback", json!({"code": query["code"], "state": query["state"]})).await;
        assert_eq!(replay["statusCode"], 400);
        let forged = call(&owner(), &env, &client, "POST", "/callback", json!({"code": "c", "state": "garbage.sig"})).await;
        assert_eq!(forged["statusCode"], 400);
    }

    #[tokio::test]
    async fn only_the_operator_can_enable_and_only_once_connected() {
        let client = scratch("hecks_host_web_test_payments_enable").await;
        let env = env_with_mock();
        assert_eq!(call(&operator(), &env, &client, "POST", "/enable", Value::Null).await["statusCode"], 409);
        connect_with_mock(&client, &env).await;
        assert_eq!(call(&owner(), &env, &client, "POST", "/enable", Value::Null).await["statusCode"], 403);
        let enabled = call(&operator(), &env, &client, "POST", "/enable", Value::Null).await;
        assert_eq!(parsed(&enabled)["status"], "enabled");
        let disabled = call(&operator(), &env, &client, "POST", "/disable", Value::Null).await;
        assert_eq!(parsed(&disabled)["status"], "connected");
    }

    #[tokio::test]
    async fn disconnecting_enabled_payments_pauses_and_reconnecting_resumes() {
        let client = scratch("hecks_host_web_test_payments_pause_resume").await;
        let env = env_with_mock();
        connect_with_mock(&client, &env).await;
        call(&operator(), &env, &client, "POST", "/enable", Value::Null).await;
        let paused = call(&owner(), &env, &client, "POST", "/disconnect", Value::Null).await;
        let paused = parsed(&paused);
        assert_eq!(paused["status"], "paused");
        assert_eq!(paused["remote_disconnected"], true);
        assert_eq!(call(&owner(), &env, &client, "POST", "/disconnect", Value::Null).await["statusCode"], 409);
        let resumed = connect_with_mock(&client, &env).await;
        assert_eq!(resumed["status"], "enabled");
    }

    #[tokio::test]
    async fn disconnecting_a_connected_link_unlinks_it_and_it_can_be_reconnected() {
        let client = scratch("hecks_host_web_test_payments_unlink").await;
        let env = env_with_mock();
        connect_with_mock(&client, &env).await;
        let unlinked = parsed(&call(&owner(), &env, &client, "POST", "/disconnect", Value::Null).await);
        assert_eq!(unlinked["status"], "disconnected");
        assert_eq!(connect_with_mock(&client, &env).await["status"], "connected");
    }

    #[tokio::test]
    async fn connecting_over_an_existing_link_is_refused() {
        let client = scratch("hecks_host_web_test_payments_already").await;
        let env = env_with_mock();
        connect_with_mock(&client, &env).await;
        let started = call(&owner(), &env, &client, "POST", "/authorize-url", json!({"processor": "mock", "mode": "test"})).await;
        let url = reqwest::Url::parse(parsed(&started)["url"].as_str().unwrap()).unwrap();
        let query: HashMap<String, String> = url.query_pairs().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        let again = call(&owner(), &env, &client, "POST", "/callback", json!({"code": query["code"], "state": query["state"]})).await;
        assert_eq!(again["statusCode"], 409);
    }

    #[tokio::test]
    async fn an_unknown_route_is_a_404() {
        let client = scratch("hecks_host_web_test_payments_404").await;
        assert_eq!(call(&owner(), &env_with_mock(), &client, "GET", "/nope", Value::Null).await["statusCode"], 404);
    }
}
