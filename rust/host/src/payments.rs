// **Payment connection** — the tenant's own link to a payment-processor
// account, and what checkout does with it. Ported from the Ruby domain
// service's `/payments/connection/*` routes, `checkout_plan` and webhook
// handling (lifeadelics/adapters/http_server.rb) so a deploy served by this
// host, not the Sinatra adapter, behaves the same way.
//
// A tenant connects their own Stripe account through Stripe Connect's OAuth
// screen. Nothing here ever holds a tenant secret: the connection stores only
// the public `acct_...` id, the mode and a display name. The credentials in
// `PlatformConfig` (platform keys, Connect client ids, the Connect webhook
// signing secret) belong to the platform, come from the environment, and never
// reach a response, a log line or the tenant's schema.
//
// A business that is not served through a platform can instead use its own
// Stripe account directly: its keys are set in the environment
// (`STRIPE_ACCOUNT_*`), an Owner chooses "use this account", and the connection
// is recorded with the reserved `account_ref` "self". Charges then use that
// account's own key with no `Stripe-Account` header, and Connect's OAuth
// handshake and deauthorization do not apply.
//
// The business can also paste its keys into the Payments page and save them
// (`save_keys_route`). The keys are checked with Stripe, the site creates the
// webhook in the business's own Stripe account itself, and the keys and the
// webhook's signing secret go into a Secrets Manager secret (keystore.rs), never
// into the tenant's schema or a response. Environment keys, where set, win over
// saved ones. Disconnecting removes the webhook and the saved keys.
//
// Who may do what is decided here, not by Governance (no Caller is bound on
// these routes): an Owner (the membership person's own `role`) connects and
// disconnects; only an operator (`PAYMENTS_OPERATOR_EMAILS`, a platform
// allowlist, never a tenant role) turns real payments on or off. The person is
// re-read from the current membership head on every request, so a disabled
// Owner's old cookie stops working at once.
//
// Checkout is decided per request from the connection's lifecycle
// (`checkout_plan`): no connection, or one that is not enabled, keeps the mock
// walkthrough; an enabled Stripe connection charges on the tenant's own account;
// a paused one (payments were enabled and the account is gone) stops
// registrations rather than falling back to a fake payment page.
//
// The aggregate this drives is `<domain>::PaymentConnection`, singleton with
// the slug "payments" (spec/fixtures/rust_host/checkout_fixture carries a
// trimmed copy of it).

use crate::auth;
use crate::checkout::STRIPE_API_VERSION;
use crate::dispatch;
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use crate::web::{instances_for, last_refusal, respond};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_postgres::Client;

mod keystore;
use keystore::{KeyStore, StoredDocument, StoredKeys};

const CONNECTION_SLUG: &str = "payments";
const STATE_PURPOSE: &str = "payment_connect";
const STATE_TTL_SECS: u64 = 600;
const STRIPE_API_BASE: &str = "https://api.stripe.com";
const STRIPE_CONNECT_BASE: &str = "https://connect.stripe.com";
const MODES: [&str; 2] = ["test", "live"];
/// The reserved `account_ref` of a connection that uses the business's own
/// Stripe account directly: no connected account exists, so no
/// `Stripe-Account` header is sent and there is nothing to deauthorize.
pub const SELF_ACCOUNT: &str = "self";
const DIRECT_DISPLAY_FALLBACK: &str = "Your Stripe account";
const STRIPE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// The platform's own payment settings, read from the environment once per
/// request and passed down as a plain value, so a test can build one directly
/// instead of mutating process-wide env vars. Deliberately not `Debug`: it
/// holds secret keys.
#[derive(Clone)]
pub struct PlatformConfig {
    pub site_url: String,
    /// The public origin Stripe delivers webhooks to: `PAYMENTS_WEBHOOK_BASE_URL`,
    /// else `site_url`. The webhook the site creates in a business's own Stripe
    /// account points at `<this>/webhooks/stripe`.
    pub webhook_base_url: String,
    /// Where keys saved from the Payments page live, when this deploy has such a
    /// store (keystore.rs); `None` means keys can only come from the environment.
    pub store: Option<Arc<KeyStore>>,
    /// A snapshot of what the store held when `apply_store` last ran. Empty
    /// until then.
    pub stored: Arc<StoredDocument>,
    pub api_base: String,
    pub connect_base: String,
    pub test_key: String,
    pub live_key: String,
    /// The platform's publishable keys, one per mode. Public values the
    /// browser needs to mount the embedded payment form; unlike the secret
    /// keys they may appear in a response.
    pub test_publishable_key: String,
    pub live_publishable_key: String,
    pub test_client_id: String,
    pub live_client_id: String,
    /// The business's own Stripe keys, one pair per mode, for a deploy that
    /// charges the business's account directly instead of connecting it through
    /// Connect. A mode is available once both its secret and publishable key
    /// are set.
    pub direct_test_key: String,
    pub direct_live_key: String,
    pub direct_test_publishable_key: String,
    pub direct_live_publishable_key: String,
    /// The webhook endpoint's signing secret (the Connect endpoint's, or the
    /// business's own endpoint's in direct mode); `None` when unset.
    pub webhook_secret: Option<String>,
    /// Lower-cased emails allowed to enable or disable real payments.
    pub operators: Vec<String>,
}

