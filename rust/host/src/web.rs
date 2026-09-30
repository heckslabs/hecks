// Renders the web UI for a Function-URL HTTP event, in the same process
// as the Lambda's internal verb/read dispatch — no second network hop.

use crate::api;
use crate::auth;
use crate::auth::Session;
use crate::dispatch;
use crate::field_hints::{EMAIL_HINT, TEL_HINT, TEXTAREA_HINT, URL_HINT};
use crate::ir::ir;
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use crate::payments;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

mod newsletter;
mod newsletter_send;
mod registration_receipt;
mod registrations;

use registrations::payments_routes;
// payments.rs, its tests and the boot check reach these through `web::`.
pub(crate) use registrations::{checkout_enabled, registration_complete_route, registrations_route, webhook_route, MOCK_STRIPE_WEBHOOK_SECRET};
#[cfg(test)]
pub(crate) use registrations::{seats_left, seats_taken};

const UNGATED_PATHS: &[&str] = &["/login", "/logout", "/auth/google", "/auth/google/callback"];

#[allow(clippy::too_many_arguments)]
pub async fn render(
    body: &Value,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    let http_event = body.get("requestContext")?.get("http")?;

    let method = http_event.get("method").and_then(|v| v.as_str()).unwrap_or("GET");
    let path = body.get("rawPath").and_then(|v| v.as_str()).unwrap_or("/");
    let raw_body = body.get("body").and_then(|v| v.as_str()).unwrap_or("");
    let raw_body = if body.get("isBase64Encoded").and_then(|v| v.as_bool()) == Some(true) {
        String::from_utf8(base64_decode(raw_body)).unwrap_or_default()
    } else {
        raw_body.to_string()
    };

    // Parsed before `checkout_enabled` because newsletter's email-link
    // routes need it there. Query strings are RFC 3986 — `+` is literal,
    // not a space (unlike form bodies, which still use parse_form).
    let query = parse_query(body.get("rawQueryString").and_then(|v| v.as_str()).unwrap_or(""));

    // Registration/checkout/newsletter routes are opt-in: they only exist
    // when HECKS_CHECKOUT_DOMAIN names this domain, since Event/Registration
    // and the Payments::Payment chapter are declared against it specifically.
    // The capability shapes are pinned by spec/fixtures/rust_host/checkout_fixture,
    // which this module's tests run against.
    if checkout_enabled(std::env::var("HECKS_CHECKOUT_DOMAIN").ok().as_deref(), &config.domain) {
        // Newsletter subscribe shares this gate (same hecksagon as the
        // registration aggregates) and is checked first since it needs none
        // of the Payments::Payment/Event context checkout requires.
        if let Some(response) = newsletter::newsletter_route(method, path, &query, &raw_body, client, wasm_path, config, invoker).await {
            return Some(response);
        }
        let stripe_signature = body.get("headers").and_then(|h| h.get("stripe-signature")).and_then(|v| v.as_str()).unwrap_or("");
        if let Some(response) = payments_routes(ir(), method, path, &raw_body, stripe_signature, client, wasm_path, config, invoker).await {
            return Some(response);
        }
    }

    let Some(domain_ir) = ir() else {
        return Some(respond(500, "text/plain", "HECKS_IR_PATH not set or unreadable — this domain has no web layer configured"));
    };

    let cookies = extract_cookies(body);

    Some(route(domain_ir, method, path, &query, &raw_body, &cookies, client, wasm_path, config, invoker).await)
}

fn extract_cookies(body: &Value) -> HashMap<String, String> {
    // Function URL payload's own `cookies` array, or a raw `headers.cookie`
    // header as a fallback — both reduce to the same map.
    let mut map = HashMap::new();
    if let Some(list) = body.get("cookies").and_then(|v| v.as_array()) {
        for c in list {
            if let Some((k, v)) = c.as_str().and_then(|s| s.split_once('=')) {
                map.insert(k.trim().to_string(), v.trim().to_string());
            }
        }
    } else if let Some(header) = body.get("headers").and_then(|h| h.get("cookie")).and_then(|v| v.as_str()) {
        for pair in header.split(';') {
            if let Some((k, v)) = pair.split_once('=') {
                map.insert(k.trim().to_string(), v.trim().to_string());
            }
        }
    }
    map
}

// Refuses on an empty/unset secret rather than defaulting to "" and
// signing every cookie with a publicly-known key. Checked here, not
// at boot, since a domain with no web layer never sets it at all.
fn session_secret() -> String {
    let secret = std::env::var("SESSION_SECRET").unwrap_or_default();
    if let Err(e) = validate_session_secret(&secret) {
        panic!("{e}");
    }
    secret
}

// Kept pure and separately testable; only `session_secret` panics.
fn validate_session_secret(secret: &str) -> Result<(), String> {
    if secret.is_empty() {
        Err("SESSION_SECRET is required and must not be empty -- refusing to sign/verify session \
             cookies and OAuth state with a publicly-known empty-string HMAC key"
            .to_string())
    } else {
        Ok(())
    }
}

fn redirect_uri() -> String {
    std::env::var("GOOGLE_REDIRECT_URI").unwrap_or_default()
}

// JSON callers get a 401 to branch on; browsers get redirected instead.
fn auth_gate(path: &str, authenticated: bool) -> Option<Value> {
    if authenticated || UNGATED_PATHS.contains(&path) {
        return None;
    }

    Some(if json_shaped(path) {
        // The Ruby engine's own refusal body, key for key, so a client
        // can branch on it without caring which runtime answered.
        respond(401, "application/json", &json!({"error": "Unauthenticated", "message": "sign in first"}).to_string())
    } else {
        redirect("/login")
    })
}

// Reuses `split_format` so this can't drift from the renderers' own HTML/JSON branch.
fn json_shaped(path: &str) -> bool {
    if path.starts_with("/api/") {
        return true;
    }
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    match segments.last() {
        Some(last) if segments.len() >= 2 => split_format(last).1 != "html",
        _ => false,
    }
}

#[allow(clippy::too_many_arguments)]
async fn route(
    domain_ir: &Value,
    method: &str,
    path: &str,
    query: &HashMap<String, String>,
    raw_body: &str,
    cookies: &HashMap<String, String>,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let domain_name = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let secret = session_secret();
    let session = cookies.get("session").and_then(|c| auth::parse_session_cookie(&secret, c));

    if let Some(response) = auth_route(domain_ir, path, method, query, raw_body, cookies, session.as_ref(), &secret, client, wasm_path, config, invoker).await {
        return response;
    }

    if let Some(refusal) = auth_gate(path, session.is_some()) {
        return refusal;
    }

    // Every /api/ path belongs to api.rs's contract, including ones it
    // 404s itself — falling through would 404 here as "no domain \"api\""
    // instead, for a request the Ruby engine answers with data.
    if path.starts_with("/api/") {
        return api::route(domain_ir, method, path, query, raw_body, session.as_ref(), client, wasm_path, config, invoker).await;
    }

    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();

    if segments.is_empty() {
        return html(200, &page("Loaded domains", &home_body(domain_ir)));
    }

    if segments[0] != domain_name {
        return respond(404, "text/plain", &format!("no domain {:?} loaded", segments[0]));
    }

    let Some((aggregate_seg, format)) = segments.get(1).map(|s| split_format(s)) else {
        return respond(404, "text/plain", "no route");
    };
    let Some(aggregate) = find_aggregate(domain_ir, &aggregate_seg) else {
        return respond(404, "text/plain", &format!("{domain_name} has no aggregate {aggregate_seg:?}"));
    };

    if segments.len() == 2 {
        return aggregate_index(domain_name, aggregate, &format, client, wasm_path).await;
    }

    if segments.len() == 3 {
        let (verb_or_id, format) = split_format(segments[2]);
        if let Some(command) = find_command(aggregate, &verb_or_id) {
            let action = format!("/{domain_name}/{}/{}.html", agg_name(aggregate), verb_or_id);
            return command_route(
                domain_ir, domain_name, aggregate, command, &action, &format, method, query, raw_body,
                client, wasm_path, config, invoker,
            )
            .await;
        }
        return record_show(domain_name, aggregate, &verb_or_id, &format, client, wasm_path).await;
    }

    respond(404, "text/plain", &format!("no route for {path}"))
}

// Routes /login, /logout, /auth/google(/callback) and /admin/members.
// `None` here falls through to route()'s ordinary IR-driven dispatch.
#[allow(clippy::too_many_arguments)]
async fn auth_route(
    domain_ir: &Value,
    path: &str,
    method: &str,
    query: &HashMap<String, String>,
    raw_body: &str,
    cookies: &HashMap<String, String>,
    session: Option<&Session>,
    secret: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    match (method, path) {
        ("GET", "/login") => Some(html(200, &login_page(query.get("error").map(|s| s.as_str())))),

        ("POST", "/logout") => Some(redirect_with_cookie("/login", &format!("session=; Max-Age=0{}", cookie_flags()))),

        // No password login: Google OAuth is the only sign-in path, and the
        // /accounts/* routes here are just the session-cookie family that
        // follows one (logout, me, sso-token) — never a signup by itself.
        ("POST", "/accounts/logout") => Some(respond_with_cookie(
            200,
            "application/json",
            r#"{"ok":true}"#,
            &format!("{}=; Max-Age=0{}", auth::account_cookie_name(), cookie_flags()),
        )),

        ("GET", "/accounts/me") => Some(accounts_me_route(domain_ir, cookies, secret, client).await),

        ("GET", "/members") => Some(members_route(domain_ir, cookies, secret, client).await),

        ("POST", "/members") => Some(add_member_route(domain_ir, raw_body, cookies, secret, client, wasm_path, config).await),

        // Sending a newsletter issue (web/newsletter_send.rs's own header):
        // an Admin's or Owner's account cookie, unlike the
        // guest newsletter routes served ahead of this gate.
        (method, path) if newsletter_send::issue_action(method, path).is_some() => {
            newsletter_send::issue_route(method, path, domain_ir, raw_body, cookies, secret, client, wasm_path, config, invoker).await
        }

        ("POST", "/signups") => Some(signup_route(raw_body, secret, client, wasm_path, config, invoker).await),

        ("GET", "/registrations") => Some(registrations_list_route(domain_ir, cookies, secret, client, wasm_path, config).await),

        ("POST", "/members/disable") => Some(set_member_disabled_route(domain_ir, raw_body, cookies, secret, client, config, true).await),

        ("POST", "/members/enable") => Some(set_member_disabled_route(domain_ir, raw_body, cookies, secret, client, config, false).await),

        ("POST", "/members/role") => Some(set_member_role_route(domain_ir, raw_body, cookies, secret, client, config).await),

        ("POST", "/members/delete") => Some(set_member_deleted_route(domain_ir, raw_body, cookies, secret, client, config).await),

        // The tenant's payment connection: same gate as the checkout routes,
        // since only the HECKS_CHECKOUT_DOMAIN domain carries one — any
        // other domain served by this binary falls through as unknown.
        (method, path)
            if payments::owns(method, path) && checkout_enabled(std::env::var("HECKS_CHECKOUT_DOMAIN").ok().as_deref(), &config.domain) =>
        {
            payments::route(method, path, raw_body, cookies, secret, domain_ir, &payments::PlatformConfig::load().await, client, wasm_path, config, invoker).await
        }

        // cms/src/endpoints/sso.ts verifies this with the same account_token
        // wire format; deploy-aws/platform/template.yaml shares SessionSecret
        // with the cms container as AUTH_SECRET so both sides agree on it.
        ("GET", "/accounts/sso-token") => Some(accounts_sso_token_route(domain_ir, cookies, secret, client).await),

        ("GET", "/auth/google") => match auth::authorization_url(&redirect_uri(), secret) {
            Ok(url) => Some(redirect(&url)),
            Err(e) => Some(respond(500, "text/plain", &format!("Google sign-in isn't configured: {e}"))),
        },

        ("GET", "/auth/google/callback") => Some(google_callback(domain_ir, query, client, wasm_path, config, secret, invoker).await),

        ("GET", "/admin/members") => {
            let Some(session) = session else { return Some(redirect("/login")) };
            if !is_admin(client, wasm_path, domain_ir, &session.identity_id).await {
                return Some(html(403, "<p>Admins only.</p>"));
            }
            Some(html(200, &admin_members_page(client, domain_ir).await))
        }

        ("POST", "/admin/members") => {
            let Some(session) = session else { return Some(redirect("/login")) };
            if !is_admin(client, wasm_path, domain_ir, &session.identity_id).await {
                return Some(html(403, "<p>Admins only.</p>"));
            }
            let form = parse_form(raw_body);
            let email = form.get("email").cloned().unwrap_or_default();
            let role = form.get("role").cloned().unwrap_or_default();
            if !auth::GRANTABLE_ROLES.contains(&role.as_str()) {
                return Some(html(400, &format!("<p>Role must be one of {}.</p>", auth::GRANTABLE_ROLES.join(", "))));
            }
            match auth::grant_access(client, wasm_path, config, domain_ir, &email, &role).await {
                Ok(true) => Some(redirect("/admin/members")),
                Ok(false) => Some(html(404, "<p>No member with that email.</p>")),
                Err(e) => Some(html(500, &format!("<p>{}</p>", esc(&e.to_string())))),
            }
        }

        _ => None,
    }
}

async fn is_admin(client: &Mutex<Client>, wasm_path: &Path, domain_ir: &Value, identity_id: &str) -> bool {
    let provider = crate::ir::authorization_provider(domain_ir);
    match dispatch::read(client, wasm_path).await {
        Ok(read) => auth::holds_admin(read.get("instances").unwrap_or(&json!({})), identity_id, provider.as_ref()),
        Err(_) => false,
    }
}

// Verifies the token AND that the person still has access, so a
// disable takes effect immediately even with an unexpired cookie.
async fn active_session_email(
    domain_ir: &Value,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
) -> Result<String, Value> {
    let not_logged_in = || respond(401, "application/json", &json!({"error": "not logged in"}).to_string());
    let Some(email) = cookies.get(&auth::account_cookie_name()).and_then(|token| auth::verify_account_token(secret, token)) else {
        return Err(not_logged_in());
    };
    match auth::has_access(client, domain_ir, &email).await {
        Ok(true) => Ok(email),
        Ok(false) => Err(not_logged_in()),
        Err(e) => Err(respond(500, "application/json", &json!({"error": format!("members lookup failed: {e}")}).to_string())),
    }
}

async fn accounts_me_route(domain_ir: &Value, cookies: &HashMap<String, String>, secret: &str, client: &Mutex<Client>) -> Value {
    match active_session_email(domain_ir, cookies, secret, client).await {
        Ok(email) => respond(200, "application/json", &json!({"email": email}).to_string()),
        Err(response) => response,
    }
}

// GET /members: admitted people as JSON, for a caller holding the
// account cookie but not the Governance session /admin/members needs.
async fn members_route(domain_ir: &Value, cookies: &HashMap<String, String>, secret: &str, client: &Mutex<Client>) -> Value {
    if let Err(response) = active_session_email(domain_ir, cookies, secret, client).await {
        return response;
    }
    match auth::all_people(client, domain_ir).await {
        Ok(people) => respond(200, "application/json", &Value::Array(sorted_by_name(people)).to_string()),
        Err(e) => respond(500, "application/json", &json!({"error": format!("members lookup failed: {e}")}).to_string()),
    }
}

// POST /members: admits a person and grants a role, for a server-side
// caller. Any admin may grant Owner, since the first Owner needs one.
pub(crate) async fn add_member_route(
    domain_ir: &Value,
    raw_body: &str,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
) -> Value {
    let json_error = |status: u16, message: &str| respond(status, "application/json", &json!({"error": message}).to_string());

    let Some(caller) = cookies.get(&auth::account_cookie_name()).and_then(|token| auth::verify_account_token(secret, token)) else {
        return json_error(401, "not logged in");
    };
    match auth::caller_is_admin(client, domain_ir, &caller).await {
        Ok(true) => {}
        Ok(false) => return json_error(403, "admins only"),
        Err(e) => return json_error(500, &format!("members lookup failed: {e}")),
    }

    let body: Value = serde_json::from_str(raw_body).unwrap_or(Value::Null);
    let field = |key: &str| body.get(key).and_then(|v| v.as_str()).map(|s| s.trim().to_string()).unwrap_or_default();
    let (email, name) = (field("email"), field("name"));
    let looks_like_email = email.split_once('@').is_some_and(|(local, domain)| !local.is_empty() && domain.contains('.') && !email.contains(char::is_whitespace));
    if name.is_empty() || !looks_like_email {
        return json_error(400, "a name and a valid email are required");
    }
    let role = match body.get("role") {
        None | Some(Value::Null) => "Admin".to_string(),
        Some(value) => value.as_str().map(|s| s.trim().to_string()).unwrap_or_default(),
    };
    if !auth::GRANTABLE_ROLES.contains(&role.as_str()) {
        return json_error(400, &format!("role must be one of {}", auth::GRANTABLE_ROLES.join(", ")));
    }

    match auth::admit_person(client, config, domain_ir, &email, &name).await {
        Ok(true) => {}
        Ok(false) => return json_error(409, "that email is already admitted"),
        Err(e) => return json_error(500, &format!("admit failed: {e}")),
    }
    let email = email.to_lowercase();
    match auth::grant_access(client, wasm_path, config, domain_ir, &email, &role).await {
        Ok(true) => respond(
            201,
            "application/json",
            &json!({"name": name, "email": email, "role": role, "linked": false, "granted": true, "disabled": false}).to_string(),
        ),
        Ok(false) => json_error(500, &format!("the person was admitted but the {role} role was not granted")),
        Err(e) => json_error(500, &format!("the person was admitted but the {role} role was not granted: {e}")),
    }
}

