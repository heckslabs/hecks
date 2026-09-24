// Email-and-password accounts (`Accounts::Account`): register and
// login, the driving adapter for one vendored chapter. A child module of
// `web`, so it reuses web's own response/read helpers without widening
// their visibility.
//
// Neither route is reachable over HTTP; `auth_route` in web.rs says why.
// The hashing, the login check and the session token live here, never in
// the domain.

use super::{cookie_flags, instances_for, last_refusal, respond, respond_with_cookie};
use crate::auth;
use crate::dispatch;
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use serde_json::{json, Value};
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

// Accounts::Account.Register -- "Accounts", a literal chapter name, not
// config.domain, same reasoning "Payments::Payment.Initiate" is
// hardcoded in web.rs registrations_route: both are vendored
// embryonaut_bluebooks chapters loaded into THIS deploy's own hecksagon
// (lifeadelics.hecksagon's own `uses_embryonaut_bluebook "accounts"`),
// never a top-level `Hecks.world` of their own. bcrypt hashing happens
// here, in this driving adapter, never the domain -- accounts.bluebook's
// own header: "Hashing/verifying happens in a consuming project's own
// driving adapter (this package has no opinion on bcrypt vs. anything
// else)", ported unchanged from http_server.rb's own POST /accounts/
// register (same BCrypt::Password.create call, this crate's own
// bcrypt::hash at the default cost).
pub(super) async fn accounts_register_route(raw_body: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return respond(400, "application/json", &json!({"error": format!("invalid JSON: {e}")}).to_string()),
    };
    let Some(email) = body.get("email").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing email"}).to_string());
    };
    let Some(password) = body.get("password").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing password"}).to_string());
    };

    let password_hash = match bcrypt::hash(password, bcrypt::DEFAULT_COST) {
        Ok(h) => h,
        Err(e) => return respond(500, "text/plain", &format!("hashing password: {e}")),
    };

    let args = json!({"email": {"value": email}, "password_hash": {"value": password_hash}});
    let outcome = match dispatch::handle(client, wasm_path, "Accounts::Account.Register", args, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
    }

    respond(200, "application/json", &json!({"email": email}).to_string())
}