impl PlatformConfig {
    pub fn from_env() -> Self {
        let var = |name: &str| std::env::var(name).unwrap_or_default();
        let site_url = std::env::var("SITE_URL").unwrap_or_else(|_| "http://localhost:4321".to_string());
        let webhook_base_url = Some(var("PAYMENTS_WEBHOOK_BASE_URL")).filter(|url| !url.trim().is_empty()).unwrap_or_else(|| site_url.clone()).trim_end_matches('/').to_string();
        Self {
            site_url,
            webhook_base_url,
            store: keystore::default_store(),
            stored: Arc::new(StoredDocument::default()),
            api_base: STRIPE_API_BASE.to_string(),
            connect_base: STRIPE_CONNECT_BASE.to_string(),
            test_key: var("STRIPE_PLATFORM_TEST_KEY"),
            live_key: var("STRIPE_PLATFORM_LIVE_KEY"),
            test_publishable_key: var("STRIPE_PLATFORM_TEST_PUBLISHABLE_KEY"),
            live_publishable_key: var("STRIPE_PLATFORM_LIVE_PUBLISHABLE_KEY"),
            test_client_id: var("STRIPE_CONNECT_TEST_CLIENT_ID"),
            live_client_id: var("STRIPE_CONNECT_LIVE_CLIENT_ID"),
            direct_test_key: var("STRIPE_ACCOUNT_TEST_KEY"),
            direct_live_key: var("STRIPE_ACCOUNT_LIVE_KEY"),
            direct_test_publishable_key: var("STRIPE_ACCOUNT_TEST_PUBLISHABLE_KEY"),
            direct_live_publishable_key: var("STRIPE_ACCOUNT_LIVE_PUBLISHABLE_KEY"),
            webhook_secret: Some(var("STRIPE_WEBHOOK_SECRET")).filter(|s| !s.is_empty()),
            operators: var("PAYMENTS_OPERATOR_EMAILS")
                .split(',')
                .map(|email| email.trim().to_lowercase())
                .filter(|email| !email.is_empty())
                .collect(),
        }
    }

    fn key(&self, mode: &str) -> &str {
        if mode == "live" { &self.live_key } else { &self.test_key }
    }

    fn publishable_key(&self, mode: &str) -> &str {
        if mode == "live" { &self.live_publishable_key } else { &self.test_publishable_key }
    }

    fn client_id(&self, mode: &str) -> &str {
        if mode == "live" { &self.live_client_id } else { &self.test_client_id }
    }

    /// The modes Stripe can be connected in: those with both a platform key
    /// and a Connect client id.
    pub fn modes(&self) -> Vec<&'static str> {
        MODES.into_iter().filter(|mode| !self.key(mode).is_empty() && !self.client_id(mode).is_empty()).collect()
    }

    /// `Self::from_env()` with what the key store holds applied.
    pub async fn load() -> Self {
        let mut platform = Self::from_env();
        platform.apply_store().await;
        platform
    }

    /// Reads the key store into `stored` (from its cache when fresh). A store
    /// that cannot be read leaves only the environment's keys in play, and the
    /// log line says so without saying anything about the keys.
    pub async fn apply_store(&mut self) {
        let Some(store) = self.store.clone() else { return };
        match store.document().await {
            Ok(document) => self.stored = document,
            Err(e) => eprintln!("the saved payment keys could not be read, so only environment keys are used: {e}"),
        }
    }

    /// Whether this deploy can save keys from the Payments page.
    pub fn can_save_keys(&self) -> bool {
        self.store.is_some()
    }

    /// Whether any real Stripe credential exists here: a platform key, the
    /// business's own key from the environment, or keys saved from the Payments
    /// page. While one does, the public mock webhook secret must never verify
    /// anything.
    pub fn has_real_credentials(&self) -> bool {
        let configured = [&self.test_key, &self.live_key, &self.direct_test_key, &self.direct_live_key].iter().any(|key| !key.is_empty());
        let saved = [&self.stored.test, &self.stored.live].iter().any(|keys| keys.as_ref().is_some_and(|keys| !keys.secret_key.is_empty()));
        configured || saved
    }

    /// Every webhook signing secret this deploy accepts: the environment's, then
    /// any saved with the business's keys.
    pub fn webhook_secrets(&self) -> Vec<&str> {
        self.webhook_secret.iter().map(String::as_str).chain(self.stored.webhook_secrets()).collect()
    }

    // The business's own keys for `mode`: the environment's pair when both are
    // set, else the pair saved from the Payments page, else whatever the
    // environment has (which then leaves the mode unavailable).
    fn direct_pair(&self, mode: &str) -> (&str, &str) {
        let (key, publishable) =
            if mode == "live" { (&self.direct_live_key, &self.direct_live_publishable_key) } else { (&self.direct_test_key, &self.direct_test_publishable_key) };
        if !key.is_empty() && !publishable.is_empty() {
            return (key, publishable);
        }
        match self.stored.mode(mode) {
            Some(saved) if !saved.secret_key.is_empty() && !saved.publishable_key.is_empty() => (&saved.secret_key, &saved.publishable_key),
            _ => (key, publishable),
        }
    }

    fn direct_key(&self, mode: &str) -> &str {
        self.direct_pair(mode).0
    }

    fn direct_publishable_key(&self, mode: &str) -> &str {
        self.direct_pair(mode).1
    }

    /// The modes the business's own account can be used in: those with both
    /// its secret key and its publishable key, from the environment or saved.
    pub fn direct_modes(&self) -> Vec<&'static str> {
        MODES.into_iter().filter(|mode| !self.direct_key(mode).is_empty() && !self.direct_publishable_key(mode).is_empty()).collect()
    }

    fn is_operator(&self, email: &str) -> bool {
        self.operators.contains(&email.to_lowercase())
    }
}

/// The public facts a tenant's `PaymentConnection` holds.
pub struct Connection {
    pub status: String,
    pub processor: String,
    pub account_ref: String,
    pub mode: String,
    pub display_name: String,
}

impl Connection {
    /// Whether this connection uses the business's own Stripe account
    /// directly (`account_ref` is `SELF_ACCOUNT`) rather than a connected one.
    pub fn is_direct(&self) -> bool {
        self.account_ref == SELF_ACCOUNT
    }
}

/// This tenant's connection, read out of the replayed instances, or `None`
/// until an Owner has connected an account.
pub fn connection(read: &Value, domain: &str) -> Option<Connection> {
    let (_, state) = instances_for(read, &format!("{domain}::PaymentConnection#")).into_iter().find(|(id, _)| id == CONNECTION_SLUG)?;
    let text = |field: &str| state.get(field).and_then(|v| v.get("value")).and_then(|v| v.as_str()).unwrap_or_default().to_string();
    Some(Connection {
        status: state.get("status").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        processor: text("processor"),
        account_ref: text("account_ref"),
        mode: text("mode"),
        display_name: text("display_name"),
    })
}