// The `purpose_token` purpose a `POST /signups` call must carry.
const SIGNUP_PURPOSE: &str = "signup";

// POST /signups: dispatches Signups::Signup.SignUp as System, gated by
// a signup-purpose token rather than a session cookie (nobody is signed in yet).
async fn signup_route(raw_body: &str, secret: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let json_error = |status: u16, message: &str| respond(status, "application/json", &json!({"error": message}).to_string());

    let body: Value = serde_json::from_str(raw_body).unwrap_or(Value::Null);
    let field = |key: &str| body.get(key).and_then(|v| v.as_str()).map(|s| s.trim().to_string()).unwrap_or_default();

    if auth::verify_purpose_token(secret, SIGNUP_PURPOSE, &field("token")).is_none() {
        return json_error(401, "not authorized");
    }

    let (email, name) = (field("email").to_lowercase(), field("name"));
    let looks_like_email = email.split_once('@').is_some_and(|(local, domain)| !local.is_empty() && domain.contains('.') && !email.contains(char::is_whitespace));
    if name.is_empty() || !looks_like_email {
        return json_error(400, "a name and a valid email are required");
    }

    let args = json!({"email": {"value": email}, "name": {"value": name}});
    let outcome = match dispatch::handle(client, wasm_path, "Signups::Signup.SignUp", args, Some("System"), config, invoker).await {
        Ok(o) => o,
        Err(e) => return json_error(500, &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
    }

    respond(201, "application/json", &json!({"email": email, "name": name}).to_string())
}

// POST /members/disable|enable: turns access off/on without deleting
// the person, so enabling restores exactly the prior role and link.
async fn set_member_disabled_route(
    domain_ir: &Value,
    raw_body: &str,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
    config: &LineageConfig,
    disable: bool,
) -> Value {
    let json_error = |status: u16, message: &str| respond(status, "application/json", &json!({"error": message}).to_string());

    let Some(caller) = cookies.get(&auth::account_cookie_name()).and_then(|token| auth::verify_account_token(secret, token)) else {
        return json_error(401, "not logged in");
    };

    let body: Value = serde_json::from_str(raw_body).unwrap_or(Value::Null);
    let email = body.get("email").and_then(|v| v.as_str()).map(|s| s.trim().to_string()).unwrap_or_default();
    if email.is_empty() {
        return json_error(400, "an email is required");
    }

    match auth::set_person_disabled(client, config, domain_ir, &caller, &email, disable).await {
        Ok(auth::DisableOutcome::Done) => {
            let key = if disable { "disabled" } else { "enabled" };
            respond(200, "application/json", &json!({key: email.to_lowercase()}).to_string())
        }
        Ok(auth::DisableOutcome::CallerNotAdmin) => json_error(403, "admins only"),
        Ok(auth::DisableOutcome::SelfDisable) => json_error(403, "you can't disable your own admin access"),
        Ok(auth::DisableOutcome::UnknownPerson) => json_error(404, "no member with that email"),
        Ok(auth::DisableOutcome::LastAdmin) => json_error(409, "there must always be at least one admin"),
        Err(e) => json_error(500, &format!("members update failed: {e}")),
    }
}

// POST /members/delete: soft-deletes an already-disabled member — the row
// stays in the journal (nothing here is ever erased), but the Users page
// stops listing it. Requires disable first, same "are you sure" step that
// already gates removing someone's access at all.
async fn set_member_deleted_route(
    domain_ir: &Value,
    raw_body: &str,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
    config: &LineageConfig,
) -> Value {
    let json_error = |status: u16, message: &str| respond(status, "application/json", &json!({"error": message}).to_string());

    let Some(caller) = cookies.get(&auth::account_cookie_name()).and_then(|token| auth::verify_account_token(secret, token)) else {
        return json_error(401, "not logged in");
    };

    let body: Value = serde_json::from_str(raw_body).unwrap_or(Value::Null);
    let email = body.get("email").and_then(|v| v.as_str()).map(|s| s.trim().to_string()).unwrap_or_default();
    if email.is_empty() {
        return json_error(400, "an email is required");
    }

    match auth::set_person_deleted(client, config, domain_ir, &caller, &email).await {
        Ok(auth::DeleteOutcome::Done) => respond(200, "application/json", &json!({"deleted": email.to_lowercase()}).to_string()),
        Ok(auth::DeleteOutcome::CallerNotAdmin) => json_error(403, "admins only"),
        Ok(auth::DeleteOutcome::UnknownPerson) => json_error(404, "no member with that email"),
        Ok(auth::DeleteOutcome::NotDisabled) => json_error(409, "disable this admin first"),
        Err(e) => json_error(500, &format!("members update failed: {e}")),
    }
}

// POST /members/role: changes an already-admitted person's role. Any
// active admin may grant Owner too, since the first Owner needs one.
async fn set_member_role_route(
    domain_ir: &Value,
    raw_body: &str,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
    config: &LineageConfig,
) -> Value {
    let json_error = |status: u16, message: &str| respond(status, "application/json", &json!({"error": message}).to_string());

    let Some(caller) = cookies.get(&auth::account_cookie_name()).and_then(|token| auth::verify_account_token(secret, token)) else {
        return json_error(401, "not logged in");
    };

    let body: Value = serde_json::from_str(raw_body).unwrap_or(Value::Null);
    let field = |key: &str| body.get(key).and_then(|v| v.as_str()).map(|s| s.trim().to_string()).unwrap_or_default();
    let (email, role) = (field("email"), field("role"));
    if email.is_empty() {
        return json_error(400, "an email is required");
    }
    if !auth::GRANTABLE_ROLES.contains(&role.as_str()) {
        return json_error(400, &format!("role must be one of {}", auth::GRANTABLE_ROLES.join(", ")));
    }

    match auth::set_person_role(client, config, domain_ir, &caller, &email, &role).await {
        Ok(auth::RoleOutcome::Done) => respond(200, "application/json", &json!({"email": email.to_lowercase(), "role": role}).to_string()),
        Ok(auth::RoleOutcome::CallerNotAdmin) => json_error(403, "admins only"),
        Ok(auth::RoleOutcome::UnknownPerson) => json_error(404, "no member with that email"),
        Ok(auth::RoleOutcome::LastAdmin) => json_error(409, "there must always be at least one admin"),
        Err(e) => json_error(500, &format!("members update failed: {e}")),
    }
}

// GET /registrations: every registration as JSON for the admin Events
// page. Never returns health or payment fields — allowlisted below.
async fn registrations_list_route(
    domain_ir: &Value,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
) -> Value {
    let json_error = |status: u16, message: &str| respond(status, "application/json", &json!({"error": message}).to_string());

    let Some(caller) = cookies.get(&auth::account_cookie_name()).and_then(|token| auth::verify_account_token(secret, token)) else {
        return json_error(401, "not logged in");
    };
    match auth::caller_is_admin(client, domain_ir, &caller).await {
        Ok(true) => {}
        Ok(false) => return json_error(403, "admins only"),
        Err(e) => return json_error(500, &format!("members lookup failed: {e}")),
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(read) => read,
        Err(e) => return json_error(500, &format!("registrations lookup failed: {e:#}")),
    };
    respond(200, "application/json", &Value::Array(registration_list_rows(&read, &config.domain)).to_string())
}

// Built field-by-field from an allowlist so intake answers (health,
// medications) and payment fields can never appear here.
fn registration_list_rows(read: &Value, domain: &str) -> Vec<Value> {
    const TIMESTAMP_KEYS: [&str; 4] = ["created_at", "registered_at", "requested_at", "occurred_at"];
    let plain = |value: Option<&Value>| -> Option<Value> {
        let value = value?;
        Some(value.get("value").cloned().unwrap_or_else(|| value.clone()))
    };
    let text = |value: Option<&Value>| plain(value).and_then(|v| v.as_str().map(|s| s.trim().to_string()));

    let mut rows: Vec<(Option<String>, Value)> = instances_for(read, &crate::ir::registrations_binding(domain).registration_prefix())
        .into_iter()
        .map(|(id, registration)| {
            let attendee = registration.get("attendee").cloned().unwrap_or_else(|| json!({}));
            let joined = [text(attendee.get("first_name")), text(attendee.get("last_name"))].into_iter().flatten().collect::<Vec<_>>().join(" ");
            let name = if joined.is_empty() { text(attendee.get("name")).unwrap_or_default() } else { joined };
            let stamp = TIMESTAMP_KEYS.iter().find_map(|key| text(registration.get(*key)));
            let mut row = json!({
                "registration_id": id,
                "email": text(attendee.get("email")),
                "name": name.trim(),
                "event_slug": text(registration.get("event_slug")),
                "news_signup": plain(attendee.get("news_signup")).and_then(|v| v.as_bool()).unwrap_or(false),
            });
            if let Some(status) = text(registration.get("status")) {
                row["status"] = json!(status);
            }
            (stamp, row)
        })
        .collect();
    if rows.iter().any(|(stamp, _)| stamp.is_some()) {
        rows.sort_by(|a, b| b.0.cmp(&a.0));
    }
    rows.into_iter().map(|(_, row)| row).collect()
}

fn sorted_by_name(mut people: Vec<Value>) -> Vec<Value> {
    let name_of = |p: &Value| p.get("name").and_then(|v| v.as_str()).unwrap_or("").to_lowercase();
    people.sort_by_key(name_of);
    people
}

// Mints a 60s handoff token cms/src/endpoints/sso.ts exchanges for a
// real Payload session — one-shot, so it's returned as JSON, not a cookie.
async fn accounts_sso_token_route(domain_ir: &Value, cookies: &HashMap<String, String>, secret: &str, client: &Mutex<Client>) -> Value {
    const SSO_TOKEN_TTL_SECS: u64 = 60;
    let email = match active_session_email(domain_ir, cookies, secret, client).await {
        Ok(email) => email,
        Err(response) => return response,
    };
    let sso_token = auth::account_token(secret, &email, SSO_TOKEN_TTL_SECS);
    respond(200, "application/json", &json!({"token": sso_token}).to_string())
}

#[allow(clippy::too_many_arguments)]
async fn google_callback(
    domain_ir: &Value,
    query: &HashMap<String, String>,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    secret: &str,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let Some(code) = query.get("code") else {
        eprintln!("google_callback: missing code");
        return redirect("/login?error=google_failed");
    };
    let Some(state) = query.get("state") else {
        eprintln!("google_callback: missing state");
        return redirect("/login?error=google_failed");
    };
    if let Err(e) = auth::verify_state(state, secret) {
        eprintln!("google_callback: state: {e}");
        return redirect("/login?error=google_failed");
    }

    let claims = match auth::verify(code, &redirect_uri()).await {
        Ok(c) => c,
        Err(e) => {
            eprintln!("google_callback: token exchange: {e}");
            return redirect("/login?error=google_failed");
        }
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("google_callback: read: {e:#}");
            return redirect("/login?error=google_failed");
        }
    };
    let instances = read.get("instances").cloned().unwrap_or(json!({}));

    // PostgresEra head first — Identity is not in the WASM journal.
    // Journal `instances` is only a fallback for Lambda-era rows.
    let identity_id = match auth::resolve_identity_from_head(client, domain_ir, &claims.issuer, &claims.subject).await {
        Ok(found) => found,
        Err(e) => {
            eprintln!("google_callback: identity head: {e:#}");
            None
        }
    };
    let identity_id = identity_id.or_else(|| auth::resolve_identity(&instances, &claims.issuer, &claims.subject));

    let session = match identity_id {
        Some(ref identity_id) => match auth::session_for_member_by_identity(client, domain_ir, identity_id).await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("google_callback: member by identity: {e:#}");
                None
            }
        },
        None => None,
    };
    let session = match session {
        Some(s) => Some(s),
        None if claims.email_verified => {
            let email = claims.email.clone().unwrap_or_default();
            match auth::provision(client, wasm_path, config, domain_ir, &email, &claims.issuer, &claims.subject, invoker).await {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("google_callback: provision: {e:#}");
                    None
                }
            }
        }
        None => None,
    };

    let Some(session) = session else { return redirect("/login?error=google_unlinked") };

    // The site's admin authenticates on the account cookie, not this
    // host's own session cookie. Cross-origin, a cookie here would never
    // reach the site, so the token is handed across via /api/google-handoff.
    const SESSION_TTL_SECS: u64 = 60 * 60 * 24 * 14;
    let site = std::env::var("SITE_URL").unwrap_or_else(|_| "http://localhost:4321".to_string());
    let site = site.trim_end_matches('/');
    let token = auth::account_token(secret, &session.email, SESSION_TTL_SECS);
    if same_origin(site, &redirect_uri()) {
        let cookie = format!("{}={token}{}; Max-Age={SESSION_TTL_SECS}", auth::account_cookie_name(), cookie_flags());
        redirect_with_cookie("/admin.html", &cookie)
    } else {
        // One-redirect URL onto the Astro origin (local rust/host :4567 vs site :4321).
        redirect(&format!("{}/api/google-handoff?token={}", site, auth::urlencode(&token)))
    }
}

fn same_origin(a: &str, b: &str) -> bool {
    origin_of(a) == origin_of(b)
}

fn origin_of(url: &str) -> String {
    let rest = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    rest.split('/').next().unwrap_or(rest).to_string()
}

const ERROR_MESSAGES: &[(&str, &str)] = &[
    ("google_unlinked", "That Google account isn't recognized here."),
    ("google_failed", "Google sign-in didn't go through. Try again."),
];

fn login_page(error: Option<&str>) -> String {
    let message = error.and_then(|e| ERROR_MESSAGES.iter().find(|(k, _)| *k == e)).map(|(_, m)| *m);
    let error_html = message.map(|m| format!(r#"<p class="text-red-600 text-sm mb-4">{}</p>"#, esc(m))).unwrap_or_default();
    format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Sign in</title><script src="https://cdn.tailwindcss.com"></script></head>
        <body class="bg-slate-50 text-slate-900 min-h-screen flex items-center justify-center">
        <div class="w-full max-w-sm p-8 bg-white border border-slate-200 rounded-lg">
        <h1 class="text-xl font-semibold mb-1">Sign in</h1>
        <p class="text-slate-500 text-sm mb-6">Sign in with your Google account.</p>
        {error_html}
        <a href="/auth/google" class="block w-full text-center py-2 border border-slate-300 rounded-md hover:border-slate-400">Sign in with Google</a>
        </div></body></html>"#
    )
}

async fn admin_members_page(client: &Mutex<Client>, domain_ir: &Value) -> String {
    let people = auth::all_people(client, domain_ir).await.unwrap_or_default();
    let rows: String = people
        .iter()
        .map(|p| {
            let name = p.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let email = p.get("email").and_then(|v| v.as_str()).unwrap_or("");
            let role = p.get("role").and_then(|v| v.as_str()).unwrap_or("—");
            let access = if p.get("linked").and_then(|v| v.as_bool()) == Some(true) {
                "linked"
            } else if p.get("granted").and_then(|v| v.as_bool()) == Some(true) {
                "granted, not yet signed in"
            } else {
                "no access"
            };
            format!(
                r#"<tr class="border-b border-slate-100"><td class="py-2 pr-4">{}</td><td class="py-2 pr-4">{}</td><td class="py-2 pr-4">{}</td><td class="py-2">{}</td></tr>"#,
                esc(name), esc(email), esc(role), esc(access)
            )
        })
        .collect();

    format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Members</title><script src="https://cdn.tailwindcss.com"></script></head>
        <body class="bg-slate-50 text-slate-900 min-h-screen"><main class="max-w-2xl mx-auto px-4 py-8">
        <p class="mb-4"><a href="/" class="text-slate-500 hover:text-slate-700">&larr; back</a></p>
        <h1 class="text-xl font-semibold mb-4">Members</h1>
        <table class="w-full text-sm mb-6"><thead><tr class="text-left text-slate-500 text-xs uppercase"><th class="py-2 pr-4">Name</th><th class="py-2 pr-4">Email</th><th class="py-2 pr-4">Role</th><th class="py-2">Access</th></tr></thead><tbody>{rows}</tbody></table>
        <form method="post" action="/admin/members" class="flex gap-2 items-center">
        <input type="email" name="email" placeholder="email of an existing Member" required class="flex-1 border border-slate-300 rounded-md px-3 py-2 text-sm" />
        <select name="role" class="border border-slate-300 rounded-md px-3 py-2 text-sm"><option value="Admin">Admin</option><option value="Owner">Owner</option><option value="Member">Member</option></select>
        <button type="submit" class="px-4 py-2 bg-slate-900 text-white rounded-md text-sm">Grant access</button>
        </form></main></body></html>"#
    )
}

