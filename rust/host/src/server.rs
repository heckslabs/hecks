// **The HTTP server, for AWS Fargate** — `HECKS_SERVE_MODE=1` (main.rs's
// own top-of-`main` check) runs this instead of `lambda_runtime::run`,
// so a domain deployed via `deployed_to("AwsFargate")` (fargate.rb)
// answers the plain HTTP its generated ALB/target group already expects,
// rather than hanging forever waiting for a Lambda Runtime API that
// doesn't exist in a container. Every boot step above main.rs's own
// mode check (secrets, Postgres/TLS connect, schema setup, IR load, the
// era-minting/lineage sequence) is unchanged and shared by both modes —
// this module only replaces how a request *arrives*.
//
// `dispatch_body` below is the exact per-invocation logic
// `lambda_runtime::run`'s own `service_fn` closure used to inline
// (web::render first, then `{"read"}`, then verb/role/to/with/args) —
// factored out so neither caller repeats it: the Lambda closure now
// just unwraps its `LambdaEvent` and calls this; the axum fallback
// route below reads the request body and calls the identical function.
// One generator, read from what a request actually carries, not two
// hand-maintained copies of the same dispatch decision tree.
//
// **Concurrency** — this server can genuinely receive overlapping
// requests (that's the whole point: fast sidecar-to-sidecar networking
// inside one ECS task, awsvpc-shared `localhost`). `dispatch_body` takes
// the identical `&Mutex<Client>` `dispatch::handle`/`dispatch::read`
// already required before this file existed — see dispatch.rs's own
// comment on `handle`'s locking, which already anticipated exactly this
// ("if this process is ever invoked concurrently in-process ... nothing
// in this crate depends on [one-event-at-a-time] staying true"). That
// mutex already serializes every write-path call (`handle`) end to end,
// including the wasm execution nested inside it, onto the one Postgres
// connection this process holds; concurrent requests queue for it
// rather than corrupting anything. `dispatch::read`/`dispatch::query`
// hold it only for two lightweight snapshot queries before dropping it
// to run wasm, which is safe to do genuinely concurrently — wasmtime's
// `Engine`/`Module` are `Arc`-wrapped and documented safe to instantiate
// from many threads at once (wasm_runner.rs's own cache), each call
// getting a fresh `Store`. No new locking was added for Fargate: the
// existing one already covers the one thing that needed it (never
// interleaving statements on a single shared connection), and a
// connection-pool-based upgrade to true DB-level parallelism is a
// separate, larger change to every call site that takes `&Mutex<Client>`
// today (auth.rs, api.rs, web.rs, checkout.rs, journal.rs, mint.rs,
// approval.rs, dispatch.rs itself) — left as a follow-up, not bundled
// here.

use crate::dispatch;
use crate::journal::LineageConfig;
use crate::lambda_client::{AwsLambdaInvoker, LambdaInvoker};
use crate::log;
use crate::web;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get};
use axum::Router;
use lambda_runtime::Error;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_postgres::Client;