/// What checkout does for one request.
pub enum CheckoutPlan {
    /// No connection, or one that is not enabled: the mock walkthrough.
    Mock,
    /// Payments are enabled: a direct charge on the tenant's own account. For a
    /// connected account the call is authenticated with the platform's key for
    /// the connection's mode and names the account; for the business's own
    /// account (`account` is `None`) it is authenticated with that account's
    /// own key and names no other account. The guest pays in a form embedded in
    /// the site, which the browser mounts with the matching publishable key.
    Stripe { api_key: String, publishable_key: String, account: Option<String> },
    /// Payments were enabled and cannot be taken now. Registrations answer
    /// 503; never a fallback to the mock.
    Paused,
}

/// Decides checkout for this request from the tenant's own connection, never
/// from a process-wide setting. An enabled connection whose processor is not
/// one this host can charge, or whose platform key or publishable key is not
/// configured, is paused too: real guests must never be shown a fake payment
/// page, and the embedded form cannot be mounted without the publishable key.
pub fn checkout_plan(connection: Option<&Connection>, platform: &PlatformConfig) -> CheckoutPlan {
    let Some(connection) = connection else { return CheckoutPlan::Mock };
    match connection.status.as_str() {
        "enabled" => {
            let direct = connection.is_direct();
            let (key, publishable_key, prefix) = if direct {
                (platform.direct_key(&connection.mode), platform.direct_publishable_key(&connection.mode), "ACCOUNT")
            } else {
                (platform.key(&connection.mode), platform.publishable_key(&connection.mode), "PLATFORM")
            };
            if connection.processor != "stripe" || key.is_empty() {
                CheckoutPlan::Paused
            } else if publishable_key.is_empty() {
                eprintln!(
                    "payments are paused: the {} mode has a Stripe key but no publishable key (set STRIPE_{prefix}_{}_PUBLISHABLE_KEY)",
                    connection.mode,
                    connection.mode.to_uppercase()
                );
                CheckoutPlan::Paused
            } else {
                let account = if direct { None } else { Some(connection.account_ref.clone()) };
                CheckoutPlan::Stripe { api_key: key.to_string(), publishable_key: publishable_key.to_string(), account }
            }
        }
        "paused" => CheckoutPlan::Paused,
        _ => CheckoutPlan::Mock,
    }
}

/// How a verified webhook event relates to this tenant's connection.
pub enum EventScope {
    /// Not this tenant's event, or an account event that cannot be tied to
    /// its connected account: acknowledged and otherwise ignored.
    Ignore,
    /// Stripe reports the tenant revoked the platform's access.
    Deauthorized,
    /// An ordinary event for the checkout handlers.
    Proceed,
}

/// One platform endpoint receives every tenant's events, so an event that
/// names some other connected account is not this tenant's to act on. Events
/// with no `account` (direct or synthetic) proceed unchanged. A business using
/// its own account (`account_ref` "self") receives only account-less events, so
/// any event that does name an account is someone else's and is ignored.
pub fn event_scope(event: &Value, connection: Option<&Connection>) -> EventScope {
    let account = event.get("account").and_then(|v| v.as_str());
    let ours = connection.map(|c| c.account_ref.as_str());
    if account.is_some() && account != ours {
        return EventScope::Ignore;
    }
    if event.get("type").and_then(|v| v.as_str()) == Some("account.application.deauthorized") {
        return if account.is_some() { EventScope::Deauthorized } else { EventScope::Ignore };
    }
    EventScope::Proceed
}

