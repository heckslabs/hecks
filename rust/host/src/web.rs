// **The web UI, in-process** — no second Lambda, no network hop. Detects
// a Function-URL HTTP event (`requestContext.http`/`rawPath` present
// — the API Gateway v2 payload format every Function URL invocation
// uses, unconditionally) and, if present, resolves it against the
// same IR `Hecks::Presentation::FieldShape` walks in Ruby
// (`HECKS_IR_PATH`, a plain-JSON sidecar — see domain_generator.rb's
// own comment on why this isn't the metadata.rs-embedded constant:
// this crate has no path dependency on the kernel crate that embeds
// it), dispatching through the same `dispatch::handle`/`dispatch::read`
// this Lambda already uses for its internal `{"verb"}`/`{"read"}`
// events. Ported from HecksOnWeb::Router/FieldShape/FormBuilder (the
// Ruby framework, hecks_on_web) — same routing rules, same field-shape
// mapping, same Tailwind classes, Rust.
//
// Returns `None` for anything that isn't a Function-URL HTTP event —
// `main.rs` falls through to its existing `read`/`verb` handling
// untouched in that case, zero risk to the internal-dispatch path.

use crate::api;
use crate::auth;
use crate::auth::Session;
use crate::checkout;
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

    // Parsed here, once, rather than only below `checkout_enabled` — the
    // newsletter confirm/unsubscribe routes (reached from an email link,
    // never a JSON body) need `?email=...` before `route()`'s own later
    // `auth_gate` check would ever run for them. Query strings are RFC
    // 3986, not application/x-www-form-urlencoded: `+` is a literal
    // plus. Google's OAuth `code` routinely contains `+`; treating it as
    // space (HTML-form rules) breaks the token exchange and surfaces as
    // `/login?error=google_failed`. Form bodies still use parse_form.
    let query = parse_query(body.get("rawQueryString").and_then(|v| v.as_str()).unwrap_or(""));

    // **Checkout glue, opt-in by configuration** — `HECKS_CHECKOUT_DOMAIN`
    // names the domain whose Event/Registration aggregates (plus the
    // Payments::Payment chapter beside them) the checkout routes
    // dispatch against; unset, or naming a different domain, these
    // routes don't exist. An env var rather than an IR-driven "outbound
    // port"/"webhook signature scheme" capability — considered for
    // real (equivalence-gap plan 3.3) and declined; checkout.rs's own
    // header has the reasoning. Membership, unlike checkout, *did* move
    // onto a declared capability (`provides "membership"`). The verb shapes these routes hardcode
    // are pinned by spec/fixtures/rust_host/checkout_fixture, which this
    // module's tests run against. Checked before the ir()/HECKS_IR_PATH
    // gate below, deliberately: a Shared-mode deploy with no generic
    // FieldShape UI never sets HECKS_IR_PATH, and neither route needs a
    // domain_ir at all.
    if checkout_enabled(std::env::var("HECKS_CHECKOUT_DOMAIN").ok().as_deref(), &config.domain) {
        // Guest-facing newsletter subscribe -- same gate as checkout
        // (HECKS_CHECKOUT_DOMAIN), not a second env var: both are
        // vendored embryonaut_bluebooks chapters loaded into the SAME
        // Lifeadelics hecksagon (uses_embryonaut_bluebook "newsletter"),
        // so "this is the real Lifeadelics deployment with guest routes
        // on" is one fact, not two. Checked first, deliberately: it
        // needs no Payments::Payment/Event context checkout_route's own
        // routes carry, and public signup should never depend on
        // checkout being reachable.
        if let Some(response) = newsletter_route(method, path, &query, &raw_body, client, wasm_path, config, invoker).await {
            return Some(response);
        }
        let stripe_signature = body.get("headers").and_then(|h| h.get("stripe-signature")).and_then(|v| v.as_str()).unwrap_or("");
        if let Some(response) = checkout_route(method, path, &raw_body, stripe_signature, client, wasm_path, config, invoker).await {
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
    // API Gateway v2 / Function URL payload format's own `cookies`
    // array — each element one "name=value" pair split off the raw
    // Cookie header already. Falls back to a raw `headers.cookie`
    // string (semicolon-separated) for anything that sends it that
    // way instead — both shapes reduce to the same map either way.
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

// H11 (docs/audits/2026-08-10-main-bug-audit.md) — this secret HMAC-signs
// every session cookie and OAuth `state` parameter (auth.rs's own
// `session_cookie`/`verify_state`), and `parse_session_cookie` treats
// anything that verifies against it as a trusted session, bypassing the
// `session.is_none()` -> `/login` redirect gate entirely. Without the
// `validate_session_secret` call below, an unset or empty
// `SESSION_SECRET` would fail open here (`unwrap_or_default()`),
// signing every cookie with a publicly-known empty-string key instead
// of refusing to serve — unlike every other required var this crate
// reads (main.rs's own `DATABASE_URL`/`HECKS_DOMAIN`/`HECKS_IR_PATH`,
// each a hard `?` that refuses to boot rather than silently defaulting). Not required
// at main.rs's own top-level boot, deliberately: unlike those vars,
// SESSION_SECRET is genuinely absent for a domain with no web layer at
// all (Banking/Pizzas's own template.yaml never sets it) — this only
// has to refuse the moment a request actually needs it, i.e. here.
fn session_secret() -> String {
    let secret = std::env::var("SESSION_SECRET").unwrap_or_default();
    if let Err(e) = validate_session_secret(&secret) {
        panic!("{e}");
    }
    secret
}

// Pure and separately unit-tested from the panic above — same split
// main.rs's own `mint::decide_boot_action` already uses for its boot
// gate (a pure decision function, panicking/erroring only at the one
// call site that owns process lifecycle).
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

// The gate, and why it has two answers — an unauthenticated request is
// refused here, but how it's refused has to match what the caller can
// actually do with the refusal. A browser navigating to a page wants to
// be sent somewhere it can sign in. A `fetch()`/`curl` asking for JSON
// wants a status code it can branch on, and a 302 to an HTML login page
// is the one answer it cannot use: the redirect is followed
// transparently, so the caller gets 200 and a login page exactly where
// it expected data, and only notices when parsing fails.
//
// Redirecting both the same way would silently break
// embryonautfoundersapp's own CI assertion (`curl -o /dev/null -w
// '%{http_code}' /api/clients` is `401`) the moment the same domain is
// served by this host instead of the Ruby console engine — a gap found
// in production, not by a test.
//
// The rule is the Ruby engine's rule (embryonaut_console's
// `web/app.rb` `before` filter: UNGATED_PATHS pass, then `/api/` gets
// `halt 401, json({error:, message:})`, everything else redirects),
// plus the one request shape that engine has no equivalent for — this
// host's own routes carry their format in the path, so JSON-shaped here
// is a wider set than just `/api/`. See `json_shaped`.
//
// Path, not `Accept:` — deliberately, on two counts. The Ruby engine
// keys off `request.path_info.start_with?("/api/")` and ignores
// `Accept` entirely; keying off the header here would buy agreement on
// the reported case at the price of a second, subtler disagreement (a
// browser's own `Accept: text/html,...` sent to an `/api/` path would
// then redirect in Rust and 401 in Ruby). And it's the honest fit for
// this call chain: `route` is handed cookies, query and body, never
// headers — `render` reads the incoming headers exactly once, for the
// Stripe webhook signature — so honoring `Accept` would mean threading
// a header down four call sites to decide something the path already
// answers.
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

// `/api/` first, so an `/api/...` path refuses the way Ruby refuses it
// whatever suffix it carries. Everything after that is this host's own
// `/<Domain>/<aggregate>[.fmt][/<verb-or-id>[.fmt]]` routing, read
// through the same `split_format` the renderers read it through —
// `.html` is the page, and anything else, including no suffix at all,
// is already the JSON branch (`aggregate_index`, `record_show` and
// `command_route` all test `format != "html"`). Reusing that one
// function is the point: a gate that decided "JSON-shaped" its own way
// could drift into 401-ing a path that renders HTML, or redirecting one
// that renders JSON. Fewer than two segments is `/`, `/favicon.ico` or
// a bare `/<Domain>` — the home page and the text/HTML 404s around it,
// no JSON route among them.
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

    // The console's own `/api/*` contract (api.rs) — answered before
    // this host's `/<Domain>/<aggregate>` routing, and unconditionally:
    // every path under `/api/` belongs to that surface, including one
    // it doesn't recognize (which it answers as a JSON 404). Falling
    // through instead would produce `404 no domain "api"
    // loaded` for an authenticated `/api/clients` — a plain-text
    // refusal, from this host's own router, for a request the Ruby
    // engine answers with data.
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

// ---- auth: /login, /logout, /auth/google(/callback), /admin/members ----
// Mirrors embryonaut_access_control.rb's own route shapes exactly
// (README's own "Signing in" section, Ruby side) -- same paths, same
// query-param error codes, same "GrantAccess is separate from Admit"
// rule. `None` for anything that isn't one of these paths, so `route`
// falls through to its ordinary IR-driven dispatch untouched.
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

        // Accounts::Account's own email+password admin login used to be
        // reachable here (POST /accounts/register, /accounts/login) --
        // ported behavior-for-behavior from lifeadelics/adapters/
        // http_server.rb, same bcrypt hashing, same flat signed token.
        // DELIBERATELY REMOVED FROM ROUTING (Chris, 2026-09-23: "only
        // admin access and the signup stuff on the site" -- no public
        // account creation at all): the only real sign-in path is Google
        // OAuth for an already-admitted Membership::Person (/auth/google
        // below), and the only PUBLIC "signups" are the three guest
        // actions the site forms already drive (newsletter subscribe,
        // event registration, contact) -- none of which mints an
        // Account. `accounts_register_route`/`accounts_login_route`
        // stay defined (and unit-tested) below since Accounts::Account
        // itself is unchanged -- only the HTTP door into it is closed;
        // nothing in this codebase calls either route any more
        // (confirmed: no caller in src/pages/**, grepped clean).
        ("POST", "/accounts/logout") => Some(respond_with_cookie(
            200,
            "application/json",
            r#"{"ok":true}"#,
            &format!("lifeadelics_session=; Max-Age=0{}", cookie_flags()),
        )),

        ("GET", "/accounts/me") => Some(accounts_me_route(domain_ir, cookies, secret, client).await),

        ("GET", "/members") => Some(members_route(domain_ir, cookies, secret, client).await),

        ("POST", "/members") => Some(add_member_route(domain_ir, raw_body, cookies, secret, client, wasm_path, config).await),

        ("GET", "/registrations") => Some(registrations_list_route(domain_ir, cookies, secret, client, wasm_path, config).await),

        ("POST", "/members/disable") => Some(set_member_disabled_route(domain_ir, raw_body, cookies, secret, client, config, true).await),

        ("POST", "/members/enable") => Some(set_member_disabled_route(domain_ir, raw_body, cookies, secret, client, config, false).await),

        // The tenant's payment connection (payments.rs's own header). Same
        // gate as the checkout routes: only the domain named by
        // HECKS_CHECKOUT_DOMAIN carries a PaymentConnection, so any other
        // domain served by this binary falls through as an unknown path.
        (method, path)
            if payments::owns(method, path) && checkout_enabled(std::env::var("HECKS_CHECKOUT_DOMAIN").ok().as_deref(), &config.domain) =>
        {
            payments::route(method, path, raw_body, cookies, secret, domain_ir, &payments::PlatformConfig::from_env(), client, wasm_path, config, invoker).await
        }

        // GET /accounts/sso-token, ported from http_server.rb's own
        // route (found missing live, not in #786's own port: every
        // "Site Content" click 401'd here, silently bounced through
        // /admin-login.html and back to /admin.html — looked like the
        // dashboard reloading itself inside its own iframe). Verified by
        // cms/src/endpoints/sso.ts's own verifyHandoffToken, using the
        // exact same account_token wire format (base64url payload +
        // hex-HMAC-SHA256 signature) as the lifeadelics_session cookie
        // itself — deploy-aws/platform/template.yaml's own SessionSecret
        // is shared with the cms container as AUTH_SECRET specifically
        // so the two sides verify the same token.
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

// Accounts::Account.Register -- "Accounts", a literal chapter name, not
// config.domain, same reasoning "Payments::Payment.Initiate" is
// hardcoded in registrations_route below: both are vendored
// embryonaut_bluebooks chapters loaded into THIS deploy's own hecksagon
// (lifeadelics.hecksagon's own `uses_embryonaut_bluebook "accounts"`),
// never a top-level `Hecks.world` of their own. bcrypt hashing happens
// here, in this driving adapter, never the domain -- accounts.bluebook's
// own header: "Hashing/verifying happens in a consuming project's own
// driving adapter (this package has no opinion on bcrypt vs. anything
// else)", ported unchanged from http_server.rb's own POST /accounts/
// register (same BCrypt::Password.create call, this crate's own
// bcrypt::hash at the default cost).
async fn accounts_register_route(raw_body: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
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
// registrations_route below uses to find an Event by slug -- reading,
// not dispatching, since Accounts::Account declares no Login command of
// its own; verification is this driving adapter's own concern, same as
// hashing), verify the bcrypt hash, sign a 14-day token (Ruby's own
// SESSION_TTL), set it as lifeadelics_session -- never Accounts::Account
// itself learning anything about sessions or cookies.
async fn accounts_login_route(raw_body: &str, secret: &str, client: &Mutex<Client>, wasm_path: &Path) -> Value {
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

// The email behind a `lifeadelics_session` cookie, only while that person
// still has access. The token signature alone isn't enough: a cookie lives
// up to 14 days, so a later disable must take effect on the next request.
// `Err` carries the JSON response to return: a 401 for a missing, invalid
// or no-longer-valid session, a 500 when the membership lookup itself fails.
async fn active_session_email(
    domain_ir: &Value,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
) -> Result<String, Value> {
    let not_logged_in = || respond(401, "application/json", &json!({"error": "not logged in"}).to_string());
    let Some(email) = cookies.get("lifeadelics_session").and_then(|token| auth::verify_account_token(secret, token)) else {
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

// GET /members -- the admitted people as JSON, for a server-side caller
// (the Astro admin's Users page) that holds the `lifeadelics_session`
// cookie but not the Governance `session` cookie /admin/members needs.
// Any session whose person still has access is enough; a disabled person's
// old cookie gets the same JSON 401 as no cookie at all, rather than the
// /login redirect, so a fetch() never follows it into an HTML page. A
// lookup failure is a 500, not an empty list.
async fn members_route(domain_ir: &Value, cookies: &HashMap<String, String>, secret: &str, client: &Mutex<Client>) -> Value {
    if let Err(response) = active_session_email(domain_ir, cookies, secret, client).await {
        return response;
    }
    match auth::all_people(client, domain_ir).await {
        Ok(people) => respond(200, "application/json", &Value::Array(sorted_by_name(people)).to_string()),
        Err(e) => respond(500, "application/json", &json!({"error": format!("members lookup failed: {e}")}).to_string()),
    }
}

// POST /members -- admits a new person and grants them the Admin role, for
// a server-side caller holding the `lifeadelics_session` cookie. Takes
// `{"email", "name"}` as JSON. Answers a JSON 401 without a valid session
// and a 403 unless the caller is already a granted Admin; then 400 for a
// blank or malformed field, 409 for an email that is already admitted,
// and 201 with the new person's row. If the role grant fails after the
// person was admitted, that is a 500 saying so, never a silent partial
// state.
async fn add_member_route(
    domain_ir: &Value,
    raw_body: &str,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
) -> Value {
    let json_error = |status: u16, message: &str| respond(status, "application/json", &json!({"error": message}).to_string());

    let Some(caller) = cookies.get("lifeadelics_session").and_then(|token| auth::verify_account_token(secret, token)) else {
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

    match auth::admit_person(client, config, domain_ir, &email, &name).await {
        Ok(true) => {}
        Ok(false) => return json_error(409, "that email is already admitted"),
        Err(e) => return json_error(500, &format!("admit failed: {e}")),
    }
    let email = email.to_lowercase();
    match auth::grant_access(client, wasm_path, config, domain_ir, &email, "Admin").await {
        Ok(true) => respond(
            201,
            "application/json",
            &json!({"name": name, "email": email, "role": "Admin", "linked": false, "granted": true, "disabled": false}).to_string(),
        ),
        Ok(false) => json_error(500, "the person was admitted but the Admin role was not granted"),
        Err(e) => json_error(500, &format!("the person was admitted but the Admin role was not granted: {e}")),
    }
}

// POST /members/disable and POST /members/enable -- switch a person's
// access off or back on without deleting them, for a server-side caller
// holding the `lifeadelics_session` cookie. Takes `{"email"}` as JSON.
// Disabling keeps the person, role and identity link, so enabling restores
// exactly the prior access. Answers a JSON 401 without a valid session, a
// 403 unless the caller is an active Admin, a 403 when an admin disables
// themselves, a 404 for an unknown email, a 409 when disabling would leave
// no active Admin, and 200 otherwise, including when the person is already
// in the requested state. Every rule is re-checked under the membership
// write lock in `auth::set_person_disabled`.
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

    let Some(caller) = cookies.get("lifeadelics_session").and_then(|token| auth::verify_account_token(secret, token)) else {
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

// GET /registrations -- every event registration as JSON, for the admin
// Events page. Server-side callers only: a valid `lifeadelics_session`
// cookie is required (JSON 401 otherwise, never a redirect), and the person
// behind it must currently be an active Admin, re-checked against the
// membership head on every request (403 otherwise, including a disabled
// admin). Reads the replayed registration instances, the same source
// `registration_show_route` uses, and never returns health or payment
// fields. The public `POST /registrations` is a different route and is
// untouched.
async fn registrations_list_route(
    domain_ir: &Value,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
) -> Value {
    let json_error = |status: u16, message: &str| respond(status, "application/json", &json!({"error": message}).to_string());

    let Some(caller) = cookies.get("lifeadelics_session").and_then(|token| auth::verify_account_token(secret, token)) else {
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

// The registration rows the admin list shows. Built field by field from an
// allowlist, so intake answers such as medications and health concerns, and
// anything from the payment, can never appear. Newest first when the
// registrations carry a timestamp, otherwise in the order they were read.
fn registration_list_rows(read: &Value, domain: &str) -> Vec<Value> {
    const TIMESTAMP_KEYS: [&str; 4] = ["created_at", "registered_at", "requested_at", "occurred_at"];
    let plain = |value: Option<&Value>| -> Option<Value> {
        let value = value?;
        Some(value.get("value").cloned().unwrap_or_else(|| value.clone()))
    };
    let text = |value: Option<&Value>| plain(value).and_then(|v| v.as_str().map(|s| s.trim().to_string()));

    let mut rows: Vec<(Option<String>, Value)> = instances_for(read, &format!("{domain}::Registration#"))
        .into_iter()
        .map(|(id, registration)| {
            let attendee = registration.get("attendee").cloned().unwrap_or_else(|| json!({}));
            let joined = [text(attendee.get("first_name")), text(attendee.get("last_name"))].into_iter().flatten().collect::<Vec<_>>().join(" ");
            let name = if joined.is_empty() { text(attendee.get("name")).unwrap_or_default() } else { joined };
            let stamp = TIMESTAMP_KEYS.iter().find_map(|key| text(registration.get(*key)));
            let row = json!({
                "registration_id": id,
                "email": text(attendee.get("email")),
                "name": name.trim(),
                "event_slug": text(registration.get("event_slug")),
                "news_signup": plain(attendee.get("news_signup")).and_then(|v| v.as_bool()).unwrap_or(false),
            });
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

// GET /accounts/sso-token — mints the short-lived (60s, Ruby's own
// SSO_TOKEN_TTL: "one redirect's worth, deliberately tight") handoff
// token src/pages/api/cms-sso.ts exchanges for a real Payload session at
// cms/src/endpoints/sso.ts. Re-verifies the requester's own
// lifeadelics_session cookie first — same account_token scheme, just a
// much shorter TTL and returned as JSON instead of a cookie, since this
// token is a one-shot redirect target, never stored. A disabled person's
// old cookie is refused here too, so no new handoff token is minted for them.
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

    // The Lifeadelics admin (Astro) authenticates on `lifeadelics_session`,
    // not rust/host's own Governance `session` cookie. Mint the same
    // account_token /accounts/login already sets. Same origin (production):
    // set the cookie here and send the browser to /admin.html. Different
    // origin (local rust/host :4567 vs Astro :4321): a cookie on this
    // response would never be sent to the site, so hand the token across
    // on SITE_URL's own /api/google-handoff (60s, one redirect).
    const SESSION_TTL_SECS: u64 = 60 * 60 * 24 * 14;
    let site = std::env::var("SITE_URL").unwrap_or_else(|_| "http://localhost:4321".to_string());
    let site = site.trim_end_matches('/');
    let token = auth::account_token(secret, &session.email, SESSION_TTL_SECS);
    if same_origin(site, &redirect_uri()) {
        let cookie = format!("lifeadelics_session={token}{}; Max-Age={SESSION_TTL_SECS}", cookie_flags());
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
        <select name="role" class="border border-slate-300 rounded-md px-3 py-2 text-sm"><option value="Admin">Admin</option><option value="Member">Member</option></select>
        <button type="submit" class="px-4 py-2 bg-slate-900 text-white rounded-md text-sm">Grant access</button>
        </form></main></body></html>"#
    )
}

// ---- IR helpers -----------------------------------------------------

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

// ---- field shape — IR::Attribute -> Field, mirrors ------------------
// Hecks::Presentation::FieldShape / hecks_on_web's own copy of it.

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
    // A cents+currency value object (Money) — renders/collects exactly
    // like Group (a fieldset around its two children); kept as its own
    // variant only because a caller who wants to know "is this a money
    // field" (a future currency-aware renderer, say) shouldn't have to
    // pattern-match Group's children looking for the shape.
    Money(Vec<Field>),
    // `Reference<X>` — a bare id, per aggregates-and-value-objects.md's
    // "a reference is a bare id — a String — not a nested object"
    // (rust/project/naming.rb's own comment, read directly). `target`
    // is the aggregate it points at, carried for a future renderer
    // (a dropdown of existing records — Ruby's own `reference_options`,
    // deliberately not ported here, see web.rs's own header) to use;
    // today's render arm ignores it and renders a plain text input —
    // `#[allow(dead_code)]` because that non-consumption is a real,
    // deliberate scope boundary (see this file's own header), not an
    // oversight; the tests below still assert on it directly.
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

// `Hecks::Presentation::FieldShape#resolve`'s own dispatch order,
// mirrored exactly (field_shape.rb): list? -> reference? -> admits
// truthy -> not-a-primitive (value object) -> primitive. `domain_ir` is
// the whole chapter — needed by `admits:` resolution (a set can be
// declared on any aggregate, not just this attribute's own) and by the
// cross-aggregate value-object fallback below.
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

// `Reference<X>` -> `Some("X")` — the exact string-prefix convention
// rust/project/naming.rb's own `reference_type?`/`reference_target`
// already use for the same job in command-struct codegen (read
// directly, matched here rather than reinvented): a bare
// `Reference<...>` spelling is the export's pinned contract
// (IR::Reference#to_s), never a nested object.
fn reference_target(ty: &str) -> Option<String> {
    ty.strip_prefix("Reference<")?.strip_suffix('>').map(String::from)
}

// A value object's own declared shape, checked on the owning aggregate
// first and only then walked across the whole domain — `own_value_
// object`'s exact fallback order (field_shape.rb).
fn value_object_shape<'a>(domain_ir: &'a Value, aggregate: &'a Value, ty: &str) -> Option<&'a Value> {
    find_value_object(aggregate, ty).or_else(|| cross_aggregate_value_object(domain_ir, ty))
}

// `FieldShape#cross_aggregate_value_object`, mirrored exactly despite
// its name being scoped like a sibling search — it's a whole-domain
// walk (field_shape.rb's own comment says so plainly): a command's
// declared value-object-typed attribute may name a shape belonging to
// another aggregate entirely (Transfer's own `narrative: Narrative`
// argument, resolved with Transfer as the owning aggregate, could in
// principle point at a Narrative declared on Account instead — this is
// the fallback that makes that legal). The root-cause fix: without
// this, a cross-aggregate value object falls all the way through to
// `primitive_field`'s bare-text default, and neither `admits:`
// resolution below nor Tier B's textarea hint ever gets a chance to
// run against the real, unwrapped inner attribute.
fn cross_aggregate_value_object<'a>(domain_ir: &'a Value, type_name: &str) -> Option<&'a Value> {
    domain_ir.get("aggregates")?.as_array()?.iter().find_map(|sibling| find_value_object(sibling, type_name))
}

// The discriminant field name plus its member values, factored out of
// the native `one_of` branch below so the `admits:` branch (which
// checks a different aggregate's closed set) can share the exact same
// reading rather than a second, drifting copy of it.
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

// Radio under 4 members, Select otherwise — `FieldShape#select_or_
// radio`'s own threshold, mirrored exactly. `path`'s own last segment
// is the label (the outer path, not yet dotted down to a discriminant)
// — callers that need the discriminant hop mutate `.path` afterward,
// same as Ruby's `options.path = "#{common[:path]}.#{discriminant}"`
// leaving `label` untouched.
fn select_or_radio(path: &str, optional: bool, members: Vec<String>) -> Field {
    let label = humanize(path);
    let kind = if members.len() <= 4 { FieldKind::Radio(members) } else { FieldKind::Select(members) };
    Field { path: path.to_string(), label, kind, optional }
}

// `FieldShape#admitted_field` — a closed set declared elsewhere
// (`"Account::LedgerDirection"`), resolved and rendered exactly the
// way the native `one_of` branch renders its own same-attribute set,
// via the shared `closed_set_members`/`select_or_radio` helpers above.
fn admitted_field(domain_ir: &Value, aggregate: &Value, attribute: &Value, admits: &str, ty: &str, path: &str, optional: bool) -> Field {
    let mut parts = admits.splitn(2, "::");
    let set_aggregate_name = parts.next().unwrap_or("");
    let set_name = parts.next();

    let set = set_name.and_then(|name| find_aggregate(domain_ir, set_aggregate_name).and_then(|agg| find_value_object(agg, name)));
    // Undeclared set — refuse-at-dispatch stays the backstop (Ruby's own
    // comment on this exact fallback); render it as whatever a plain
    // scalar of this attribute would be, using the real attribute so
    // its own name/pattern still drive Tier B's hints correctly.
    let Some(set) = set else { return primitive_field(attribute, ty, path, optional) };

    let (_, members) = closed_set_members(set);
    let mut field = select_or_radio(path, optional, members);

    // The attribute's own type still has to land on the shape coercion
    // expects — a value object like `MovementDirection { value }` still
    // needs the ".value" hop even though the set it's checked against
    // is declared somewhere else entirely (same unwrap `value_object_
    // field` does, kept separate because an admitted set changes the
    // options, not which field the hop lands on).
    let Some(own_shape) = value_object_shape(domain_ir, aggregate, ty) else { return field };
    let attrs = own_shape.get("attributes").and_then(|v| v.as_array());
    let Some(attrs) = attrs.filter(|a| a.len() == 1) else { return field };

    let inner_name = attrs[0].get("name").and_then(|v| v.as_str()).unwrap_or("value");
    field.path = format!("{path}.{inner_name}");
    field
}

// `FieldShape#value_object_field` — closed_set? -> money_shaped? ->
// single-attribute-unwrap -> group, in that order, mirrored exactly.
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

    // Single-attribute value object (PizzaName{value}, Price{cents}) —
    // a name for a scalar, not a genuine group. The outer label wins
    // (humanize(path), not the recursively-resolved inner field's own
    // label) — "value"/"cents" is internal storage shape, never what a
    // human reads. Recursing back through `resolve_field` (not
    // straight to `primitive_field`) is what lets the inner attribute's
    // own pattern/admits drive its shape — Narrative{text}'s "text" is
    // this inner attribute's own bare name, which is what makes Tier
    // B's textarea hint match it.
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

// `FieldShape#money_shaped?` — exactly `{cents, currency}`, sorted, and
// nothing else.
fn money_shaped(attrs: &[Value]) -> bool {
    let mut names: Vec<&str> = attrs.iter().filter_map(|a| a.get("name").and_then(|v| v.as_str())).collect();
    names.sort_unstable();
    names == ["cents", "currency"]
}

// `FieldShape#money_field` — cents as a whole-integer Number, currency
// as free Text, always optional (a currency code defaults to "USD"
// whether or not the outer amount itself is required).
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

// `FieldShape#text_field` — Tier B's four declared hints
// (field_hints.rs, generated from Vocabulary::FieldHint), matched in
// Ruby's own precedence. `attribute`'s own bare `name`/`pattern` drive
// this, not any derivation off `path` — after a single-attribute
// unwrap (`value_object_field` above), `attribute` is the inner
// attribute (Narrative's own "text", EmailAddress's own "address"),
// exactly the case Tier B exists to catch.
fn text_field(attribute: &Value, path: &str, optional: bool) -> Field {
    let name = attribute.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let pattern = attribute.get("pattern").and_then(|v| v.as_str()).unwrap_or("");
    let html_type = text_html_type(name, pattern);
    let kind = text_kind(html_type, name);
    Field { path: path.to_string(), label: humanize(path), kind, optional }
}

// email, then url, then tel — first match wins, exactly Ruby's
// if/elsif chain. `pattern.include?("@")` and `pattern.match?(/https?/
// i)` are both inline checks in Ruby too (never promoted to their own
// named Vocabulary::FieldHint member) — `/https?/i` case-insensitively
// matching is exactly a case-insensitive "http" substring check, since
// "https" already contains "http".
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

// Only checked once `html_type` has fallen all the way through to
// "text" — Ruby's own `html_type == "text" && name.match?(TEXTAREA_
// HINT)` guard, not a competing branch.
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

// ---- params: flat dotted form body -> nested JSON args --------------
// Mirrors Hecks::Presentation::Params/hecks_on_web's own copy.

// `Err` — a human-readable refusal message, never a panic — on a
// path-prefix collision (L23, docs/audits/2026-08-11-bug-triage.md
// Tier 7): see `nest`'s own header for what that collision is.
fn extract_args(fields: &[Field], raw: &HashMap<String, String>) -> Result<Value, String> {
    let mut pairs: Vec<(String, Value)> = Vec::new();
    for field in fields {
        collect_field(field, raw, &mut pairs);
    }
    nest(pairs)
}

fn collect_field(field: &Field, raw: &HashMap<String, String>, pairs: &mut Vec<(String, Value)>) {
    match &field.kind {
        // Money shares Group's own children-flattening — its two
        // fields (cents/currency) collect exactly like any other
        // fieldset's would.
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

// L23 (docs/audits/2026-08-11-bug-triage.md Tier 7) — a path-prefix
// collision: one field's path is a bare scalar (`"price"`) while
// another's is that same name dotted deeper (`"price.cents"`, implying
// `price` should be an object). Inserting the object-shaped one after
// the scalar would otherwise panic outright (`.as_object_mut().unwrap()`
// on a `Value::Number`/`Value::String`, a 500); inserting it the other
// way round — scalar after the nested object was already built — would
// never panic, but would silently clobber the nested object with the
// scalar, dropping every child it had already collected, no refusal,
// no error, just quietly wrong `args`. Both directions are the same
// bug (a collision this function has no business resolving on its
// own), so both are caught here and refused identically, cleanly, as
// an `Err` — never a panic, never silent data loss. In real command
// dispatch this can only actually arise from a malformed/hand-edited
// IR (`command_fields`'s own resolved field paths never collide this
// way for a well-formed one) — but a web-facing function refuses
// cleanly on bad input rather than trusting its caller never sends it.
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
        // The other direction: `leaf` already holds an object (built by
        // an earlier, longer path sharing this prefix) and the value
        // about to land there is a plain scalar/array — inserting it
        // would silently erase every child already nested underneath.
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

// ---- routes -----------------------------------------------------------

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

    // L23 (docs/audits/2026-08-11-bug-triage.md Tier 7) — a path-prefix
    // collision refuses cleanly here (400) rather than panicking inside
    // `nest` (`extract_args`'s own header).
    let args = match extract_args(fields, raw) {
        Ok(a) => a,
        Err(e) => return bad_request(domain_name, aggregate, command, fields, raw, json_mode, &e),
    };

    // `None` -- the web UI has no notion of an authenticated caller's
    // role yet (a separate, not-yet-built concern; see auth.rs's own
    // session handling), so this preserves exactly the behavior every
    // command submitted through the Founder App has always had.
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

// L23's own clean-refusal shape — mirrors the 422-refusal rendering
// just below (same json_mode/html split, same `form_body` error-banner
// reuse), at 400 rather than 422: this is a malformed submission `nest`
// itself caught, never a WASM-kernel domain refusal.
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

// L24 (docs/audits/2026-08-11-bug-triage.md Tier 7) — the id to redirect
// to after an accepted command is this call's own new step's own
// mutation, never whichever mutation happens to sit last in that step.
// `orchestrate` (rust/src/kernel/orchestrate.rs) always dispatches the
// command itself first — pushing exactly one `MutationRecord` for the
// aggregate/id the command actually targets (`dispatch`/`dispatch_
// entity`, rust/src/kernel/dispatch.rs) — before it ever calls
// `react_policies`/`advance_saga` on the resulting event(s), which is
// what can push further mutations onto the same step for a cascaded
// reaction's own aggregate (a policy or saga firing as a side effect).
// So within the last step's own mutations array, the first entry is
// always the form's own command target; anything after it belongs to a
// reaction, never the id this redirect should land on. `.last()` used
// to grab whichever mutation ran most recently instead — correct only
// by accident, whenever no reaction fired within that same step.
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

// A refused command's own most recent refusal — `.last()` because
// `dispatch::handle` reruns the whole rehydrated history, and every
// step before this call's own already succeeded once (dispatch.rs's own
// header on why); shared by `submit` above and `registrations_route`
// below rather than each keeping its own copy.
pub(crate) fn last_refusal(result: &Value) -> Value {
    result
        .get("refusals")
        .and_then(|r| r.as_array())
        .and_then(|rs| rs.last())
        .cloned()
        .unwrap_or_else(|| json!({"error": "Refused"}))
}

// ---- checkout: /registrations, /webhooks/stripe ------------------------
// See `render`'s own "checkout glue" header and checkout.rs's own header
// for why this is hardcoded rather than IR-driven. Ported from the first
// consuming domain's adapters/http_server.rb (the Ruby app, lifeadelics
// repo) — same two routes, same status codes, same dispatch order, Rust.

// Pure and separately unit-tested from the env read in `render` — same
// split `membership_aggregate`/`resolve_membership_aggregate` use in
// auth.rs. Exact match, not merely "set": a deploy whose HECKS_DOMAIN
// disagrees with HECKS_CHECKOUT_DOMAIN would otherwise dispatch
// `<wrong domain>::Registration.Request` and refuse every registration.
fn checkout_enabled(configured: Option<&str>, domain: &str) -> bool {
    configured.is_some_and(|c| !c.is_empty() && c == domain)
}

// The fixed, publicly-known, non-secret mock webhook secret. It verifies a
// webhook only while STRIPE_WEBHOOK_SECRET is unset, so a mock deploy needs no
// webhook secret configured to be exercisable end to end; `webhook_route`
// refuses anything that could only come from a real processor when a
// webhook was verified against it.
pub(crate) const MOCK_STRIPE_WEBHOOK_SECRET: &str = "whsec_mock_checkout_fixed";

// The processor a Payment reports, as Payments::Payment.Initiate recorded it
// ("mock_stripe" for the walkthrough, "stripe" for a real charge). Read off the
// Payment itself rather than guessed from whatever is connected now: the
// connection can change between a guest registering and the webhook arriving.
fn payment_processor(read: &Value, reference: &str) -> Option<String> {
    instances_for(read, "Payments::Payment#")
        .into_iter()
        .find(|(id, _)| id == reference)
        .and_then(|(_, payment)| payment.get("processor").and_then(|p| p.get("value")).and_then(|v| v.as_str()).map(String::from))
}

#[allow(clippy::too_many_arguments)]
async fn checkout_route(
    method: &str,
    path: &str,
    raw_body: &str,
    stripe_signature: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    match (method, path) {
        ("POST", "/registrations") => {
            Some(registrations_route(raw_body, &payments::PlatformConfig::from_env(), client, wasm_path, config, invoker).await)
        }
        // GET /registrations/:id — read-only, re-derives the truth
        // (http_server.rb's own GET /registrations/:id comment: "never
        // trust a client-held value") for registration-confirmed.astro
        // and src/pages/pay/[registrationId].astro, both of which fetch
        // this server-to-server rather than trusting their own query
        // string/URL. PHI fields (medications/health_concerns) stay off
        // this response the same way http_server.rb's own route omits
        // them — no read-gate/redaction exists here yet to let an
        // authorized caller see them unmasked, so they're simply never
        // serialized.
        ("GET", path) if path.starts_with("/registrations/") && !path.ends_with("/complete") => {
            let registration_id = path.trim_start_matches("/registrations/");
            Some(registration_show_route(registration_id, client, wasm_path, config).await)
        }
        // POST /registrations/:id/complete — LocalCheckout's own
        // "Pay"/"Cancel" button (src/pages/pay/[registrationId].astro),
        // refused for any Payment a real processor collected: the
        // processor is read off the Payment itself, so this can only
        // settle a payment that was started on the mock walkthrough.
        // Settles the Payment through the SAME PaymentGateway port POST
        // /webhooks/stripe uses — never a parallel, untested way to
        // reach the same two states.
        ("POST", path) if path.starts_with("/registrations/") && path.ends_with("/complete") => {
            let registration_id = path.trim_start_matches("/registrations/").trim_end_matches("/complete").trim_end_matches('/');
            Some(registration_complete_route(registration_id, raw_body, client, wasm_path, config, invoker).await)
        }
        ("POST", "/webhooks/stripe") => {
            Some(webhook_route(raw_body, stripe_signature, &payments::PlatformConfig::from_env(), client, wasm_path, config, invoker).await)
        }
        // POST /events — mock_payments/ (a separate service, its own
        // bluebook) DRIVING IN: puts a new session on the calendar
        // whenever a CMS editor picks a date on an Experience with Stripe
        // Checkout on (cms/src/collections/hooks/provisionSession.ts).
        // Ported field-for-field from http_server.rb's own POST /events —
        // never had a rust/host counterpart at all until now (found live:
        // mock_payments successfully reaches this host over the shared
        // ECS task network, but every real POST /events 302'd/404'd
        // against it, because no route recognized the path). Idempotent
        // on purpose, same reasoning as the Ruby route's own comment:
        // mock_payments already guards against calling this twice for the
        // same slug (its own Session ledger), but a driving endpoint
        // shouldn't rely on every caller getting that right — Event.find
        // first means a repeat call is a no-op, not a duplicate-id error.
        ("POST", "/events") => Some(events_route(raw_body, client, wasm_path, config, invoker).await),
        _ => None,
    }
}

/// POST /events — see checkout_route's own match arm for the full
/// reasoning. `config.domain`-qualified ("Lifeadelics::Event.Schedule"),
/// same as registrations_route's own `Registration.Request` — Event is
/// this deploy's own top-level aggregate, never a vendored chapter like
/// Payments/Newsletter.
async fn events_route(raw_body: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return respond(400, "application/json", &json!({"error": format!("invalid JSON: {e}")}).to_string()),
    };
    let Some(slug) = body.get("slug").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing slug"}).to_string());
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let events = instances_for(&read, &format!("{}::Event#", config.domain));
    if let Some((_, existing)) = events.iter().find(|(id, _)| id == slug) {
        return respond(200, "application/json", &serde_json::to_string_pretty(&with_id(slug, existing)).unwrap_or_default());
    }

    let Some(name) = body.get("name").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing name"}).to_string());
    };
    let Some(price_cents) = body.get("price_cents").and_then(|v| v.as_i64()) else {
        return respond(400, "application/json", &json!({"error": "missing price_cents"}).to_string());
    };
    let Some(capacity) = body.get("capacity").and_then(|v| v.as_i64()) else {
        return respond(400, "application/json", &json!({"error": "missing capacity"}).to_string());
    };

    let args = json!({
        "slug": {"value": slug},
        "name": {"value": name},
        "price": {"cents": price_cents},
        "capacity": {"value": capacity},
    });
    let verb = format!("{}::Event.Schedule", config.domain);
    let outcome = match dispatch::handle(client, wasm_path, &verb, args, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let events = instances_for(&read, &format!("{}::Event#", config.domain));
    let Some((_, event)) = events.iter().find(|(id, _)| id == slug) else {
        return respond(500, "text/plain", "event vanished immediately after being scheduled");
    };
    respond(201, "application/json", &serde_json::to_string_pretty(&with_id(slug, event)).unwrap_or_default())
}

/// GET /registrations/:id's own shape, ported field-for-field from
/// http_server.rb's own route: event slug/name, attendee's own public
/// fields, amount_cents and payment_status from the SAME-reference
/// Payment (registrations_route's own header: registration_id IS the
/// Payment's own reference, minted once).
async fn registration_show_route(registration_id: &str, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig) -> Value {
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let registrations = instances_for(&read, &format!("{}::Registration#", config.domain));
    let Some((_, registration)) = registrations.iter().find(|(id, _)| id == registration_id) else {
        return respond(404, "application/json", &json!({"error": "no such registration"}).to_string());
    };
    let event_slug = registration.get("event_slug").and_then(|v| v.as_str());
    let events = instances_for(&read, &format!("{}::Event#", config.domain));
    let event = event_slug.and_then(|slug| events.iter().find(|(id, _)| id == slug)).map(|(_, e)| e);

    let payments = instances_for(&read, "Payments::Payment#");
    let payment = payments.iter().find(|(id, _)| id == registration_id).map(|(_, p)| p);

    let attendee = registration.get("attendee").cloned().unwrap_or_else(|| json!({}));
    respond(200, "application/json", &json!({
        "registration_id": registration_id,
        "event": {
            "slug": event_slug,
            "name": event.and_then(|e| e.get("name")).and_then(|n| n.get("value")).and_then(|v| v.as_str()),
        },
        "attendee": {
            "first_name": attendee.get("first_name"),
            "last_name": attendee.get("last_name"),
            "email": attendee.get("email"),
            "phone": attendee.get("phone"),
        },
        "amount_cents": payment.and_then(|p| p.get("amount")).and_then(|a| a.get("cents")),
        "payment_status": payment.and_then(|p| p.get("status")),
    }).to_string())
}

/// POST /registrations/:id/complete — refused outright for any Payment that
/// was not itself initiated on the mock processor ("mock_stripe"), same
/// per-payment guard http_server.rb's own route carries. Settles the
/// shared-reference Payment through the same PaymentGateway.Succeeded/Failed
/// port webhook_route already dispatches through — a repeat call on an
/// already-settled Payment is the same benign no-op webhook_route's own header
/// already documents.
pub(crate) async fn registration_complete_route(
    registration_id: &str,
    raw_body: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return respond(400, "application/json", &json!({"error": format!("invalid JSON: {e}")}).to_string()),
    };
    let Some(outcome) = body.get("outcome").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing outcome"}).to_string());
    };
    if outcome != "succeeded" && outcome != "failed" {
        return respond(400, "application/json", &json!({"error": "outcome must be \"succeeded\" or \"failed\""}).to_string());
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let registrations = instances_for(&read, &format!("{}::Registration#", config.domain));
    if !registrations.iter().any(|(id, _)| id == registration_id) {
        return respond(404, "application/json", &json!({"error": "no such registration"}).to_string());
    }

    let processor = match payment_processor(&read, registration_id) {
        Some(processor) if processor == "mock_stripe" => processor,
        _ => return respond(403, "application/json", &json!({"error": "not available with a real payment processor"}).to_string()),
    };
    let reported_processor = json!({"value": processor});
    // `reference_to Payment, as: :reference` keeps the receiver field inside
    // `with:` (routing.rs's own "Field Retention" comment) so the command's
    // argument parser can still see it — `to:` alone isn't enough, the kernel
    // still expects `reference` present in facts or it TypeMismatches.
    let reference_fact = json!({"value": registration_id});
    let (verb, facts) = if outcome == "succeeded" {
        (
            "Payments::Payment.PaymentGateway.Succeeded",
            json!({"reference": reference_fact, "transaction_id": {"value": format!("local_{}", uuid::Uuid::new_v4().simple())}, "reported_processor": reported_processor}),
        )
    } else {
        (
            "Payments::Payment.PaymentGateway.Failed",
            json!({"reference": reference_fact, "reason": {"value": "declined_at_local_checkout"}, "reported_processor": reported_processor}),
        )
    };
    let outcome_result = match dispatch::handle_routed(client, wasm_path, verb, json!(registration_id), facts, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    // A repeat Succeeded/Failed through the same PaymentGateway port on
    // an already-settled Payment is a silent no-op on Payment's own
    // `given` (webhook_route's own header on this exact case) — not
    // surfaced as a 422 here either, same reasoning.
    if !outcome_result.accepted {
        let refusal = last_refusal(&outcome_result.result);
        let already_settled = refusal.get("error").and_then(|v| v.as_str()).map(|s| s.contains("pending")).unwrap_or(false);
        if !already_settled {
            return respond(422, "application/json", &refusal.to_string());
        }
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let payments = instances_for(&read, "Payments::Payment#");
    let status = payments.iter().find(|(id, _)| id == registration_id).and_then(|(_, p)| p.get("status")).and_then(|v| v.as_str()).unwrap_or("");
    respond(200, "application/json", &json!({"registration_id": registration_id, "payment_status": status}).to_string())
}

// ---- newsletter: guest-facing subscribe/confirm/unsubscribe, admin
// listing ----------------------------------------------------------
// Ported from http_server.rb's own POST /newsletter/subscribers, GET
// /newsletter/subscribers, GET /newsletter/subscribers/confirm, and GET
// /newsletter/subscribers/unsubscribe. Confirm/unsubscribe were NOT
// ported when this module was first written ("stay Ruby-only for now,
// reached through LIFEADELICS_DOMAIN_SERVICE_URL pointing at the Ruby
// process in whichever environment still runs it") — a real gap, since
// production runs THIS host exclusively, with no Ruby fallback at all:
// confirmed live, every real unsubscribe link 401'd ("sign in first",
// auth_gate's own refusal — these two paths fell through to it since
// nothing here recognized them, and neither is in UNGATED_PATHS), never
// so much as reaching a "no such subscriber" 404. Same match-arm
// ordering concern http_server.rb's own comment on this exact pair
// flags for Sinatra (declared before a generic /:email route so
// "confirm"/"unsubscribe" can't be treated as an email) doesn't apply
// here — Rust match on an exact (method, path) tuple has no such
// prefix/wildcard ambiguity to order around.
async fn newsletter_route(
    method: &str,
    path: &str,
    query: &HashMap<String, String>,
    raw_body: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    match (method, path) {
        ("POST", "/newsletter/subscribers") => Some(newsletter_subscribe_route(raw_body, client, wasm_path, config, invoker).await),
        ("GET", "/newsletter/subscribers") => Some(newsletter_subscribers_list_route(client, wasm_path).await),
        ("GET", "/newsletter/subscribers/confirm") => Some(newsletter_confirm_route(query, client, wasm_path, config, invoker).await),
        ("GET", "/newsletter/subscribers/unsubscribe") => Some(newsletter_unsubscribe_route(query, client, wasm_path, config, invoker).await),
        _ => None,
    }
}

/// POST /newsletter/subscribers — Subscribe on a new email, AddName on a
/// returning one (the two-step public signup form's own step
/// 1/step 2 — NewsletterSubscribeForm.astro's own header has the full
/// reasoning), Confirm dispatched right after either path since a
/// freshly-subscribed record always starts `pending` and this project's
/// own newsletter has no real double opt-in yet (subscriber.bluebook's
/// own "no signed token" gap, carried over unchanged from Ruby's route).
async fn newsletter_subscribe_route(
    raw_body: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return respond(400, "application/json", &json!({"error": format!("invalid JSON: {e}")}).to_string()),
    };
    let Some(email) = body.get("email").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "email"}).to_string());
    };
    let first_name = body.get("first_name").and_then(|v| v.as_str()).filter(|s| !s.is_empty());
    let last_name = body.get("last_name").and_then(|v| v.as_str()).filter(|s| !s.is_empty());

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let existing = instances_for(&read, "Newsletter::Subscriber#").iter().any(|(id, _)| id == email);

    if existing {
        if let (Some(first), Some(last)) = (first_name, last_name) {
            let facts = json!({"first_name": {"value": first}, "last_name": {"value": last}});
            if let Err(e) = dispatch::handle_routed(client, wasm_path, "Newsletter::Subscriber.AddName", json!(email), facts, None, config, invoker).await {
                return respond(500, "text/plain", &format!("{e:#}"));
            }
        }
    } else {
        let mut facts = json!({"email": {"value": email}});
        if let Some(first) = first_name {
            facts["first_name"] = json!({"value": first});
        }
        if let Some(last) = last_name {
            facts["last_name"] = json!({"value": last});
        }
        let outcome = match dispatch::handle_facts(client, wasm_path, "Newsletter::Subscriber.Subscribe", facts, None, config, invoker).await {
            Ok(o) => o,
            Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
        };
        if !outcome.accepted {
            return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
        }
    }

    // Confirm right after — a pending subscriber always exists at this
    // point on the fresh-Subscribe path; on the AddName path it may
    // already be confirmed (a returning subscriber filling in their
    // name), so Confirm only dispatches when it's actually pending,
    // same idempotency reasoning http_server.rb's own route already
    // follows (Confirm's own `given` refuses a second attempt outright).
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, "Newsletter::Subscriber#");
    let Some((_, subscriber)) = subscribers.iter().find(|(id, _)| id == email) else {
        return respond(500, "text/plain", "subscriber vanished immediately after being written");
    };
    if subscriber.get("status").and_then(|v| v.as_str()) == Some("pending") {
        if let Err(e) = dispatch::handle_routed(client, wasm_path, "Newsletter::Subscriber.Confirm", json!(email), json!({}), None, config, invoker).await {
            return respond(500, "text/plain", &format!("{e:#}"));
        }
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, "Newsletter::Subscriber#");
    let status = subscribers.iter().find(|(id, _)| id == email).and_then(|(_, s)| s.get("status")).and_then(|v| v.as_str()).unwrap_or("pending");
    respond(200, "application/json", &json!({"email": email, "status": status}).to_string())
}

/// GET /newsletter/subscribers — every subscriber, alphabetically by
/// email (Newsletter::Subscriber.Listing's own declared order) — the
/// admin overview/Users pages' own read. Read directly off `instances`
/// rather than `dispatch::query` (which would need the qualified
/// question name resolved against `config.domain`, but Subscriber lives
/// under "Newsletter", not `config.domain` -- same cross-chapter
/// reasoning `instances_for(&read, "Payments::Payment#")` above already
/// follows for reading Payment).
async fn newsletter_subscribers_list_route(client: &Mutex<Client>, wasm_path: &Path) -> Value {
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let mut subscribers: Vec<Value> = instances_for(&read, "Newsletter::Subscriber#")
        .into_iter()
        .map(|(email, s)| {
            json!({
                "email": email,
                "status": s.get("status"),
                "first_name": s.get("first_name").and_then(|v| v.get("value")),
                "last_name": s.get("last_name").and_then(|v| v.get("value")),
            })
        })
        .collect();
    subscribers.sort_by(|a, b| a["email"].as_str().unwrap_or("").cmp(b["email"].as_str().unwrap_or("")));
    respond(200, "application/json", &json!(subscribers).to_string())
}

/// GET /newsletter/subscribers/confirm?email=... — ported field-for-field
/// from http_server.rb's own route. NO SIGNED TOKEN, matching that
/// route's own known, flagged gap (subscriber.bluebook's own header):
/// anyone who knows an email can confirm it. Idempotent the same way —
/// Confirm only dispatches when the subscriber is actually `pending`
/// (its own `given` refuses a second attempt outright), so a guest
/// double-clicking, or a mail client prefetching the link, still lands
/// on the same success response instead of a 422.
async fn newsletter_confirm_route(query: &HashMap<String, String>, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let Some(email) = query.get("email") else {
        return respond(400, "application/json", &json!({"error": "email"}).to_string());
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, "Newsletter::Subscriber#");
    let Some((_, subscriber)) = subscribers.iter().find(|(id, _)| id == email) else {
        return respond(404, "application/json", &json!({"error": "no such subscriber"}).to_string());
    };

    if subscriber.get("status").and_then(|v| v.as_str()) == Some("pending") {
        if let Err(e) = dispatch::handle_routed(client, wasm_path, "Newsletter::Subscriber.Confirm", json!(email), json!({}), None, config, invoker).await {
            return respond(500, "text/plain", &format!("{e:#}"));
        }
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, "Newsletter::Subscriber#");
    let status = subscribers.iter().find(|(id, _)| id == email).and_then(|(_, s)| s.get("status")).and_then(|v| v.as_str()).unwrap_or("pending");
    respond(200, "application/json", &json!({"email": email, "status": status}).to_string())
}

/// GET /newsletter/subscribers/unsubscribe?email=... — same shape as
/// newsletter_confirm_route above, ported from http_server.rb's own
/// route (same "no signed token" gap, same idempotency reasoning:
/// Unsubscribe's own `given` only accepts a pending or confirmed
/// subscriber, so a repeat click on an already-unsubscribed row would
/// otherwise 422 instead of showing the same success page). This is the
/// one newsletter-unsubscribed.astro's own server-side fetch calls —
/// unreachable before this route existed (confirmed live: fell through
/// to auth_gate's 401, never a 404, since neither this path nor
/// /confirm was in UNGATED_PATHS and nothing recognized either one).
async fn newsletter_unsubscribe_route(query: &HashMap<String, String>, client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, invoker: &dyn LambdaInvoker) -> Value {
    let Some(email) = query.get("email") else {
        return respond(400, "application/json", &json!({"error": "email"}).to_string());
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, "Newsletter::Subscriber#");
    let Some((_, subscriber)) = subscribers.iter().find(|(id, _)| id == email) else {
        return respond(404, "application/json", &json!({"error": "no such subscriber"}).to_string());
    };

    if subscriber.get("status").and_then(|v| v.as_str()) != Some("unsubscribed") {
        if let Err(e) = dispatch::handle_routed(client, wasm_path, "Newsletter::Subscriber.Unsubscribe", json!(email), json!({}), None, config, invoker).await {
            return respond(500, "text/plain", &format!("{e:#}"));
        }
    }

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let subscribers = instances_for(&read, "Newsletter::Subscriber#");
    let status = subscribers.iter().find(|(id, _)| id == email).and_then(|(_, s)| s.get("status")).and_then(|v| v.as_str()).unwrap_or("pending");
    respond(200, "application/json", &json!({"email": email, "status": status}).to_string())
}

// Whatever shape a consuming domain's own `Attendee` value object
// declares — this crate's own checkout glue is shared, generic
// dispatch code (hardcoded rather than IR-driven, this module's own
// "checkout glue" header), not specific to any one domain's Attendee
// fields. Lifeadelics's own Attendee grew, over a real redesign, from
// a bare `{name, email}` to eight required fields (first_name,
// last_name, email, phone, previous_sessions, first_time, how_heard,
// aim) plus three optional ones — `registrations_route` used to
// hardcode exactly the OLD two-field shape, which silently broke every
// real registration the moment that redesign shipped (confirmed live:
// every attempt failed "Attendee does not declare name"). Forwarding
// the caller's own submitted fields through verbatim, whatever they
// are, means this route never needs to know or hardcode any one
// domain's Attendee shape again — each domain's own generated
// given/invariant checks are still the real validation, exactly as
// they already were for `event_slug`/`registration_id` above.
// `event_slug`/`return_to` are the only two fields definitely NOT part
// of any Attendee (routing metadata this function itself consumes),
// so those are the only ones stripped.
fn attendee_from(body: &Value) -> Value {
    let mut attendee = body.clone();
    if let Some(object) = attendee.as_object_mut() {
        object.remove("event_slug");
        object.remove("return_to");
    }
    attendee
}

// Payments::Payment's own `Client` value object is NOT part of this
// redesign — payment.bluebook's own `Client` still only ever wants a
// single `name` + `email` (checked live: unaffected by lifeadelics's
// Attendee split) — so a caller sending the OLD flat `name` (the
// CheckoutFixture test double, and any future simple-shape domain)
// keeps working completely unchanged, and a caller sending the NEW
// `first_name`/`last_name` split (lifeadelics today) gets a real
// display name composed from both, rather than this route needing to
// pick one shape and hardcode it.
fn display_name_from(body: &Value) -> Option<String> {
    if let Some(name) = body.get("name").and_then(|v| v.as_str()) {
        return Some(name.to_string());
    }
    let first = body.get("first_name").and_then(|v| v.as_str())?;
    let last = body.get("last_name").and_then(|v| v.as_str())?;
    Some(format!("{first} {last}"))
}

// **The site driving in** — http_server.rb's own `POST /registrations`.
// Payment first, then Registration, sharing one reference minted here
// (lifeadelics.bluebook's own Registration comment has the full
// reasoning: a Registration with no Payment behind it is meaningless,
// a Payment with no Registration just needs cleaning up eventually).
// `role: None` throughout — this route has no notion of an
// authenticated caller's role any more than web.rs's own generic
// `submit` does (that function's own comment); the Astro site calls in
// server-to-server, not as a signed-in user.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn registrations_route(
    raw_body: &str,
    platform: &payments::PlatformConfig,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return respond(400, "application/json", &json!({"error": format!("invalid JSON: {e}")}).to_string()),
    };
    let Some(event_slug) = body.get("event_slug").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing event_slug"}).to_string());
    };
    // Cheap early exits before ever dispatching Payment.Initiate — the
    // real, complete Attendee validation still happens downstream, in
    // Registration.Request's own given/invariant checks, whatever this
    // domain's Attendee actually requires; these two are just the
    // fields THIS route itself needs before that (a display name for
    // Payment's own Client, an email address for both Client and
    // Attendee).
    let Some(name) = display_name_from(&body) else {
        return respond(400, "application/json", &json!({"error": "missing name (or first_name and last_name)"}).to_string());
    };
    let Some(email) = body.get("email").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing email"}).to_string());
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let events = instances_for(&read, &format!("{}::Event#", config.domain));
    let Some((_, event)) = events.iter().find(|(id, _)| id == event_slug) else {
        return respond(404, "application/json", &json!({"error": "no such event"}).to_string());
    };
    if event.get("status").and_then(|v| v.as_str()) != Some("open") {
        return respond(422, "application/json", &json!({"error": "registration is closed for this event"}).to_string());
    }
    let price_cents = event.get("price").and_then(|p| p.get("cents")).and_then(|v| v.as_i64()).unwrap_or(0);
    let event_name = event.get("name").and_then(|n| n.get("value")).and_then(|v| v.as_str()).unwrap_or("");

    // What checkout does is decided per request from this tenant's own
    // PaymentConnection, before anything is written: a paused connection
    // must not leave an orphaned Payment behind, and must never fall back
    // to the mock walkthrough (payments.rs's own header).
    let plan = payments::checkout_plan(payments::connection(&read, &config.domain).as_ref(), platform);
    let processor = match plan {
        payments::CheckoutPlan::Mock => "mock_stripe",
        payments::CheckoutPlan::Stripe { .. } => "stripe",
        payments::CheckoutPlan::Paused => {
            return respond(503, "application/json", &json!({"error": "payments are temporarily unavailable"}).to_string());
        }
    };
    let site_url = platform.site_url.as_str();

    let reference = uuid::Uuid::new_v4().to_string();

    let initiate_args = json!({
        "reference": {"value": reference},
        "processor": {"value": processor},
        "payment_type": {"value": "card"},
        "amount": {"cents": price_cents},
        "client": {"name": name, "email": email},
    });
    let outcome = match dispatch::handle(client, wasm_path, "Payments::Payment.Initiate", initiate_args, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
    }

    let request_args = json!({
        "event_slug": event_slug,
        "registration_id": {"value": reference},
        "attendee": attendee_from(&body),
    });
    let request_verb = format!("{}::Registration.Request", config.domain);
    let outcome = match dispatch::handle(client, wasm_path, &request_verb, request_args, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
    }

    // A GUEST-SUPPLIED PATH, NEVER TRUSTED RAW -- `return_to` rides
    // through as a query param on registration-confirmed.html's own URL
    // (http_server.rb's own POST /registrations comment: `/#{event.id}.
    // html?registered=...` was dead code, since the frontend never read
    // `registered` and event.id is the Event's own slug, not the
    // Experience's CMS slug [slug].astro looks up -- 404ing on landing).
    // A value like "https://evil.example" or "//evil.example" (protocol-
    // relative -- no scheme, but still an absolute redirect in a
    // browser) would turn this into an open redirect if interpolated
    // as-is; `safe_return_to`'s own "starts with exactly one leading
    // slash" check keeps it a same-site path no matter what a caller
    // sends, falling back to "/" -- never the event's own page --
    // exactly like `safe_return_to`'s own Ruby original.
    let return_to = match body.get("return_to").and_then(|v| v.as_str()) {
        Some(path) if path.starts_with('/') && !path.starts_with("//") => path.to_string(),
        _ => "/".to_string(),
    };
    let confirm_query = |outcome: &str| -> String {
        let mut url = reqwest::Url::parse("http://placeholder.invalid/").unwrap();
        url.query_pairs_mut()
            .append_pair("registration_id", &reference)
            .append_pair("outcome", outcome)
            .append_pair("return_to", &return_to);
        url.query().unwrap_or("").to_string()
    };
    let success_url = format!("{site_url}/registration-confirmed.html?{}", confirm_query("succeeded"));
    let cancel_url = format!("{site_url}/registration-confirmed.html?{}", confirm_query("cancelled"));

    // **Mock, not an error** — a tenant with no connection, or one that is
    // not enabled, is on the mock walkthrough (this route's own header,
    // checkout.rs's own header) — never a misconfiguration to refuse.
    let payments::CheckoutPlan::Stripe { api_key, account } = plan else {
        let checkout_url = checkout::mock_checkout_session(&reference, &success_url, &cancel_url, site_url);
        return respond(200, "application/json", &json!({"checkout_url": checkout_url, "registration_id": reference}).to_string());
    };

    // A direct charge on the tenant's own connected account: the platform's
    // key, and the `Stripe-Account` header naming whose money it is.
    let auth = checkout::StripeAuth { api_key: &api_key, account: Some(&account), base_url: &platform.api_base };
    match checkout::create_checkout_session(&auth, price_cents, event_name, &reference, &success_url, &cancel_url).await {
        Ok(checkout_url) => respond(200, "application/json", &json!({"checkout_url": checkout_url, "registration_id": reference}).to_string()),
        Err(e) => respond(500, "text/plain", &format!("{e:#}")),
    }
}

// **Stripe driving in** — http_server.rb's own `POST /webhooks/stripe`.
// `reference` round-trips through Checkout's own metadata (set above,
// keyed "registration_id" — the same string is both the Registration's
// own id and the Payment's own reference), read back here — never
// trusted without a verified signature first. Dispatches through
// Payment's own vendored PaymentGateway port, never Registration's
// (removed — see lifeadelics.bluebook's own Registration comment).
//
// One platform endpoint receives every tenant's Connect events, signed with
// the platform's `STRIPE_WEBHOOK_SECRET`. An event naming some other connected
// account is acknowledged and ignored; `account.application.deauthorized`
// pauses or unlinks this tenant's connection (payments.rs). While that secret
// is unset the public mock secret verifies the signature instead, and
// anything only a real processor could send (an account event, or an event
// for a Payment a real processor collected) is refused rather than trusted on
// a publicly-known key.
pub(crate) async fn webhook_route(
    raw_body: &str,
    signature_header: &str,
    platform: &payments::PlatformConfig,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
    let secret = platform.webhook_secret.as_deref().unwrap_or(MOCK_STRIPE_WEBHOOK_SECRET);
    if let Err(e) = checkout::verify_signature(raw_body, signature_header, secret, now) {
        return respond(400, "text/plain", &e.to_string());
    }
    let event: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(_) => return respond(400, "text/plain", "invalid JSON"),
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let connection = payments::connection(&read, &config.domain);
    let fallback_secret = platform.webhook_secret.is_none();
    let refuse_fallback = || {
        respond(
            500,
            "application/json",
            &json!({"error": "STRIPE_WEBHOOK_SECRET is required to accept events from a real payment processor -- \
                              refusing to trust the publicly-known mock webhook secret"})
            .to_string(),
        )
    };

    match payments::event_scope(&event, connection.as_ref()) {
        payments::EventScope::Ignore => return respond(200, "text/plain", ""),
        payments::EventScope::Deauthorized => {
            if fallback_secret {
                return refuse_fallback();
            }
            return match payments::apply_deauthorization(connection.as_ref(), client, wasm_path, config, invoker).await {
                Ok(()) => respond(200, "text/plain", ""),
                Err(e) => respond(500, "text/plain", &format!("{e:#}")),
            };
        }
        payments::EventScope::Proceed => {}
    }
    if fallback_secret && event.get("account").is_some_and(|account| !account.is_null()) {
        return refuse_fallback();
    }

    let event_type = event.get("type").and_then(|v| v.as_str()).unwrap_or("");
    let object = event.get("data").and_then(|d| d.get("object")).cloned().unwrap_or_else(|| json!({}));
    let reference = object.get("metadata").and_then(|m| m.get("registration_id")).and_then(|v| v.as_str()).map(String::from);

    if let Some(reference) = reference {
        // The processor Payment.Initiate recorded — "stripe" when there is
        // no such Payment, as http_server.rb's own route defaults it.
        let processor = payment_processor(&read, &reference).unwrap_or_else(|| "stripe".to_string());
        if fallback_secret && processor != "mock_stripe" {
            return refuse_fallback();
        }
        let reported_processor = json!({"value": processor});
        // **Routed, not mixed args** — the kernel refuses a flat
        // `{"reference": ..., ...}` for an aggregate-scoped port
        // operation ("invalid routing envelope: aggregate-scoped
        // operation requires to"), and the benign-refusal rule below
        // turned that into a silent 200 with the payment left pending.
        // Found wiring these tests to spec/fixtures/rust_host/
        // checkout_fixture. `to` is the bare reference string.
        // `reference` is ALSO kept inside `with:` (routing.rs's own "Field
        // Retention" comment for port operations) — `to:` alone doesn't
        // satisfy the `reference_to Payment, as: :reference` declaration,
        // which the argument parser still expects to find in facts.
        let reference_fact = json!({"value": reference.clone()});
        let verb_and_facts = match event_type {
            "checkout.session.completed" => {
                // Checkout's own PaymentIntent id when one exists (every
                // card/wallet payment mints one), the Checkout Session's
                // own id otherwise — `.get(...)`, not a panic on a
                // missing key, matching http_server.rb's own `[]`
                // comment (a synthetic test payload carries no
                // payment_intent at all).
                let transaction_id = object.get("payment_intent").and_then(|v| v.as_str())
                    .or_else(|| object.get("id").and_then(|v| v.as_str()))
                    .unwrap_or("")
                    .to_string();
                Some(("Payments::Payment.PaymentGateway.Succeeded", json!({
                    "reference": reference_fact,
                    "transaction_id": {"value": transaction_id},
                    "reported_processor": reported_processor,
                })))
            }
            "checkout.session.expired" => Some(("Payments::Payment.PaymentGateway.Failed", json!({
                "reference": reference_fact,
                "reason": {"value": "checkout_expired"},
                "reported_processor": reported_processor,
            }))),
            _ => None,
        };

        if let Some((verb, facts)) = verb_and_facts {
            // A refusal here (e.g. a redelivered webhook for an already-
            // settled payment — Stripe's own delivery is at-least-once)
            // is a benign no-op, not an error: the payment already holds
            // the right status, there's nothing left to do, and
            // returning 200 is what tells Stripe's own retry logic to
            // stop. http_server.rb's own Ruby route has no rescue around
            // its equivalent `dispatch_port` call at all (unlike POST
            // /registrations, just above it) — an uncaught
            // DOMAIN_REFUSALS there 500s and leaves Stripe retrying
            // forever; only a genuine Err (a WASM/database fault, not a
            // domain refusal) propagates as a real failure here, a
            // deliberate improvement over the Ruby route's own gap, not
            // a divergence papering over one.
            if let Err(e) = dispatch::handle_routed(client, wasm_path, verb, json!(reference), facts, None, config, invoker).await {
                return respond(500, "text/plain", &format!("{e:#}"));
            }
        }
    }

    respond(200, "text/plain", "")
}

// ---- rendering: form ---------------------------------------------------

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
        // No `reference_options` dropdown here on purpose — see this
        // file's own header: no candidate-fetching scaffolding exists
        // yet, so a reference is a plain text id input, same as Ruby's
        // own fallback for one.
        FieldKind::Reference { .. } => format!(
            r#"{label}<input type="text" name="{}" value="{}" class="{input_class}">"#,
            esc(&field.path), esc(&current)
        ),
    }
}

// ---- plumbing -----------------------------------------------------------

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

// pub(crate) — server.rs's own Function-URL-shaped response translation
// (`statusCode`/`headers`/`body`/`isBase64Encoded`, the exact shape
// this module's own `respond`/`redirect` produce) decodes the same way
// a real Lambda Function URL invocation would, rather than carrying a
// second copy of this decoder.
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

// H10 (docs/audits/2026-08-10-main-bug-audit.md) — `id` is a record's own
// identity, free-form and user-supplied unless `pattern:`-constrained, not
// a bluebook-declared name the way `agg`/`domain_name`/`cn` are. Every
// call site that places `id` into rendered HTML routes through one of
// these two functions so escaping (and, for the query-string position,
// percent-encoding) can't be forgotten at a third call site — Ruby's
// own `Escape.html`/`.attr` already covers `id` everywhere
// (`record_table.rb:45`, `record_renderer.rb:43,79`); this closes the
// parallel Rust gap, not a new
// capability Ruby lacks too.
//
// `id` goes into a query-string value here (`?id=...`), not just an HTML
// attribute — `esc()` alone is not enough (a raw `&` would end the
// parameter early, corrupting `cn` as a second bogus param), so this
// percent-encodes via `auth::urlencode` (already RFC3986-unreserved-safe,
// already exercised by the OAuth redirect path) rather than HTML-escaping
// the query value. `cn` is still `esc()`-escaped for the link text/href
// segment, even though it's bluebook-declared rather than user input —
// cheap, consistent, and never wrong.
fn action_link(domain_name: &str, agg: &str, cn: &str, id: &str, class: &str) -> String {
    format!(r#"<a href="/{domain_name}/{agg}/{}.html?id={}" class="{class}">{}</a>"#, esc(cn), auth::urlencode(id), esc(cn))
}

// The row's own link to itself — `id` sits in a path segment here, not a
// query value, so `esc()` (not percent-encoding) is the right guard,
// matching what the sibling not-found/field-row branches already do
// correctly (`html_not_found`, the field-value `<dd>` rows).
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

// HttpOnly + SameSite always. Secure only when the registered OAuth
// redirect is https — a localhost http:// callback cannot set a Secure
// cookie, and the URI is already the source of truth for that (same env
// rust/host uses for the handshake). Not a deploy-time flag.
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

    // H10 (docs/audits/2026-08-10-main-bug-audit.md) — a record's own
    // identity is user-supplied, free-form unless `pattern:`-constrained.
    // Left unescaped at these two call sites, a creating command
    // persisting this exact id would render live, executable markup for
    // every later viewer of the index row or record page; the tests
    // below pin that it doesn't.
    const MALICIOUS_ID: &str = r#"x"><script>alert(1)</script>"#;

    // H11 (docs/audits/2026-08-10-main-bug-audit.md) — an unset or empty
    // SESSION_SECRET must never be treated as valid: `session_secret()`'s
    // own `unwrap_or_default()` would otherwise silently fall back to
    // `""`, HMAC-signing every session cookie and OAuth `state` with a
    // publicly-known empty key instead of refusing to serve.
    #[test]
    fn validate_session_secret_refuses_empty_or_unset() {
        assert!(validate_session_secret("").is_err());
        assert!(validate_session_secret("s3cret").is_ok());
    }

    // ---- the auth gate ---------------------------------------------
    //
    // `auth_gate` is the whole gate, factored out of `route` so it can
    // be tested at all: `route` itself needs a live `Mutex<Client>`
    // (tokio_postgres) and a compiled wasm domain, which is why every
    // other test in this module is a pure-function test too. What's
    // asserted here is exactly what `route` does with the answer —
    // `None` means the request carries on to ordinary dispatch, `Some`
    // is returned as the response verbatim.
    //
    // The bug these pin: without the gate's two-answer split, every
    // unauthenticated request would get the same 302 to /login, so a
    // JSON caller would follow the redirect and parse a login page.
    // embryonautfoundersapp's CI asserts a 401 on
    // `/api/clients`; the Ruby console engine gives it one.

    fn status(response: &Value) -> u64 {
        response.get("statusCode").and_then(|v| v.as_u64()).expect("a response always carries a statusCode")
    }

    #[test]
    fn an_unauthenticated_api_request_is_refused_with_the_ruby_engines_own_401_json() {
        let refusal = auth_gate("/api/clients", false).expect("an unauthenticated /api/ request must be refused");

        assert_eq!(status(&refusal), 401);
        assert_eq!(refusal["headers"]["content-type"], "application/json");
        // Byte-for-byte embryonaut_console web/app.rb's own
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

    // This host's own routes, which the Ruby engine has no counterpart
    // for: the format lives in the path, `.html` is the page and
    // everything else — including a bare segment with no suffix — is
    // the JSON branch (`aggregate_index`/`record_show`/`command_route`
    // all branch on `format != "html"`). So a no-suffix aggregate URL
    // is a JSON request, not an HTML one, and refusing it with a
    // redirect would hand a JSON caller a login page just as surely as
    // `/api/clients` did.
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

    // The home page and the not-a-route paths around it are HTML (or
    // plain-text 404s reached through the HTML side), and a browser is
    // who asks for them — unchanged behavior, and the reason the rule
    // isn't simply "everything that isn't `.html`".
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
        // The query value must be percent-encoded, not HTML-escaped —
        // `esc()` alone leaves a raw `&` in a `values.each` id, say, which
        // would terminate the `id=` param early and smuggle a second
        // bogus query parameter in.
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

    // Real corpus shapes throughout (examples/banking/bluebook/
    // banking.bluebook, examples/pizzas/bluebook/pizzas.bluebook) — read
    // directly, not guessed at. `domain_ir`/`aggregate` fixtures below
    // are trimmed to only the keys `resolve_field`'s own call graph
    // ever reads (`name`/`value_objects` on an aggregate, `aggregates`
    // on the domain) — a real generated IR carries far more, but
    // nothing else here is ever consulted.

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
        // Account's real Narrative{text} value object — declared on
        // Account, never on CardPayment (CardPayment's own real
        // value_objects list, confirmed by reading the live generated
        // IR, is AuthorisationCode/PaymentAmount/MerchantName/Tag —
        // no Narrative). The attribute itself is real too: Transfer.
        // Request's own "narrative" argument JSON, byte-for-byte —
        // reused here scoped against CardPayment instead of Transfer
        // specifically to prove the fallback walks the whole domain,
        // not just the declaring aggregate's own siblings
        // (field_shape.rb's own comment on cross_aggregate_value_
        // object: "a WHOLE-DOMAIN walk despite its name").
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
        // ExternalTransfer.direction: MovementDirection{value}, admits:
        // "Account::LedgerDirection" — the real, live `admits:` example
        // in the corpus (examples/banking/bluebook/).
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
        // No `pattern:` at all — synthetic, since every real email-
        // shaped attribute in the corpus (Customer.email) also carries
        // one; proves the or in Ruby's own `pattern.include?("@") ||
        // name.match?(EMAIL_HINT)` really is an or, not pattern-gated.
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
        // No real corpus example of either shape exists (confirmed
        // during design research) — both built minimal here, same
        // style auth.rs's own tests use for a fixture with no real
        // counterpart.
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
        // pizzas' Price{cents} — one field, no currency — must unwrap
        // to a plain scalar (money_shaped? needs exactly {cents,
        // currency}), never :money.
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
        // Proves \b in the `regex` crate behaves the way these
        // patterns need it to, rather than assuming it — "link" is a
        // whole word in "link" but only a substring of "blinking", and
        // the boundary must reject the latter; same for "text" inside
        // "context". Case-insensitivity ((?i), the Rust spelling of
        // Ruby's trailing `/i`) checked too.
        assert!(URL_HINT.is_match("link"));
        assert!(!URL_HINT.is_match("blinking"));
        assert!(TEXTAREA_HINT.is_match("text"));
        assert!(!TEXTAREA_HINT.is_match("context"));
        assert!(EMAIL_HINT.is_match("EMAIL"));
    }

    // ---- nest / extract_args: L23's own path-prefix collision --------
    // (docs/audits/2026-08-11-bug-triage.md Tier 7)

    #[test]
    fn nest_builds_an_ordinary_dotted_path_into_a_nested_object() {
        let result = nest(vec![("price.cents".to_string(), json!(500)), ("price.currency".to_string(), json!("USD"))]).unwrap();
        assert_eq!(result, json!({"price": {"cents": 500, "currency": "USD"}}));
    }

    #[test]
    fn nest_refuses_rather_than_panics_when_a_scalar_is_inserted_before_a_deeper_path_sharing_its_prefix() {
        // `price` lands as a plain scalar first, then `price.cents`
        // tries to descend into it as though it were an object — the
        // exact shape that would otherwise panic on
        // `.as_object_mut().unwrap()` (a 500), rather than refuse cleanly.
        let err = nest(vec![("price".to_string(), json!(500)), ("price.cents".to_string(), json!(500))]).unwrap_err();
        assert!(err.contains("price"), "{err}");
    }

    #[test]
    fn nest_refuses_rather_than_silently_dropping_data_when_the_deeper_path_is_inserted_first() {
        // The other order never panicked at all — it silently
        // clobbered the nested object `price` already held with a bare
        // scalar, dropping `cents` with no error. Must now refuse
        // instead of corrupting the result.
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

    // ---- own_command_target_id: L24's own cascaded-reaction redirect -
    // (docs/audits/2026-08-11-bug-triage.md Tier 7)

    #[test]
    fn own_command_target_id_picks_the_forms_own_target_when_no_reaction_fired() {
        let result = json!({"mutations": [[{"aggregate": "Pizzas::Order", "id": "order-1", "operation": "save"}]]});
        assert_eq!(own_command_target_id(&result), Some("order-1"));
    }

    #[test]
    fn own_command_target_id_picks_the_first_mutation_not_a_cascaded_reactions_last_one() {
        // The command's own mutation (Order) is pushed first by
        // `orchestrate` (rust/src/kernel/orchestrate.rs), before any
        // policy/saga reaction it triggers can push a second mutation
        // for a different aggregate entirely (a Loyalty account, say)
        // onto the very same step. `.last()` would grab the reaction's
        // own id instead of the form's own target, which is why this
        // function reads the first mutation, not the last.
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

    #[test]
    fn checkout_is_enabled_only_for_the_exactly_configured_domain() {
        assert!(checkout_enabled(Some("CheckoutFixture"), "CheckoutFixture"));
        assert!(!checkout_enabled(None, "CheckoutFixture"));
        assert!(!checkout_enabled(Some(""), "CheckoutFixture"));
        assert!(!checkout_enabled(Some("Banking"), "CheckoutFixture"));
    }

    // ---- attendee_from / display_name_from: the Attendee-redesign fix —
    // registrations_route no longer hardcodes {name, email}, it forwards
    // whatever the caller actually submitted (this comment block's own
    // header on registrations_route has the full "found live" story).

    #[test]
    fn attendee_from_strips_only_routing_metadata_not_attendee_fields() {
        let body = json!({
            "event_slug": "yoga-aug",
            "return_to": "/yoga-aug",
            "first_name": "Ada",
            "last_name": "Lovelace",
            "email": "ada@example.com",
            "phone": "555-0100",
            "previous_sessions": false,
            "first_time": true,
            "how_heard": "a friend",
            "aim": "flexibility",
        });

        let attendee = attendee_from(&body);

        assert_eq!(attendee.get("event_slug"), None, "routing metadata must not leak into Attendee");
        assert_eq!(attendee.get("return_to"), None, "routing metadata must not leak into Attendee");
        assert_eq!(attendee["first_name"], "Ada");
        assert_eq!(attendee["last_name"], "Lovelace");
        assert_eq!(attendee["email"], "ada@example.com");
        assert_eq!(attendee["phone"], "555-0100");
        assert_eq!(attendee["previous_sessions"], false);
        assert_eq!(attendee["first_time"], true);
        assert_eq!(attendee["how_heard"], "a friend");
        assert_eq!(attendee["aim"], "flexibility");
    }

    #[test]
    fn attendee_from_forwards_the_old_flat_shape_unchanged_for_backward_compatibility() {
        // The exact shape CheckoutFixture's own tests (below) and any
        // future simple-Attendee domain still send — must round-trip
        // byte-for-byte, or this fix would be a breaking change instead
        // of an additive one.
        let body = json!({"event_slug": "happy-event", "name": "Ada Lovelace", "email": "ada@example.com"});
        assert_eq!(attendee_from(&body), json!({"name": "Ada Lovelace", "email": "ada@example.com"}));
    }

    #[test]
    fn display_name_from_prefers_a_flat_name_field_when_present() {
        let body = json!({"name": "Ada Lovelace", "first_name": "should be ignored", "last_name": "should be ignored"});
        assert_eq!(display_name_from(&body), Some("Ada Lovelace".to_string()));
    }

    #[test]
    fn display_name_from_composes_first_and_last_name_when_no_flat_name_exists() {
        let body = json!({"first_name": "Ada", "last_name": "Lovelace"});
        assert_eq!(display_name_from(&body), Some("Ada Lovelace".to_string()));
    }

    #[test]
    fn display_name_from_is_none_when_neither_shape_is_present() {
        assert_eq!(display_name_from(&json!({"email": "ada@example.com"})), None);
        assert_eq!(display_name_from(&json!({"first_name": "Ada"})), None, "last_name alone is missing");
        assert_eq!(display_name_from(&json!({"last_name": "Lovelace"})), None, "first_name alone is missing");
    }

    // ---- checkout_route: real Postgres, spec/fixtures/rust_host/
    // checkout_fixture's wasm (rust/dist/checkout_fixture.wasm), no
    // network ----------------------------------------------------------
    // `registrations_route`'s own final hop (checkout::create_checkout_
    // session, a third-party HTTPS call to Stripe) is aimed at a
    // recording server on 127.0.0.1 by payments.rs's own tests, never at
    // api.stripe.com; auth.rs's own Google OAuth calls
    // (verify/verify_id_token) still stay real-network, verified live
    // rather than locally unit-tested. What is tested below is
    // everything genuinely this route's own logic: event lookup, the
    // closed/missing-field/refusal branches, and the dispatch chain all
    // the way through Registration.Request — a platform with no
    // connection is what stops each successful case at the mock
    // checkout URL, which doubles as proof the whole chain up to there
    // ran for real (a wrong dispatch anywhere earlier would fail on its
    // own assertion first).
    use crate::lambda_client;
    use tokio_postgres::NoTls;

    async fn scratch_db(name: &str) -> Mutex<Client> {
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

    // Same shape dispatch.rs's own `provision_lineage` already builds —
    // duplicated here rather than shared, matching this crate's own
    // established precedent (auth.rs keeps its own `scratch_member_db`
    // rather than reusing dispatch.rs's `scratch_db` too).
    async fn provision_lineage(client: &Client, domain: &str, era: i32, aggregate_storage_names: &[&str]) {
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

    fn checkout_config(era: i32) -> LineageConfig {
        LineageConfig { domain: "CheckoutFixture".to_string(), era: Some(era), mirrored: None }
    }

    fn checkout_wasm_path() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/checkout_fixture.wasm")
    }

    // Its own dedicated fixture, not folded into CheckoutFixture above --
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

    async fn schedule_event(client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, slug: &str, price_cents: i64) {
        let args = json!({
            "slug": {"value": slug}, "name": {"value": "Yogadelics"},
            "price": {"cents": price_cents}, "capacity": {"value": 20},
        });
        let outcome = dispatch::handle(client, wasm_path, "CheckoutFixture::Event.Schedule", args, None, config, &lambda_client::NeverInvoker)
            .await
            .unwrap();
        assert!(outcome.accepted, "scheduling the fixture event should succeed: {:?}", outcome.result);
    }

    fn sign_stripe_header(secret: &str, now: i64, payload: &str) -> String {
        use hmac::{Hmac, Mac};
        use sha2::Sha256;
        let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(format!("{now}.{payload}").as_bytes());
        format!("t={now},v1={}", mac.finalize().into_bytes().iter().map(|b| format!("{b:02x}")).collect::<String>())
    }

    fn now_secs() -> i64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs() as i64
    }

    #[tokio::test]
    async fn registrations_route_refuses_a_body_missing_any_required_field() {
        let client = scratch_db("hecks_host_web_test_registrations_missing_fields").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let response = registrations_route(r#"{"event_slug":"yoga-aug"}"#, &payments::test_platform(), &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 400);
        assert!(response["body"].as_str().unwrap().contains("missing name"));
    }

    // The exact real-world case that broke live for lifeadelics: a
    // caller submits the NEW `first_name`/`last_name` shape (no flat
    // `name` at all) against a domain whose Attendee still only
    // declares the OLD `name` field (CheckoutFixture, a stable, pinned
    // fixture this crate never redesigns). `display_name_from` still
    // composes a real name for Payment's own Client (proving Payment.
    // Initiate succeeds), and `attendee_from` forwards `first_name`/
    // `last_name` through UNCHANGED rather than silently coercing them
    // into `name` — so Registration.Request correctly refuses on
    // CheckoutFixture's own real Attendee invariant, the same shape of
    // refusal lifeadelics's own real Attendee produced live. Proves
    // both pieces of the fix without needing a second wasm fixture.
    #[tokio::test]
    async fn registrations_route_forwards_a_new_shaped_attendee_verbatim_even_against_an_old_shaped_fixture() {
        let client = scratch_db("hecks_host_web_test_registrations_new_shape").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "happy-event", 4200).await;

        let body = json!({
            "event_slug": "happy-event",
            "first_name": "Ada",
            "last_name": "Lovelace",
            "email": "ada@example.com",
        })
        .to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;

        // Registration.Request refuses (CheckoutFixture's Attendee has
        // no first_name/last_name) — but that's AFTER Payment.Initiate
        // already ran, proving display_name_from really did compose
        // "Ada Lovelace" and Payment accepted it.
        assert_eq!(response["statusCode"], 422, "{response:?}");
        assert!(
            response["body"].as_str().unwrap().contains("name"),
            "should surface CheckoutFixture's own real Attendee refusal, not a generic error: {response:?}"
        );

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert!(
            instances.keys().any(|k| k.starts_with("Payments::Payment#")),
            "Payment.Initiate should have committed for real using the composed display name: {instances:?}"
        );
        assert!(
            instances.keys().all(|k| !k.starts_with("CheckoutFixture::Registration#")),
            "Registration.Request must never have committed: {instances:?}"
        );
    }

    #[tokio::test]
    async fn registrations_route_refuses_invalid_json_outright() {
        let client = scratch_db("hecks_host_web_test_registrations_bad_json").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let response = registrations_route("not json", &payments::test_platform(), &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 400);
    }

    // ---- events_route: POST /events, mock_payments/'s own driving call --
    // http_server.rb's own POST /events, ported field-for-field (this
    // route's own header has the full "found live" story: mock_payments
    // could already reach this host over the shared ECS task network,
    // but every real call 404'd/302'd since no route recognized the path
    // at all until now).

    #[tokio::test]
    async fn events_route_refuses_invalid_json_outright() {
        let client = scratch_db("hecks_host_web_test_events_bad_json").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let response = events_route("not json", &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 400);
    }

    #[tokio::test]
    async fn events_route_refuses_a_body_missing_any_required_field() {
        let client = scratch_db("hecks_host_web_test_events_missing_fields").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let response = events_route(r#"{"slug":"new-event"}"#, &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 400);
        assert!(response["body"].as_str().unwrap().contains("missing name"));
    }

    #[tokio::test]
    async fn events_route_schedules_a_new_event_and_returns_201() {
        let client = scratch_db("hecks_host_web_test_events_new").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        let body = json!({"slug": "mock-payments-event", "name": "Mock Payments Event", "price_cents": 4200, "capacity": 20}).to_string();
        let response = events_route(&body, &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 201, "{response:?}");
        let response_body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        assert_eq!(response_body["slug"]["value"], "mock-payments-event");
        assert_eq!(response_body["name"]["value"], "Mock Payments Event");
        assert_eq!(response_body["price"]["cents"], 4200);
        assert_eq!(response_body["capacity"]["value"], 20);
        assert_eq!(response_body["status"], "open");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert!(
            instances.keys().any(|k| k == "CheckoutFixture::Event#mock-payments-event"),
            "Event.Schedule should have committed for real: {instances:?}"
        );
    }

    // Idempotent by construction (this route's own header) — a repeat
    // call for the same slug is a 200 no-op returning the EXISTING
    // event's own state, never a second Event.Schedule dispatch (which
    // would refuse outright on the duplicate identity anyway, but this
    // route never even reaches that dispatch on the repeat).
    #[tokio::test]
    async fn events_route_is_idempotent_on_a_repeat_slug() {
        let client = scratch_db("hecks_host_web_test_events_idempotent").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        let body = json!({"slug": "repeat-event", "name": "Repeat Event", "price_cents": 1000, "capacity": 5}).to_string();
        let first = events_route(&body, &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(first["statusCode"], 201, "{first:?}");

        // A second call, even with different name/price/capacity (mock_
        // payments never sends a different shape for the same slug in
        // practice, but this route's own idempotency check keys ONLY on
        // slug, matching Event.find-before-schedule's own semantics) —
        // returns the ORIGINAL event's state, 200, not a second 201.
        let second_body = json!({"slug": "repeat-event", "name": "Different Name", "price_cents": 9999, "capacity": 1}).to_string();
        let second = events_route(&second_body, &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(second["statusCode"], 200, "{second:?}");
        let second_body: Value = serde_json::from_str(second["body"].as_str().unwrap()).unwrap();
        assert_eq!(second_body["name"]["value"], "Repeat Event", "must return the ORIGINAL event, not re-schedule with the new fields");
        assert_eq!(second_body["price"]["cents"], 1000);

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert_eq!(
            instances.keys().filter(|k| k.starts_with("CheckoutFixture::Event#repeat-event")).count(),
            1,
            "exactly one Event, never a second dispatch: {instances:?}"
        );
    }

    #[tokio::test]
    async fn registrations_route_404s_an_unknown_event_slug() {
        let client = scratch_db("hecks_host_web_test_registrations_no_event").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let body = json!({"event_slug": "nope", "name": "Ada", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 404);
    }

    #[tokio::test]
    async fn registrations_route_refuses_a_closed_event() {
        let client = scratch_db("hecks_host_web_test_registrations_closed_event").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "closed-event", 4200).await;
        let close = dispatch::handle(&client, &wasm_path, "CheckoutFixture::Event.Close", json!({"id": "closed-event"}), None, &config, &lambda_client::NeverInvoker)
            .await
            .unwrap();
        assert!(close.accepted, "closing the fixture event should succeed: {:?}", close.result);

        let body = json!({"event_slug": "closed-event", "name": "Ada", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 422);
        assert!(response["body"].as_str().unwrap().contains("closed"));
    }

    #[tokio::test]
    async fn registrations_route_propagates_a_real_domain_refusal_from_payment_initiate() {
        // A zero-price event -- PositiveMoney's own "an amount is
        // positive" invariant refuses Payment.Initiate before
        // Registration.Request is ever reached, proving the refusal
        // this route surfaces is the real domain rule, not a stand-in.
        let client = scratch_db("hecks_host_web_test_registrations_zero_price").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "free-event", 0).await;

        let body = json!({"event_slug": "free-event", "name": "Ada", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 422);
        assert!(
            response["body"].as_str().unwrap().contains("positive"),
            "should surface PositiveMoney's own invariant text: {response:?}"
        );

        // And neither the payment nor the registration was persisted —
        // Registration.Request must never have been dispatched at all.
        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert!(instances.keys().all(|k| !k.starts_with("CheckoutFixture::Registration#") && !k.starts_with("Payments::Payment#")));
    }

    #[tokio::test]
    async fn registrations_route_runs_the_whole_dispatch_chain_and_returns_a_real_mock_checkout_url() {
        let client = scratch_db("hecks_host_web_test_registrations_happy_path").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "happy-event", 4200).await;

        // No connection -- checkout genuinely on the mock walkthrough
        // (this route's own header), not a misconfiguration: the whole
        // chain runs for real and returns a real, working mock checkout
        // URL, never a 500.
        let body = json!({"event_slug": "happy-event", "name": "Ada Lovelace", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let reference = body["registration_id"].as_str().unwrap().to_string();
        // LocalCheckout's own exact shape (checkout.rs's own header):
        // this site's own /pay/<reference>.html page, with success_url
        // and cancel_url riding along as encoded query params, each
        // pointing at registration-confirmed.html (this route's own
        // header on why that replaced the old, dead-code event-page
        // redirect) -- no return_to sent, so it falls back to "/".
        assert_eq!(
            body["checkout_url"],
            format!(
                "http://localhost:4321/pay/{reference}.html?success_url=http%3A%2F%2Flocalhost%3A4321%2Fregistration-confirmed.html%3Fregistration_id%3D{reference}%26outcome%3Dsucceeded%26return_to%3D%252F&cancel_url=http%3A%2F%2Flocalhost%3A4321%2Fregistration-confirmed.html%3Fregistration_id%3D{reference}%26outcome%3Dcancelled%26return_to%3D%252F"
            )
        );

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        let registration = instances.iter().find(|(k, _)| k.starts_with("CheckoutFixture::Registration#")).map(|(_, v)| v);
        let payment = instances.iter().find(|(k, _)| k.starts_with("Payments::Payment#")).map(|(_, v)| v);
        assert!(registration.is_some(), "Registration.Request should have committed for real: {instances:?}");
        assert!(payment.is_some(), "Payment.Initiate should have committed for real: {instances:?}");

        let registration = registration.unwrap();
        let payment = payment.unwrap();
        assert_eq!(registration["event_slug"], "happy-event");
        assert_eq!(registration["attendee"]["name"], "Ada Lovelace");
        // **One shared reference** — the Registration's own id equals the
        // Payment's own reference, minted once (this route's own header
        // on why), never independently.
        assert_eq!(registration["registration_id"]["value"], reference);
        assert_eq!(payment["reference"]["value"], reference);
        assert_eq!(payment["amount"]["cents"], 4200);
        // Mock, not "stripe" -- the processor `checkout_plan` picks for a
        // tenant with no connection, which the webhook then reads back
        // off the Payment itself (this function's own header on why that
        // drift matters: Payment::Succeed's own "the processor matches"
        // given).
        assert_eq!(payment["processor"]["value"], "mock_stripe");
    }

    // A caller's own `return_to` (the page the guest was actually
    // registering from) drives the redirect, not the event's own
    // slug -- the exact bug found live: a real Yogadelics registration
    // succeeded but then redirected to /yogadelics-friday-september-5.html
    // (the domain Event's own internal slug, never a real page route)
    // instead of back to /yogadelics.html, 404ing every real guest right
    // after a successful, already-charged registration.
    #[tokio::test]
    async fn registrations_route_redirects_to_the_caller_s_own_return_to_not_the_event_slug() {
        let client = scratch_db("hecks_host_web_test_registrations_return_to").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "happy-event", 4200).await;

        let body = json!({
            "event_slug": "happy-event",
            "name": "Ada Lovelace",
            "email": "ada@example.com",
            "return_to": "/yogadelics.html",
        })
        .to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let reference = body["registration_id"].as_str().unwrap().to_string();
        assert_eq!(
            body["checkout_url"],
            format!(
                "http://localhost:4321/pay/{reference}.html?success_url=http%3A%2F%2Flocalhost%3A4321%2Fregistration-confirmed.html%3Fregistration_id%3D{reference}%26outcome%3Dsucceeded%26return_to%3D%252Fyogadelics.html&cancel_url=http%3A%2F%2Flocalhost%3A4321%2Fregistration-confirmed.html%3Fregistration_id%3D{reference}%26outcome%3Dcancelled%26return_to%3D%252Fyogadelics.html"
            )
        );
    }

    // safe_return_to's own guest-supplied-path reasoning (http_server.rb's
    // own comment on it, ported byte for byte) -- an absolute or
    // protocol-relative return_to must never become an open redirect;
    // falls back to "/", exactly as if no return_to had been sent at all
    // (never the event's own page -- that redirect target was retired
    // alongside the old, dead-code `?registered=` shape, this route's
    // own header above).
    #[tokio::test]
    async fn registrations_route_refuses_an_absolute_or_protocol_relative_return_to() {
        let client = scratch_db("hecks_host_web_test_registrations_return_to_unsafe").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "happy-event", 4200).await;

        for unsafe_return_to in ["https://evil.example", "//evil.example"] {
            let body = json!({
                "event_slug": "happy-event",
                "name": "Ada Lovelace",
                "email": "ada@example.com",
                "return_to": unsafe_return_to,
            })
            .to_string();
            let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
            assert_eq!(response["statusCode"], 200, "{response:?}");
            let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
            // checkout_url is now the /pay/<id>.html walkthrough page (LocalCheckout's
            // own shape); registration-confirmed.html's own return_to shows up
            // encoded (twice: once for the /pay page's success_url, once more for
            // registration-confirmed.html's own return_to inside that) as "%252F".
            let checkout_url = body["checkout_url"].as_str().unwrap();
            let parsed = reqwest::Url::parse(checkout_url).unwrap();
            let success_url = parsed.query_pairs().find(|(k, _)| k == "success_url").map(|(_, v)| v.into_owned()).unwrap_or_default();
            assert!(
                success_url.ends_with("return_to=%2F"),
                "an unsafe return_to ({unsafe_return_to:?}) must fall back to \"/\": {body:?}"
            );
        }
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
        tampered.insert("lifeadelics_session".to_string(), "garbage.notasignature".to_string());
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
        cookies.insert("lifeadelics_session".to_string(), auth::account_token(secret, "zed@example.com", 60 * 60 * 24 * 14));
        let response = accounts_sso_token_route(&domain_ir, &cookies, secret, &client).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let sso_token = body["token"].as_str().expect("a sso token string");

        // The whole point: cms/src/endpoints/sso.ts verifies this same
        // token with the same wire format (verify_account_token is the
        // Rust side of that same scheme) — a real, decodable token, not
        // an opaque string this route just happens to return 200 with.
        assert_eq!(auth::verify_account_token(secret, sso_token).as_deref(), Some("zed@example.com"));

        // Missing or invalid session cookie -- refused, no token minted.
        let empty = HashMap::new();
        assert_eq!(accounts_sso_token_route(&domain_ir, &empty, secret, &client).await["statusCode"], 401);

        let mut tampered = HashMap::new();
        tampered.insert("lifeadelics_session".to_string(), "garbage.notasignature".to_string());
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
                    "CREATE TABLE embryonaut_member_head_snapshot_1 (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL);
                     CREATE VIEW embryonaut_member_head AS SELECT id, state FROM embryonaut_member_head_snapshot_1;
                     CREATE TABLE hecks_journal_embryonaut (
                         ordinal bigserial PRIMARY KEY, era int NOT NULL, aggregate text NOT NULL,
                         aggregate_id text NOT NULL, operation text NOT NULL, state jsonb, mirrors jsonb
                     );",
                )
                .await
                .unwrap();
            guard
                .execute(
                    "INSERT INTO embryonaut_member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 0, $2::jsonb), ($3, 0, $4::jsonb)",
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
            "name": "Embryonaut",
            "lineage": {"capable_aggregates": [{"name": "Member", "storage_name": "member"}]},
            "membership": {"provider": "Embryonaut", "aggregate": "Embryonaut::Member"},
        });
        (client, domain_ir)
    }

    #[tokio::test]
    async fn members_route_lists_admitted_people_as_json_sorted_by_name_for_a_valid_session() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_members_route").await;

        let mut cookies = HashMap::new();
        cookies.insert("lifeadelics_session".to_string(), auth::account_token(secret, "zed@example.com", 60));
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
        tampered.insert("lifeadelics_session".to_string(), "garbage.notasignature".to_string());
        let mut wrong_secret = HashMap::new();
        wrong_secret.insert("lifeadelics_session".to_string(), auth::account_token("another", "zed@example.com", 60));
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
        cookies.insert("lifeadelics_session".to_string(), auth::account_token(secret, email, 60));
        cookies
    }

    fn members_config() -> LineageConfig {
        LineageConfig { domain: "Embryonaut".to_string(), era: Some(1), mirrored: None }
    }

    #[tokio::test]
    async fn add_member_route_refuses_a_missing_or_invalid_session_with_a_json_401_and_writes_nothing() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_members_db("hecks_host_web_test_add_member_401").await;
        let body = r#"{"email": "new@example.com", "name": "New Person"}"#;

        let mut tampered = HashMap::new();
        tampered.insert("lifeadelics_session".to_string(), "garbage.notasignature".to_string());
        let mut wrong_secret = HashMap::new();
        wrong_secret.insert("lifeadelics_session".to_string(), auth::account_token("another", "zed@example.com", 60));

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
            .query_one("SELECT count(*) FROM hecks_journal_embryonaut WHERE aggregate_id = 'new@example.com'", &[])
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
            .query_one("SELECT count(*) FROM hecks_journal_embryonaut WHERE aggregate_id = $1", &[&id])
            .await
            .unwrap()
            .get(0)
    }

    #[tokio::test]
    async fn disable_and_enable_routes_refuse_a_missing_or_invalid_session_and_a_blank_email() {
        let secret = "s3cret";
        let (client, domain_ir) = scratch_two_admins("hecks_host_web_test_disable_401").await;

        let mut tampered = HashMap::new();
        tampered.insert("lifeadelics_session".to_string(), "garbage.notasignature".to_string());
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
        let config = LineageConfig { domain: "Lifeadelics".to_string(), era: Some(1), mirrored: None };
        // The wasm path doesn't exist: every refusal below must come before any registration read.
        let wasm_path = Path::new("does-not-exist.wasm");

        let mut tampered = HashMap::new();
        tampered.insert("lifeadelics_session".to_string(), "garbage.notasignature".to_string());
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

    #[test]
    fn registration_list_rows_have_exactly_the_admin_list_shape_and_never_carry_health_or_payment_fields() {
        let read = json!({"instances": {
            "Lifeadelics::Registration#reg-old": {
                "event_slug": "yoga-aug",
                "created_at": "2026-09-01T10:00:00Z",
                "attendee": {"first_name": " Ada ", "last_name": "Lovelace", "email": "ada@example.com", "news_signup": true,
                             "phone": "555-0100", "medications": "SECRET-MEDICATION", "health_concerns": "SECRET-CONCERN"},
            },
            "Lifeadelics::Registration#reg-new": {
                "event_slug": "yoga-sep",
                "created_at": "2026-09-20T10:00:00Z",
                "attendee": {"first_name": {"value": "Grace"}, "last_name": {"value": "Hopper"}, "email": {"value": "grace@example.com"}},
                "amount": {"cents": 9900},
            },
            "Lifeadelics::Event#yoga-aug": {"name": {"value": "Yoga"}},
            "Payments::Payment#reg-old": {"amount": {"cents": 12345}, "status": "succeeded"},
        }});

        let rows = registration_list_rows(&read, "Lifeadelics");
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
    fn registration_list_rows_keep_read_order_without_timestamps_and_are_empty_with_no_registrations() {
        let read = json!({"instances": {
            "Lifeadelics::Registration#a": {"event_slug": "e", "attendee": {"name": "Flat Name", "email": "flat@example.com"}},
        }});
        let rows = registration_list_rows(&read, "Lifeadelics");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["name"], "Flat Name", "falls back to a flat name when there is no first and last name");

        assert_eq!(registration_list_rows(&json!({"instances": {}}), "Lifeadelics"), Vec::<Value>::new());
        assert_eq!(registration_list_rows(&json!({}), "Lifeadelics"), Vec::<Value>::new());
        let other_domain = json!({"instances": {"Elsewhere::Registration#x": {"attendee": {"email": "x@example.com"}}}});
        assert!(registration_list_rows(&other_domain, "Lifeadelics").is_empty(), "another domain's registrations are not listed");
    }

    #[test]
    fn sorted_by_name_orders_case_insensitively_and_puts_a_missing_name_first() {
        let people = vec![json!({"name": "bob"}), json!({"name": "Ada"}), json!({"name": null}), json!({"name": "Cy"})];
        let names: Vec<Value> = sorted_by_name(people).into_iter().map(|p| p["name"].clone()).collect();
        assert_eq!(names, [json!(null), json!("Ada"), json!("bob"), json!("Cy")]);
    }

    #[tokio::test]
    async fn a_mock_registration_confirms_end_to_end_through_a_synthetic_signed_webhook() {
        // The full loop, mock adapter both ends — registrations_route's
        // own mock checkout_url, then a webhook shaped exactly like
        // domain/bin/confirm_payment_manually's own (Ruby, lifeadelics
        // repo) sends, signed against the same fixed default
        // `webhook_route` falls back to while STRIPE_WEBHOOK_SECRET is
        // unset. Proves the "processor matches" given (Payment::Succeed's
        // own) actually admits a mock-initiated payment's own
        // mock-reported confirmation.
        let client = scratch_db("hecks_host_web_test_mock_full_loop").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "mock-loop-event", 4200).await;

        let body = json!({"event_slug": "mock-loop-event", "name": "Ada Lovelace", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let response_body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let reference = response_body["registration_id"].as_str().unwrap().to_string();

        let secret = MOCK_STRIPE_WEBHOOK_SECRET;
        let payload = json!({
            "type": "checkout.session.completed",
            "data": {"object": {"id": format!("cs_manual_{reference}"), "metadata": {"registration_id": reference}}},
        }).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(&payload, &header, &payments::test_platform(), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"][format!("Payments::Payment#{reference}")];
        assert_eq!(payment["status"], "succeeded");
        assert_eq!(payment["transaction_id"]["value"], format!("cs_manual_{reference}"));
    }

    // ---- webhook_route: no network at all, fully testable end to end --

    #[tokio::test]
    async fn webhook_route_rejects_a_bad_signature_before_touching_the_domain_at_all() {
        let client = scratch_db("hecks_host_web_test_webhook_bad_sig").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let payload = json!({"type": "checkout.session.completed", "data": {"object": {}}}).to_string();
        let bad_header = "t=1700000000,v1=deadbeef";

        let response = webhook_route(&payload, bad_header, &payments::test_platform_with_secret("whsec_test_bad_sig"), &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 400);
    }

    #[tokio::test]
    async fn webhook_route_settles_a_payment_on_checkout_session_completed() {
        let client = scratch_db("hecks_host_web_test_webhook_completed").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "webhook-event", 4200).await;
        let initiate = dispatch::handle(
            &client, &wasm_path, "Payments::Payment.Initiate",
            json!({
                "reference": {"value": "REG-WEBHOOK-1"}, "processor": {"value": "stripe"},
                "payment_type": {"value": "card"}, "amount": {"cents": 4200},
                "client": {"name": "Ada Lovelace", "email": "ada@example.com"},
            }),
            None, &config, &lambda_client::NeverInvoker,
        ).await.unwrap();
        assert!(initiate.accepted, "{:?}", initiate.result);

        let secret = "whsec_test_completed";
        let payload = json!({
            "type": "checkout.session.completed",
            "data": {"object": {"metadata": {"registration_id": "REG-WEBHOOK-1"}, "payment_intent": "pi_test_abc"}},
        }).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(&payload, &header, &payments::test_platform_with_secret(secret), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"]["Payments::Payment#REG-WEBHOOK-1"];
        assert_eq!(payment["status"], "succeeded");
        assert_eq!(payment["transaction_id"]["value"], "pi_test_abc");

        // A redelivered webhook (Stripe's own delivery is at-least-once)
        // for the same already-succeeded payment must still answer 200
        // — the real domain refusal underneath is a benign no-op here,
        // not surfaced as an error (this route's own header explains
        // why, and why that's a deliberate improvement over
        // http_server.rb's own unguarded equivalent).
        let redelivered = webhook_route(&payload, &header, &payments::test_platform_with_secret(secret), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(redelivered["statusCode"], 200, "a redelivered webhook must not surface the resulting refusal as an error: {redelivered:?}");
    }

    #[tokio::test]
    async fn webhook_route_declines_a_payment_on_checkout_session_expired() {
        let client = scratch_db("hecks_host_web_test_webhook_expired").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;
        let config = checkout_config(1);
        let wasm_path = checkout_wasm_path();

        schedule_event(&client, &wasm_path, &config, "webhook-event-2", 4200).await;
        dispatch::handle(
            &client, &wasm_path, "Payments::Payment.Initiate",
            json!({
                "reference": {"value": "REG-WEBHOOK-2"}, "processor": {"value": "stripe"},
                "payment_type": {"value": "card"}, "amount": {"cents": 4200},
                "client": {"name": "Ada Lovelace", "email": "ada@example.com"},
            }),
            None, &config, &lambda_client::NeverInvoker,
        ).await.unwrap().accepted.then_some(()).expect("initiate should succeed");

        let secret = "whsec_test_expired";
        let payload = json!({
            "type": "checkout.session.expired",
            "data": {"object": {"metadata": {"registration_id": "REG-WEBHOOK-2"}}},
        }).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(&payload, &header, &payments::test_platform_with_secret(secret), &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"]["Payments::Payment#REG-WEBHOOK-2"];
        assert_eq!(payment["status"], "failed");
        assert_eq!(payment["failure_reason"]["value"], "checkout_expired");
    }

    #[tokio::test]
    async fn webhook_route_ignores_an_event_type_it_does_not_handle_and_still_answers_200() {
        let client = scratch_db("hecks_host_web_test_webhook_unhandled_type").await;
        provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event", "Registration", "Payment"]).await;

        let secret = "whsec_test_unhandled";
        let payload = json!({"type": "charge.refunded", "data": {"object": {"metadata": {"registration_id": "whatever"}}}}).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(&payload, &header, &payments::test_platform_with_secret(secret), &client, &checkout_wasm_path(), &checkout_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200);
    }
}
