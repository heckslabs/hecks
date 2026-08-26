// THE WEB UI, IN-PROCESS — no second Lambda, no network hop. Detects
// a Function-URL HTTP event (`requestContext.http`/`rawPath` present
// — the API Gateway v2 payload format every Function URL invocation
// uses, unconditionally) and, if present, resolves it against the
// SAME IR `Hecks::Presentation::FieldShape` walks in Ruby
// (`HECKS_IR_PATH`, a plain-JSON sidecar — see domain_generator.rb's
// own comment on why this isn't the metadata.rs-embedded constant:
// this crate has no path dependency on the kernel crate that embeds
// it), dispatching through the SAME `dispatch::handle`/`dispatch::read`
// this Lambda already uses for its internal `{"verb"}`/`{"read"}`
// events. Ported from HecksOnWeb::Router/FieldShape/FormBuilder (the
// Ruby framework, hecks_on_web) — same routing rules, same field-shape
// mapping, same Tailwind classes, Rust.
//
// Returns `None` for anything that isn't a Function-URL HTTP event —
// `main.rs` falls through to its existing `read`/`verb` handling
// untouched in that case, zero risk to the internal-dispatch path.

use crate::auth;
use crate::auth::Session;
use crate::checkout;
use crate::dispatch;
use crate::field_hints::{EMAIL_HINT, TEL_HINT, TEXTAREA_HINT, URL_HINT};
use crate::ir::ir;
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
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

    // LIFEADELICS-SPECIFIC GLUE, MARKED — same convention auth.rs's own
    // header uses for its Embryonaut-specific glue: checkout_route
    // hardcodes verb strings against Lifeadelics' own aggregates
    // (Registration, and vendored Payments::Payment's PaymentGateway
    // port), the pragmatic working version for lifeadelics today rather
    // than a new IR-driven "outbound port"/"webhook signature scheme"
    // capability with no second domain to prove it against (checkout.rs's
    // own header has the fuller reasoning). Checked BEFORE the ir()/
    // HECKS_IR_PATH gate below, deliberately: lifeadelics declares no
    // `web "Rust"` (Shared mode, no generic FieldShape UI — the same
    // shape Banking's own Shared-mode deploy already uses), so
    // HECKS_IR_PATH is never set for it and `ir()` always returns None
    // here; neither of these two routes needs a domain_ir at all.
    if config.domain == "Lifeadelics" {
        let stripe_signature = body.get("headers").and_then(|h| h.get("stripe-signature")).and_then(|v| v.as_str()).unwrap_or("");
        if let Some(response) = checkout_route(method, path, &raw_body, stripe_signature, client, wasm_path, config, invoker).await {
            return Some(response);
        }
    }

    let Some(domain_ir) = ir() else {
        return Some(respond(500, "text/plain", "HECKS_IR_PATH not set or unreadable — this domain has no web layer configured"));
    };

    let query = parse_form(body.get("rawQueryString").and_then(|v| v.as_str()).unwrap_or(""));
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

fn session_secret() -> String {
    std::env::var("SESSION_SECRET").unwrap_or_default()
}