/// The tenant revoked access from Stripe's side: same outcome as an Owner
/// disconnecting here. Enabled payments pause, a connection that was never
/// enabled just unlinks, anything else is left alone.
pub async fn apply_deauthorization(
    connection: Option<&Connection>,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<()> {
    let command = match connection.map(|c| c.status.as_str()) {
        Some("enabled") => "Suspend",
        Some("connected") => "Disconnect",
        _ => return Ok(()),
    };
    dispatch_on_connection(command, json!({}), client, wasm_path, config, invoker).await?;
    Ok(())
}

async fn dispatch_on_connection(
    command: &str,
    facts: Value,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<dispatch::Outcome> {
    let verb = format!("{}::PaymentConnection.{command}", config.domain);
    dispatch::handle_routed(client, wasm_path, &verb, json!(CONNECTION_SLUG), facts, None, config, invoker).await
}

// ---- routes ------------------------------------------------------------

/// Whether `path` belongs to the payments surface.
pub fn owns(method: &str, path: &str) -> bool {
    matches!(
        (method, path),
        ("GET", "/payments/connection")
            | ("POST", "/payments/connection/authorize-url")
            | ("POST", "/payments/connection/callback")
            | ("POST", "/payments/connection/direct")
            | ("POST", "/payments/connection/disconnect")
            | ("POST", "/payments/connection/enable")
            | ("POST", "/payments/connection/disable")
    )
}

fn json_error(status: u16, message: &str) -> Value {
    respond(status, "application/json", &json!({"error": message}).to_string())
}

fn refusal_message(refusal: &Value) -> String {
    ["message", "error"].iter().find_map(|key| refusal.get(*key).and_then(|v| v.as_str())).unwrap_or("Refused").to_string()
}

struct Caller {
    email: String,
    owner: bool,
    operator: bool,
}

// The person behind an account cookie, only while they still
// have access, with what they may do here. `Err` is the JSON response.
async fn caller(domain_ir: &Value, cookies: &HashMap<String, String>, secret: &str, client: &Mutex<Client>, platform: &PlatformConfig) -> Result<Caller, Value> {
    let not_logged_in = || json_error(401, "not logged in");
    let Some(email) = cookies.get(&auth::account_cookie_name()).and_then(|token| auth::verify_account_token(secret, token)) else {
        return Err(not_logged_in());
    };
    match auth::active_role(client, domain_ir, &email).await {
        Ok(Some(role)) => Ok(Caller { owner: role == "Owner", operator: platform.is_operator(&email), email }),
        Ok(None) => Err(not_logged_in()),
        Err(e) => Err(json_error(500, &format!("members lookup failed: {e}"))),
    }
}

fn require_owner(caller: &Caller) -> Result<(), Value> {
    if caller.owner { Ok(()) } else { Err(json_error(403, "only an Owner can manage payments")) }
}

fn require_operator(caller: &Caller) -> Result<(), Value> {
    if caller.operator { Ok(()) } else { Err(json_error(403, "only the platform operator can change whether payments are enabled")) }
}

// What the payments page may show: public facts and which processors can be
// connected. Built field by field, so a credential can never appear here: none
// is ever read into this value.
fn connection_json(connection: Option<&Connection>, platform: &PlatformConfig, caller: &Caller) -> Value {
    let label = connection.filter(|c| c.processor == "stripe").map(|_| "Stripe");
    let present = |value: Option<&str>| value.filter(|s| !s.is_empty()).map(Value::from).unwrap_or(Value::Null);
    let stripe_modes = platform.modes();
    let adapters = if stripe_modes.is_empty() { json!([]) } else { json!([{"processor": "stripe", "label": "Stripe", "modes": stripe_modes}]) };
    json!({
        "status": connection.map(|c| c.status.as_str()).unwrap_or("not_connected"),
        "processor": present(connection.map(|c| c.processor.as_str())),
        "label": label,
        "account_ref": present(connection.map(|c| c.account_ref.as_str())),
        "mode": present(connection.map(|c| c.mode.as_str())),
        "display_name": present(connection.map(|c| c.display_name.as_str())),
        "adapters": adapters,
        "direct_modes": platform.direct_modes(),
        "direct": connection.is_some_and(Connection::is_direct),
        "can_save_keys": platform.can_save_keys(),
        "can_manage": caller.owner,
        "can_enable": caller.operator,
    })
}

async fn current_connection(client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig) -> Result<Option<Connection>, Value> {
    match dispatch::read(client, wasm_path).await {
        Ok(read) => Ok(connection(&read, &config.domain)),
        Err(e) => Err(json_error(500, &format!("payment connection lookup failed: {e:#}"))),
    }
}

async fn connection_response(caller: &Caller, platform: &PlatformConfig, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, remote_disconnected: Option<bool>) -> Value {
    match current_connection(client, wasm_path, config).await {
        Ok(connection) => {
            let mut body = connection_json(connection.as_ref(), platform, caller);
            if let Some(remote) = remote_disconnected {
                body["remote_disconnected"] = json!(remote);
            }
            respond(200, "application/json", &body.to_string())
        }
        Err(response) => response,
    }
}

/// The `/payments/connection` routes, for a server-side caller holding the
/// account cookie. Every answer is JSON, and a missing, invalid
/// or no-longer-valid session is a 401, never a redirect. `None` for a path
/// this module does not own.
#[allow(clippy::too_many_arguments)]
pub async fn route(
    method: &str,
    path: &str,
    raw_body: &str,
    cookies: &HashMap<String, String>,
    secret: &str,
    domain_ir: &Value,
    platform: &PlatformConfig,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    if !owns(method, path) {
        return None;
    }
    let caller = match caller(domain_ir, cookies, secret, client, platform).await {
        Ok(caller) => caller,
        Err(response) => return Some(response),
    };
    Some(match path {
        "/payments/connection" => show(&caller, platform, client, wasm_path, config).await,
        "/payments/connection/authorize-url" => authorize_url_route(&caller, raw_body, secret, platform),
        "/payments/connection/callback" => callback_route(&caller, raw_body, secret, platform, client, wasm_path, config, invoker).await,
        "/payments/connection/direct" => direct_route(&caller, raw_body, platform, client, wasm_path, config, invoker).await,
        "/payments/connection/disconnect" => disconnect_route(&caller, platform, client, wasm_path, config, invoker).await,
        "/payments/connection/enable" => switch_route(&caller, "EnablePayments", platform, client, wasm_path, config, invoker).await,
        _ => switch_route(&caller, "DisablePayments", platform, client, wasm_path, config, invoker).await,
    })
}

// GET: readable by an Owner or the operator, nobody else.
async fn show(caller: &Caller, platform: &PlatformConfig, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig) -> Value {
    if !caller.owner && !caller.operator {
        return json_error(403, "not permitted");
    }
    connection_response(caller, platform, client, wasm_path, config, None).await
}

fn body_field(body: &Value, key: &str) -> Result<String, Value> {
    body.get(key).and_then(|v| v.as_str()).map(String::from).ok_or_else(|| json_error(400, &format!("missing {key}")))
}

fn parse_body(raw_body: &str) -> Result<Value, Value> {
    serde_json::from_str(raw_body).map_err(|e| json_error(400, &format!("invalid JSON: {e}")))
}

// Step one of connecting: an Owner picks a processor and a mode; the answer is
// the processor's own authorization URL, carrying a short-lived signed `state`
// bound to this person so the callback can prove the same one came back. The
// state is signed under its own purpose, so it can never pass as a session.
fn authorize_url_route(caller: &Caller, raw_body: &str, secret: &str, platform: &PlatformConfig) -> Value {
    let respond_with = || -> Result<Value, Value> {
        require_owner(caller)?;
        let body = parse_body(raw_body)?;
        let processor = body_field(&body, "processor")?;
        let mode = body_field(&body, "mode")?;
        if processor != "stripe" {
            return Err(json_error(422, "unknown payment processor"));
        }
        if !platform.modes().contains(&mode.as_str()) {
            return Err(json_error(422, &format!("Stripe is not set up for {mode} mode")));
        }
        let state = auth::purpose_token(secret, STATE_PURPOSE, json!({"email": caller.email, "processor": processor, "mode": mode}), STATE_TTL_SECS);
        let redirect_uri = format!("{}/api/payment-connect-callback", platform.site_url);
        let mut url = reqwest::Url::parse(&format!("{}/oauth/authorize", platform.connect_base)).map_err(|e| json_error(500, &format!("bad Connect URL: {e}")))?;
        url.query_pairs_mut()
            .append_pair("response_type", "code")
            .append_pair("scope", "read_write")
            .append_pair("state", &state)
            .append_pair("redirect_uri", &redirect_uri)
            .append_pair("client_id", platform.client_id(&mode));
        Ok(respond(200, "application/json", &json!({"url": url.to_string()}).to_string()))
    };
    respond_with().unwrap_or_else(|response| response)
}

// Step two: the processor sent the person's browser back with a `code`, which
// the site forwards here. Only the processor is asked to trade it; what comes
// back is the public account id, which is all that is stored.
#[allow(clippy::too_many_arguments)]
async fn callback_route(
    caller: &Caller,
    raw_body: &str,
    secret: &str,
    platform: &PlatformConfig,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    if let Err(response) = require_owner(caller) {
        return response;
    }
    let body = match parse_body(raw_body) {
        Ok(body) => body,
        Err(response) => return response,
    };
    let (code, state) = match (body_field(&body, "code"), body_field(&body, "state")) {
        (Ok(code), Ok(state)) => (code, state),
        (Err(response), _) | (_, Err(response)) => return response,
    };
    let claims = auth::verify_purpose_token(secret, STATE_PURPOSE, &state).filter(|c| c.get("email").and_then(|v| v.as_str()) == Some(caller.email.as_str()));
    let Some(claims) = claims else {
        return json_error(400, "this connection attempt expired — start again");
    };
    let mode = claims.get("mode").and_then(|v| v.as_str()).unwrap_or_default().to_string();
    if claims.get("processor").and_then(|v| v.as_str()) != Some("stripe") {
        return json_error(422, "unknown payment processor");
    }

    let account = match complete_connection(platform, &mode, &code).await {
        Ok(account) => account,
        Err(message) => return json_error(422, &format!("Stripe could not connect that account: {message}")),
    };
    let facts = json!({
        "processor": {"value": "stripe"},
        "account_ref": {"value": account.account_ref},
        "mode": {"value": account.mode},
        "display_name": {"value": account.display_name},
    });
    record_connection(caller, platform, facts, client, wasm_path, config, invoker).await
}

// Records the connection an Owner just made, whichever way they made it: a
// first connection creates the singleton, a disconnected one reconnects, a
// paused one resumes, and anything else already has an account linked.
async fn record_connection(
    caller: &Caller,
    platform: &PlatformConfig,
    facts: Value,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let existing = match current_connection(client, wasm_path, config).await {
        Ok(existing) => existing,
        Err(response) => return response,
    };
    let outcome = match existing.as_ref().map(|c| c.status.as_str()) {
        None => {
            let mut creation = facts;
            creation["slug"] = json!({"value": CONNECTION_SLUG});
            dispatch::handle_facts(client, wasm_path, &format!("{}::PaymentConnection.Connect", config.domain), creation, None, config, invoker).await
        }
        Some("disconnected") => dispatch_on_connection("Reconnect", facts, client, wasm_path, config, invoker).await,
        Some("paused") => dispatch_on_connection("Resume", facts, client, wasm_path, config, invoker).await,
        Some(_) => return json_error(409, "an account is already connected — disconnect it first"),
    };
    match outcome {
        Ok(outcome) if outcome.accepted => connection_response(caller, platform, client, wasm_path, config, None).await,
        Ok(outcome) => json_error(422, &refusal_message(&last_refusal(&outcome.result))),
        Err(e) => json_error(500, &format!("{e:#}")),
    }
}

// The business's own account, used directly (no Connect). An Owner picks a
// mode; the answer is the same connection JSON the OAuth callback gives. Only
// the public facts are stored: the reserved account ref, the mode and a display
// name read with the account's own key. That key is never stored or logged.
#[allow(clippy::too_many_arguments)]
async fn direct_route(caller: &Caller, raw_body: &str, platform: &PlatformConfig, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    if let Err(response) = require_owner(caller) {
        return response;
    }
    let body = match parse_body(raw_body) {
        Ok(body) => body,
        Err(response) => return response,
    };
    // The Payments page's Save form sends the keys themselves; the older form
    // names a mode whose keys are already in the environment.
    if body.get("secret_key").is_some() || body.get("publishable_key").is_some() {
        return save_keys_route(caller, &body, platform, client, wasm_path, config, invoker).await;
    }
    let mode = match body_field(&body, "mode") {
        Ok(mode) => mode,
        Err(response) => return response,
    };
    if !platform.direct_modes().contains(&mode.as_str()) {
        return json_error(422, &format!("this site's own Stripe account is not set up for {mode} mode"));
    }
    let display_name = own_account_display_name(platform, platform.direct_key(&mode)).await;
    let facts = json!({
        "processor": {"value": "stripe"},
        "account_ref": {"value": SELF_ACCOUNT},
        "mode": {"value": mode},
        "display_name": {"value": display_name},
    });
    record_connection(caller, platform, facts, client, wasm_path, config, invoker).await
}

// Disconnect. Not enabled: a plain disconnect. Enabled: registrations pause
// instead, because real guests have paid through this account. Either way
// Stripe is told to revoke access first, best effort: a processor that is
// down must not leave the tenant stuck unable to disconnect, so the outcome is
// reported in `remote_disconnected` rather than raised. The business's own
// account has nothing to revoke, so it makes no Stripe call and reports no
// `remote_disconnected`.
async fn disconnect_route(caller: &Caller, platform: &PlatformConfig, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    if let Err(response) = require_owner(caller) {
        return response;
    }
    let existing = match current_connection(client, wasm_path, config).await {
        Ok(existing) => existing,
        Err(response) => return response,
    };
    let Some(existing) = existing.filter(|c| matches!(c.status.as_str(), "connected" | "enabled")) else {
        return json_error(409, "nothing to disconnect");
    };

    let remote = if existing.is_direct() { None } else { Some(existing.processor == "stripe" && revoke_access(platform, &existing.mode, &existing.account_ref).await) };
    let command = if existing.status == "enabled" { "Suspend" } else { "Disconnect" };
    match dispatch_on_connection(command, json!({}), client, wasm_path, config, invoker).await {
        Ok(outcome) if outcome.accepted => {
            // The business's own account: take the webhook out of its Stripe
            // account and delete what was saved, so nothing keeps working after
            // an Owner disconnects.
            if existing.is_direct() {
                forget_saved_keys(platform, &existing.mode).await;
            }
            let refreshed = refreshed(platform).await;
            connection_response(caller, &refreshed, client, wasm_path, config, remote).await
        }
        Ok(outcome) => json_error(422, &refusal_message(&last_refusal(&outcome.result))),
        Err(e) => json_error(500, &format!("{e:#}")),
    }
}

// Enable or disable real payments: operator only.
async fn switch_route(caller: &Caller, command: &str, platform: &PlatformConfig, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    if let Err(response) = require_operator(caller) {
        return response;
    }
    match current_connection(client, wasm_path, config).await {
        Ok(Some(_)) => {}
        Ok(None) => return json_error(409, "connect an account first"),
        Err(response) => return response,
    }
    match dispatch_on_connection(command, json!({}), client, wasm_path, config, invoker).await {
        Ok(outcome) if outcome.accepted => connection_response(caller, platform, client, wasm_path, config, None).await,
        Ok(outcome) => json_error(422, &refusal_message(&last_refusal(&outcome.result))),
        Err(e) => json_error(500, &format!("{e:#}")),
    }
}

// ---- Stripe Connect calls ----------------------------------------------

struct ConnectedAccount {
    account_ref: String,
    mode: String,
    display_name: String,
}

fn stripe_error_message(body: &Value) -> String {
    let error = body.get("error");
    body.get("error_description")
        .and_then(|v| v.as_str())
        .or_else(|| error.and_then(|e| e.get("message")).and_then(|v| v.as_str()))
        .or_else(|| error.and_then(|e| e.as_str()))
        .unwrap_or("unknown Stripe error")
        .to_string()
}

fn stripe_http() -> Result<reqwest::Client, String> {
    reqwest::Client::builder().timeout(STRIPE_TIMEOUT).build().map_err(|e| e.to_string())
}

// Trades the OAuth `code` for the connected account's id, using the platform's
// key for `mode`. Stripe reports which mode the authorized account is really
// in; that is trusted over the mode the caller asked for, and a mismatch is
// refused. The access token in the response is never read.
async fn complete_connection(platform: &PlatformConfig, mode: &str, code: &str) -> Result<ConnectedAccount, String> {
    let key = platform.key(mode);
    if key.is_empty() {
        return Err(format!("Stripe {mode} platform key is not configured"));
    }
    let response = stripe_http()?
        .post(format!("{}/oauth/token", platform.connect_base))
        .bearer_auth(key)
        .form(&[("grant_type", "authorization_code"), ("code", code)])
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let status = response.status();
    let token: Value = response.json().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(stripe_error_message(&token));
    }

    let actual = if token.get("livemode").and_then(|v| v.as_bool()) == Some(true) { "live" } else { "test" };
    if actual != mode {
        return Err(format!("Stripe authorized a {actual} account but {mode} was requested"));
    }
    let account_ref = token.get("stripe_user_id").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).ok_or("Stripe's response carried no account id")?.to_string();
    let display_name = account_display_name(platform, key, &account_ref).await;
    Ok(ConnectedAccount { account_ref, mode: actual.to_string(), display_name })
}

