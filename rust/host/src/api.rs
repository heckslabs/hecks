// THE CONSOLE'S `/api/*` SURFACE, IN THIS HOST — the JSON contract
// embryonaut_console's `web/app.rb` serves (its `/api/me`,
// `/api/presentation`, `/api/ui-schema`, `/api/schema`, `/api/:coll`
// routes), answered by the Rust Lambda that actually serves that app
// in production now (`web "Rust"`, web.rs).
//
// WHY THIS EXISTS AT ALL — the deployed host already refuses an
// unauthenticated `/api/...` request exactly the way the Ruby engine
// does (web.rs's `auth_gate`, PR #728: 401 + `{"error":
// "Unauthenticated","message":"sign in first"}`), but an AUTHENTICATED
// one fell straight through to this host's own `/<Domain>/<aggregate>`
// router and came back `404 no domain "api" loaded`. The refusal
// contract matched and the success contract didn't. This module is the
// success contract.
//
// SHAPES ARE THE RUBY ENGINE'S, KEY FOR KEY. Every response body here
// is what `app.rb`'s own `json(...)` would have produced for the same
// request — compact (never pretty-printed, unlike this host's own
// `/<Domain>/<aggregate>` JSON, which has no Ruby counterpart to agree
// with), the same error envelope (`{"error": ..., "message": ...}`),
// the same status codes. A client cannot tell which runtime answered,
// which is the whole point: index.html is served unchanged.
//
// ROUTING IS FLAT AND EXHAUSTIVE. `web::route` hands this module every
// path under `/api/`, and this module answers all of them — an
// unmatched one included, as a JSON 404 rather than by falling through
// to a renderer that would answer HTML. Sinatra's own unmatched-route
// 404 carries its default HTML page with a `json` content type (its
// `before` filter sets the header, its 404 handler doesn't); a JSON
// body is the honest version of the same status, and no client reads
// that body.

use crate::auth::Session;
use crate::presentation;
use crate::ui_schema;
use crate::web::respond;
use serde_json::{json, Value};
use tokio::sync::Mutex;
use tokio_postgres::Client;

/// Every `/api/...` request, answered. `session` is always `Some` in
/// production — `web::route` runs `auth_gate` first, which refuses an
/// unauthenticated JSON request with the Ruby engine's own 401 before
/// this module is reached — but it is threaded through rather than
/// unwrapped, because `/api/me` is precisely the route whose Ruby
/// counterpart (`json(session[:member] || {})`) also has an
/// empty-session branch.
pub async fn route(domain_ir: &Value, method: &str, path: &str, session: Option<&Session>, client: &Mutex<Client>) -> Value {
    match (method, path) {
        ("GET", "/api/me") => ok(&me(session)),

        // THE WHOLE UI, DERIVED — nav, columns, field shapes,
        // transitions, create forms, merged with whatever the config
        // adds. Read fresh every call, same as `/api/presentation`
        // below and for the same reason: a Settings-screen save has to
        // be visible on this app's very next request, not after a
        // restart.
        ("GET", "/api/ui-schema") => match presentation::load(client).await {
            Ok(config) => ok(&ui_schema::build(domain_ir, &config)),
            Err(e) => internal_error(&e.to_string()),
        },

        // EVERY REAL AGGREGATE, ITS REAL LIFECYCLE STATES, EVERY REAL
        // QUERY — a pure structural fact with no presentation opinion
        // in it, which the Settings screen's own list_query picker and
        // the table's live query picker both read.
        ("GET", "/api/schema") => match presentation::load(client).await {
            Ok(config) => ok(&ui_schema::schema(domain_ir, &config)),
            Err(e) => internal_error(&e.to_string()),
        },

        // Read fresh every call, never memoized — a Settings-screen
        // save has to be visible on the very next request, which is
        // the same reason app.rb calls `PresentationConfig.load` per
        // request rather than caching it in a constant.
        ("GET", "/api/presentation") => match presentation::load(client).await {
            Ok(config) => ok(&config),
            Err(e) => internal_error(&e.to_string()),
        },

        ("PUT", "/api/presentation") => not_implemented(PRESENTATION_WRITE_REFUSAL),

        _ => not_found(&format!("no API route for {method} {path}")),
    }
}

/// `GET /api/me` — `json(session[:member] || {})`, and
/// `session[:member]` is exactly what the consuming app's own
/// access-control adapter builds (`session_for`, embryonaut_access_
/// control.rb): `{"email", "name", "identity_id", "role"}`, in that
/// order. This host's own `Session` (auth.rs) already carries those
/// four fields and nothing else, because it was ported from that same
/// adapter — so this is a rename-free projection, not a translation.
///
/// index.html reads `me.name` and `me.role` only, and treats a body
/// with no `name` as "don't render the signed-in banner" — which is
/// what makes `{}` (Ruby's own no-session branch) a real, handled
/// answer rather than a broken one.
fn me(session: Option<&Session>) -> Value {
    let Some(session) = session else { return json!({}) };
    json!({
        "email": session.email,
        "name": session.name,
        "identity_id": session.identity_id,
        "role": session.role,
    })
}