fn redirect_uri() -> String {
    std::env::var("GOOGLE_REDIRECT_URI").unwrap_or_default()
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

    if let Some(response) = auth_route(path, method, query, raw_body, session.as_ref(), &secret, client, wasm_path, config, invoker).await {
        return response;
    }

    if !UNGATED_PATHS.contains(&path) && session.is_none() {
        return redirect("/login");
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
    path: &str,
    method: &str,
    query: &HashMap<String, String>,
    raw_body: &str,
    session: Option<&Session>,
    secret: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    match (method, path) {
        ("GET", "/login") => Some(html(200, &login_page(query.get("error").map(|s| s.as_str())))),

        ("POST", "/logout") => Some(redirect_with_cookie("/login", "session=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax")),

        ("GET", "/auth/google") => match auth::authorization_url(&redirect_uri(), secret) {
            Ok(url) => Some(redirect(&url)),
            Err(e) => Some(respond(500, "text/plain", &format!("Google sign-in isn't configured: {e}"))),
        },

        ("GET", "/auth/google/callback") => Some(google_callback(query, client, wasm_path, config, secret, invoker).await),

        ("GET", "/admin/members") => {
            let Some(session) = session else { return Some(redirect("/login")) };
            if !is_admin(client, wasm_path, &session.identity_id).await {
                return Some(html(403, "<p>Admins only.</p>"));
            }
            Some(html(200, &admin_members_page(client).await))
        }

        ("POST", "/admin/members") => {
            let Some(session) = session else { return Some(redirect("/login")) };
            if !is_admin(client, wasm_path, &session.identity_id).await {
                return Some(html(403, "<p>Admins only.</p>"));
            }
            let form = parse_form(raw_body);
            let email = form.get("email").cloned().unwrap_or_default();
            let role = form.get("role").cloned().unwrap_or_default();
            match auth::grant_access(client, wasm_path, config, &email, &role).await {
                Ok(true) => Some(redirect("/admin/members")),
                Ok(false) => Some(html(404, "<p>No member with that email.</p>")),
                Err(e) => Some(html(500, &format!("<p>{}</p>", esc(&e.to_string())))),
            }
        }

        _ => None,
    }
}

async fn is_admin(client: &Mutex<Client>, wasm_path: &Path, identity_id: &str) -> bool {
    match dispatch::read(client, wasm_path).await {
        Ok(read) => auth::holds_admin(read.get("instances").unwrap_or(&json!({})), identity_id),
        Err(_) => false,
    }
}

#[allow(clippy::too_many_arguments)]
async fn google_callback(
    query: &HashMap<String, String>,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    secret: &str,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let Some(code) = query.get("code") else { return redirect("/login?error=google_failed") };
    let Some(state) = query.get("state") else { return redirect("/login?error=google_failed") };
    if auth::verify_state(state, secret).is_err() {
        return redirect("/login?error=google_failed");
    }

    let claims = match auth::verify(code, &redirect_uri()).await {
        Ok(c) => c,
        Err(_) => return redirect("/login?error=google_failed"),
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(_) => return redirect("/login?error=google_failed"),
    };
    let instances = read.get("instances").cloned().unwrap_or(json!({}));

    let session = match auth::resolve_identity(&instances, &claims.issuer, &claims.subject) {
        Some(identity_id) => auth::session_for_member_by_identity(client, &identity_id).await.unwrap_or(None),
        None => None,
    };
    let session = match session {
        Some(s) => Some(s),
        None if claims.email_verified => {
            let email = claims.email.clone().unwrap_or_default();
            match auth::provision(client, wasm_path, config, &email, &claims.issuer, &claims.subject, invoker).await {
                Ok(s) => s,
                Err(_) => None,
            }
        }
        None => None,
    };

    let Some(session) = session else { return redirect("/login?error=google_unlinked") };
    let cookie = format!("session={}; Path=/; HttpOnly; Secure; SameSite=Lax", auth::session_cookie(secret, &session));
    redirect_with_cookie("/", &cookie)
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

async fn admin_members_page(client: &Mutex<Client>) -> String {
    let people = auth::all_people(client).await.unwrap_or_default();
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
    // deliberately NOT ported here, see web.rs's own header) to use;
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
// truthy -> not-a-PRIMITIVE (value object) -> primitive. `domain_ir` is
// the WHOLE chapter — needed by `admits:` resolution (a set can be
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

// A value object's own declared shape, checked on the OWNING aggregate
// first and only then walked across the whole domain — `own_value_
// object`'s exact fallback order (field_shape.rb).
fn value_object_shape<'a>(domain_ir: &'a Value, aggregate: &'a Value, ty: &str) -> Option<&'a Value> {
    find_value_object(aggregate, ty).or_else(|| cross_aggregate_value_object(domain_ir, ty))
}

// `FieldShape#cross_aggregate_value_object`, mirrored exactly despite
// its name being scoped like a sibling search — it's a WHOLE-DOMAIN
// walk (field_shape.rb's own comment says so plainly): a command's
// declared value-object-typed attribute may name a shape belonging to
// ANOTHER aggregate entirely (Transfer's own `narrative: Narrative`
// argument, resolved with Transfer as the owning aggregate, could in
// principle point at a Narrative declared on Account instead — this is
// the fallback that makes that legal). THE ROOT-CAUSE FIX: without
// this, a cross-aggregate value object falls all the way through to
// `primitive_field`'s bare-text default, and neither `admits:`
// resolution below nor Tier B's textarea hint ever gets a chance to
// run against the real, UNWRAPPED inner attribute.
fn cross_aggregate_value_object<'a>(domain_ir: &'a Value, type_name: &str) -> Option<&'a Value> {
    domain_ir.get("aggregates")?.as_array()?.iter().find_map(|sibling| find_value_object(sibling, type_name))
}

// The discriminant field name plus its member values, factored out of
// the native `one_of` branch below so the `admits:` branch (which
// checks a DIFFERENT aggregate's closed set) can share the exact same
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
// is the label (the OUTER path, not yet dotted down to a discriminant)
// — callers that need the discriminant hop mutate `.path` afterward,
// same as Ruby's `options.path = "#{common[:path]}.#{discriminant}"`
// leaving `label` untouched.
fn select_or_radio(path: &str, optional: bool, members: Vec<String>) -> Field {
    let label = humanize(path);
    let kind = if members.len() <= 4 { FieldKind::Radio(members) } else { FieldKind::Select(members) };
    Field { path: path.to_string(), label, kind, optional }
}

// `FieldShape#admitted_field` — a closed set declared ELSEWHERE
// (`"Account::LedgerDirection"`), resolved and rendered exactly the
// way the native `one_of` branch renders its own SAME-attribute set,
// via the shared `closed_set_members`/`select_or_radio` helpers above.
fn admitted_field(domain_ir: &Value, aggregate: &Value, attribute: &Value, admits: &str, ty: &str, path: &str, optional: bool) -> Field {
    let mut parts = admits.splitn(2, "::");
    let set_aggregate_name = parts.next().unwrap_or("");
    let set_name = parts.next();

    let set = set_name.and_then(|name| find_aggregate(domain_ir, set_aggregate_name).and_then(|agg| find_value_object(agg, name)));
    // Undeclared set — refuse-at-dispatch stays the backstop (Ruby's own
    // comment on this exact fallback); render it as whatever a plain
    // scalar of this attribute would be, using the REAL attribute so
    // its own name/pattern still drive Tier B's hints correctly.
    let Some(set) = set else { return primitive_field(attribute, ty, path, optional) };

    let (_, members) = closed_set_members(set);
    let mut field = select_or_radio(path, optional, members);

    // The attribute's OWN type still has to land on the shape coercion
    // expects — a value object like `MovementDirection { value }` still
    // needs the ".value" hop even though the SET it's checked against
    // is declared somewhere else entirely (same unwrap `value_object_
    // field` does, kept separate because an admitted set changes the
    // OPTIONS, not which field the hop lands on).
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
    // a NAME for a scalar, not a genuine group. The OUTER label wins
    // (humanize(path), not the recursively-resolved inner field's own
    // label) — "value"/"cents" is internal storage shape, never what a
    // human reads. Recursing back through `resolve_field` (not
    // straight to `primitive_field`) is what lets the INNER attribute's
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
// this, NOT any derivation off `path` — after a single-attribute
// unwrap (`value_object_field` above), `attribute` is the INNER
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
// i)` are both INLINE checks in Ruby too (never promoted to their own
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

fn extract_args(fields: &[Field], raw: &HashMap<String, String>) -> Value {
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

fn nest(pairs: Vec<(String, Value)>) -> Value {
    let mut result = json!({});
    for (path, value) in pairs {
        let segments: Vec<&str> = path.split('.').collect();
        let mut node = &mut result;
        for segment in &segments[..segments.len() - 1] {
            node = node.as_object_mut().unwrap().entry(*segment).or_insert_with(|| json!({}));
        }
        node.as_object_mut().unwrap().insert(segments[segments.len() - 1].to_string(), value);
    }
    result
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
    let args = extract_args(fields, raw);

    // `None` -- the web UI has no notion of an authenticated caller's
    // role yet (a separate, not-yet-built concern; see auth.rs's own
    // session handling), so this preserves exactly the behavior every
    // command submitted through the Founder App has always had.
    let outcome = match dispatch::handle(client, wasm_path, &verb, args, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };

    if outcome.accepted {
        let id = outcome
            .result
            .get("mutations")
            .and_then(|m| m.as_array())
            .and_then(|steps| steps.last())
            .and_then(|last| last.as_array())
            .and_then(|muts| muts.last())
            .and_then(|m| m.get("id"))
            .and_then(|v| v.as_str())
            .unwrap_or("");
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

// A refused command's own MOST RECENT refusal — `.last()` because
// `dispatch::handle` reruns the whole rehydrated history, and every
// step before this call's own already succeeded once (dispatch.rs's own
// header on why); shared by `submit` above and `registrations_route`
// below rather than each keeping its own copy.
fn last_refusal(result: &Value) -> Value {
    result
        .get("refusals")
        .and_then(|r| r.as_array())
        .and_then(|rs| rs.last())
        .cloned()
        .unwrap_or_else(|| json!({"error": "Refused"}))
}

// ---- lifeadelics: /registrations, /webhooks/stripe ---------------------
// See `render`'s own "LIFEADELICS-SPECIFIC GLUE" header and checkout.rs's
// own header for why this is hardcoded rather than IR-driven. Ported
// from adapters/http_server.rb (the Ruby app, lifeadelics repo) —
// same two routes, same status codes, same dispatch order, Rust.

// Env vars read ONCE here, at the routing layer, passed down as plain
// parameters — the same shape `route`'s own `session_secret()` already
// reads once and hands `auth_route` rather than each auth_route arm
// reading it independently. Keeps `registrations_route`/`webhook_route`
// themselves free of hidden global state, the same reason `checkout::
// verify_signature` takes `now` as a parameter instead of reading the
// clock internally — a test can pass an explicit secret/key instead of
// mutating a PROCESS-WIDE env var, which `cargo test`'s default
// parallelism would otherwise race between tests.
// BLANK, NOT A BARE .unwrap() — lifeadelics.world's own comment on why
// this same default is blank there too: real in a deploy that actually
// sets it, deferred (never a boot-time panic) everywhere else, the SAME
// reasoning `stripe_api_key`'s own blank default already holds to.
fn stripe_api_key() -> String {
    std::env::var("STRIPE_API_KEY").unwrap_or_default()
}

// THE SAME FIXED, PUBLICLY-KNOWN, NON-SECRET DEFAULT adapters/
// http_server.rb hardcodes (`ENV.fetch("STRIPE_WEBHOOK_SECRET",
// "whsec_mock_lifeadelics_fixed")`) — domain/bin/confirm_payment_
// manually signs against this exact string, so a mock deploy (empty
// `stripe_api_key`) needs no Lambda environment configuration at all
// to be fully exercisable end to end.
fn stripe_webhook_secret() -> String {
    std::env::var("STRIPE_WEBHOOK_SECRET").unwrap_or_else(|_| "whsec_mock_lifeadelics_fixed".to_string())
}

fn site_url() -> String {
    std::env::var("SITE_URL").unwrap_or_else(|_| "http://localhost:4321".to_string())
}

// http_server.rb's own PROCESSOR constant, derived from the SAME fact
// `stripe_api_key` already answers rather than a second, independently-
// settable flag — a blank key means checkout is genuinely bound to the
// mock adapter, so reporting anything other than "mock_stripe" would be
// exactly the drift that constant's own comment warns against ("a lie
// in production data"). Read ONCE here and threaded through both
// routes as a parameter — `registrations_route`'s own Payment.Initiate
// and `webhook_route`'s own reported_processor MUST agree, or
// Payment::Succeed's own "the processor matches the one this payment
// was initiated with" given refuses every mock confirmation (the exact
// bug class this session already found live once, for the real-Stripe
// path — see naming.rb's own fielded_capable_nested? header).
fn checkout_processor() -> &'static str {
    if stripe_api_key().is_empty() { "mock_stripe" } else { "stripe" }
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
            Some(registrations_route(raw_body, &stripe_api_key(), checkout_processor(), &site_url(), client, wasm_path, config, invoker).await)
        }
        ("POST", "/webhooks/stripe") => {
            Some(webhook_route(raw_body, stripe_signature, &stripe_webhook_secret(), checkout_processor(), client, wasm_path, config, invoker).await)
        }
        _ => None,
    }
}

// THE SITE DRIVING IN — http_server.rb's own `POST /registrations`.
// Payment first, then Registration, sharing ONE reference minted here
// (lifeadelics.bluebook's own Registration comment has the full
// reasoning: a Registration with no Payment behind it is meaningless,
// a Payment with no Registration just needs cleaning up eventually).
// `role: None` throughout — this route has no notion of an
// authenticated caller's role any more than web.rs's own generic
// `submit` does (that function's own comment); the Astro site calls in
// server-to-server, not as a signed-in user.
#[allow(clippy::too_many_arguments)]
async fn registrations_route(
    raw_body: &str,
    api_key: &str,
    processor: &str,
    site_url: &str,
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
    let Some(name) = body.get("name").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing name"}).to_string());
    };
    let Some(email) = body.get("email").and_then(|v| v.as_str()) else {
        return respond(400, "application/json", &json!({"error": "missing email"}).to_string());
    };

    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let events = instances_for(&read, "Lifeadelics::Event#");
    let Some((_, event)) = events.iter().find(|(id, _)| id == event_slug) else {
        return respond(404, "application/json", &json!({"error": "no such event"}).to_string());
    };
    if event.get("status").and_then(|v| v.as_str()) != Some("open") {
        return respond(422, "application/json", &json!({"error": "registration is closed for this event"}).to_string());
    }
    let price_cents = event.get("price").and_then(|p| p.get("cents")).and_then(|v| v.as_i64()).unwrap_or(0);
    let event_name = event.get("name").and_then(|n| n.get("value")).and_then(|v| v.as_str()).unwrap_or("");

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
        "attendee": {"name": name, "email": email},
    });
    let outcome = match dispatch::handle(client, wasm_path, "Lifeadelics::Registration.Request", request_args, None, config, invoker).await {
        Ok(o) => o,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    if !outcome.accepted {
        return respond(422, "application/json", &last_refusal(&outcome.result).to_string());
    }

    let success_url = format!("{site_url}/{event_slug}.html?registered=1");
    let cancel_url = format!("{site_url}/{event_slug}.html?registered=0");

    // MOCK, NOT AN ERROR — an empty `api_key` means checkout is
    // genuinely bound to the mock adapter (this route's own header,
    // checkout.rs's own header) exactly the way lifeadelics.hecksagon's
    // own `opened_by("MockStripeAdapter")` is the default in every Ruby
    // environment except a real deploy — never a misconfiguration to
    // refuse.
    if api_key.is_empty() {
        let checkout_url = checkout::mock_checkout_session(&reference, &success_url);
        return respond(200, "application/json", &json!({"checkout_url": checkout_url, "registration_id": reference}).to_string());
    }

    match checkout::create_checkout_session(api_key, price_cents, event_name, &reference, &success_url, &cancel_url).await {
        Ok(checkout_url) => respond(200, "application/json", &json!({"checkout_url": checkout_url, "registration_id": reference}).to_string()),
        Err(e) => respond(500, "text/plain", &format!("{e:#}")),
    }
}