// The business name shown on the payments page. Falls back to the account id
// when Stripe cannot be asked or has nothing better.
async fn account_display_name(platform: &PlatformConfig, key: &str, account_ref: &str) -> String {
    let fetch = async {
        let response = stripe_http()?.get(format!("{}/v1/accounts/{account_ref}", platform.api_base)).bearer_auth(key).send().await.map_err(|e| e.to_string())?;
        if !response.status().is_success() {
            return Err("account lookup refused".to_string());
        }
        response.json::<Value>().await.map_err(|e| e.to_string())
    };
    let Ok(account) = fetch.await else { return account_ref.to_string() };
    let candidates = [
        account.get("business_profile").and_then(|p| p.get("name")),
        account.get("settings").and_then(|s| s.get("dashboard")).and_then(|d| d.get("display_name")),
        account.get("email"),
    ];
    let name = candidates.into_iter().flatten().find_map(|v| v.as_str().filter(|s| !s.is_empty())).unwrap_or(account_ref).to_string();
    name
}

// The name of the business's own account, read with that account's own key
// (`GET /v1/account`). Falls back to a generic label when Stripe cannot be
// asked or has nothing better; the key is only ever sent as the bearer.
async fn own_account_display_name(platform: &PlatformConfig, key: &str) -> String {
    let fetch = async {
        let response = stripe_http()?.get(format!("{}/v1/account", platform.api_base)).bearer_auth(key).send().await.map_err(|e| e.to_string())?;
        if !response.status().is_success() {
            return Err("account lookup refused".to_string());
        }
        response.json::<Value>().await.map_err(|e| e.to_string())
    };
    let Ok(account) = fetch.await else { return DIRECT_DISPLAY_FALLBACK.to_string() };
    let candidates = [
        account.get("business_profile").and_then(|p| p.get("name")),
        account.get("settings").and_then(|s| s.get("dashboard")).and_then(|d| d.get("display_name")),
        account.get("email"),
    ];
    let name = candidates.into_iter().flatten().find_map(|v| v.as_str().filter(|s| !s.is_empty())).unwrap_or(DIRECT_DISPLAY_FALLBACK).to_string();
    name
}