// PUT /api/presentation IS DELIBERATELY NOT PORTED, AND SAYS SO.
//
// The Ruby engine's write path (`PresentationConfig.save!`) validates
// the whole submitted config against the live domain IR and then
// dispatches a dozen real `ConsoleSettings::*` commands — Declare,
// SetTone, SetAttention, ReplaceColumns, ReplaceDetailFields,
// ReplacePreconditions, ReplaceStats — through a runtime that has that
// chapter booted. This host does not have it booted and cannot: its
// `.wasm` kernel is the consuming domain's own, and ConsoleSettings
// has never been compiled into it (the consuming app pins that chapter
// to Ruby's Postgres adapter permanently — see presentation.rs's own
// header for why, in the app's own words).
//
// So the write would have to be one of: (a) hand-rolled SQL appending
// to Ruby's era journal and upserting its head snapshot, with the
// aggregate's own invariants — `tone` is a `one_of`, a state must be
// Declared before it is styled — simply not run; (b) a second store
// (S3, a config table) that Ruby's own console would then not read,
// splitting one config in two; or (c) compiling ConsoleSettings into
// this domain's kernel and migrating the existing rows into this
// crate's flat journal, which is a real deployment decision with a
// data migration attached, not a code change.
//
// (a) and (b) are both "write it somewhere and hope" — this file
// refuses instead. The READ path above is complete and live, so every
// console screen that only READS presentation config works here
// today; only the Settings screen's save does not, and it says which
// of the three decisions is outstanding rather than 404-ing as if the
// route had never existed.
const PRESENTATION_WRITE_REFUSAL: &str =
    "this host serves the console's presentation config read-only: it has no ConsoleSettings kernel to \
     dispatch StateStyle/Collection/Overview commands through, and writing the rows behind its back would \
     skip the invariants those commands enforce. Save from the Ruby console engine, or decide to move \
     ConsoleSettings into this domain's own kernel.";

// ---- response envelopes — app.rb's own `json`/`halt` shapes ---------

/// `json(data)` — `JSON.generate`, compact.
fn ok(body: &Value) -> Value {
    respond(200, "application/json", &body.to_string())
}

/// Every "that doesn't exist" case in the Ruby engine surfaces as
/// `Runtime::NotFound`, which its own `error` handler renders as a 404
/// with this envelope.
pub(crate) fn not_found(message: &str) -> Value {
    refusal(404, "NotFound", message)
}

/// `error do ... status 500; json({error: "InternalError", ...})` —
/// app.rb's own catch-all.
pub(crate) fn internal_error(message: &str) -> Value {
    refusal(500, "InternalError", message)
}

fn not_implemented(message: &str) -> Value {
    refusal(501, "NotImplemented", message)
}

pub(crate) fn refusal(status: u16, error: &str, message: &str) -> Value {
    respond(status, "application/json", &json!({"error": error, "message": message}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> Session {
        Session {
            identity_id: "11111111-2222-3333-4444-555555555555".to_string(),
            email: "chris@example.com".to_string(),
            name: "Chris".to_string(),
            role: Some("Admin".to_string()),
        }
    }

    fn body(response: &Value) -> Value {
        serde_json::from_str(response["body"].as_str().expect("a JSON body")).expect("valid JSON")
    }

    // app.rb: `get "/api/me" { json(session[:member] || {}) }`, where
    // session[:member] is embryonaut_access_control.rb's own
    // `{ "email" =>, "name" =>, "identity_id" =>, "role" => }`.
    #[test]
    fn me_is_the_ruby_engines_own_member_hash() {
        assert_eq!(
            me(Some(&session())),
            json!({
                "email": "chris@example.com",
                "name": "Chris",
                "identity_id": "11111111-2222-3333-4444-555555555555",
                "role": "Admin"
            })
        );
    }

    // A Member with a session but no granted role reads `role: null`,
    // not a missing key — Ruby's own hash always carries all four keys
    // (`role` comes back nil when Governance holds no grant and the
    // aggregate's own field is unset).
    #[test]
    fn me_keeps_a_null_role_rather_than_dropping_the_key() {
        let mut session = session();
        session.role = None;
        assert_eq!(me(Some(&session))["role"], Value::Null);
    }

    #[test]
    fn me_with_no_session_is_the_empty_object_ruby_answers() {
        assert_eq!(me(None), json!({}));
    }

    #[test]
    fn an_unknown_api_route_is_a_json_404_not_an_html_one() {
        let response = not_found("no API route for GET /api/nope/nope/nope");
        assert_eq!(response["statusCode"], 404);
        assert_eq!(response["headers"]["content-type"], "application/json");
        assert_eq!(body(&response)["error"], "NotFound");
    }

    // The refusal envelope every non-2xx answer in this module shares,
    // pinned against app.rb's own `json({ error:, message: })`.
    #[test]
    fn a_refusal_carries_exactly_error_and_message() {
        let response = refusal(422, "PreconditionFailed", "the proposal hasn't been accepted yet");
        assert_eq!(response["statusCode"], 422);
        assert_eq!(
            response["body"],
            r#"{"error":"PreconditionFailed","message":"the proposal hasn't been accepted yet"}"#
        );
    }

    #[test]
    fn the_presentation_write_route_refuses_in_its_own_words() {
        let response = not_implemented(PRESENTATION_WRITE_REFUSAL);
        assert_eq!(response["statusCode"], 501);
        assert_eq!(body(&response)["error"], "NotImplemented");
        assert!(
            body(&response)["message"].as_str().expect("a message").contains("ConsoleSettings"),
            "the refusal has to name what is missing: {response}"
        );
    }
}