// STRIPE DRIVING IN — http_server.rb's own `POST /webhooks/stripe`.
// `reference` round-trips through Checkout's own metadata (set above,
// keyed "registration_id" — the same string is both the Registration's
// own id and the Payment's own reference), read back here — never
// trusted without a verified signature first. Dispatches through
// Payment's own vendored PaymentGateway port, never Registration's
// (removed — see lifeadelics.bluebook's own Registration comment).
#[allow(clippy::too_many_arguments)]
async fn webhook_route(
    raw_body: &str,
    signature_header: &str,
    secret: &str,
    processor: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
    if let Err(e) = checkout::verify_signature(raw_body, signature_header, secret, now) {
        return respond(400, "text/plain", &e.to_string());
    }
    let event: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(_) => return respond(400, "text/plain", "invalid JSON"),
    };

    let event_type = event.get("type").and_then(|v| v.as_str()).unwrap_or("");
    let object = event.get("data").and_then(|d| d.get("object")).cloned().unwrap_or_else(|| json!({}));
    let reference = object.get("metadata").and_then(|m| m.get("registration_id")).and_then(|v| v.as_str()).map(String::from);

    if let Some(reference) = reference {
        let reported_processor = json!({"value": processor});
        let verb_and_args = match event_type {
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
                    "reference": reference,
                    "transaction_id": {"value": transaction_id},
                    "reported_processor": reported_processor,
                })))
            }
            "checkout.session.expired" => Some(("Payments::Payment.PaymentGateway.Failed", json!({
                "reference": reference,
                "reason": {"value": "checkout_expired"},
                "reported_processor": reported_processor,
            }))),
            _ => None,
        };

        if let Some((verb, args)) = verb_and_args {
            // A REFUSAL HERE (e.g. a redelivered webhook for an already-
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
            if let Err(e) = dispatch::handle(client, wasm_path, verb, args, None, config, invoker).await {
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

fn instances_for(result: &Value, prefix: &str) -> Vec<(String, Value)> {
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
    text.split('&')
        .filter(|s| !s.is_empty())
        .filter_map(|pair| {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            Some((percent_decode(k), percent_decode(v)))
        })
        .collect()
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
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

fn base64_decode(input: &str) -> Vec<u8> {
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
// identity, free-form and user-supplied unless `pattern:`-constrained, NOT
// a bluebook-declared name the way `agg`/`domain_name`/`cn` are. Every
// call site that places `id` into rendered HTML routes through one of
// these two functions so escaping (and, for the query-string position,
// percent-encoding) can't be forgotten at a THIRD call site the way it
// was at these two before this fix — Ruby's own `Escape.html`/`.attr`
// already covers `id` everywhere (`record_table.rb:45`, `record_
// renderer.rb:43,79`); this closes the parallel Rust gap, not a new
// capability Ruby lacks too.
//
// `id` goes into a QUERY-STRING value here (`?id=...`), not just an HTML
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

// The row's own link to itself — `id` sits in a PATH segment here, not a
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

fn redirect_with_cookie(location: &str, cookie: &str) -> Value {
    json!({"statusCode": 302, "headers": {"location": location}, "cookies": [cookie], "body": "", "isBase64Encoded": false})
}

fn respond(status: u16, content_type: &str, body: &str) -> Value {
    json!({"statusCode": status, "headers": {"content-type": content_type}, "body": body, "isBase64Encoded": false})
}

#[cfg(test)]
mod tests {
    use super::*;

    // H10 (docs/audits/2026-08-10-main-bug-audit.md) — a record's own
    // identity is user-supplied, free-form unless `pattern:`-constrained,
    // and used to be interpolated raw at these two call sites. A creating
    // command persisting this exact id used to render live, executable
    // markup for every later viewer of the index row or record page.
    const MALICIOUS_ID: &str = r#"x"><script>alert(1)</script>"#;

    #[test]
    fn action_link_escapes_the_link_text_and_percent_encodes_the_query_value() {
        let link = action_link("Pizzas", "Order", "Purchase", MALICIOUS_ID, "mr-3");

        assert!(!link.contains("<script"), "{link}");
        assert!(!link.contains(MALICIOUS_ID), "the raw id must not survive into the rendered link: {link}");
        // The query VALUE must be percent-encoded, not HTML-escaped —
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

    // THE KEY REGRESSION TEST — exercises Tier A's cross-aggregate
    // lookup and Tier B's textarea hint together, the same combination
    // that was silently broken before this change.
    #[test]
    fn narrative_used_from_a_different_aggregate_renders_as_a_textarea_via_the_cross_aggregate_lookup() {
        // Account's REAL Narrative{text} value object — declared on
        // Account, never on CardPayment (CardPayment's own real
        // value_objects list, confirmed by reading the live generated
        // IR, is AuthorisationCode/PaymentAmount/MerchantName/Tag —
        // no Narrative). The attribute itself is real too: Transfer.
        // Request's own "narrative" argument JSON, byte-for-byte —
        // reused here scoped against CardPayment instead of Transfer
        // specifically to prove the fallback walks the WHOLE domain,
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
        // No `pattern:` at all — synthetic, since every REAL email-
        // shaped attribute in the corpus (Customer.email) also carries
        // one; proves the OR in Ruby's own `pattern.include?("@") ||
        // name.match?(EMAIL_HINT)` really is an OR, not pattern-gated.
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
        // to a plain scalar (money_shaped? needs EXACTLY {cents,
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
        // whole word in "link" but only a SUBSTRING of "blinking", and
        // the boundary must reject the latter; same for "text" inside
        // "context". Case-insensitivity ((?i), the Rust spelling of
        // Ruby's trailing `/i`) checked too.
        assert!(URL_HINT.is_match("link"));
        assert!(!URL_HINT.is_match("blinking"));
        assert!(TEXTAREA_HINT.is_match("text"));
        assert!(!TEXTAREA_HINT.is_match("context"));
        assert!(EMAIL_HINT.is_match("EMAIL"));
    }

    // ---- checkout_route: real Postgres, real lifeadelics.wasm, no
    // network ----------------------------------------------------------
    // `registrations_route`'s own final hop (checkout::create_checkout_
    // session, a genuine third-party HTTPS call to api.stripe.com) is
    // deliberately NOT trait-injected/mocked here — auth.rs's own
    // Google OAuth calls (verify/verify_id_token) hold to the exact
    // same precedent: real third-party network code stays real-network,
    // verified live rather than locally unit-tested. What IS tested
    // below is everything genuinely this route's own logic: event
    // lookup, the closed/missing-field/refusal branches, and the
    // dispatch chain all the way through Registration.Request — a
    // missing STRIPE_API_KEY is what stops each successful case one
    // step short of the real network call, which doubles as proof the
    // whole chain up to there ran for real (a wrong dispatch anywhere
    // earlier would fail on ITS OWN assertion first).
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
            let snapshot_table = format!("{}_head_snapshot_{era}", crate::journal::snake(name));
            client
                .batch_execute(&format!("CREATE TABLE IF NOT EXISTS \"{snapshot_table}\" (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL)"))
                .await
                .unwrap();
        }
    }

    fn lifeadelics_config(era: i32) -> LineageConfig {
        LineageConfig { domain: "Lifeadelics".to_string(), era: Some(era) }
    }

    fn lifeadelics_wasm_path() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/lifeadelics.wasm")
    }

    async fn schedule_event(client: &Mutex<Client>, wasm_path: &Path, config: &LineageConfig, slug: &str, price_cents: i64) {
        let args = json!({
            "slug": {"value": slug}, "name": {"value": "Yogadelics"},
            "price": {"cents": price_cents}, "capacity": {"value": 20},
        });
        let outcome = dispatch::handle(client, wasm_path, "Lifeadelics::Event.Schedule", args, None, config, &lambda_client::NeverInvoker)
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
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;

        let response = registrations_route(r#"{"event_slug":"yoga-aug"}"#, "", "mock_stripe", "http://localhost:4321", &client, &lifeadelics_wasm_path(), &lifeadelics_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 400);
        assert!(response["body"].as_str().unwrap().contains("missing name"));
    }

    #[tokio::test]
    async fn registrations_route_refuses_invalid_json_outright() {
        let client = scratch_db("hecks_host_web_test_registrations_bad_json").await;
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;

        let response = registrations_route("not json", "", "mock_stripe", "http://localhost:4321", &client, &lifeadelics_wasm_path(), &lifeadelics_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 400);
    }

    #[tokio::test]
    async fn registrations_route_404s_an_unknown_event_slug() {
        let client = scratch_db("hecks_host_web_test_registrations_no_event").await;
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;

        let body = json!({"event_slug": "nope", "name": "Ada", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, "", "mock_stripe", "http://localhost:4321", &client, &lifeadelics_wasm_path(), &lifeadelics_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 404);
    }

    #[tokio::test]
    async fn registrations_route_refuses_a_closed_event() {
        let client = scratch_db("hecks_host_web_test_registrations_closed_event").await;
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;
        let config = lifeadelics_config(1);
        let wasm_path = lifeadelics_wasm_path();

        schedule_event(&client, &wasm_path, &config, "closed-event", 4200).await;
        let close = dispatch::handle(&client, &wasm_path, "Lifeadelics::Event.Close", json!({"id": "closed-event"}), None, &config, &lambda_client::NeverInvoker)
            .await
            .unwrap();
        assert!(close.accepted, "closing the fixture event should succeed: {:?}", close.result);

        let body = json!({"event_slug": "closed-event", "name": "Ada", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, "", "mock_stripe", "http://localhost:4321", &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 422);
        assert!(response["body"].as_str().unwrap().contains("closed"));
    }

    #[tokio::test]
    async fn registrations_route_propagates_a_real_domain_refusal_from_payment_initiate() {
        // A ZERO-PRICE event -- PositiveMoney's own "an amount is
        // positive" invariant refuses Payment.Initiate before
        // Registration.Request is ever reached, proving the refusal
        // this route surfaces is the REAL domain rule, not a stand-in.
        let client = scratch_db("hecks_host_web_test_registrations_zero_price").await;
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;
        let config = lifeadelics_config(1);
        let wasm_path = lifeadelics_wasm_path();

        schedule_event(&client, &wasm_path, &config, "free-event", 0).await;

        let body = json!({"event_slug": "free-event", "name": "Ada", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, "", "mock_stripe", "http://localhost:4321", &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 422);
        assert!(
            response["body"].as_str().unwrap().contains("positive"),
            "should surface PositiveMoney's own invariant text: {response:?}"
        );

        // AND NEITHER THE PAYMENT NOR THE REGISTRATION WAS PERSISTED —
        // Registration.Request must never have been dispatched at all.
        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        assert!(instances.keys().all(|k| !k.starts_with("Lifeadelics::Registration#") && !k.starts_with("Payments::Payment#")));
    }

    #[tokio::test]
    async fn registrations_route_runs_the_whole_dispatch_chain_and_returns_a_real_mock_checkout_url() {
        let client = scratch_db("hecks_host_web_test_registrations_happy_path").await;
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;
        let config = lifeadelics_config(1);
        let wasm_path = lifeadelics_wasm_path();

        schedule_event(&client, &wasm_path, &config, "happy-event", 4200).await;

        // EMPTY api_key -- checkout genuinely bound to the mock adapter
        // (this route's own header), not a misconfiguration: the whole
        // chain runs for real and returns a real, working mock checkout
        // URL, never a 500.
        let body = json!({"event_slug": "happy-event", "name": "Ada Lovelace", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, "", "mock_stripe", "http://localhost:4321", &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let reference = body["registration_id"].as_str().unwrap().to_string();
        // MockStripeAdapter's own exact shape (checkout.rs's own header):
        // the success_url, `?` since it carries no query string yet,
        // then mock_checkout=1&mock_registration_id=<reference>.
        assert_eq!(
            body["checkout_url"],
            format!("http://localhost:4321/happy-event.html?registered=1&mock_checkout=1&mock_registration_id={reference}")
        );

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let instances = read["instances"].as_object().unwrap();
        let registration = instances.iter().find(|(k, _)| k.starts_with("Lifeadelics::Registration#")).map(|(_, v)| v);
        let payment = instances.iter().find(|(k, _)| k.starts_with("Payments::Payment#")).map(|(_, v)| v);
        assert!(registration.is_some(), "Registration.Request should have committed for real: {instances:?}");
        assert!(payment.is_some(), "Payment.Initiate should have committed for real: {instances:?}");

        let registration = registration.unwrap();
        let payment = payment.unwrap();
        assert_eq!(registration["event_slug"], "happy-event");
        assert_eq!(registration["attendee"]["name"], "Ada Lovelace");
        // ONE SHARED REFERENCE — the Registration's own id equals the
        // Payment's own reference, minted once (this route's own header
        // on why), never independently.
        assert_eq!(registration["registration_id"]["value"], reference);
        assert_eq!(payment["reference"]["value"], reference);
        assert_eq!(payment["amount"]["cents"], 4200);
        // MOCK, NOT "stripe" -- the exact processor this route's own
        // `checkout_processor` derives from the same blank api_key,
        // never a second, independently-settable flag (this function's
        // own header on why that drift matters: Payment::Succeed's own
        // "the processor matches" given).
        assert_eq!(payment["processor"]["value"], "mock_stripe");
    }

    #[tokio::test]
    async fn a_mock_registration_confirms_end_to_end_through_a_synthetic_signed_webhook() {
        // THE FULL LOOP, mock adapter both ends — registrations_route's
        // own mock checkout_url, then a webhook shaped exactly like
        // domain/bin/confirm_payment_manually's own (Ruby, lifeadelics
        // repo) sends, signed against the SAME fixed default `stripe_
        // webhook_secret` falls back to. Proves the "processor matches"
        // given (Payment::Succeed's own) actually admits a mock-
        // initiated payment's own mock-reported confirmation — the
        // exact drift `checkout_processor`'s own header warns a second,
        // independently-settable flag would risk.
        let client = scratch_db("hecks_host_web_test_mock_full_loop").await;
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;
        let config = lifeadelics_config(1);
        let wasm_path = lifeadelics_wasm_path();

        schedule_event(&client, &wasm_path, &config, "mock-loop-event", 4200).await;

        let body = json!({"event_slug": "mock-loop-event", "name": "Ada Lovelace", "email": "ada@example.com"}).to_string();
        let response = registrations_route(&body, "", "mock_stripe", "http://localhost:4321", &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");
        let response_body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
        let reference = response_body["registration_id"].as_str().unwrap().to_string();

        let secret = "whsec_mock_lifeadelics_fixed";
        let payload = json!({
            "type": "checkout.session.completed",
            "data": {"object": {"id": format!("cs_manual_{reference}"), "metadata": {"registration_id": reference}}},
        }).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(&payload, &header, secret, "mock_stripe", &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
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
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;

        let payload = json!({"type": "checkout.session.completed", "data": {"object": {}}}).to_string();
        let bad_header = "t=1700000000,v1=deadbeef";

        let response = webhook_route(&payload, bad_header, "whsec_test_bad_sig", "stripe", &client, &lifeadelics_wasm_path(), &lifeadelics_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 400);
    }

    #[tokio::test]
    async fn webhook_route_settles_a_payment_on_checkout_session_completed() {
        let client = scratch_db("hecks_host_web_test_webhook_completed").await;
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;
        let config = lifeadelics_config(1);
        let wasm_path = lifeadelics_wasm_path();

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

        let response = webhook_route(&payload, &header, secret, "stripe", &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"]["Payments::Payment#REG-WEBHOOK-1"];
        assert_eq!(payment["status"], "succeeded");
        assert_eq!(payment["transaction_id"]["value"], "pi_test_abc");

        // A REDELIVERED webhook (Stripe's own delivery is at-least-once)
        // for the SAME already-succeeded payment must still answer 200
        // — the real domain refusal underneath is a benign no-op here,
        // not surfaced as an error (this route's own header explains
        // why, and why that's a deliberate improvement over
        // http_server.rb's own unguarded equivalent).
        let redelivered = webhook_route(&payload, &header, secret, "stripe", &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(redelivered["statusCode"], 200, "a redelivered webhook must not surface the resulting refusal as an error: {redelivered:?}");
    }

    #[tokio::test]
    async fn webhook_route_declines_a_payment_on_checkout_session_expired() {
        let client = scratch_db("hecks_host_web_test_webhook_expired").await;
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;
        let config = lifeadelics_config(1);
        let wasm_path = lifeadelics_wasm_path();

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

        let response = webhook_route(&payload, &header, secret, "stripe", &client, &wasm_path, &config, &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200, "{response:?}");

        let read = dispatch::read(&client, &wasm_path).await.unwrap();
        let payment = &read["instances"]["Payments::Payment#REG-WEBHOOK-2"];
        assert_eq!(payment["status"], "failed");
        assert_eq!(payment["failure_reason"]["value"], "checkout_expired");
    }

    #[tokio::test]
    async fn webhook_route_ignores_an_event_type_it_does_not_handle_and_still_answers_200() {
        let client = scratch_db("hecks_host_web_test_webhook_unhandled_type").await;
        provision_lineage(&*client.lock().await, "Lifeadelics", 1, &["Event", "Registration", "Payment"]).await;

        let secret = "whsec_test_unhandled";
        let payload = json!({"type": "charge.refunded", "data": {"object": {"metadata": {"registration_id": "whatever"}}}}).to_string();
        let now = now_secs();
        let header = sign_stripe_header(secret, now, &payload);

        let response = webhook_route(&payload, &header, secret, "stripe", &client, &lifeadelics_wasm_path(), &lifeadelics_config(1), &lambda_client::NeverInvoker).await;
        assert_eq!(response["statusCode"], 200);
    }
}