/// The whole per-request dispatch decision, shared verbatim between the
/// Lambda custom-runtime path (main.rs's own `service_fn` closure) and
/// the axum fallback route below. `body` is already-parsed JSON, shaped
/// one of three ways, checked in this order:
///
/// 1. A Function-URL/API-Gateway-v2 HTTP event
///    (`requestContext.http`/`rawPath` present) — the public web UI,
///    resolved by `web::render` and returned as its own
///    `{"statusCode", "headers", "body", ...}` envelope.
/// 2. `{"read": true}` — the kernel's own current-state read, no verb.
/// 3. Otherwise, a command: `verb` plus one of `to`/`with` (routed),
///    `with` alone (facts-only), or legacy `args` — the same shape a
///    single entry of the kernel's own `{"steps": [...]}` array already
///    has.
pub async fn dispatch_body(
    body: Value,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Result<Value, Error> {
    if let Some(response) = web::render(&body, client, wasm_path, config, invoker).await {
        return Ok(response);
    }

    if body.get("read").and_then(|v| v.as_bool()) == Some(true) {
        // `{e:#}` — see main.rs's own prior comment on this exact
        // mapping: a bare `tokio_postgres` error's Display is the
        // uninformative literal "db error"; anyhow's alternate Display
        // walks `source()` to the real message underneath it.
        let result = dispatch::read(client, wasm_path).await.map_err(|e| format!("{e:#}"))?;
        return Ok(result);
    }

    let verb = body
        .get("verb")
        .and_then(|v| v.as_str())
        .ok_or("event missing \"verb\"")?
        .to_string();
    let role = body.get("role").and_then(|v| v.as_str()).map(|s| s.to_string());

    let outcome = if let Some(to) = body.get("to").cloned() {
        if body.get("args").is_some() {
            return Err("cannot combine to/with with legacy args".into());
        }
        let facts = body.get("with").cloned().unwrap_or_else(|| serde_json::json!({}));
        dispatch::handle_routed(client, wasm_path, &verb, to, facts, role.as_deref(), config, invoker)
            .await
            .map_err(|e| format!("{e:#}"))?
    } else if let Some(facts) = body.get("with").cloned() {
        if body.get("args").is_some() {
            return Err("cannot combine \"with\" with legacy args".into());
        }
        dispatch::handle_facts(client, wasm_path, &verb, facts, role.as_deref(), config, invoker)
            .await
            .map_err(|e| format!("{e:#}"))?
    } else {
        let args = body.get("args").cloned().unwrap_or_else(|| serde_json::json!({}));
        dispatch::handle(client, wasm_path, &verb, args, role.as_deref(), config, invoker)
            .await
            .map_err(|e| format!("{e:#}"))?
    };
    Ok(outcome.result)
}

/// Everything `dispatch_body` needs, `Arc`-shared with axum's own
/// per-request handler cloning — the identical set main.rs already
/// builds once at boot and clones into every Lambda invocation's own
/// closure.
#[derive(Clone)]
pub struct ServerState {
    pub client: Arc<Mutex<Client>>,
    pub wasm_path: Arc<PathBuf>,
    pub lineage_config: Arc<LineageConfig>,
    pub invoker: Arc<AwsLambdaInvoker>,
}

/// Binds `0.0.0.0:$PORT` (`PORT`, matching `fargate.rb`'s own generated
/// container `Environment` — falls back to 8080, the same default
/// `deployed_to("AwsFargate")`'s own `port` setting uses, purely for
/// convenience running this outside a real deploy) and serves forever.
///
/// Two routes: `GET /` is a bare, dispatch-free `200 OK` — the ALB
/// health check `fargate.rb` already targets at this exact path/port,
/// answered without touching the Postgres mutex or wasmtime at all, so
/// a backlog of real dispatch requests never delays it. Everything else
/// (any other path, or any other method on `/`) goes through
/// `dispatch_body` — see this module's own header for why the
/// translation into JSON is a plain "parse the request body" rather
/// than reconstructing a Function-URL event: this is the same wire
/// shape `Adapters::Lambda::Client#dispatch` (Ruby) already sends over
/// `lambda:InvokeFunction`, so a sidecar container in a future shared
/// ECS task can send this Fargate-hosted domain the identical payload
/// over plain `localhost` HTTP instead, unchanged. A caller that does
/// send a full Function-URL-shaped body (`requestContext.http` present)
/// still reaches the web UI through `dispatch_body`'s own first check —
/// nothing here has to special-case that path.
pub async fn serve(state: ServerState) -> Result<(), Error> {
    let port: u16 = std::env::var("PORT").ok().and_then(|v| v.parse().ok()).unwrap_or(8080);

    let app = Router::new()
        .route("/", get(health))
        .fallback(any(dispatch_route))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

/// The ALB health check — cheap and fast on purpose, no dispatch logic
/// behind it at all (this module's own header has the full reasoning).
async fn health() -> StatusCode {
    StatusCode::OK
}

/// Runs one request and writes its access-log line — method, path (never
/// the query string: it can carry OAuth codes and tokens), status and
/// duration.
async fn dispatch_route(State(state): State<ServerState>, method: Method, uri: Uri, headers: HeaderMap, body: Bytes) -> Response {
    let started = std::time::Instant::now();
    let path = uri.path().to_string();
    let verb = method.as_str().to_string();
    let response = route_request(state, method, uri, headers, body).await;
    let status = response.status().as_u16();
    let fields = serde_json::json!({
        "method": verb, "path": path, "status": status, "ms": started.elapsed().as_millis() as u64,
    });
    if status >= 500 {
        log::error("request", fields);
    } else {
        log::info("request", fields);
    }
    response
}

async fn route_request(state: ServerState, method: Method, uri: Uri, headers: HeaderMap, body: Bytes) -> Response {
    let parsed: Value = if body.is_empty() {
        serde_json::json!({})
    } else {
        match serde_json::from_slice(&body) {
            Ok(value) => value,
            Err(e) => return (StatusCode::BAD_REQUEST, format!("invalid JSON body: {e}")).into_response(),
        }
    };

    // A real HTTP client — a browser through the ALB, or the site's own
    // server-to-server checkout call — gets none of a Lambda Function
    // URL's automatic wrapping into `{"requestContext": {"http": ...},
    // "rawPath", ...}`: that translation is API Gateway's own job,
    // upstream of `lambda_runtime::run`, and nothing stands in for it
    // here. Anything that ISN'T already one of `dispatch_body`'s own
    // three recognized shapes (checked by `is_internal_dispatch_shape`
    // below) synthesizes that same envelope from the real request this
    // handler actually received, so `web::render`/`checkout_route` see
    // the identical shape they already do behind a real Function URL.
    // A body that already matches one of the three shapes — the
    // sidecar-to-sidecar internal RPC protocol this module's own header
    // documents — passes through completely unchanged; this can only
    // ever turn a previously-guaranteed `"event missing \"verb\""`
    // error into a real route, never break an existing one.
    let envelope = if is_internal_dispatch_shape(&parsed) {
        parsed
    } else {
        synthesize_function_url_envelope(&method, &uri, &headers, &body)
    };

    match dispatch_body(envelope, &state.client, &state.wasm_path, &state.lineage_config, state.invoker.as_ref()).await {
        Ok(value) => value_to_response(value),
        Err(e) => {
            log::error("dispatch_failed", serde_json::json!({ "error": format!("{e}") }));
            (StatusCode::INTERNAL_SERVER_ERROR, axum::Json(serde_json::json!({ "error": format!("{e}") }))).into_response()
        }
    }
}

/// Whether `value` already matches one of `dispatch_body`'s own three
/// recognized shapes (its own doc comment has the full list) — a
/// Function-URL/API-Gateway-v2 event, `{"read": true}`, or a verb
/// command. Anything else (including a bare `{}`, which today only
/// ever produces `"event missing \"verb\""`) is real REST traffic that
/// needs `synthesize_function_url_envelope` instead.
fn is_internal_dispatch_shape(value: &Value) -> bool {
    value.get("requestContext").is_some() || value.get("read").is_some() || value.get("verb").is_some()
}

/// Rebuilds the exact envelope shape a real Lambda Function URL
/// invocation already produces automatically (the one `web::render`'s
/// own header documents reading), from the raw axum request parts —
/// see `dispatch_route`'s own comment on why this only runs for a body
/// that isn't already the internal dispatch protocol.
fn synthesize_function_url_envelope(method: &Method, uri: &Uri, headers: &HeaderMap, body: &Bytes) -> Value {
    let mut header_map = serde_json::Map::new();
    for (name, value) in headers.iter() {
        if let Ok(value) = value.to_str() {
            header_map.insert(name.as_str().to_ascii_lowercase(), Value::String(value.to_string()));
        }
    }

    serde_json::json!({
        "requestContext": { "http": { "method": method.as_str() } },
        "rawPath": uri.path(),
        "rawQueryString": uri.query().unwrap_or(""),
        "headers": header_map,
        "body": String::from_utf8_lossy(body).into_owned(),
        "isBase64Encoded": false,
    })
}

/// Translates `dispatch_body`'s own JSON result into a real HTTP
/// response. Two distinct shapes reach here, disambiguated by whether a
/// top-level `"statusCode"` key exists at all — no ordinary dispatch
/// outcome (the kernel's own `{"instances","events","refusals",...}`,
/// or a read's identical shape) ever has one:
///
/// - **Present**: `web::render`'s own Function-URL response envelope
///   (`respond`/`redirect` in web.rs) — unwrapped into a genuine status
///   code, headers, and body, the one translation step left after
///   removing the AWS-specific envelope Lambda Function URLs require.
/// - **Absent**: a raw dispatch/read outcome, wrapped as `200 OK` JSON
///   verbatim — the exact payload a direct `lambda:InvokeFunction`
///   caller already receives today, now also reachable over plain HTTP.
fn value_to_response(value: Value) -> Response {
    let Some(status_code) = value.get("statusCode").and_then(|v| v.as_u64()) else {
        return (StatusCode::OK, axum::Json(value)).into_response();
    };
    let status = StatusCode::from_u16(status_code as u16).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);

    let mut headers = HeaderMap::new();
    if let Some(header_obj) = value.get("headers").and_then(|h| h.as_object()) {
        for (name, header_value) in header_obj {
            let Some(header_value) = header_value.as_str() else { continue };
            if let (Ok(name), Ok(header_value)) = (HeaderName::from_bytes(name.as_bytes()), HeaderValue::from_str(header_value)) {
                headers.insert(name, header_value);
            }
        }
    }
    // Function-URL response's own `cookies` — a bare array of raw
    // "name=value; ..." Set-Cookie strings (web.rs's own
    // `redirect_with_cookie`), not folded into `headers` above; each
    // becomes its own `Set-Cookie` header the way a real Function URL
    // invocation already turns this same array into.
    if let Some(cookies) = value.get("cookies").and_then(|c| c.as_array()) {
        for cookie in cookies {
            if let Some(cookie) = cookie.as_str() {
                if let Ok(header_value) = HeaderValue::from_str(cookie) {
                    headers.append(axum::http::header::SET_COOKIE, header_value);
                }
            }
        }
    }

    let raw_body = value.get("body").and_then(|v| v.as_str()).unwrap_or("");
    let body_bytes = if value.get("isBase64Encoded").and_then(|v| v.as_bool()) == Some(true) {
        web::base64_decode(raw_body)
    } else {
        raw_body.as_bytes().to_vec()
    };

    (status, headers, body_bytes).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_function_url_shaped_body_is_recognized_as_internal_dispatch() {
        assert!(is_internal_dispatch_shape(&serde_json::json!({"requestContext": {"http": {"method": "GET"}}})));
    }

    #[test]
    fn a_bare_read_body_is_recognized_as_internal_dispatch() {
        assert!(is_internal_dispatch_shape(&serde_json::json!({"read": true})));
    }

    #[test]
    fn a_verb_command_body_is_recognized_as_internal_dispatch() {
        assert!(is_internal_dispatch_shape(&serde_json::json!({"verb": "Register", "args": {}})));
    }

    #[test]
    fn a_plain_rest_payload_is_not_internal_dispatch() {
        assert!(!is_internal_dispatch_shape(&serde_json::json!({"email": "a@example.com"})));
    }

    #[test]
    fn an_empty_body_is_not_internal_dispatch() {
        assert!(!is_internal_dispatch_shape(&serde_json::json!({})));
    }

    // The exact case that was silently broken before this fix: a real
    // REST client's plain POST, with no Function-URL wrapping at all —
    // this must synthesize the same shape `web::render`/`checkout_route`
    // already read behind a real Function URL, not error out on a
    // missing "verb".
    #[test]
    fn synthesizes_a_function_url_envelope_from_a_real_rest_request() {
        let method = Method::POST;
        let uri: Uri = "/registrations?utm_source=test".parse().unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(HeaderName::from_static("stripe-signature"), HeaderValue::from_static("t=1,v1=abc"));
        headers.insert(HeaderName::from_static("content-type"), HeaderValue::from_static("application/json"));
        let body = Bytes::from_static(br#"{"event_id":"ci-verification-test"}"#);

        let envelope = synthesize_function_url_envelope(&method, &uri, &headers, &body);

        assert_eq!(envelope["requestContext"]["http"]["method"], "POST");
        assert_eq!(envelope["rawPath"], "/registrations");
        assert_eq!(envelope["rawQueryString"], "utm_source=test");
        assert_eq!(envelope["headers"]["stripe-signature"], "t=1,v1=abc");
        assert_eq!(envelope["headers"]["content-type"], "application/json");
        assert_eq!(envelope["body"], r#"{"event_id":"ci-verification-test"}"#);
        assert_eq!(envelope["isBase64Encoded"], false);
        assert!(is_internal_dispatch_shape(&envelope), "the synthesized envelope must itself be recognized on a second pass");
    }

    #[test]
    fn synthesizes_an_empty_query_string_when_the_request_has_none() {
        let method = Method::GET;
        let uri: Uri = "/login".parse().unwrap();
        let headers = HeaderMap::new();
        let body = Bytes::new();

        let envelope = synthesize_function_url_envelope(&method, &uri, &headers, &body);

        assert_eq!(envelope["rawQueryString"], "");
        assert_eq!(envelope["body"], "");
    }
}
