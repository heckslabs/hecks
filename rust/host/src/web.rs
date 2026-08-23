// THE WEB UI, IN-PROCESS — no second Lambda, no network hop. Detects
// a Function-URL HTTP event (`requestContext.http`/`rawPath` present
// — the API Gateway v2 payload format every Function URL invocation
// uses, unconditionally) and, if present, resolves it against the
// SAME IR `Hecksagain::Presentation::FieldShape` walks in Ruby
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
    let Some(domain_ir) = ir() else {
        return Some(respond(500, "text/plain", "HECKS_IR_PATH not set or unreadable — this domain has no web layer configured"));
    };

    let method = http_event.get("method").and_then(|v| v.as_str()).unwrap_or("GET");
    let path = body.get("rawPath").and_then(|v| v.as_str()).unwrap_or("/");
    let query = parse_form(body.get("rawQueryString").and_then(|v| v.as_str()).unwrap_or(""));
    let raw_body = body.get("body").and_then(|v| v.as_str()).unwrap_or("");
    let raw_body = if body.get("isBase64Encoded").and_then(|v| v.as_bool()) == Some(true) {
        String::from_utf8(base64_decode(raw_body)).unwrap_or_default()
    } else {
        raw_body.to_string()
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
// Hecksagain::Presentation::FieldShape / hecks_on_web's own copy of it.

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

// `Hecksagain::Presentation::FieldShape#resolve`'s own dispatch order,
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
// Mirrors Hecksagain::Presentation::Params/hecks_on_web's own copy.

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

    let refusal = outcome
        .result
        .get("refusals")
        .and_then(|r| r.as_array())
        .and_then(|rs| rs.last())
        .cloned()
        .unwrap_or_else(|| json!({"error": "Refused"}));

    if json_mode {
        return respond(422, "application/json", &refusal.to_string());
    }

    let action = format!("/{domain_name}/{agg}/{cname}.html");
    html(422, &page(&format!("{domain_name}::{agg}.{cname}"), &form_body(domain_name, aggregate, command, &action, fields, raw, Some(&refusal))))
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
        // in the corpus (examples/banking/bluebook/banking.bluebook).
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
}