// ---- saving the business's own keys --------------------------------------

const KEYS_NOT_ENABLED: &str = "saving keys is not set up on this site";
const KEY_REFUSED: &str = "Stripe did not accept that key.";
const STRIPE_UNREACHABLE: &str = "Could not reach Stripe. Please try again in a moment.";
const WEBHOOK_PERMISSION: &str = "That key can't create the webhook. In Stripe, give it Webhook Endpoints → Write as well and try again.";
const WEBHOOK_FAILED: &str = "Stripe could not set up the payment webhook. Please try again.";
const STORE_FAILED: &str = "The keys could not be stored, so nothing was saved. Please try again.";
const WEBHOOK_EVENTS: [&str; 3] = ["checkout.session.completed", "checkout.session.expired", "charge.refunded"];
const WEBHOOK_DESCRIPTION: &str = "Lifeadelics website";

// A copy of `platform` with the key store read again, for a response that must
// show the keys just saved or removed.
async fn refreshed(platform: &PlatformConfig) -> PlatformConfig {
    let mut fresh = platform.clone();
    fresh.apply_store().await;
    fresh
}

// The mode both keys belong to. Each message says what to fix and never quotes
// any part of a key.
fn keys_mode(secret_key: &str, publishable_key: &str) -> Result<&'static str, &'static str> {
    let secret_mode = ["rk_test_", "sk_test_"]
        .iter()
        .any(|prefix| secret_key.starts_with(prefix))
        .then_some("test")
        .or_else(|| ["rk_live_", "sk_live_"].iter().any(|prefix| secret_key.starts_with(prefix)).then_some("live"))
        .ok_or("That does not look like a Stripe restricted key. It should start with rk_test_ or rk_live_.")?;
    let publishable_mode = if publishable_key.starts_with("pk_test_") {
        "test"
    } else if publishable_key.starts_with("pk_live_") {
        "live"
    } else {
        return Err("That does not look like a Stripe publishable key. It should start with pk_test_ or pk_live_.");
    };
    if secret_mode == publishable_mode {
        Ok(secret_mode)
    } else {
        Err("One key is for test mode and the other is for live mode. Use two keys from the same mode.")
    }
}