// POST /accounts/login, ported from http_server.rb's own route: find the
// Account by email (the same instances_for/dispatch::read pattern
// web.rs registrations_route uses to find an Event by slug -- reading,
// not dispatching, since Accounts::Account declares no Login command of
// its own; verification is this driving adapter's own concern, same as
// hashing), verify the bcrypt hash, sign a 14-day token (Ruby's own
// SESSION_TTL), set it as lifeadelics_session -- never Accounts::Account
// itself learning anything about sessions or cookies.
pub(super) async fn accounts_login_route(raw_body: &str, secret: &str, client: &Mutex<Client>, wasm_path: &Path) -> Value {
    const SESSION_TTL_SECS: u64 = 60 * 60 * 24 * 14;
    let invalid = || respond(401, "application/json", &json!({"error": "invalid email or password"}).to_string());

    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return respond(400, "application/json", &json!({"error": format!("invalid JSON: {e}")}).to_string()),
    };
    let Some(email) = body.get("email").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing email"}).to_string());
    };
    let Some(password) = body.get("password").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing password"}).to_string());
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let accounts = instances_for(&read, "Accounts::Account#");
    let Some((_, account)) = accounts.iter().find(|(id, _)| id == email) else {
        return invalid();
    };
    let Some(hash) = account.get("password_hash").and_then(|v| v.get("value")).and_then(|v| v.as_str()) else {
        return invalid();
    };
    match bcrypt::verify(password, hash) {
        Ok(true) => {}
        _ => return invalid(),
    }

    let token = auth::account_token(secret, email, SESSION_TTL_SECS);
    let cookie = format!("lifeadelics_session={token}{}; Max-Age={SESSION_TTL_SECS}", cookie_flags());
    respond_with_cookie(200, "application/json", &json!({"email": email}).to_string(), &cookie)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lambda_client;
    use crate::web::tests::{provision_lineage, scratch_db};


    // Its own dedicated fixture, not folded into web.rs CheckoutFixture --
    // spec/fixtures/rust_host/accounts_fixture's own header has the full
    // reasoning (a second top-level chapter there flipped bin/project_
    // wasm's own primary-domain selection, silently breaking
    // checkout_fixture.ir.json's Event/Registration aggregates).
    fn accounts_config(era: i32) -> LineageConfig {
        LineageConfig { domain: "Accounts".to_string(), era: Some(era), mirrored: None }
    }

    fn accounts_wasm_path() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/accounts_fixture.wasm")
    }

    #[tokio::test]
    async fn accounts_register_route_creates_a_real_account_with_a_real_bcrypt_hash() {
        let client = scratch_db("hecks_host_web_test_accounts_register").await;
        provision_lineage(&*client.lock().await, "Accounts", 1, &["Account"]).await;
        let config = accounts_config(1);
        let wasm_path = accounts_wasm_path();

        let body = json!({"email": "ada@example.com", "password": "hunter2"}).to_string();
        let response = accounts_register_route(&body, &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let response_body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        assert_eq!(response_body["email"], "ada@example.com");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        let account = instances.get("Accounts::Account#ada@example.com").expect("Account.Register should have committed for real");
        let hash = account["password_hash"]["value"].as_str().unwrap();
        assert!(hash.starts_with("$2"), "should be a real bcrypt hash, not the plaintext password: {hash:?}");
        assert_ne!(hash, "hunter2");
        assert!(bcrypt::verify("hunter2", hash).unwrap(), "the stored hash should verify against the real password");
    }

    #[tokio::test]
    async fn accounts_register_route_refuses_a_duplicate_email() {
        let client = scratch_db("hecks_host_web_test_accounts_register_dup").await;
        provision_lineage(&*client.lock().await, "Accounts", 1, &["Account"]).await;
        let config = accounts_config(1);
        let wasm_path = accounts_wasm_path();

        let body = json!({"email": "ada@example.com", "password": "hunter2"}).to_string();
        let first = accounts_register_route(&body, &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(first["statusCode"], 200, "{first:?}");

        let second = accounts_register_route(&body, &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(second["statusCode"], 422, "a second Register for the same identified_by email should refuse: {second:?}");
    }

    #[tokio::test]
    async fn accounts_login_route_sets_a_real_session_cookie_and_rejects_wrong_creds() {
        let client = scratch_db("hecks_host_web_test_accounts_login").await;
        provision_lineage(&*client.lock().await, "Accounts", 1, &["Account"]).await;
        let config = accounts_config(1);
        let wasm_path = accounts_wasm_path();

        let register_body = json!({"email": "ada@example.com", "password": "hunter2"}).to_string();
        accounts_register_route(&register_body, &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;

        // Right password -- a real, verifiable session cookie comes back.
        let login_body = json!({"email": "ada@example.com", "password": "hunter2"}).to_string();
        let response = accounts_login_route(&login_body, "s3cret", &client, &wasm_path).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let cookies = response["cookies"].as_array().expect("a successful login should set a cookie");
        let cookie = cookies[0].as_str().unwrap();
        assert!(cookie.starts_with("lifeadelics_session="), "{cookie:?}");
        let token = cookie.strip_prefix("lifeadelics_session=").unwrap().split(';').next().unwrap();
        assert_eq!(auth::verify_account_token("s3cret", token).as_deref(), Some("ada@example.com"));

        // Wrong password -- refused, no cookie.
        let wrong_password = json!({"email": "ada@example.com", "password": "not-it"}).to_string();
        let response = accounts_login_route(&wrong_password, "s3cret", &client, &wasm_path).await;
        assert_eq!(response["statusCode"], 401);
        assert!(response.get("cookies").is_none());

        // Unknown email -- the same refusal, never revealing which half was wrong.
        let unknown_email = json!({"email": "nobody@example.com", "password": "hunter2"}).to_string();
        let response = accounts_login_route(&unknown_email, "s3cret", &client, &wasm_path).await;
        assert_eq!(response["statusCode"], 401);
    }
}