fn find_aggregate<'a>(domain_ir: &'a Value, name: &str) -> Option<&'a Value> {
    domain_ir.get("aggregates")?.as_array()?.iter().find(|a| a.get("name").and_then(|v| v.as_str()) == Some(name))
}

fn find_command<'a>(aggregate: &'a Value, name: &str) -> Option<&'a Value> {
    aggregate.get("commands")?.as_array()?.iter().find(|c| c.get("name").and_then(|v| v.as_str()) == Some(name))
}

fn find_value_object<'a>(aggregate: &'a Value, name: &str) -> Option<&'a Value> {
    aggregate.get("value_objects")?.as_array()?.iter().find(|v| v.get("name").and_then(|v| v.as_str()) == Some(name))
}

fn agg_name(aggregate: &Value) -> &str {
    aggregate.get("name").and_then(|v| v.as_str()).unwrap_or("")
}

fn identity_paths(aggregate: &Value) -> Vec<String> {
    aggregate
        .get("identified_by")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|p| p.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

// IR::Attribute -> Field, mirroring Hecks::Presentation::FieldShape.

#[derive(Clone, Debug)]
struct Field {
    path: String,
    label: String,
    kind: FieldKind,
    optional: bool,
}

#[derive(Clone, Debug)]
enum FieldKind {
    Text { html_type: &'static str },
    Textarea,
    Number { step: &'static str },
    Boolean,
    Radio(Vec<String>),
    Select(Vec<String>),
    Group(Vec<Field>),
    // Renders/collects exactly like Group — its own variant only so a
    // caller can ask "is this money" without matching Group's children.
    Money(Vec<Field>),
    // `target` is unused by today's render arm (a plain text input) but
    // kept for a future dropdown renderer — hence `#[allow(dead_code)]`
    // rather than removing the field.
    Reference {
        #[allow(dead_code)]
        target: Option<String>,
    },
    List(Box<Field>),
}

fn humanize(path: &str) -> String {
    let segment = path.rsplit('.').next().unwrap_or(path);
    let words: Vec<&str> = segment.split('_').collect();
    if words.is_empty() {
        return segment.to_string();
    }
    let mut out = String::new();
    for (i, w) in words.iter().enumerate() {
        if i > 0 {
            out.push(' ');
        }
        if i == 0 {
            let mut chars = w.chars();
            if let Some(first) = chars.next() {
                out.push(first.to_ascii_uppercase());
                out.push_str(chars.as_str());
            }
        } else {
            out.push_str(w);
        }
    }
    out
}

const PRIMITIVES: &[&str] = &["String", "Integer", "Float", "TrueClass", "FalseClass"];

// Dispatch order: list? -> reference? -> admits -> value object ->
// primitive. `domain_ir` is the whole chapter, needed for cross-aggregate lookups.
fn resolve_field(domain_ir: &Value, attribute: &Value, aggregate: &Value, path: &str) -> Field {
    let is_list = attribute.get("list").and_then(|v| v.as_bool()).unwrap_or(false);
    let optional = attribute.get("optional").and_then(|v| v.as_bool()).unwrap_or(false);
    let ty = attribute.get("type").and_then(|v| v.as_str()).unwrap_or("String");

    if is_list {
        let scalar = json!({
            "name": attribute.get("name"), "type": ty, "list": false, "optional": true,
            "pattern": attribute.get("pattern"), "admits": attribute.get("admits"),
        });
        let item = resolve_field(domain_ir, &scalar, aggregate, path);
        return Field { path: path.to_string(), label: humanize(path), kind: FieldKind::List(Box::new(item)), optional };
    }

    if let Some(target) = reference_target(ty) {
        return Field { path: path.to_string(), label: humanize(path), kind: FieldKind::Reference { target: Some(target) }, optional };
    }

    if let Some(admits) = attribute.get("admits").and_then(|v| v.as_str()) {
        return admitted_field(domain_ir, aggregate, attribute, admits, ty, path, optional);
    }

    if PRIMITIVES.contains(&ty) {
        return primitive_field(attribute, ty, path, optional);
    }

    let Some(shape) = value_object_shape(domain_ir, aggregate, ty) else {
        return primitive_field(attribute, ty, path, optional);
    };
    value_object_field(domain_ir, aggregate, shape, path, optional)
}

// `Reference<X>` -> `Some("X")`. `Reference<...>` is the IR's pinned
// export spelling (never a nested object) — mirrors naming.rb.
fn reference_target(ty: &str) -> Option<String> {
    ty.strip_prefix("Reference<")?.strip_suffix('>').map(String::from)
}

// Checked on the owning aggregate first, then across the whole domain.
fn value_object_shape<'a>(domain_ir: &'a Value, aggregate: &'a Value, ty: &str) -> Option<&'a Value> {
    find_value_object(aggregate, ty).or_else(|| cross_aggregate_value_object(domain_ir, ty))
}

// Walks the whole domain, not just siblings — a value object's shape
// may be declared on a different aggregate than the one referencing it.
fn cross_aggregate_value_object<'a>(domain_ir: &'a Value, type_name: &str) -> Option<&'a Value> {
    domain_ir.get("aggregates")?.as_array()?.iter().find_map(|sibling| find_value_object(sibling, type_name))
}

// Shared by the native one_of branch and the admits: branch below, so
// neither carries its own drifting copy of this reading.
fn closed_set_members(vo: &Value) -> (String, Vec<String>) {
    let attrs = vo.get("attributes").and_then(|v| v.as_array());
    let discriminant = attrs.and_then(|a| a.first()).and_then(|a| a.get("name")).and_then(|v| v.as_str()).unwrap_or("value").to_string();
    let members = vo
        .get("members")
        .and_then(|v| v.as_array())
        .map(|members| {
            members
                .iter()
                .filter_map(|m| {
                    m.as_array()?.iter().find_map(|pair| {
                        let pair = pair.as_array()?;
                        if pair.first()?.as_str()? == discriminant {
                            pair.get(1)?.as_str().map(String::from)
                        } else {
                            None
                        }
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    (discriminant, members)
}

// Radio under 4 members, Select otherwise. Callers append a discriminant
// to `.path` afterward without touching `label`, which is set here.
fn select_or_radio(path: &str, optional: bool, members: Vec<String>) -> Field {
    let label = humanize(path);
    let kind = if members.len() <= 4 { FieldKind::Radio(members) } else { FieldKind::Select(members) };
    Field { path: path.to_string(), label, kind, optional }
}

// A closed set declared elsewhere (e.g. "Account::LedgerDirection"),
// rendered the same way the native one_of branch renders its own.
fn admitted_field(domain_ir: &Value, aggregate: &Value, attribute: &Value, admits: &str, ty: &str, path: &str, optional: bool) -> Field {
    let mut parts = admits.splitn(2, "::");
    let set_aggregate_name = parts.next().unwrap_or("");
    let set_name = parts.next();

    let set = set_name.and_then(|name| find_aggregate(domain_ir, set_aggregate_name).and_then(|agg| find_value_object(agg, name)));
    // Undeclared set: render as a plain scalar (using the real attribute
    // so its name/pattern still drive Tier B's hints) — dispatch refuses.
    let Some(set) = set else { return primitive_field(attribute, ty, path, optional) };

    let (_, members) = closed_set_members(set);
    let mut field = select_or_radio(path, optional, members);

    // The attribute's own value object still needs its ".value" hop
    // (same unwrap `value_object_field` does) even though the admitted
    // set lives on a different aggregate — it only changes the options.
    let Some(own_shape) = value_object_shape(domain_ir, aggregate, ty) else { return field };
    let attrs = own_shape.get("attributes").and_then(|v| v.as_array());
    let Some(attrs) = attrs.filter(|a| a.len() == 1) else { return field };

    let inner_name = attrs[0].get("name").and_then(|v| v.as_str()).unwrap_or("value");
    field.path = format!("{path}.{inner_name}");
    field
}

// Order: closed_set? -> money_shaped? -> single-attribute-unwrap -> group.
fn value_object_field(domain_ir: &Value, aggregate: &Value, shape: &Value, path: &str, optional: bool) -> Field {
    let closed_set = shape.get("closed_set").and_then(|v| v.as_bool()).unwrap_or(false);
    let attrs = shape.get("attributes").and_then(|v| v.as_array()).cloned().unwrap_or_default();

    if closed_set {
        let (discriminant, members) = closed_set_members(shape);
        let mut field = select_or_radio(path, optional, members);
        field.path = format!("{path}.{discriminant}");
        return field;
    }

    if money_shaped(&attrs) {
        return money_field(path, optional);
    }

    // A single-attribute value object names a scalar, not a group, so
    // the outer label wins. Recursing through `resolve_field` (not
    // `primitive_field`) keeps the inner name/pattern driving Tier B.
    if attrs.len() == 1 {
        let inner = &attrs[0];
        let inner_name = inner.get("name").and_then(|v| v.as_str()).unwrap_or("value");
        let inner_path = format!("{path}.{inner_name}");
        let mut field = resolve_field(domain_ir, inner, aggregate, &inner_path);
        field.label = humanize(path);
        field.optional = optional || field.optional;
        return field;
    }

    let children = attrs
        .iter()
        .map(|inner| {
            let inner_name = inner.get("name").and_then(|v| v.as_str()).unwrap_or("");
            resolve_field(domain_ir, inner, aggregate, &format!("{path}.{inner_name}"))
        })
        .collect();
    Field { path: path.to_string(), label: humanize(path), kind: FieldKind::Group(children), optional }
}

// Exactly `{cents, currency}`, sorted, and nothing else.
fn money_shaped(attrs: &[Value]) -> bool {
    let mut names: Vec<&str> = attrs.iter().filter_map(|a| a.get("name").and_then(|v| v.as_str())).collect();
    names.sort_unstable();
    names == ["cents", "currency"]
}

// Cents as a whole-integer Number; currency as free Text, always
// optional (it defaults to "USD" regardless of the outer field).
fn money_field(path: &str, optional: bool) -> Field {
    let cents = Field { path: format!("{path}.cents"), label: "Amount (cents)".to_string(), kind: FieldKind::Number { step: "1" }, optional };
    let currency = Field { path: format!("{path}.currency"), label: "Currency".to_string(), kind: FieldKind::Text { html_type: "text" }, optional: true };
    Field { path: path.to_string(), label: humanize(path), kind: FieldKind::Money(vec![cents, currency]), optional }
}

fn primitive_field(attribute: &Value, ty: &str, path: &str, optional: bool) -> Field {
    let label = humanize(path);
    let kind = match ty {
        "Integer" => FieldKind::Number { step: "1" },
        "Float" => FieldKind::Number { step: "any" },
        "TrueClass" | "FalseClass" => FieldKind::Boolean,
        _ => return text_field(attribute, path, optional),
    };
    Field { path: path.to_string(), label, kind, optional }
}

// Tier B's hints (field_hints.rs) match on `attribute`'s own name/
// pattern, never derived from `path` — matters after the unwrap above.
fn text_field(attribute: &Value, path: &str, optional: bool) -> Field {
    let name = attribute.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let pattern = attribute.get("pattern").and_then(|v| v.as_str()).unwrap_or("");
    let html_type = text_html_type(name, pattern);
    let kind = text_kind(html_type, name);
    Field { path: path.to_string(), label: humanize(path), kind, optional }
}

// email, then url, then tel — first match wins. Case-insensitive
// "http" substring catches both "http" and "https".
fn text_html_type(name: &str, pattern: &str) -> &'static str {
    if pattern.contains('@') || EMAIL_HINT.is_match(name) {
        return "email";
    }
    if pattern.to_ascii_lowercase().contains("http") || URL_HINT.is_match(name) {
        return "url";
    }
    if TEL_HINT.is_match(name) {
        return "tel";
    }
    "text"
}

// Only checked once `html_type` has already fallen through to "text".
fn text_kind(html_type: &'static str, name: &str) -> FieldKind {
    if html_type == "text" && TEXTAREA_HINT.is_match(name) {
        return FieldKind::Textarea;
    }
    FieldKind::Text { html_type }
}

fn command_fields(domain_ir: &Value, aggregate: &Value, command: &Value) -> Vec<Field> {
    let creates = command.get("references").map(|v| v.is_null()).unwrap_or(true);
    let mut fields = Vec::new();
    if !creates {
        let paths = identity_paths(aggregate).join(", ");
        fields.push(Field {
            path: "id".to_string(),
            label: format!("{} ({paths})", agg_name(aggregate)),
            kind: FieldKind::Text { html_type: "text" },
            optional: false,
        });
    }
    if let Some(attrs) = command.get("attributes").and_then(|v| v.as_array()) {
        for attribute in attrs {
            let name = attribute.get("name").and_then(|v| v.as_str()).unwrap_or("");
            fields.push(resolve_field(domain_ir, attribute, aggregate, name));
        }
    }
    fields
}

// Flat dotted form body -> nested JSON args, mirroring
// Hecks::Presentation::Params.

// `Err`, never a panic, on a path-prefix collision — see `nest`'s own doc.
fn extract_args(fields: &[Field], raw: &HashMap<String, String>) -> Result<Value, String> {
    let mut pairs: Vec<(String, Value)> = Vec::new();
    for field in fields {
        collect_field(field, raw, &mut pairs);
    }
    nest(pairs)
}

fn collect_field(field: &Field, raw: &HashMap<String, String>, pairs: &mut Vec<(String, Value)>) {
    match &field.kind {
        // Money shares Group's own children-flattening.
        FieldKind::Group(children) | FieldKind::Money(children) => {
            for child in children {
                collect_field(child, raw, pairs);
            }
        }
        FieldKind::List(item) => {
            if let Some(text) = raw.get(&field.path) {
                let values: Vec<Value> = text
                    .lines()
                    .map(str::trim)
                    .filter(|l| !l.is_empty())
                    .map(|l| cast_scalar(item, l))
                    .collect();
                if !values.is_empty() {
                    pairs.push((field.path.clone(), Value::Array(values)));
                }
            }
        }
        FieldKind::Boolean => {
            let checked = raw.get(&field.path).map(|v| matches!(v.as_str(), "on" | "1" | "true")).unwrap_or(false);
            pairs.push((field.path.clone(), Value::Bool(checked)));
        }
        _ => {
            if let Some(text) = raw.get(&field.path) {
                if !(text.is_empty() && field.optional) {
                    pairs.push((field.path.clone(), cast_scalar(field, text)));
                }
            }
        }
    }
}

fn cast_scalar(field: &Field, text: &str) -> Value {
    match &field.kind {
        FieldKind::Number { step } if *step == "1" => text.parse::<i64>().map(Value::from).unwrap_or(Value::Null),
        FieldKind::Number { .. } => text.parse::<f64>().map(Value::from).unwrap_or(Value::Null),
        _ => Value::String(text.to_string()),
    }
}

// Refuses a path-prefix collision (e.g. "price" vs "price.cents")
// cleanly, rather than panicking one way and silently dropping data the other.
fn nest(pairs: Vec<(String, Value)>) -> Result<Value, String> {
    let mut result = json!({});
    for (path, value) in pairs {
        let segments: Vec<&str> = path.split('.').collect();
        let mut node = &mut result;
        for depth in 0..segments.len() - 1 {
            let obj = node
                .as_object_mut()
                .ok_or_else(|| collision_error(&path, &segments[..depth]))?;
            node = obj.entry(segments[depth]).or_insert_with(|| json!({}));
        }
        let leaf = segments[segments.len() - 1];
        let obj = node
            .as_object_mut()
            .ok_or_else(|| collision_error(&path, &segments[..segments.len() - 1]))?;
        // The other collision direction: inserting a scalar over an
        // already-built object here would silently erase its children.
        if matches!(obj.get(leaf), Some(existing) if existing.is_object()) && !value.is_object() {
            return Err(collision_error(&path, &segments));
        }
        obj.insert(leaf.to_string(), value);
    }
    Ok(result)
}

fn collision_error(path: &str, existing_prefix: &[&str]) -> String {
    format!(
        "form field {path:?} collides with {:?} — one implies a scalar value, the other a nested object; refusing rather than guessing or silently dropping data",
        existing_prefix.join(".")
    )
}

fn home_body(domain_ir: &Value) -> String {
    let name = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let vision = domain_ir.get("vision").and_then(|v| v.as_str()).unwrap_or("");
    let aggregates = domain_ir.get("aggregates").and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let items: String = aggregates
        .iter()
        .map(|a| {
            let n = agg_name(a);
            format!(r#"<li><a href="/{name}/{n}.html" class="text-indigo-600 hover:underline">{n}</a></li>"#)
        })
        .collect();
    format!(
        r#"<h1 class="text-2xl font-bold mb-4">Loaded domains</h1>
        <ul class="space-y-4"><li><h2 class="font-semibold text-slate-800">{}</h2>
        <p class="text-sm text-slate-500">{}</p>
        <ul class="ml-4 mt-1 list-disc list-inside">{}</ul></li></ul>"#,
        esc(name), esc(vision), items
    )
}

async fn aggregate_index(domain_name: &str, aggregate: &Value, format: &str, client: &Mutex<Client>, wasm_path: &Path) -> Value {
    let agg = agg_name(aggregate);
    let prefix = format!("{domain_name}::{agg}#");
    let records = match dispatch::read(client, wasm_path).await {
        Ok(result) => instances_for(&result, &prefix),
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };

    if format != "html" {
        let list: Vec<Value> = records.iter().map(|(id, state)| with_id(id, state)).collect();
        return respond(200, "application/json", &serde_json::to_string_pretty(&list).unwrap_or_default());
    }

    let creating: Vec<&Value> = aggregate
        .get("commands")
        .and_then(|v| v.as_array())
        .map(|cs| cs.iter().filter(|c| c.get("references").map(|r| r.is_null()).unwrap_or(true)).collect())
        .unwrap_or_default();
    let acting: Vec<&Value> = aggregate
        .get("commands")
        .and_then(|v| v.as_array())
        .map(|cs| cs.iter().filter(|c| !c.get("references").map(|r| r.is_null()).unwrap_or(true)).collect())
        .unwrap_or_default();

    let new_links: String = creating
        .iter()
        .map(|c| {
            let cn = c.get("name").and_then(|v| v.as_str()).unwrap_or("");
            format!(r#"<a href="/{domain_name}/{agg}/{cn}.html" class="rounded-md bg-indigo-600 px-3 py-1.5 text-sm text-white hover:bg-indigo-500">{cn}</a>"#)
        })
        .collect();

    let rows: String = records
        .iter()
        .map(|(id, _)| {
            let actions: String = acting
                .iter()
                .map(|c| {
                    let cn = c.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    action_link(domain_name, agg, cn, id, "text-indigo-600 hover:underline mr-3")
                })
                .collect();
            index_row_html(domain_name, agg, id, &actions)
        })
        .collect();

    let body = if records.is_empty() {
        format!(
            r#"<div class="flex items-center justify-between mb-4"><h1 class="text-2xl font-bold">{domain_name}::{agg}</h1><div class="flex gap-2">{new_links}</div></div><p class="text-slate-500">No records yet.</p>"#
        )
    } else {
        format!(
            r#"<div class="flex items-center justify-between mb-4"><h1 class="text-2xl font-bold">{domain_name}::{agg}</h1><div class="flex gap-2">{new_links}</div></div>
            <table class="w-full text-sm border border-slate-200 rounded-md overflow-hidden"><thead class="bg-slate-100 text-left"><tr><th class="px-3 py-2">id</th><th class="px-3 py-2">actions</th></tr></thead>
            <tbody class="divide-y divide-slate-100 bg-white">{rows}</tbody></table>"#
        )
    };
    html(200, &page(&format!("{domain_name}::{agg}"), &body))
}

async fn record_show(domain_name: &str, aggregate: &Value, id: &str, format: &str, client: &Mutex<Client>, wasm_path: &Path) -> Value {
    let agg = agg_name(aggregate);
    let prefix = format!("{domain_name}::{agg}#");
    let result = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let records = instances_for(&result, &prefix);
    let Some((_, state)) = records.iter().find(|(rid, _)| rid == id) else {
        let message = format!("No {agg} {id}.");
        return if format != "html" {
            respond(404, "application/json", &json!({"error":"NotFound","message":message}).to_string())
        } else {
            html(404, &page("Not found", &format!(r#"<h1 class="text-2xl font-bold mb-4">Not found</h1><p class="text-slate-600">{}</p>"#, esc(&message))))
        };
    };

    if format != "html" {
        return respond(200, "application/json", &serde_json::to_string_pretty(&with_id(id, state)).unwrap_or_default());
    }

    let rows: String = state
        .as_object()
        .map(|o| {
            o.iter()
                .map(|(k, v)| format!(r#"<div class="px-4 py-2 grid grid-cols-3 gap-2"><dt class="text-sm font-medium text-slate-500">{}</dt><dd class="col-span-2 text-sm text-slate-900 font-mono">{}</dd></div>"#, esc(k), esc(&v.to_string())))
                .collect()
        })
        .unwrap_or_default();
    let actions: String = aggregate
        .get("commands")
        .and_then(|v| v.as_array())
        .map(|cs| {
            cs.iter()
                .filter(|c| !c.get("references").map(|r| r.is_null()).unwrap_or(true))
                .map(|c| {
                    let cn = c.get("name").and_then(|v| v.as_str()).unwrap_or("");
                    action_link(domain_name, agg, cn, id, "rounded-md bg-indigo-600 px-3 py-1.5 text-sm text-white hover:bg-indigo-500 mr-3")
                })
                .collect::<String>()
        })
        .unwrap_or_default();
    let body = format!(
        r#"<h1 class="text-2xl font-bold">{} <span class="font-mono text-lg text-slate-500">{}</span></h1>
        <dl class="mt-4 divide-y divide-slate-200 border border-slate-200 rounded-md bg-white">{rows}</dl>
        <div class="mt-6">{actions}<a href="/{domain_name}/{agg}.html" class="text-indigo-600 hover:underline">← {agg} list</a></div>"#,
        esc(agg), esc(id)
    );
    html(200, &page(&format!("{agg} {id}"), &body))
}

#[allow(clippy::too_many_arguments)]
async fn command_route(
    domain_ir: &Value, domain_name: &str, aggregate: &Value, command: &Value, action: &str, format: &str, method: &str,
    query: &HashMap<String, String>, raw_body: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let fields = command_fields(domain_ir, aggregate, command);
    let cname = command.get("name").and_then(|v| v.as_str()).unwrap_or("");

    if format != "html" {
        if method == "GET" {
            return respond(200, "application/json", &command.to_string());
        }
        let raw = parse_form(raw_body);
        return submit(domain_name, aggregate, command, &fields, &raw, client, wasm_path, config, true, invoker).await;
    }

    if method == "GET" {
        return html(200, &page(&format!("{domain_name}::{}.{cname}", agg_name(aggregate)), &form_body(domain_name, aggregate, command, action, &fields, query, None)));
    }

    let raw = parse_form(raw_body);
    submit(domain_name, aggregate, command, &fields, &raw, client, wasm_path, config, false, invoker).await
}

#[allow(clippy::too_many_arguments)]
async fn submit(
    domain_name: &str, aggregate: &Value, command: &Value, fields: &[Field], raw: &HashMap<String, String>,
    client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, json_mode: bool, invoker: &dyn LambdaInvoker,
) -> Value {
    let agg = agg_name(aggregate);
    let cname = command.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let verb = format!("{domain_name}::{agg}.{cname}");

    // A path-prefix collision refuses cleanly here (400) rather than
    // panicking inside `nest` (see `extract_args`'s own doc).
    let args = match extract_args(fields, raw) {
        Ok(a) => a,
        Err(e) => return bad_request(domain_name, aggregate, command, fields, raw, json_mode, &e),
    };

    // `None`: this web UI has no concept of an authenticated caller's
    // role yet (see auth.rs's own session handling for that).
    let outcome = match dispatch::handle(client, wasm_path, &verb, args, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };

    if outcome.accepted {
        let id = own_command_target_id(&outcome.result).unwrap_or("");
        if json_mode {
            return respond(201, "application/json", &outcome.result.to_string());
        }
        return redirect(&format!("/{domain_name}/{agg}/{id}.html"));
    }

    let refusal = last_refusal(&outcome.result);

    if json_mode {
        return respond(422, "application/json", &refusal.to_string());
    }

    let action = format!("/{domain_name}/{agg}/{cname}.html");
    html(422, &page(&format!("{domain_name}::{agg}.{cname}"), &form_body(domain_name, aggregate, command, &action, fields, raw, Some(&refusal))))
}

// Mirrors the 422-refusal rendering below (same json/html split) but at
// 400 — this is a malformed submission `nest` caught, not a domain refusal.
#[allow(clippy::too_many_arguments)]
fn bad_request(domain_name: &str, aggregate: &Value, command: &Value, fields: &[Field], raw: &HashMap<String, String>, json_mode: bool, message: &str) -> Value {
    let refusal = json!({"error": message});
    if json_mode {
        return respond(400, "application/json", &refusal.to_string());
    }
    let agg = agg_name(aggregate);
    let cname = command.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let action = format!("/{domain_name}/{agg}/{cname}.html");
    html(400, &page(&format!("{domain_name}::{agg}.{cname}"), &form_body(domain_name, aggregate, command, &action, fields, raw, Some(&refusal))))
}

// The first mutation in the last step is always the command's own
// target — a cascaded reaction's mutation, if any, comes after it.
fn own_command_target_id(result: &Value) -> Option<&str> {
    result
        .get("mutations")
        .and_then(|m| m.as_array())
        .and_then(|steps| steps.last())
        .and_then(|last| last.as_array())
        .and_then(|muts| muts.first())
        .and_then(|m| m.get("id"))
        .and_then(|v| v.as_str())
}

// `.last()`: dispatch::handle reruns the whole rehydrated history, and
// every step before this call's own already succeeded once.
pub(crate) fn last_refusal(result: &Value) -> Value {
    result
        .get("refusals")
        .and_then(|r| r.as_array())
        .and_then(|rs| rs.last())
        .cloned()
        .unwrap_or_else(|| json!({"error": "Refused"}))
}

fn form_body(domain_name: &str, aggregate: &Value, command: &Value, action: &str, fields: &[Field], values: &HashMap<String, String>, error: Option<&Value>) -> String {
    let agg = agg_name(aggregate);
    let cname = command.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let role = command.get("role").and_then(|v| v.as_str());
    let goal = command.get("goal").and_then(|v| v.as_str());
    let givens: String = command
        .get("givens")
        .and_then(|v| v.as_array())
        .map(|gs| gs.iter().filter_map(|g| g.get("description").and_then(|d| d.as_str())).map(|d| format!("<li>{}</li>", esc(d))).collect::<String>())
        .unwrap_or_default();

    let error_banner = error
        .map(|e| {
            let msg = e.get("error").or_else(|| e.get("message")).and_then(|v| v.as_str()).unwrap_or("Refused");
            format!(r#"<div class="mt-3 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800"><strong>Refused</strong> — {}</div>"#, esc(msg))
        })
        .unwrap_or_default();

    let inputs: String = fields.iter().map(|f| render_field(f, values)).collect();

    format!(
        r#"<h1 class="text-2xl font-bold">{domain_name}::{agg}.{cname}</h1>
        {}{}
        {}
        <form method="post" action="{}" novalidate>{}
        <div class="mt-6 flex gap-3"><button type="submit" class="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-indigo-500">{cname}</button>
        <a href="/{domain_name}/{agg}.html" class="inline-flex items-center rounded-md border border-slate-300 px-4 py-2 text-sm text-slate-700 hover:bg-slate-50">Cancel</a></div></form>"#,
        role.map(|r| format!(r#"<span class="inline-block mt-1 rounded bg-slate-200 px-2 py-0.5 text-xs text-slate-600">role: {}</span>"#, esc(r))).unwrap_or_default(),
        goal.map(|g| format!(r#"<p class="mt-2 text-slate-600">{}</p>"#, esc(g))).unwrap_or_default(),
        if givens.is_empty() { String::new() } else { format!(r#"<div class="mt-3 rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800"><strong>Preconditions</strong> — refused if any fail:<ul class="list-disc list-inside mt-1">{givens}</ul></div>{error_banner}"#) },
        esc(action), inputs
    )
}

fn render_field(field: &Field, values: &HashMap<String, String>) -> String {
    let label = format!(
        r#"<label class="block text-sm font-medium text-slate-700 mt-4">{}{}</label>"#,
        esc(&field.label),
        if field.optional { "" } else { r#" <span class="text-red-500">*</span>"# }
    );
    let input_class = "mt-1 block w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 sm:text-sm";
    let current = values.get(&field.path).cloned().unwrap_or_default();

    match &field.kind {
        // Money renders as the same fieldset a Group does — its two
        // children (cents/currency) are just another pair of fields
        // inside it.
        FieldKind::Group(children) | FieldKind::Money(children) => {
            let inner: String = children.iter().map(|c| render_field(c, values)).collect();
            format!(r#"<fieldset class="mt-4 border border-slate-200 rounded-md p-4"><legend class="text-sm font-semibold text-slate-700 px-1">{}</legend>{}</fieldset>"#, esc(&field.label), inner)
        }
        FieldKind::List(_) => format!(
            r#"{label}<textarea name="{}" rows="4" placeholder="one per line" class="{input_class}">{}</textarea>"#,
            esc(&field.path), esc(&current)
        ),
        FieldKind::Textarea => format!(r#"{label}<textarea name="{}" class="{input_class}">{}</textarea>"#, esc(&field.path), esc(&current)),
        FieldKind::Boolean => format!(
            r#"<div class="mt-4 flex items-center gap-2"><input type="checkbox" name="{}" class="rounded border-slate-300 text-indigo-600 focus:ring-indigo-500"><label class="text-sm text-slate-700">{}</label></div>"#,
            esc(&field.path), esc(&field.label)
        ),
        FieldKind::Radio(options) => {
            let opts: String = options
                .iter()
                .map(|o| format!(r#"<label class="inline-flex items-center gap-1 text-sm text-slate-700"><input type="radio" name="{}" value="{}" class="text-indigo-600 focus:ring-indigo-500">{}</label>"#, esc(&field.path), esc(o), esc(o)))
                .collect();
            format!(r#"{label}<div class="mt-1 flex gap-4">{opts}</div>"#)
        }
        FieldKind::Select(options) => {
            let opts: String = options.iter().map(|o| format!(r#"<option value="{}">{}</option>"#, esc(o), esc(o))).collect();
            format!(r#"{label}<select name="{}" class="{input_class}">{opts}</select>"#, esc(&field.path))
        }
        FieldKind::Number { step } => format!(
            r#"{label}<input type="number" name="{}" value="{}" step="{step}" class="{input_class}">"#,
            esc(&field.path), esc(&current)
        ),
        FieldKind::Text { html_type } => format!(
            r#"{label}<input type="{html_type}" name="{}" value="{}" class="{input_class}">"#,
            esc(&field.path), esc(&current)
        ),
        // No reference-picker dropdown: no candidate-fetching scaffolding
        // exists yet, so this is a plain text id input, like Ruby's own fallback.
        FieldKind::Reference { .. } => format!(
            r#"{label}<input type="text" name="{}" value="{}" class="{input_class}">"#,
            esc(&field.path), esc(&current)
        ),
    }
}

pub(crate) fn instances_for(result: &Value, prefix: &str) -> Vec<(String, Value)> {
    result
        .get("instances")
        .and_then(|v| v.as_object())
        .map(|o| {
            o.iter()
                .filter_map(|(k, v)| k.strip_prefix(prefix).map(|id| (id.to_string(), v.clone())))
                .collect()
        })
        .unwrap_or_default()
}

fn with_id(id: &str, state: &Value) -> Value {
    let mut m = state.clone();
    if let Some(obj) = m.as_object_mut() {
        obj.insert("id".to_string(), Value::String(id.to_string()));
    }
    m
}

fn split_format(segment: &str) -> (String, String) {
    match segment.split_once('.') {
        Some((name, fmt)) => (name.to_string(), fmt.to_string()),
        None => (segment.to_string(), "json".to_string()),
    }
}

fn parse_form(text: &str) -> HashMap<String, String> {
    parse_urlencoded(text, true)
}

fn parse_query(text: &str) -> HashMap<String, String> {
    parse_urlencoded(text, false)
}

fn parse_urlencoded(text: &str, plus_as_space: bool) -> HashMap<String, String> {
    text.split('&')
        .filter(|s| !s.is_empty())
        .map(|pair| {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            (percent_decode_impl(k, plus_as_space), percent_decode_impl(v, plus_as_space))
        })
        .collect()
}

pub(crate) fn percent_decode(s: &str) -> String {
    percent_decode_impl(s, true)
}

fn percent_decode_impl(s: &str, plus_as_space: bool) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' if plus_as_space => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                if let Ok(byte) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    out.push(byte);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

const B64: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// pub(crate) so server.rs's own Function URL response handling can
// decode the same way, without a second copy of this decoder.
pub(crate) fn base64_decode(input: &str) -> Vec<u8> {
    let mut table = [255u8; 256];
    for (i, &c) in B64.iter().enumerate() {
        table[c as usize] = i as u8;
    }
    let clean: Vec<u8> = input.bytes().filter(|&b| b != b'=' && !b.is_ascii_whitespace()).collect();
    let mut out = Vec::with_capacity(clean.len() * 3 / 4);
    for chunk in clean.chunks(4) {
        let vals: Vec<u32> = chunk.iter().map(|&b| table[b as usize] as u32).collect();
        let n = vals.len();
        let combined = vals.iter().enumerate().fold(0u32, |acc, (i, &v)| acc | (v << (18 - 6 * i)));
        out.push((combined >> 16) as u8);
        if n > 2 {
            out.push((combined >> 8) as u8);
        }
        if n > 3 {
            out.push(combined as u8);
        }
    }
    out
}

fn esc(value: &str) -> String {
    value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}

// `id` is user-supplied and sits in a query-string value here, so
// `esc()` alone isn't enough — percent-encode via `auth::urlencode`.
fn action_link(domain_name: &str, agg: &str, cn: &str, id: &str, class: &str) -> String {
    format!(r#"<a href="/{domain_name}/{agg}/{}.html?id={}" class="{class}">{}</a>"#, esc(cn), auth::urlencode(id), esc(cn))
}

// `id` sits in a path segment here, not a query value, so `esc()`
// (not percent-encoding) is the right guard.
fn index_row_html(domain_name: &str, agg: &str, id: &str, actions: &str) -> String {
    let id = esc(id);
    format!(
        r#"<tr><td class="px-3 py-2 font-mono text-xs"><a href="/{domain_name}/{agg}/{id}.html" class="text-indigo-600 hover:underline">{id}</a></td><td class="px-3 py-2">{actions}</td></tr>"#
    )
}

fn page(title: &str, body: &str) -> String {
    format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{}</title><script src="https://cdn.tailwindcss.com"></script></head><body class="bg-slate-50 text-slate-900 min-h-screen"><header class="bg-white border-b border-slate-200"><div class="max-w-3xl mx-auto px-4 py-3"><a href="/" class="font-semibold text-slate-900">rust/host — served straight off the bluebook IR</a></div></header><main class="max-w-3xl mx-auto px-4 py-8">{}</main></body></html>"#,
        esc(title), body
    )
}

fn html(status: u16, body: &str) -> Value {
    respond(status, "text/html; charset=utf-8", body)
}

fn redirect(location: &str) -> Value {
    json!({"statusCode": 302, "headers": {"location": location}, "body": "", "isBase64Encoded": false})
}

// HttpOnly + SameSite always; Secure only when GOOGLE_REDIRECT_URI is
// https — a localhost http:// callback can't set a Secure cookie.
fn cookie_flags() -> &'static str {
    let uri = std::env::var("GOOGLE_REDIRECT_URI").unwrap_or_default();
    if uri.starts_with("http://") {
        "; Path=/; HttpOnly; SameSite=Lax"
    } else {
        "; Path=/; HttpOnly; Secure; SameSite=Lax"
    }
}

fn redirect_with_cookie(location: &str, cookie: &str) -> Value {
    json!({"statusCode": 302, "headers": {"location": location}, "cookies": [cookie], "body": "", "isBase64Encoded": false})
}

pub(crate) fn respond(status: u16, content_type: &str, body: &str) -> Value {
    json!({"statusCode": status, "headers": {"content-type": content_type}, "body": body, "isBase64Encoded": false})
}

fn respond_with_cookie(status: u16, content_type: &str, body: &str, cookie: &str) -> Value {
    json!({"statusCode": status, "headers": {"content-type": content_type}, "cookies": [cookie], "body": body, "isBase64Encoded": false})
}

#[cfg(test)]
mod tests {
    use super::*;

    // A record's id is user-supplied; left unescaped, a malicious one
    // would render as live markup — these tests pin that it can't.
    const MALICIOUS_ID: &str = r#"x"><script>alert(1)</script>"#;

    // Pins that an unset/empty SESSION_SECRET is refused, not silently
    // treated as a valid empty-string HMAC key.
    #[test]
    fn validate_session_secret_refuses_empty_or_unset() {
        assert!(validate_session_secret("").is_err());
        assert!(validate_session_secret("s3cret").is_ok());
    }

    // Pins the gate's two-answer split: without it, an unauthenticated
    // JSON request would get a redirect instead of a 401 it can branch on.

    fn status(response: &Value) -> u64 {
        response.get("statusCode").and_then(|v| v.as_u64()).expect("a response always carries a statusCode")
    }

    #[test]
    fn an_unauthenticated_api_request_is_refused_with_the_ruby_engines_own_401_json() {
        let refusal = auth_gate("/api/clients", false).expect("an unauthenticated /api/ request must be refused");

        assert_eq!(status(&refusal), 401);
        assert_eq!(refusal["headers"]["content-type"], "application/json");
        // Byte-for-byte the console app's own web/app.rb
        // `halt 401, json({ error: "Unauthenticated", message: "sign in first" })`.
        assert_eq!(refusal["body"], r#"{"error":"Unauthenticated","message":"sign in first"}"#);
        assert!(refusal["headers"].get("location").is_none(), "a JSON caller must not be redirected: {refusal}");
    }

    // Ruby keys off the `/api/` prefix alone and doesn't look at a
    // suffix; so does this, checked before the format-based rule below.
    #[test]
    fn an_api_path_is_json_shaped_whatever_suffix_it_carries() {
        assert!(json_shaped("/api/clients"));
        assert!(json_shaped("/api/clients.html"));
        assert!(json_shaped("/api/ui-schema"));
    }

    // A no-suffix aggregate URL is still a JSON request here (format
    // lives in the path), so it must be 401'd, never redirected.
    #[test]
    fn an_unauthenticated_host_route_is_401_unless_it_asks_for_html() {
        assert_eq!(status(&auth_gate("/Pizzas/Order.json", false).expect("refused")), 401);
        assert_eq!(status(&auth_gate("/Pizzas/Order", false).expect("refused")), 401);
        assert_eq!(status(&auth_gate("/Pizzas/Order/p1.json", false).expect("refused")), 401);

        let page = auth_gate("/Pizzas/Order.html", false).expect("refused");
        assert_eq!(status(&page), 302);
        assert_eq!(page["headers"]["location"], "/login");

        let record_page = auth_gate("/Pizzas/Order/p1.html", false).expect("refused");
        assert_eq!(status(&record_page), 302);
        assert_eq!(record_page["headers"]["location"], "/login");
    }

    // The home page and its 404s are HTML, reached by a browser — why
    // the rule isn't simply "everything that isn't .html".
    #[test]
    fn an_unauthenticated_browser_navigation_still_redirects_to_login() {
        let home = auth_gate("/", false).expect("refused");
        assert_eq!(status(&home), 302);
        assert_eq!(home["headers"]["location"], "/login");

        assert_eq!(status(&auth_gate("/favicon.ico", false).expect("refused")), 302);
        assert_eq!(status(&auth_gate("/Pizzas", false).expect("refused")), 302);
    }

    #[test]
    fn the_ungated_paths_are_still_ungated_without_a_session() {
        for path in UNGATED_PATHS {
            assert!(auth_gate(path, false).is_none(), "{path} must reach its own handler with no session");
        }
    }

    // No regression for a signed-in caller: the gate refuses nothing,
    // JSON-shaped or not, and the request goes on to ordinary dispatch.
    #[test]
    fn an_authenticated_request_passes_the_gate_untouched() {
        assert!(auth_gate("/api/clients", true).is_none());
        assert!(auth_gate("/Pizzas/Order", true).is_none());
        assert!(auth_gate("/Pizzas/Order.html", true).is_none());
        assert!(auth_gate("/", true).is_none());
    }

    #[test]
    fn action_link_escapes_the_link_text_and_percent_encodes_the_query_value() {
        let link = action_link("Pizzas", "Order", "Purchase", MALICIOUS_ID, "mr-3");

        assert!(!link.contains("<script"), "{link}");
        assert!(!link.contains(MALICIOUS_ID), "the raw id must not survive into the rendered link: {link}");
        // Percent-encoded, not HTML-escaped — esc() alone would leave a
        // raw `&` that terminates the `id=` param early.
        assert!(link.contains("id=x%22%3E%3Cscript%3Ealert%281%29%3C%2Fscript%3E"), "{link}");
    }

    #[test]
    fn action_link_renders_an_ordinary_id_unchanged() {
        let link = action_link("Pizzas", "Order", "Purchase", "p1", "mr-3");
        assert_eq!(link, r#"<a href="/Pizzas/Order/Purchase.html?id=p1" class="mr-3">Purchase</a>"#);
    }

    #[test]
    fn index_row_html_escapes_the_id_in_both_the_link_text_and_the_path_segment() {
        let row = index_row_html("Pizzas", "Order", MALICIOUS_ID, "");
        assert!(!row.contains("<script"), "{row}");
        assert!(row.contains("&lt;script&gt;"), "{row}");
    }

    #[test]
    fn index_row_html_renders_an_ordinary_id_unchanged() {
        let row = index_row_html("Pizzas", "Order", "p1", "");
        assert_eq!(
            row,
            r#"<tr><td class="px-3 py-2 font-mono text-xs"><a href="/Pizzas/Order/p1.html" class="text-indigo-600 hover:underline">p1</a></td><td class="px-3 py-2"></td></tr>"#
        );
    }

    // Fixtures below are trimmed to only the keys `resolve_field`'s own
    // call graph reads; real corpus shapes (examples/banking, pizzas) confirmed them.

    #[test]
    fn customer_email_reads_the_pattern_as_email_even_nested_inside_a_value_object() {
        // Customer.email is EmailAddress{address}; `address`'s own
        // `pattern:` names "@" — the same case field_shape_spec.rb
        // tests directly off the live Ruby IR.
        let email_address_vo = json!({
            "name": "EmailAddress",
            "attributes": [{"name": "address", "type": "String", "list": false, "default": null, "optional": false, "pattern": "^[^@ ]+@[^@ ]+\\.[^@ ]+$", "admits": null}],
            "invariants": [], "closed_set": false, "members": []
        });
        let customer = json!({"name": "Customer", "value_objects": [email_address_vo]});
        let domain_ir = json!({"aggregates": [customer.clone()]});
        let attribute = json!({"name": "email", "type": "EmailAddress", "list": false, "default": null, "optional": false, "pattern": null, "admits": null});

        let field = resolve_field(&domain_ir, &attribute, &customer, "email");
        assert_eq!(field.path, "email.address");
        match field.kind {
            FieldKind::Text { html_type } => assert_eq!(html_type, "email"),
            other => panic!("expected Text{{html_type: email}}, got {other:?}"),
        }
    }

    #[test]
    fn account_balance_renders_as_money_with_cents_and_currency_children() {
        let money_vo = json!({
            "name": "Money",
            "attributes": [
                {"name": "cents", "type": "Integer", "list": false, "default": 0, "optional": false, "pattern": null, "admits": null},
                {"name": "currency", "type": "String", "list": false, "default": "USD", "optional": false, "pattern": null, "admits": null}
            ],
            "invariants": [], "closed_set": false, "members": []
        });
        let account = json!({"name": "Account", "value_objects": [money_vo]});
        let domain_ir = json!({"aggregates": [account.clone()]});
        let attribute = json!({"name": "balance", "type": "Money", "list": false, "default": null, "optional": false, "pattern": null, "admits": null});

        let field = resolve_field(&domain_ir, &attribute, &account, "balance");
        match field.kind {
            FieldKind::Money(children) => {
                let paths: Vec<&str> = children.iter().map(|c| c.path.as_str()).collect();
                assert_eq!(paths, vec!["balance.cents", "balance.currency"]);
                assert!(!children[0].optional, "cents follows the outer attribute's own optionality");
                assert!(children[1].optional, "currency is always optional, defaulting to USD, regardless of the outer field");
            }
            other => panic!("expected Money, got {other:?}"),
        }
    }

    #[test]
    fn account_open_customer_id_renders_as_a_reference_carrying_its_target() {
        let account = json!({"name": "Account", "value_objects": []});
        let domain_ir = json!({"aggregates": [account.clone()]});
        let attribute = json!({"name": "customer_id", "type": "Reference<Customer>", "list": false, "default": null, "optional": false, "pattern": null, "admits": null});

        let field = resolve_field(&domain_ir, &attribute, &account, "customer_id");
        match field.kind {
            FieldKind::Reference { target } => assert_eq!(target.as_deref(), Some("Customer")),
            other => panic!("expected Reference, got {other:?}"),
        }
    }

    // **The key regression test** — exercises Tier A's cross-aggregate
    // lookup and Tier B's textarea hint together, the one combination
    // that silently breaks if either regresses alone.
    #[test]
    fn narrative_used_from_a_different_aggregate_renders_as_a_textarea_via_the_cross_aggregate_lookup() {
        // Narrative is declared on Account, never CardPayment — scoped
        // here against CardPayment specifically to prove the fallback
        // walks the whole domain, not just declaring-aggregate siblings.
        let narrative_vo = json!({
            "name": "Narrative",
            "attributes": [{"name": "text", "type": "String", "list": false, "default": null, "optional": false, "pattern": null, "admits": null}],
            "invariants": [{"description": "a movement explains itself", "canonical": "!text.to_s.empty?"}],
            "closed_set": false, "members": []
        });
        let account = json!({"name": "Account", "value_objects": [narrative_vo]});
        let card_payment = json!({
            "name": "CardPayment",
            "value_objects": [{"name": "AuthorisationCode", "attributes": [], "invariants": [], "closed_set": false, "members": []}]
        });
        let domain_ir = json!({"aggregates": [account, card_payment.clone()]});
        let attribute = json!({"name": "narrative", "type": "Narrative", "list": false, "default": null, "optional": false, "pattern": null, "admits": null});

        let field = resolve_field(&domain_ir, &attribute, &card_payment, "narrative");
        assert_eq!(field.path, "narrative.text");
        match field.kind {
            FieldKind::Textarea => {}
            other => panic!("expected Textarea, got {other:?}"),
        }
    }

    #[test]
    fn external_transfer_direction_resolves_its_admits_declared_set_across_aggregates() {
        // The real, live admits: example in the corpus
        // (examples/banking/bluebook/).
        let ledger_direction_vo = json!({
            "name": "LedgerDirection",
            "attributes": [{"name": "value", "type": "String", "list": false, "default": null, "optional": false, "pattern": null, "admits": null}],
            "invariants": [], "closed_set": true,
            "members": [[["value", "credit"]], [["value", "debit"]]]
        });
        let account = json!({"name": "Account", "value_objects": [ledger_direction_vo]});
        let movement_direction_vo = json!({
            "name": "MovementDirection",
            "attributes": [{"name": "value", "type": "String", "list": false, "default": null, "optional": false, "pattern": null, "admits": null}],
            "invariants": [], "closed_set": false, "members": []
        });
        let external_transfer = json!({"name": "ExternalTransfer", "value_objects": [movement_direction_vo]});
        let domain_ir = json!({"aggregates": [account, external_transfer.clone()]});
        let attribute = json!({"name": "direction", "type": "MovementDirection", "list": false, "default": null, "optional": false, "pattern": null, "admits": "Account::LedgerDirection"});

        let field = resolve_field(&domain_ir, &attribute, &external_transfer, "direction");
        assert_eq!(field.path, "direction.value");
        match field.kind {
            FieldKind::Radio(members) => assert_eq!(members, vec!["credit".to_string(), "debit".to_string()]),
            other => panic!("expected Radio with exactly 2 members, got {other:?}"),
        }
    }

    #[test]
    fn a_name_containing_email_matches_even_with_no_at_pattern_at_all() {
        // No `pattern:` at all (synthetic — every real email attribute
        // also carries one) — proves the name-based match alone is enough.
        let aggregate = json!({"name": "Whatever", "value_objects": []});
        let domain_ir = json!({"aggregates": [aggregate.clone()]});
        let attribute = json!({"name": "contact_email", "type": "String", "list": false, "default": null, "optional": false, "pattern": null, "admits": null});

        let field = resolve_field(&domain_ir, &attribute, &aggregate, "contact_email");
        match field.kind {
            FieldKind::Text { html_type } => assert_eq!(html_type, "email"),
            other => panic!("expected Text{{html_type: email}}, got {other:?}"),
        }
    }

    #[test]
    fn synthetic_url_and_tel_named_attributes_resolve_their_html_type_from_the_name_alone() {
        // No real corpus example of either shape exists; built minimal
        // here, same as auth.rs's own fixtures with no real counterpart.
        let aggregate = json!({"name": "Whatever", "value_objects": []});
        let domain_ir = json!({"aggregates": [aggregate.clone()]});

        let website = json!({"name": "website", "type": "String", "list": false, "default": null, "optional": false, "pattern": null, "admits": null});
        match resolve_field(&domain_ir, &website, &aggregate, "website").kind {
            FieldKind::Text { html_type } => assert_eq!(html_type, "url"),
            other => panic!("expected url, got {other:?}"),
        }

        let phone = json!({"name": "phone_number", "type": "String", "list": false, "default": null, "optional": false, "pattern": null, "admits": null});
        match resolve_field(&domain_ir, &phone, &aggregate, "phone_number").kind {
            FieldKind::Text { html_type } => assert_eq!(html_type, "tel"),
            other => panic!("expected tel, got {other:?}"),
        }
    }

    #[test]
    fn a_single_attribute_cents_only_value_object_is_not_money_shaped() {
        // One field, no currency — must unwrap to a plain scalar, never money.
        let price_vo = json!({
            "name": "Price",
            "attributes": [{"name": "cents", "type": "Integer", "list": false, "default": null, "optional": false, "pattern": null, "admits": null}],
            "invariants": [{"description": "a price is never negative", "canonical": "cents >= 0"}],
            "closed_set": false, "members": []
        });
        let order = json!({"name": "Order", "value_objects": [price_vo]});
        let domain_ir = json!({"aggregates": [order.clone()]});
        let attribute = json!({"name": "price_cents", "type": "Price", "list": false, "default": null, "optional": false, "pattern": null, "admits": null});

        match resolve_field(&domain_ir, &attribute, &order, "price_cents").kind {
            FieldKind::Number { step } => assert_eq!(step, "1"),
            other => panic!("expected a plain Number (unwrapped, not Money), got {other:?}"),
        }
    }

    #[test]
    fn field_hint_word_boundaries_reject_a_substring_that_is_not_a_whole_word() {
        // Proves \b in the `regex` crate rejects a substring match
        // ("blinking" for "link") rather than assuming it does, and
        // that (?i) case-insensitivity works too.
        assert!(URL_HINT.is_match("link"));
        assert!(!URL_HINT.is_match("blinking"));
        assert!(TEXTAREA_HINT.is_match("text"));
        assert!(!TEXTAREA_HINT.is_match("context"));
        assert!(EMAIL_HINT.is_match("EMAIL"));
    }

    #[test]
    fn nest_builds_an_ordinary_dotted_path_into_a_nested_object() {
        let result = nest(vec![("price.cents".to_string(), json!(500)), ("price.currency".to_string(), json!("USD"))]).unwrap();
        assert_eq!(result, json!({"price": {"cents": 500, "currency": "USD"}}));
    }

    #[test]
    fn nest_refuses_rather_than_panics_when_a_scalar_is_inserted_before_a_deeper_path_sharing_its_prefix() {
        // `price` lands as a scalar first, then `price.cents` tries to
        // descend into it — the shape that would otherwise panic instead of refusing cleanly.
        let err = nest(vec![("price".to_string(), json!(500)), ("price.cents".to_string(), json!(500))]).unwrap_err();
        assert!(err.contains("price"), "{err}");
    }

    #[test]
    fn nest_refuses_rather_than_silently_dropping_data_when_the_deeper_path_is_inserted_first() {
        // The reverse insertion order clobbers a nested object with a
        // bare scalar instead of panicking — must refuse here too.
        let err = nest(vec![("price.cents".to_string(), json!(500)), ("price".to_string(), json!(500))]).unwrap_err();
        assert!(err.contains("price"), "{err}");
    }

    #[test]
    fn nest_is_unaffected_by_an_unrelated_sibling_sharing_no_prefix() {
        let result = nest(vec![("price.cents".to_string(), json!(500)), ("name".to_string(), json!("Widget"))]).unwrap();
        assert_eq!(result, json!({"price": {"cents": 500}, "name": "Widget"}));
    }

    #[test]
    fn parse_query_keeps_a_literal_plus_so_google_oauth_codes_round_trip() {
        let q = parse_query("code=abc+def%2Fgh&state=1.sig");
        assert_eq!(q.get("code").map(String::as_str), Some("abc+def/gh"));
        assert_eq!(q.get("state").map(String::as_str), Some("1.sig"));
        let form = parse_form("code=abc+def");
        assert_eq!(form.get("code").map(String::as_str), Some("abc def"), "HTML forms still treat + as space");
    }

    #[test]
    fn extract_args_surfaces_a_collision_as_an_error_rather_than_panicking() {
        let scalar_field = Field { path: "price".to_string(), label: "Price".to_string(), kind: FieldKind::Number { step: "1" }, optional: false };
        let nested_field = Field {
            path: "price".to_string(),
            label: "Price".to_string(),
            kind: FieldKind::Group(vec![Field { path: "price.cents".to_string(), label: "Cents".to_string(), kind: FieldKind::Number { step: "1" }, optional: false }]),
            optional: false,
        };
        let mut raw = HashMap::new();
        raw.insert("price".to_string(), "500".to_string());
        raw.insert("price.cents".to_string(), "500".to_string());

        let result = extract_args(&[scalar_field, nested_field], &raw);
        assert!(result.is_err(), "expected a collision error, got {result:?}");
    }

    #[test]
    fn own_command_target_id_picks_the_forms_own_target_when_no_reaction_fired() {
        let result = json!({"mutations": [[{"aggregate": "Pizzas::Order", "id": "order-1", "operation": "save"}]]});
        assert_eq!(own_command_target_id(&result), Some("order-1"));
    }

    #[test]
    fn own_command_target_id_picks_the_first_mutation_not_a_cascaded_reactions_last_one() {
        // The command's own mutation (Order) is pushed first by
        // `orchestrate`, before any cascaded reaction's mutation lands
        // on the same step — `.last()` would grab the reaction's id instead.
        let result = json!({
            "mutations": [[
                {"aggregate": "Pizzas::Order", "id": "order-1", "operation": "save"},
                {"aggregate": "Pizzas::LoyaltyAccount", "id": "loyalty-9", "operation": "save"}
            ]]
        });
        assert_eq!(own_command_target_id(&result), Some("order-1"), "must redirect to the command's OWN aggregate, not the cascaded reaction's");
    }

    #[test]
    fn own_command_target_id_only_looks_at_the_last_step_never_prior_replayed_history() {
        let result = json!({
            "mutations": [
                [{"aggregate": "Pizzas::Order", "id": "stale-from-history", "operation": "save"}],
                [{"aggregate": "Pizzas::Order", "id": "order-2", "operation": "save"}]
            ]
        });
        assert_eq!(own_command_target_id(&result), Some("order-2"));
    }

    #[test]
    fn own_command_target_id_is_none_when_mutations_is_missing_or_empty() {
        assert_eq!(own_command_target_id(&json!({})), None);
        assert_eq!(own_command_target_id(&json!({"mutations": []})), None);
        assert_eq!(own_command_target_id(&json!({"mutations": [[]]})), None);
    }

    // scratch_db provisions a real Postgres schema; only the Stripe hop
    // in payments.rs's own tests is faked, aimed at a local recording server.
    use tokio_postgres::NoTls;

    pub(super) async fn scratch_db(name: &str) -> Mutex<Client> {
        let (admin, conn) = tokio_postgres::connect("host=localhost dbname=postgres", NoTls).await.expect("connect to postgres");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        admin.batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)")).await.unwrap();
        admin.batch_execute(&format!("CREATE DATABASE {name}")).await.unwrap();

        let (client, conn) = tokio_postgres::connect(&format!("host=localhost dbname={name}"), NoTls).await.expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        crate::journal::ensure_schema(&client).await.unwrap();
        Mutex::new(client)
    }

    // Duplicates dispatch.rs's own provision_lineage shape rather than
    // sharing it, matching this crate's existing per-module test fixtures.
    pub(super) async fn provision_lineage(client: &Client, domain: &str, era: i32, aggregate_storage_names: &[&str]) {
        client.batch_execute("CREATE TABLE IF NOT EXISTS hecks_eras (domain text, ordinal int, held_text text)").await.unwrap();
        client
            .execute("INSERT INTO hecks_eras (domain, ordinal, held_text) VALUES ($1, $2, 'test')", &[&domain, &era])
            .await
            .unwrap();

        let journal_table = format!("hecks_journal_{}", crate::journal::snake(domain));
        client
            .batch_execute(&format!(
                "CREATE TABLE IF NOT EXISTS \"{journal_table}\" (
                    ordinal      bigserial PRIMARY KEY,
                    era          int NOT NULL,
                    aggregate    text NOT NULL,
                    aggregate_id text NOT NULL,
                    operation    text NOT NULL,
                    state        jsonb
                )"
            ))
            .await
            .unwrap();

        for name in aggregate_storage_names {
            // domain-qualified (docs/decisions/0059) — matches what a real
            // `journal::append_lineage_mutation` write actually targets now.
            let snapshot_table = crate::journal::qualified_name(domain, &format!("{}_head_snapshot_{era}", crate::journal::snake(name)));
            client
                .batch_execute(&format!("CREATE TABLE IF NOT EXISTS \"{snapshot_table}\" (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL)"))
                .await
                .unwrap();
        }
    }

    #[tokio::test]
    async fn accounts_me_route_reads_a_real_cookie_and_refuses_a_missing_or_invalid_one() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_accounts_me").await;

        let cookies = session_cookies(secret, "zed@example.com");
        let response = accounts_me_route(&domain_ir, &cookies, secret, &client).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        assert_eq!(body["email"], "zed@example.com");

        let empty = HashMap::new();
        assert_eq!(accounts_me_route(&domain_ir, &empty, secret, &client).await["statusCode"], 401);

        let mut tampered = HashMap::new();
        tampered.insert(auth::account_cookie_name(), "garbage.notasignature".to_string());
        assert_eq!(accounts_me_route(&domain_ir, &tampered, secret, &client).await["statusCode"], 401);

        // A validly signed token for someone with no granted role, or nobody
        // admitted at all, is no session.
        for email in ["amy@example.com", "stranger@example.com"] {
            let response = accounts_me_route(&domain_ir, &session_cookies(secret, email), secret, &client).await;
            assert_eq!(response["statusCode"], 401, "{email}: {response:?}");
        }
    }

    #[tokio::test]
    async fn accounts_sso_token_route_mints_a_short_lived_token_verifiable_by_the_same_secret() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_accounts_sso_token").await;

        let mut cookies = HashMap::new();
        cookies.insert(auth::account_cookie_name(), auth::account_token(secret, "zed@example.com", 60 * 60 * 24 * 14));
        let response = accounts_sso_token_route(&domain_ir, &cookies, secret, &client).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let sso_token = body["token"].as_str().expect("a sso token string");

        // The point: cms/src/endpoints/sso.ts verifies this exact wire
        // format — a real, decodable token, not just a 200 with any string.
        assert_eq!(auth::verify_account_token(secret, sso_token).as_deref(), Some("zed@example.com"));

        // Missing or invalid session cookie -- refused, no token minted.
        let empty = HashMap::new();
        assert_eq!(accounts_sso_token_route(&domain_ir, &empty, secret, &client).await["statusCode"], 401);

        let mut tampered = HashMap::new();
        tampered.insert(auth::account_cookie_name(), "garbage.notasignature".to_string());
        assert_eq!(accounts_sso_token_route(&domain_ir, &tampered, secret, &client).await["statusCode"], 401);

        let no_role = accounts_sso_token_route(&domain_ir, &session_cookies(secret, "amy@example.com"), secret, &client).await;
        assert_eq!(no_role["statusCode"], 401, "{no_role:?}");
    }

    // Same head-view shape auth.rs's own tests build for the Membership
    // aggregate, seeded with one granted, linked admin and one admitted
    // person with no access yet.
    async fn scratch_members_db(name: &str) -> (Mutex<Client>, Value) {
        let client = scratch_db(name).await;
        {
            let guard = client.lock().await;
            guard
                .batch_execute(
                    "CREATE TABLE acme_member_head_snapshot_1 (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL);
                     CREATE VIEW acme_member_head AS SELECT id, state FROM acme_member_head_snapshot_1;
                     CREATE TABLE hecks_journal_acme (
                         ordinal bigserial PRIMARY KEY, era int NOT NULL, aggregate text NOT NULL,
                         aggregate_id text NOT NULL, operation text NOT NULL, state jsonb, mirrors jsonb
                     );",
                )
                .await
                .unwrap();
            guard
                .execute(
                    "INSERT INTO acme_member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 0, $2::jsonb), ($3, 0, $4::jsonb)",
                    &[
                        &"zed@example.com",
                        &json!({"name": {"value": "Zed"}, "email": {"value": "zed@example.com"},
                                "role": {"value": "Admin"}, "identity_id": {"value": "id-1"}}),
                        &"amy@example.com",
                        &json!({"name": {"value": "amy"}, "email": {"value": "amy@example.com"},
                                "role": null, "identity_id": null}),
                    ],
                )
                .await
                .unwrap();
        }
        let domain_ir = json!({
            "name": "Acme",
            "lineage": {"capable_aggregates": [{"name": "Member", "storage_name": "member"}]},
            "membership": {"provider": "Acme", "aggregate": "Acme::Member"},
        });
        (client, domain_ir)
    }

    #[tokio::test]
    async fn members_route_lists_admitted_people_as_json_sorted_by_name_for_a_valid_session() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_members_route").await;

        let mut cookies = HashMap::new();
        cookies.insert(auth::account_cookie_name(), auth::account_token(secret, "zed@example.com", 60));
        let response = members_route(&domain_ir, &cookies, secret, &client).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let people: Vec<Value> = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let names: Vec<&str> = people.iter().map(|p| p["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["amy", "Zed"], "sorted case-insensitively by name");
        assert_eq!(
            people[1],
            json!({"name": "Zed", "email": "zed@example.com", "role": "Admin", "linked": true, "granted": true, "disabled": false})
        );
        assert_eq!(
            people[0],
            json!({"name": "amy", "email": "amy@example.com", "role": null, "linked": false, "granted": false, "disabled": false})
        );
    }

    #[tokio::test]
    async fn members_route_refuses_a_missing_or_invalid_session_with_a_json_401_and_no_people() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_members_route_401").await;

        let mut tampered = HashMap::new();
        tampered.insert(auth::account_cookie_name(), "garbage.notasignature".to_string());
        let mut wrong_secret = HashMap::new();
        wrong_secret.insert(auth::account_cookie_name(), auth::account_token("another", "zed@example.com", 60));
        let mut governance_only = HashMap::new();
        governance_only.insert("session".to_string(), "anything".to_string());

        for cookies in [HashMap::new(), tampered, wrong_secret, governance_only] {
            let response = members_route(&domain_ir, &cookies, secret, &client).await;
            assert_eq!(response["statusCode"], 401, "{response:?}");
            assert!(response.get("headers").and_then(|h| h.get("location")).is_none(), "never a redirect: {response:?}");
            let body = response["body"].as_str().unwrap();
            for leaked in ["zed@example.com", "amy@example.com", "Zed", "Admin"] {
                assert!(!body.contains(leaked), "{leaked:?} leaked to an unauthenticated caller: {body}");
            }
        }
    }

    fn session_cookies(secret: &str, email: &str) -> HashMap<String, String> {
        let mut cookies = HashMap::new();
        cookies.insert(auth::account_cookie_name(), auth::account_token(secret, email, 60));
        cookies
    }

    fn members_config() -> LineageConfig {
        LineageConfig { domain: "Acme".to_string(), era: Some(1), mirrored: None }
    }

    #[tokio::test]
    async fn signup_route_refuses_anything_but_a_valid_signup_token_with_a_json_401_and_writes_nothing() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_signup_401").await;
        let body = |token: &str| json!({"token": token, "email": "new@example.com", "name": "New Person"}).to_string();

        // A session token and a token minted for another purpose both verify
        // as tokens under some key, but never as a signup token.
        let session_token = auth::account_token(secret, "zed@example.com", 60);
        let other_purpose = auth::purpose_token(secret, "another_purpose", json!({}), 60);
        let wrong_secret = auth::purpose_token("another", SIGNUP_PURPOSE, json!({}), 60);

        for token in ["", "garbage.notasignature", session_token.as_str(), other_purpose.as_str(), wrong_secret.as_str()] {
            let response = signup_route(&body(token), secret, &client, Path::new("unused"), &members_config(), &crate::lambda_client::NeverInvoker).await;
            assert_eq!(response["statusCode"], 401, "{response:?}");
            assert!(response.get("headers").and_then(|h| h.get("location")).is_none(), "never a redirect: {response:?}");
        }
        let unparseable = signup_route("not json", secret, &client, Path::new("unused"), &members_config(), &crate::lambda_client::NeverInvoker).await;
        assert_eq!(unparseable["statusCode"], 401, "{unparseable:?}");
        assert_eq!(auth::all_people(&client, &domain_ir).await.unwrap().len(), 2, "nothing was written");
    }

    #[tokio::test]
    async fn signup_route_rejects_a_blank_or_malformed_name_or_email_with_a_400() {
        let secret = "s3cret";
        let (client, _) = scratch_members_db("hecks_host_web_test_signup_400").await;
        let token = auth::purpose_token(secret, SIGNUP_PURPOSE, json!({}), 60);

        for (email, name) in [("", "Ada"), ("no-at-sign", "Ada"), ("a@nodot", "Ada"), ("has space@x.io", "Ada"), ("ada@x.io", ""), ("ada@x.io", "   ")] {
            let body = json!({"token": token, "email": email, "name": name}).to_string();
            let response = signup_route(&body, secret, &client, Path::new("unused"), &members_config(), &crate::lambda_client::NeverInvoker).await;
            assert_eq!(response["statusCode"], 400, "{email:?} / {name:?}: {response:?}");
        }
    }

    #[tokio::test]
    async fn add_member_route_refuses_a_missing_or_invalid_session_with_a_json_401_and_writes_nothing() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_add_member_401").await;
        let body = r#"{"email": "new@example.com", "name": "New Person"}"#;

        let mut tampered = HashMap::new();
        tampered.insert(auth::account_cookie_name(), "garbage.notasignature".to_string());
        let mut wrong_secret = HashMap::new();
        wrong_secret.insert(auth::account_cookie_name(), auth::account_token("another", "zed@example.com", 60));

        for cookies in [HashMap::new(), tampered, wrong_secret] {
            let response = add_member_route(&domain_ir, body, &cookies, secret, &client, Path::new("unused"), &members_config()).await;
            assert_eq!(response["statusCode"], 401, "{response:?}");
            assert!(response.get("headers").and_then(|h| h.get("location")).is_none(), "never a redirect: {response:?}");
            let text = response["body"].as_str().unwrap();
            for leaked in ["zed@example.com", "amy@example.com", "Zed", "Admin"] {
                assert!(!text.contains(leaked), "{leaked:?} leaked to an unauthenticated caller: {text}");
            }
        }
        assert_eq!(auth::all_people(&client, &domain_ir).await.unwrap().len(), 2, "nothing was written");
    }

    #[tokio::test]
    async fn add_member_route_refuses_a_caller_who_is_not_a_granted_admin_with_a_403() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_add_member_403").await;
        let body = r#"{"email": "new@example.com", "name": "New Person"}"#;

        // amy is admitted but has no role; a stranger is not admitted at all.
        for caller in ["amy@example.com", "stranger@example.com"] {
            let cookies = session_cookies(secret, caller);
            let response = add_member_route(&domain_ir, body, &cookies, secret, &client, Path::new("unused"), &members_config()).await;
            assert_eq!(response["statusCode"], 403, "{caller}: {response:?}");
        }
        assert_eq!(auth::all_people(&client, &domain_ir).await.unwrap().len(), 2, "nothing was written");
    }

    #[tokio::test]
    async fn add_member_route_rejects_a_blank_or_malformed_email_or_name_with_a_400() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_add_member_400").await;
        let cookies = session_cookies(secret, "zed@example.com");

        for body in [
            "",
            "not json",
            "{}",
            r#"{"email": "new@example.com"}"#,
            r#"{"name": "New Person"}"#,
            r#"{"email": "   ", "name": "New Person"}"#,
            r#"{"email": "new@example.com", "name": "   "}"#,
            r#"{"email": "no-at-sign", "name": "New Person"}"#,
            r#"{"email": "@example.com", "name": "New Person"}"#,
            r#"{"email": "new@nodot", "name": "New Person"}"#,
            r#"{"email": "two words@example.com", "name": "New Person"}"#,
            r#"{"email": 42, "name": "New Person"}"#,
        ] {
            let response = add_member_route(&domain_ir, body, &cookies, secret, &client, Path::new("unused"), &members_config()).await;
            assert_eq!(response["statusCode"], 400, "{body:?}: {response:?}");
        }
        assert_eq!(auth::all_people(&client, &domain_ir).await.unwrap().len(), 2, "nothing was written");
    }

    #[tokio::test]
    async fn add_member_route_answers_409_for_an_email_that_is_already_admitted_in_any_case() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_add_member_409").await;
        let cookies = session_cookies(secret, "zed@example.com");

        for email in ["amy@example.com", "AMY@Example.com"] {
            let body = json!({"email": email, "name": "Another Amy"}).to_string();
            let response = add_member_route(&domain_ir, &body, &cookies, secret, &client, Path::new("unused"), &members_config()).await;
            assert_eq!(response["statusCode"], 409, "{email}: {response:?}");
        }
        assert_eq!(auth::all_people(&client, &domain_ir).await.unwrap().len(), 2, "nothing was written");
    }

    #[tokio::test]
    async fn add_member_route_admits_and_grants_admin_then_lists_the_person_as_granted() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_add_member_201").await;
        let cookies = session_cookies(secret, "Zed@Example.com");

        let body = r#"{"email": "  New@Example.com ", "name": " New Person "}"#;
        let response = add_member_route(&domain_ir, body, &cookies, secret, &client, Path::new("unused"), &members_config()).await;
        assert_eq!(response["statusCode"], 201, "{response:?}");
        let created: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        assert_eq!(
            created,
            json!({"name": "New Person", "email": "new@example.com", "role": "Admin", "linked": false, "granted": true, "disabled": false})
        );

        let listing = members_route(&domain_ir, &cookies, secret, &client).await;
        let people: Vec<Value> = serde_json::from_str(listing["body"].as_str().unwrap()).unwrap();
        assert_eq!(people.len(), 3);
        let added = people.iter().find(|p| p["email"] == "new@example.com").expect("the new person is listed");
        assert_eq!(*added, created);

        let guard = client.lock().await;
        let journalled: i64 = guard
            .query_one("SELECT count(*) FROM hecks_journal_acme WHERE aggregate_id = 'new@example.com'", &[])
            .await
            .unwrap()
            .get(0);
        assert_eq!(journalled, 2, "one journal row for Admit and one for GrantAccess");
    }

    // The scratch members database with amy also granted Admin, so two
    // active admins exist and one can act on the other.
    async fn scratch_two_admins(name: &str) -> (Mutex<Client>, Value) {
        let (client, domain_ir) = scratch_members_db(name).await;
        let granted = auth::grant_access(&client, Path::new("unused"), &members_config(), &domain_ir, "amy@example.com", "Admin").await.unwrap();
        assert!(granted);
        (client, domain_ir)
    }

    async fn switch_access(client: &Mutex<Client>, domain_ir: &Value, caller: &str, email: &str, disable: bool) -> Value {
        let secret = "s3cret";
        let body = json!({"email": email}).to_string();
        set_member_disabled_route(domain_ir, &body, &session_cookies(secret, caller), secret, client, &members_config(), disable).await
    }

    fn error_of(response: &Value) -> String {
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        body["error"].as_str().unwrap_or_default().to_string()
    }

    async fn person(client: &Mutex<Client>, domain_ir: &Value, email: &str) -> Value {
        let people = auth::all_people(client, domain_ir).await.unwrap();
        people.into_iter().find(|p| p["email"] == email).unwrap_or_else(|| panic!("{email} is not listed"))
    }

    async fn journal_rows(client: &Mutex<Client>, id: &str) -> i64 {
        let guard = client.lock().await;
        guard
            .query_one("SELECT count(*) FROM hecks_journal_acme WHERE aggregate_id = $1", &[&id])
            .await
            .unwrap()
            .get(0)
    }

    #[tokio::test]
    async fn disable_and_enable_routes_refuse_a_missing_or_invalid_session_and_a_blank_email() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_two_admins("hecks_host_web_test_disable_401").await;

        let mut tampered = HashMap::new();
        tampered.insert(auth::account_cookie_name(), "garbage.notasignature".to_string());
        let body = json!({"email": "amy@example.com"}).to_string();
        for disable in [true, false] {
            for cookies in [HashMap::new(), tampered.clone()] {
                let response = set_member_disabled_route(&domain_ir, &body, &cookies, secret, &client, &members_config(), disable).await;
                assert_eq!(response["statusCode"], 401, "{response:?}");
                assert!(response.get("headers").and_then(|h| h.get("location")).is_none(), "never a redirect: {response:?}");
            }
            for blank in ["", "   "] {
                let response = switch_access(&client, &domain_ir, "zed@example.com", blank, disable).await;
                assert_eq!(response["statusCode"], 400, "{blank:?}: {response:?}");
            }
        }
        assert_eq!(person(&client, &domain_ir, "amy@example.com").await["disabled"], false, "nothing was written");
    }

    #[tokio::test]
    async fn disable_and_enable_routes_refuse_a_caller_who_is_not_an_active_admin_with_a_403() {
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_disable_403").await;

        // amy is admitted with no role; the stranger was never admitted.
        for caller in ["amy@example.com", "stranger@example.com"] {
            for disable in [true, false] {
                let response = switch_access(&client, &domain_ir, caller, "zed@example.com", disable).await;
                assert_eq!(response["statusCode"], 403, "{caller}: {response:?}");
                assert_eq!(error_of(&response), "admins only");
            }
        }
        assert_eq!(person(&client, &domain_ir, "zed@example.com").await["granted"], true, "nothing was written");
    }

    #[tokio::test]
    async fn disable_route_refuses_an_admin_disabling_themselves_in_any_case_and_writes_nothing() {
        let (client, domain_ir) = scratch_two_admins("hecks_host_web_test_disable_self").await;
        let before = journal_rows(&client, "zed@example.com").await;

        for typed in ["zed@example.com", "  ZED@Example.com "] {
            let response = switch_access(&client, &domain_ir, "zed@example.com", typed, true).await;
            assert_eq!(response["statusCode"], 403, "{typed:?}: {response:?}");
            assert_eq!(error_of(&response), "you can't disable your own admin access");
        }
        assert_eq!(person(&client, &domain_ir, "zed@example.com").await["granted"], true);
        assert_eq!(journal_rows(&client, "zed@example.com").await, before);
    }

    #[tokio::test]
    async fn disable_and_enable_routes_answer_404_for_an_unknown_email() {
        let (client, domain_ir) = scratch_two_admins("hecks_host_web_test_disable_404").await;
        for disable in [true, false] {
            let response = switch_access(&client, &domain_ir, "zed@example.com", "nobody@example.com", disable).await;
            assert_eq!(response["statusCode"], 404, "{response:?}");
        }
    }

    async fn set_role(client: &Mutex<Client>, domain_ir: &Value, caller: &str, email: &str, role: &str) -> Value {
        let secret = "s3cret";
        let body = json!({"email": email, "role": role}).to_string();
        set_member_role_route(domain_ir, &body, &session_cookies(secret, caller), secret, client, &members_config()).await
    }

    #[tokio::test]
    async fn role_route_refuses_a_missing_session_a_blank_email_and_an_unknown_role_and_writes_nothing() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_role_400").await;
        let before = journal_rows(&client, "amy@example.com").await;

        let mut tampered = HashMap::new();
        tampered.insert(auth::account_cookie_name(), "garbage.notasignature".to_string());
        let body = json!({"email": "amy@example.com", "role": "Owner"}).to_string();
        for cookies in [HashMap::new(), tampered] {
            let response = set_member_role_route(&domain_ir, &body, &cookies, secret, &client, &members_config()).await;
            assert_eq!(response["statusCode"], 401, "{response:?}");
            assert!(response.get("headers").and_then(|h| h.get("location")).is_none(), "never a redirect: {response:?}");
        }
        for blank in ["", "   "] {
            let response = set_role(&client, &domain_ir, "zed@example.com", blank, "Owner").await;
            assert_eq!(response["statusCode"], 400, "{blank:?}: {response:?}");
        }
        for role in ["", "Root", "owner", "Owner Admin"] {
            let response = set_role(&client, &domain_ir, "zed@example.com", "amy@example.com", role).await;
            assert_eq!(response["statusCode"], 400, "{role:?}: {response:?}");
            assert_eq!(error_of(&response), "role must be one of Admin, Owner, Member");
        }
        assert_eq!(person(&client, &domain_ir, "amy@example.com").await["role"], Value::Null, "nothing was written");
        assert_eq!(journal_rows(&client, "amy@example.com").await, before);
    }

    #[tokio::test]
    async fn role_route_refuses_a_caller_who_is_not_an_active_admin_with_a_403_and_answers_404_for_an_unknown_email() {
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_role_403").await;

        // amy is admitted with no role; the stranger was never admitted.
        for caller in ["amy@example.com", "stranger@example.com"] {
            let response = set_role(&client, &domain_ir, caller, "amy@example.com", "Owner").await;
            assert_eq!(response["statusCode"], 403, "{caller}: {response:?}");
            assert_eq!(error_of(&response), "admins only");
        }

        // A plain Member cannot promote themselves either.
        assert!(auth::grant_access(&client, Path::new("unused"), &members_config(), &domain_ir, "amy@example.com", "Member").await.unwrap());
        let response = set_role(&client, &domain_ir, "amy@example.com", "amy@example.com", "Owner").await;
        assert_eq!(response["statusCode"], 403, "{response:?}");
        assert_eq!(person(&client, &domain_ir, "amy@example.com").await["role"], "Member", "nothing was written");

        let response = set_role(&client, &domain_ir, "zed@example.com", "nobody@example.com", "Owner").await;
        assert_eq!(response["statusCode"], 404, "{response:?}");
    }

    #[tokio::test]
    async fn role_route_lets_an_admin_grant_owner_to_an_already_admitted_person_and_repeating_it_writes_nothing() {
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_role_grant").await;
        let status = |response: &Value| response["statusCode"].as_i64().unwrap();

        // amy is admitted but holds no role, so she is not an admin yet.
        assert!(!auth::caller_is_admin(&client, &domain_ir, "amy@example.com").await.unwrap());

        // Case and surrounding spaces in the email do not matter.
        let response = set_role(&client, &domain_ir, "Zed@Example.com", " Amy@Example.com ", "Owner").await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        assert_eq!(body, json!({"email": "amy@example.com", "role": "Owner"}));

        // She now passes the admin gate and the Owner check payments makes.
        assert!(auth::caller_is_admin(&client, &domain_ir, "amy@example.com").await.unwrap());
        assert_eq!(auth::active_role(&client, &domain_ir, "amy@example.com").await.unwrap().as_deref(), Some("Owner"));
        let amy = person(&client, &domain_ir, "amy@example.com").await;
        assert_eq!((amy["role"].as_str(), amy["granted"].clone()), (Some("Owner"), json!(true)));

        // The new Owner can act as an admin, including granting Owner in turn.
        let response = set_role(&client, &domain_ir, "amy@example.com", "zed@example.com", "Owner").await;
        assert_eq!(status(&response), 200, "{response:?}");
        assert_eq!(auth::active_role(&client, &domain_ir, "zed@example.com").await.unwrap().as_deref(), Some("Owner"));

        // Asking for the role someone already holds is a 200 and writes nothing.
        let rows = journal_rows(&client, "amy@example.com").await;
        assert_eq!(status(&set_role(&client, &domain_ir, "zed@example.com", "amy@example.com", "Owner").await), 200);
        assert_eq!(journal_rows(&client, "amy@example.com").await, rows);
    }

    #[tokio::test]
    async fn role_route_keeps_the_identity_link_and_the_disabled_flag_when_it_changes_a_role() {
        let (client, domain_ir) = scratch_two_admins("hecks_host_web_test_role_keeps").await;

        // zed is linked (id-1 in the seed); amy is disabled while holding Admin.
        assert_eq!(switch_access(&client, &domain_ir, "zed@example.com", "amy@example.com", true).await["statusCode"], 200);
        assert_eq!(set_role(&client, &domain_ir, "zed@example.com", "amy@example.com", "Owner").await["statusCode"], 200);
        assert_eq!(set_role(&client, &domain_ir, "zed@example.com", "zed@example.com", "Owner").await["statusCode"], 200);

        let amy = person(&client, &domain_ir, "amy@example.com").await;
        assert_eq!((amy["role"].as_str(), amy["disabled"].clone(), amy["granted"].clone()), (Some("Owner"), json!(true), json!(false)));
        let zed = person(&client, &domain_ir, "zed@example.com").await;
        assert_eq!((zed["role"].as_str(), zed["linked"].clone(), zed["name"].as_str()), (Some("Owner"), json!(true), Some("Zed")));
        assert!(auth::session_for_member_by_identity(&client, &domain_ir, "id-1").await.unwrap().is_some(), "zed can still sign in");

        // Enabling amy restores her, now as an Owner.
        assert_eq!(switch_access(&client, &domain_ir, "zed@example.com", "amy@example.com", false).await["statusCode"], 200);
        assert_eq!(auth::active_role(&client, &domain_ir, "amy@example.com").await.unwrap().as_deref(), Some("Owner"));
    }

    #[tokio::test]
    async fn role_route_never_demotes_the_last_active_admin_but_may_demote_one_of_two() {
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_role_last_admin").await;

        // zed is the only active admin: demoting themselves would lock everyone out.
        let response = set_role(&client, &domain_ir, "zed@example.com", "zed@example.com", "Member").await;
        assert_eq!(response["statusCode"], 409, "{response:?}");
        assert_eq!(error_of(&response), "there must always be at least one admin");
        assert_eq!(person(&client, &domain_ir, "zed@example.com").await["role"], "Admin", "nothing was written");
        // Moving between admin roles never strands anyone.
        assert_eq!(set_role(&client, &domain_ir, "zed@example.com", "zed@example.com", "Owner").await["statusCode"], 200);

        // With a second admin, one may demote the other, and then the last one is protected again.
        assert_eq!(set_role(&client, &domain_ir, "zed@example.com", "amy@example.com", "Admin").await["statusCode"], 200);
        assert_eq!(set_role(&client, &domain_ir, "zed@example.com", "amy@example.com", "Member").await["statusCode"], 200);
        assert_eq!(set_role(&client, &domain_ir, "zed@example.com", "zed@example.com", "Member").await["statusCode"], 409);
        assert_eq!(person(&client, &domain_ir, "zed@example.com").await["role"], "Owner");
    }

    #[tokio::test]
    async fn disabling_keeps_the_role_ends_the_old_session_at_once_and_enabling_restores_it() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_two_admins("hecks_host_web_test_disable_enable").await;
        let amy_cookies = session_cookies(secret, "amy@example.com");
        let status = |response: &Value| response["statusCode"].as_i64().unwrap();
        assert_eq!(status(&accounts_me_route(&domain_ir, &amy_cookies, secret, &client).await), 200);

        let response = switch_access(&client, &domain_ir, "Zed@Example.com", " Amy@Example.com ", true).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        assert_eq!(body, json!({"disabled": "amy@example.com"}));

        // The person, role and identity fields stay; only the explicit flag flips.
        let amy = person(&client, &domain_ir, "amy@example.com").await;
        assert_eq!(amy["role"], "Admin", "the retained role still shows");
        assert_eq!(amy["granted"], false);
        assert_eq!(amy["disabled"], true);

        // amy's cookie is still validly signed and unexpired, yet stops working now.
        assert_eq!(status(&accounts_me_route(&domain_ir, &amy_cookies, secret, &client).await), 401);
        assert_eq!(status(&accounts_sso_token_route(&domain_ir, &amy_cookies, secret, &client).await), 401);
        assert_eq!(status(&members_route(&domain_ir, &amy_cookies, secret, &client).await), 401);
        let add = add_member_route(&domain_ir, r#"{"email":"x@example.com","name":"X"}"#, &amy_cookies, secret, &client, Path::new("unused"), &members_config()).await;
        assert_eq!(status(&add), 403);
        assert_eq!(status(&switch_access(&client, &domain_ir, "amy@example.com", "zed@example.com", true).await), 403);
        assert_eq!(person(&client, &domain_ir, "zed@example.com").await["granted"], true, "a disabled caller changed nothing");

        // Disabling again is a 200 and writes nothing.
        let rows = journal_rows(&client, "amy@example.com").await;
        assert_eq!(status(&switch_access(&client, &domain_ir, "zed@example.com", "amy@example.com", true).await), 200);
        assert_eq!(journal_rows(&client, "amy@example.com").await, rows);

        // Enabling restores exactly the earlier access, and is idempotent too.
        let response = switch_access(&client, &domain_ir, "zed@example.com", "amy@example.com", false).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        assert_eq!(body, json!({"enabled": "amy@example.com"}));
        let amy = person(&client, &domain_ir, "amy@example.com").await;
        assert_eq!((amy["role"].as_str(), amy["granted"].clone(), amy["disabled"].clone()), (Some("Admin"), json!(true), json!(false)));
        assert_eq!(status(&accounts_me_route(&domain_ir, &amy_cookies, secret, &client).await), 200);

        let rows = journal_rows(&client, "amy@example.com").await;
        assert_eq!(status(&switch_access(&client, &domain_ir, "zed@example.com", "amy@example.com", false).await), 200);
        assert_eq!(journal_rows(&client, "amy@example.com").await, rows);
    }

    #[tokio::test]
    async fn a_disabled_person_cannot_sign_in_again_and_an_enabled_one_can() {
        let (client, domain_ir) = scratch_two_admins("hecks_host_web_test_disable_signin").await;

        // zed holds identity id-1 in the seed; a fresh Google sign-in resolves through it.
        assert!(auth::session_for_member_by_identity(&client, &domain_ir, "id-1").await.unwrap().is_some());
        let disabled = switch_access(&client, &domain_ir, "amy@example.com", "zed@example.com", true).await;
        assert_eq!(disabled["statusCode"], 200, "{disabled:?} amy={:?}", person(&client, &domain_ir, "amy@example.com").await);
        assert!(auth::session_for_member_by_identity(&client, &domain_ir, "id-1").await.unwrap().is_none());
        assert_eq!(switch_access(&client, &domain_ir, "amy@example.com", "zed@example.com", false).await["statusCode"], 200);
        assert!(auth::session_for_member_by_identity(&client, &domain_ir, "id-1").await.unwrap().is_some());
    }

    #[tokio::test]
    async fn two_admins_disabling_each_other_at_once_leave_exactly_one_active_admin() {
        let (client, domain_ir) = scratch_two_admins("hecks_host_web_test_disable_race").await;
        let config = members_config();

        let (a, b) = tokio::join!(
            auth::set_person_disabled(&client, &config, &domain_ir, "zed@example.com", "amy@example.com", true),
            auth::set_person_disabled(&client, &config, &domain_ir, "amy@example.com", "zed@example.com", true),
        );
        let mut outcomes = [a.unwrap(), b.unwrap()];
        outcomes.sort_by_key(|o| format!("{o:?}"));
        assert_eq!(outcomes, [auth::DisableOutcome::CallerNotAdmin, auth::DisableOutcome::Done]);

        let active = auth::all_people(&client, &domain_ir).await.unwrap().iter().filter(|p| p["role"] == "Admin" && p["granted"] == true).count();
        assert_eq!(active, 1, "there must always be one active admin");
    }

    #[tokio::test]
    async fn registrations_list_route_refuses_anyone_but_an_active_admin_before_reading_any_registration() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_two_admins("hecks_host_web_test_registrations_list_auth").await;
        let config = LineageConfig { domain: "Studio".to_string(), era: Some(1), mirrored: None };
        // The wasm path doesn't exist: every refusal below must come before any registration read.
        let wasm_path = Path::new("does-not-exist.wasm");

        let mut tampered = HashMap::new();
        tampered.insert(auth::account_cookie_name(), "garbage.notasignature".to_string());
        for cookies in [HashMap::new(), tampered] {
            let response = registrations_list_route(&domain_ir, &cookies, secret, &client, wasm_path, &config).await;
            assert_eq!(response["statusCode"], 401, "{response:?}");
            assert!(response.get("headers").and_then(|h| h.get("location")).is_none(), "never a redirect: {response:?}");
        }

        // amy is a disabled admin now; the stranger was never admitted at all.
        assert_eq!(switch_access(&client, &domain_ir, "zed@example.com", "amy@example.com", true).await["statusCode"], 200);
        for caller in ["amy@example.com", "stranger@example.com"] {
            let response = registrations_list_route(&domain_ir, &session_cookies(secret, caller), secret, &client, wasm_path, &config).await;
            assert_eq!(response["statusCode"], 403, "{caller}: {response:?}");
            assert_eq!(error_of(&response), "admins only");
        }
    }

    async fn status_of(response: Value) -> u64 {
        response["statusCode"].as_u64().unwrap()
    }

    #[tokio::test]
    async fn every_admin_gate_accepts_an_owner_as_well_as_an_admin_and_refuses_a_member_and_anonymous() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_two_admins("hecks_host_web_test_owner_gates").await;
        let config = members_config();
        // amy becomes Owner (replacing her Admin role), bob is a plain Member.
        assert!(auth::grant_access(&client, Path::new("unused"), &config, &domain_ir, "amy@example.com", "Owner").await.unwrap());
        assert!(auth::admit_person(&client, &config, &domain_ir, "bob@example.com", "Bob").await.unwrap());
        assert!(auth::grant_access(&client, Path::new("unused"), &config, &domain_ir, "bob@example.com", "Member").await.unwrap());
        let studio = LineageConfig { domain: "Studio".to_string(), era: Some(1), mirrored: None };
        // No wasm at all: clearing the admin gate then fails with a 500, never 401/403.
        let missing_wasm = Path::new("does-not-exist.wasm");

        // Every gate, as one closure per route: list, add, disable, enable, registrations.
        for (caller, admits) in [("amy@example.com", true), ("zed@example.com", true), ("bob@example.com", false), ("stranger@example.com", false)] {
            let cookies = session_cookies(secret, caller);
            let add = add_member_route(&domain_ir, &json!({"email": "not an email", "name": "N"}).to_string(), &cookies, secret, &client, Path::new("unused"), &config).await;
            let add = status_of(add).await;
            let registrations = status_of(registrations_list_route(&domain_ir, &cookies, secret, &client, missing_wasm, &studio).await).await;
            let disable = status_of(switch_access(&client, &domain_ir, caller, "bob@example.com", true).await).await;
            let enable = status_of(switch_access(&client, &domain_ir, caller, "bob@example.com", false).await).await;
            if admits {
                // The email is deliberately malformed: the gate passed, validation refused it.
                assert_eq!(add, 400, "{caller} passes the add gate");
                assert_eq!(registrations, 500, "{caller} passes the registrations gate");
                assert_eq!((disable, enable), (200, 200), "{caller} passes disable and enable");
            } else {
                assert_eq!((add, registrations, disable, enable), (403, 403, 403, 403), "{caller} is refused everywhere");
            }
            // Listing needs access, not admin: a Member may list, a stranger may not.
            let listing = status_of(members_route(&domain_ir, &cookies, secret, &client).await).await;
            assert_eq!(listing, if caller == "stranger@example.com" { 401 } else { 200 }, "{caller} listing");
        }

        // Anonymous: 401 on every route, before any role is looked at.
        let none = HashMap::new();
        assert_eq!(status_of(add_member_route(&domain_ir, "{}", &none, secret, &client, Path::new("unused"), &config).await).await, 401);
        assert_eq!(status_of(members_route(&domain_ir, &none, secret, &client).await).await, 401);
        assert_eq!(status_of(registrations_list_route(&domain_ir, &none, secret, &client, missing_wasm, &studio).await).await, 401);
        assert_eq!(status_of(set_member_disabled_route(&domain_ir, r#"{"email":"bob@example.com"}"#, &none, secret, &client, &config, true).await).await, 401);
    }

    #[tokio::test]
    async fn an_admin_can_grant_owner_and_the_new_owner_keeps_admin_and_members_access() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_grant_owner").await;
        let config = members_config();

        let body = r#"{"email": "boss@example.com", "name": "Boss", "role": "Owner"}"#;
        let response = add_member_route(&domain_ir, body, &session_cookies(secret, "zed@example.com"), secret, &client, Path::new("unused"), &config).await;
        assert_eq!(response["statusCode"], 201, "{response:?}");
        let created: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        assert_eq!(created["role"], "Owner");
        assert_eq!(person(&client, &domain_ir, "boss@example.com").await["role"], "Owner");

        // The Owner isn't locked out: lists, admits, disables and enables.
        let boss = session_cookies(secret, "boss@example.com");
        assert_eq!(status_of(members_route(&domain_ir, &boss, secret, &client).await).await, 200);
        for (email, role) in [("second@example.com", "Owner"), ("plain@example.com", "Member")] {
            let body = json!({"email": email, "name": "X", "role": role}).to_string();
            let response = add_member_route(&domain_ir, &body, &boss, secret, &client, Path::new("unused"), &config).await;
            assert_eq!(response["statusCode"], 201, "{response:?}");
            assert_eq!(person(&client, &domain_ir, email).await["role"], role);
        }
        assert_eq!(switch_access(&client, &domain_ir, "boss@example.com", "zed@example.com", true).await["statusCode"], 200);
        assert_eq!(switch_access(&client, &domain_ir, "boss@example.com", "zed@example.com", false).await["statusCode"], 200);

        // A person granted only Member cannot grant anything, Owner included.
        let response = add_member_route(&domain_ir, r#"{"email": "x@example.com", "name": "X", "role": "Owner"}"#, &session_cookies(secret, "plain@example.com"), secret, &client, Path::new("unused"), &config).await;
        assert_eq!(response["statusCode"], 403, "{response:?}");
    }

    #[tokio::test]
    async fn the_add_route_refuses_an_unknown_role_and_writes_nothing() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_grant_unknown_role").await;
        for role in [json!("Root"), json!("admin"), json!(""), json!(7)] {
            let body = json!({"email": "new@example.com", "name": "New", "role": role}).to_string();
            let response = add_member_route(&domain_ir, &body, &session_cookies(secret, "zed@example.com"), secret, &client, Path::new("unused"), &members_config()).await;
            assert_eq!(response["statusCode"], 400, "{role}: {response:?}");
            assert_eq!(error_of(&response), "role must be one of Admin, Owner, Member");
        }
        assert_eq!(journal_rows(&client, "new@example.com").await, 0);
    }

    #[test]
    fn the_admin_gate_role_set_is_exactly_admin_and_owner() {
        assert!(auth::is_admin_role("Admin") && auth::is_admin_role("Owner"));
        assert!(!auth::is_admin_role("Member") && !auth::is_admin_role("owner") && !auth::is_admin_role(""));
        assert_eq!(auth::GRANTABLE_ROLES, ["Admin", "Owner", "Member"]);
    }

    #[test]
    fn registration_list_rows_have_exactly_the_admin_list_shape_and_never_carry_health_or_payment_fields() {
        let read = json!({"instances": {
            "Studio::Registration#reg-old": {
                "event_slug": "yoga-aug",
                "created_at": "2026-09-01T10:00:00Z",
                "attendee": {"first_name": " Ada ", "last_name": "Lovelace", "email": "ada@example.com", "news_signup": true,
                             "phone": "555-0100", "medications": "SECRET-MEDICATION", "health_concerns": "SECRET-CONCERN"},
            },
            "Studio::Registration#reg-new": {
                "event_slug": "yoga-sep",
                "created_at": "2026-09-20T10:00:00Z",
                "attendee": {"first_name": {"value": "Grace"}, "last_name": {"value": "Hopper"}, "email": {"value": "grace@example.com"}},
                "amount": {"cents": 9900},
            },
            "Studio::Event#yoga-aug": {"name": {"value": "Yoga"}},
            "Payments::Payment#reg-old": {"amount": {"cents": 12345}, "status": "succeeded"},
        }});

        let rows = registration_list_rows(&read, "Studio");
        assert_eq!(
            rows,
            vec![
                json!({"registration_id": "reg-new", "email": "grace@example.com", "name": "Grace Hopper", "event_slug": "yoga-sep", "news_signup": false}),
                json!({"registration_id": "reg-old", "email": "ada@example.com", "name": "Ada Lovelace", "event_slug": "yoga-aug", "news_signup": true}),
            ],
            "newest first, plain values, news_signup defaulting to false"
        );

        let body = Value::Array(rows).to_string();
        for leaked in ["SECRET-MEDICATION", "SECRET-CONCERN", "medications", "health_concerns", "555-0100", "12345", "9900", "succeeded", "amount"] {
            assert!(!body.contains(leaked), "{leaked:?} leaked into the registration list: {body}");
        }
    }

    #[test]
    fn registration_list_rows_carry_status_only_when_the_registration_has_one() {
        let read = json!({"instances": {
            "Studio::Registration#with": {"event_slug": "e", "status": "archived", "attendee": {"name": "Has Status", "email": "with@example.com"}},
            "Studio::Registration#without": {"event_slug": "e", "attendee": {"name": "No Status", "email": "without@example.com"}},
        }});
        let rows = registration_list_rows(&read, "Studio");
        let by_id = |id: &str| rows.iter().find(|row| row["registration_id"] == id).unwrap().clone();
        assert_eq!(by_id("with")["status"], "archived");
        assert!(by_id("without").get("status").is_none(), "no status key at all when the registration carries none: {:?}", by_id("without"));
        assert_eq!(
            by_id("without"),
            json!({"registration_id": "without", "email": "without@example.com", "name": "No Status", "event_slug": "e", "news_signup": false})
        );
    }

    #[test]
    fn registration_list_rows_keep_read_order_without_timestamps_and_are_empty_with_no_registrations() {
        let read = json!({"instances": {
            "Studio::Registration#a": {"event_slug": "e", "attendee": {"name": "Flat Name", "email": "flat@example.com"}},
        }});
        let rows = registration_list_rows(&read, "Studio");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["name"], "Flat Name", "falls back to a flat name when there is no first and last name");

        assert_eq!(registration_list_rows(&json!({"instances": {}}), "Studio"), Vec::<Value>::new());
        assert_eq!(registration_list_rows(&json!({}), "Studio"), Vec::<Value>::new());
        let other_domain = json!({"instances": {"Elsewhere::Registration#x": {"attendee": {"email": "x@example.com"}}}});
        assert!(registration_list_rows(&other_domain, "Studio").is_empty(), "another domain's registrations are not listed");
    }

    #[test]
    fn sorted_by_name_orders_case_insensitively_and_puts_a_missing_name_first() {
        let people = vec![json!({"name": "bob"}), json!({"name": "Ada"}), json!({"name": null}), json!({"name": "Cy"})];
        let names: Vec<Value> = sorted_by_name(people).into_iter().map(|p| p["name"].clone()).collect();
        assert_eq!(names, [json!(null), json!("Ada"), json!("bob"), json!("Cy")]);
    }

}