// The business name Stripe has for an account, when it has one.
fn business_name(account: &Value) -> Option<String> {
    let candidates = [
        account.get("business_profile").and_then(|p| p.get("name")),
        account.get("settings").and_then(|s| s.get("dashboard")).and_then(|d| d.get("display_name")),
        account.get("email"),
    ];
    candidates.into_iter().flatten().find_map(|v| v.as_str().filter(|s| !s.is_empty())).map(String::from)
}

// Asks Stripe whether the key works and what the business is called. Only a key
// Stripe rejects outright is refused here: a restricted key may not be allowed
// to read the account at all, so that reads as the generic name, and creating
// the webhook is the real test of its permissions.
async fn verify_key(platform: &PlatformConfig, key: &str) -> Result<String, &'static str> {
    let response = stripe_http()
        .map_err(|_| STRIPE_UNREACHABLE)?
        .get(format!("{}/v1/account", platform.api_base))
        .bearer_auth(key)
        .header("Stripe-Version", STRIPE_API_VERSION)
        .send()
        .await
        .map_err(|_| STRIPE_UNREACHABLE)?;
    let status = response.status();
    if status.as_u16() == 401 {
        return Err(KEY_REFUSED);
    }
    if !status.is_success() {
        return Ok(DIRECT_DISPLAY_FALLBACK.to_string());
    }
    let account = response.json::<Value>().await.unwrap_or(Value::Null);
    Ok(business_name(&account).unwrap_or_else(|| DIRECT_DISPLAY_FALLBACK.to_string()))
}

enum WebhookError {
    /// The key is not allowed to create webhook endpoints.
    Permission,
    /// Anything else: Stripe down, refusing the request, or answering oddly.
    Other,
}

// Creates the webhook endpoint in the business's own Stripe account and returns
// its id and signing secret. Stripe shows the signing secret only in this
// answer, so it is captured here and nowhere else. Only the status is logged.
async fn create_webhook(platform: &PlatformConfig, key: &str) -> Result<(String, String), WebhookError> {
    let url = format!("{}/webhooks/stripe", platform.webhook_base_url);
    let mut params: Vec<(String, String)> = vec![("url".into(), url), ("description".into(), WEBHOOK_DESCRIPTION.into())];
    params.extend(WEBHOOK_EVENTS.iter().enumerate().map(|(index, event)| (format!("enabled_events[{index}]"), event.to_string())));
    let response = stripe_http()
        .map_err(|_| WebhookError::Other)?
        .post(format!("{}/v1/webhook_endpoints", platform.api_base))
        .bearer_auth(key)
        .header("Stripe-Version", STRIPE_API_VERSION)
        .form(&params)
        .send()
        .await
        .map_err(|_| WebhookError::Other)?;
    let status = response.status();
    if matches!(status.as_u16(), 401 | 403) {
        return Err(WebhookError::Permission);
    }
    if !status.is_success() {
        eprintln!("Stripe refused to create the payment webhook ({status})");
        return Err(WebhookError::Other);
    }
    let body: Value = response.json().await.map_err(|_| WebhookError::Other)?;
    let text = |field: &str| body.get(field).and_then(|v| v.as_str()).filter(|s| !s.is_empty()).map(String::from);
    match (text("id"), text("secret")) {
        (Some(id), Some(secret)) => Ok((id, secret)),
        _ => Err(WebhookError::Other),
    }
}

// Removes a webhook endpoint from the business's Stripe account, best effort:
// the answer says whether Stripe confirmed it, and nothing else is reported.
async fn delete_webhook(platform: &PlatformConfig, key: &str, endpoint_id: &str) -> bool {
    let Ok(http) = stripe_http() else { return false };
    let sent = http.delete(format!("{}/v1/webhook_endpoints/{endpoint_id}", platform.api_base)).bearer_auth(key).header("Stripe-Version", STRIPE_API_VERSION).send().await;
    matches!(sent, Ok(response) if response.status().is_success())
}

// The Payments page's Save: check the keys, have Stripe deliver events to this
// site, keep the keys and the webhook's signing secret in the store, and record
// the connection as the business's own account. Saving again while the same
// account is already connected replaces the keys and the webhook in place.
// Nothing here answers with, logs or errors with a key.
#[allow(clippy::too_many_arguments)]
async fn save_keys_route(caller: &Caller, body: &Value, platform: &PlatformConfig, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let Some(store) = platform.store.clone() else { return json_error(422, KEYS_NOT_ENABLED) };
    let (secret_key, publishable_key) = match (body_field(body, "secret_key"), body_field(body, "publishable_key")) {
        (Ok(secret), Ok(publishable)) => (secret.trim().to_string(), publishable.trim().to_string()),
        (Err(response), _) | (_, Err(response)) => return response,
    };
    let mode = match keys_mode(&secret_key, &publishable_key) {
        Ok(mode) => mode,
        Err(message) => return json_error(422, message),
    };
    let existing = match current_connection(client, wasm_path, config).await {
        Ok(existing) => existing,
        Err(response) => return response,
    };
    let in_place = match existing.as_ref() {
        Some(c) if matches!(c.status.as_str(), "connected" | "enabled") => {
            if !(c.is_direct() && c.mode == mode) {
                return json_error(409, "an account is already connected — disconnect it first");
            }
            true
        }
        _ => false,
    };
    let display_name = match verify_key(platform, &secret_key).await {
        Ok(name) => name,
        Err(message) => return json_error(422, message),
    };

    // What the last save made, to be replaced once the new webhook is safely
    // stored: a save that fails part way must never leave the business without
    // a working webhook.
    let previous = store.refresh().await.ok().and_then(|document| document.mode(mode).cloned()).filter(|old| !old.webhook_endpoint_id.is_empty());
    let (endpoint_id, webhook_secret) = match create_webhook(platform, &secret_key).await {
        Ok(created) => created,
        Err(WebhookError::Permission) => return json_error(422, WEBHOOK_PERMISSION),
        Err(WebhookError::Other) => return json_error(422, WEBHOOK_FAILED),
    };
    let saved = StoredKeys { secret_key: secret_key.clone(), publishable_key, webhook_secret, webhook_endpoint_id: endpoint_id.clone(), saved_at: keystore::now_timestamp() };
    if let Err(e) = store.update(|document| document.set(mode, Some(saved))).await {
        eprintln!("saving the payment keys failed: {e}");
        delete_webhook(platform, &secret_key, &endpoint_id).await;
        return json_error(500, STORE_FAILED);
    }
    // The new webhook and keys are stored, so the old webhook can go. Best
    // effort: one that cannot be removed only stays in Stripe, unused.
    if let Some(old) = previous {
        if !delete_webhook(platform, &old.secret_key, &old.webhook_endpoint_id).await {
            eprintln!("the previous Stripe webhook could not be removed");
        }
    }

    let fresh = refreshed(platform).await;
    if in_place {
        return connection_response(caller, &fresh, client, wasm_path, config, None).await;
    }
    let facts = json!({
        "processor": {"value": "stripe"},
        "account_ref": {"value": SELF_ACCOUNT},
        "mode": {"value": mode},
        "display_name": {"value": display_name},
    });
    let response = record_connection(caller, &fresh, facts, client, wasm_path, config, invoker).await;
    if response["statusCode"].as_u64() != Some(200) {
        // The domain would not record the connection, so leave nothing behind.
        delete_webhook(platform, &secret_key, &endpoint_id).await;
        if store.update(|document| document.set(mode, None)).await.is_err() {
            eprintln!("the saved payment keys could not be removed after a refused connection");
        }
    }
    response
}

// After an Owner disconnects the business's own account: remove the webhook
// from its Stripe account and delete the saved keys for that mode. Best effort,
// logged without any secret; keys that came from the environment are not
// touched, and neither is Stripe if no webhook was ever saved.
async fn forget_saved_keys(platform: &PlatformConfig, mode: &str) {
    let Some(store) = platform.store.clone() else { return };
    let saved = match store.refresh().await {
        Ok(document) => document.mode(mode).cloned(),
        Err(e) => {
            eprintln!("the saved payment keys could not be read for removal: {e}");
            return;
        }
    };
    let Some(saved) = saved else { return };
    if !saved.webhook_endpoint_id.is_empty() && !delete_webhook(platform, &saved.secret_key, &saved.webhook_endpoint_id).await {
        eprintln!("the Stripe webhook could not be removed from the business's account");
    }
    if let Err(e) = store.update(|document| document.set(mode, None)).await {
        eprintln!("the saved payment keys could not be deleted: {e}");
    }
}

// Asks Stripe to revoke the platform's access to the account. True when Stripe
// confirmed it; false for any failure, including missing platform settings.
async fn revoke_access(platform: &PlatformConfig, mode: &str, account_ref: &str) -> bool {
    let (key, client_id) = (platform.key(mode), platform.client_id(mode));
    if key.is_empty() || client_id.is_empty() {
        return false;
    }
    let Ok(http) = stripe_http() else { return false };
    let sent = http
        .post(format!("{}/oauth/deauthorize", platform.connect_base))
        .bearer_auth(key)
        .form(&[("client_id", client_id), ("stripe_user_id", account_ref)])
        .send()
        .await;
    matches!(sent, Ok(response) if response.status().is_success())
}

/// A platform with nothing configured: no keys, no webhook secret, and Stripe
/// base URLs that nothing listens on. What a mock deploy looks like.
#[cfg(test)]
pub(crate) fn test_platform() -> PlatformConfig {
    PlatformConfig {
        site_url: "http://localhost:4321".to_string(),
        webhook_base_url: "http://localhost:4321".to_string(),
        store: None,
        stored: Arc::new(StoredDocument::default()),
        api_base: "http://127.0.0.1:9".to_string(),
        connect_base: "http://127.0.0.1:9".to_string(),
        test_key: String::new(),
        live_key: String::new(),
        test_publishable_key: String::new(),
        live_publishable_key: String::new(),
        test_client_id: String::new(),
        live_client_id: String::new(),
        direct_test_key: String::new(),
        direct_live_key: String::new(),
        direct_test_publishable_key: String::new(),
        direct_live_publishable_key: String::new(),
        webhook_secret: None,
        operators: Vec::new(),
    }
}

/// `test_platform` with the Connect webhook signing secret set.
#[cfg(test)]
pub(crate) fn test_platform_with_secret(secret: &str) -> PlatformConfig {
    PlatformConfig { webhook_secret: Some(secret.to_string()), ..test_platform() }
}

#[cfg(test)]
mod tests;
