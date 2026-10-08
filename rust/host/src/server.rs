//! HTTP server for AWS Fargate (`HECKS_SERVE_MODE=1`): the axum fallback route below shares
//! `dispatch_body` with the Lambda custom-runtime path, so neither repeats the other's logic.

use crate::dispatch;
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use crate::log;
use crate::rate_limit::{self, RateLimits, Verdict};
use crate::wasm_runner;
use crate::web;
use axum::body::Bytes;
use axum::extract::{ConnectInfo, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, Method, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::{any, get};
use axum::Router;
use lambda_runtime::Error;
use serde_json::Value;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::Mutex;
use tokio_postgres::Client;

/// The per-request dispatch decision, shared between the Lambda custom-runtime path and the
/// axum fallback route below. `body` is already-parsed JSON in one of its recognized shapes.
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
        // `{e:#}`: anyhow's alternate Display walks `source()` to the real message,
        // where a bare `tokio_postgres` error's Display is just "db error".
        let result = dispatch::read(client, wasm_path).await.map_err(|e| format!("{e:#}"))?;
        return Ok(result);
    }

    // A query step reads current state and writes nothing to the journal.
    if body.get("query").is_some() {
        return Ok(crate::query_step::answer(&body, crate::ir::ir(), &config.domain, client, wasm_path).await?);
    }

    let verb = body
        .get("verb")
        .and_then(|v| v.as_str())
        .ok_or("event missing \"verb\"")?
        .to_string();
    let role = body.get("role").and_then(|v| v.as_str()).map(|s| s.to_string());
    // Who the caller is, for Governance. Honored only where the internal protocol is: from this
    // host's own peers (`trusts_internal_dispatch`), never from a public caller.
    let actor_id = body.get("actor_id").and_then(|v| v.as_str()).map(|s| s.to_string());
    let caller = dispatch::Caller { role: role.as_deref(), actor_id: actor_id.as_deref() };

    let outcome = if let Some(to) = body.get("to").cloned() {
        if body.get("args").is_some() {
            return Err("cannot combine to/with with legacy args".into());
        }
        let facts = body.get("with").cloned().unwrap_or_else(|| serde_json::json!({}));
        dispatch::handle_routed_as(client, wasm_path, &verb, to, facts, caller, config, invoker)
            .await
            .map_err(|e| format!("{e:#}"))?
    } else if let Some(facts) = body.get("with").cloned() {
        if body.get("args").is_some() {
            return Err("cannot combine \"with\" with legacy args".into());
        }
        dispatch::handle_facts_as(client, wasm_path, &verb, facts, caller, config, invoker)
            .await
            .map_err(|e| format!("{e:#}"))?
    } else {
        let args = body.get("args").cloned().unwrap_or_else(|| serde_json::json!({}));
        dispatch::handle_as(client, wasm_path, &verb, args, caller, config, invoker)
            .await
            .map_err(|e| format!("{e:#}"))?
    };
    Ok(outcome.result)
}

/// Everything `dispatch_body` needs, `Arc`-shared for axum's per-request handler cloning.
/// `client`'s mutex serializes every write onto the one Postgres connection this process holds.
#[derive(Clone)]
pub struct ServerState {
    pub client: Arc<Mutex<Client>>,
    pub wasm_path: Arc<PathBuf>,
    pub lineage_config: Arc<LineageConfig>,
    pub invoker: Arc<dyn LambdaInvoker>,
    pub limits: Arc<RateLimits>,
}

/// The document `GET /version` serves: era, IR hash, and build — all fixed for the life of
/// the process, so this is built once at boot. Carries no secrets.
pub fn version_body(era: &str, ir_hash: &str, build_env: Option<&str>) -> Value {
    let build = build_env.filter(|v| !v.is_empty()).unwrap_or(env!("CARGO_PKG_VERSION"));
    serde_json::json!({ "era": era, "ir_hash": ir_hash, "build": build })
}

/// `GET /version` as its own router, merged ahead of the dispatch fallback: a matched
/// request answers a clone of the boot-time document, never touching auth or dispatch.
pub fn version_router(body: Value) -> Router {
    let body = Arc::new(body);
    Router::new().route("/version", get(move || std::future::ready(axum::Json(body.as_ref().clone()))))
}

/// Compiles the domain's wasm module, then binds `$PORT` (falls back to 8080) and serves
/// forever. Nothing listens until the compile finishes, so the health check never lies.
pub async fn serve(state: ServerState, version: Value) -> Result<(), Error> {
    let port: u16 = std::env::var("PORT").ok().and_then(|v| v.parse().ok()).unwrap_or(8080);

    warm_wasm(&state.wasm_path).await;

    let phase = log::phase_with("serve_start", serde_json::json!({ "port": port }));
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    phase.end();
    serve_on(listener, state, version).await
}

/// The router and serve loop over an already-bound `listener`, split out so a test can
/// run the real service on an ephemeral port.
async fn serve_on(listener: tokio::net::TcpListener, state: ServerState, version: Value) -> Result<(), Error> {
    let app = Router::new()
        .route("/", get(health))
        .fallback(any(dispatch_route))
        .with_state(state)
        .merge(version_router(version));

    // The connect info is the TCP peer, which `rate_limit` needs to tell a visitor from a proxy.
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await?;
    Ok(())
}

/// Compiles the domain's wasm module before the host listens, so a request right after
/// boot finds it ready. A module that fails to compile is logged, not fatal.
async fn warm_wasm(wasm_path: &Arc<PathBuf>) {
    let phase = log::phase("wasm_warm");
    let path = Arc::clone(wasm_path);
    match tokio::task::spawn_blocking(move || wasm_runner::warm(&path)).await {
        Ok(Ok(())) => {
            phase.end();
        }
        Ok(Err(e)) => log::error("wasm_warm_failed", serde_json::json!({ "error": format!("{e:#}") })),
        Err(e) => log::error("wasm_warm_failed", serde_json::json!({ "error": format!("{e}") })),
    }
}

/// The ALB health check — no dispatch logic behind it, so a request backlog never delays it.
async fn health() -> StatusCode {
    StatusCode::OK
}

/// Runs one request and logs it: method, path (never the query string, which can carry
/// OAuth codes/tokens), status, and duration.
async fn dispatch_route(
    State(state): State<ServerState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let started = std::time::Instant::now();
    let path = uri.path().to_string();
    let verb = method.as_str().to_string();
    let response = route_request(state, peer, method, uri, headers, body).await;
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

async fn route_request(state: ServerState, peer: SocketAddr, method: Method, uri: Uri, headers: HeaderMap, body: Bytes) -> Response {
    let envelope = match admit(&state.limits, peer, &method, &uri, &headers, &body) {
        Ok(envelope) => envelope,
        Err(refusal) => return *refusal,
    };

    match dispatch_body(envelope, &state.client, &state.wasm_path, &state.lineage_config, state.invoker.as_ref()).await {
        Ok(value) => value_to_response(value),
        Err(e) => {
            log::error("dispatch_failed", serde_json::json!({ "error": format!("{e}") }));
            (StatusCode::INTERNAL_SERVER_ERROR, axum::Json(serde_json::json!({ "error": format!("{e}") }))).into_response()
        }
    }
}

/// Turns a raw HTTP request into `dispatch_body`'s envelope, or into the response that ends
/// it first: a `400` for non-JSON, a `429` for a caller over a public route's rate limit.
fn admit(limits: &RateLimits, peer: SocketAddr, method: &Method, uri: &Uri, headers: &HeaderMap, body: &Bytes) -> Result<Value, Box<Response>> {
    let parsed: Value = if body.is_empty() {
        serde_json::json!({})
    } else {
        match serde_json::from_slice(body) {
            Ok(value) => value,
            Err(e) => return Err(Box::new((StatusCode::BAD_REQUEST, format!("invalid JSON body: {e}")).into_response())),
        }
    };

    // A real HTTP client (browser via the ALB, or a server-to-server call) carries none of a
    // Function URL's automatic wrapping, so anything not already one of `dispatch_body`'s
    // recognized shapes gets that envelope synthesized from the real request instead.
    // The internal shapes carry a caller's own claim of `role` with no session check, so
    // they're honored only from a peer on this host (the task's own sidecar); everyone
    // else — the load balancer, i.e. the public internet — gets an ordinary request
    // envelope for the path it actually hit.
    let envelope = if trusts_internal_dispatch(peer) && is_internal_dispatch_shape(&parsed) {
        parsed
    } else {
        synthesize_function_url_envelope(method, uri, headers, body)
    };

    if let Some((route_method, route_path)) = envelope_route(&envelope) {
        if let Verdict::Limited { retry_after_secs } = limits.check(route_method, route_path, headers, Some(peer.ip())) {
            return Err(Box::new(rate_limit::too_many_requests(retry_after_secs)));
        }
    }
    Ok(envelope)
}

/// The method and path a Function-URL-shaped envelope names, or `None` for
/// the verb and read shapes, which carry no route.
fn envelope_route(envelope: &Value) -> Option<(&str, &str)> {
    let method = envelope.get("requestContext")?.get("http")?.get("method")?.as_str()?;
    let path = envelope.get("rawPath")?.as_str()?;
    Some((method, path))
}

/// Whether `peer` is on this host (loopback) — the only caller trusted with the internal
/// dispatch protocol. An IPv4 address mapped into IPv6 counts as the IPv4 it wraps.
fn trusts_internal_dispatch(peer: SocketAddr) -> bool {
    match peer.ip() {
        std::net::IpAddr::V4(addr) => addr.is_loopback(),
        std::net::IpAddr::V6(addr) => addr.is_loopback() || addr.to_ipv4_mapped().is_some_and(|mapped| mapped.is_loopback()),
    }
}

/// Whether `value` already matches one of `dispatch_body`'s recognized shapes; anything
/// else (including a bare `{}`) is real REST traffic needing `synthesize_function_url_envelope`.
fn is_internal_dispatch_shape(value: &Value) -> bool {
    value.get("requestContext").is_some()
        || value.get("read").is_some()
        || value.get("query").is_some()
        || value.get("verb").is_some()
}

/// Rebuilds the envelope shape a real Lambda Function URL invocation already produces
/// automatically, from the raw axum request parts.
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

/// Translates `dispatch_body`'s JSON result into a real HTTP response: `web::render`'s
/// Function-URL envelope when `statusCode` is present, else the raw outcome as `200` JSON.
fn value_to_response(value: Value) -> Response {
    let Some(status_code) = value.get("statusCode").and_then(|v| v.as_u64()) else {
        return (StatusCode::OK, axum::Json(value)).into_response();
    };
    // `try_from`, not `as u16`: 65736 would wrap to 200 and turn a handler's garbage into a success.
    let status = u16::try_from(status_code).ok().and_then(|code| StatusCode::from_u16(code).ok()).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);

    let mut headers = HeaderMap::new();
    if let Some(header_obj) = value.get("headers").and_then(|h| h.as_object()) {
        for (name, header_value) in header_obj {
            let Some(header_value) = header_value.as_str() else { continue };
            if let (Ok(name), Ok(header_value)) = (HeaderName::from_bytes(name.as_bytes()), HeaderValue::from_str(header_value)) {
                headers.insert(name, header_value);
            }
        }
    }
    // The Function-URL response's `cookies` array (raw "name=value; ..." strings) becomes
    // its own `Set-Cookie` header per entry, the way a real Function URL invocation does.
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
    fn a_declared_query_body_is_recognized_as_internal_dispatch() {
        // `dispatch_body` answers `{"query": ...}`, and the generated editor's list and picture
        // pickers ask it; without this a loopback caller was sent to the login page.
        assert!(is_internal_dispatch_shape(&serde_json::json!({"query": "Pictures::MediaItem.Pictures", "args": {}})));
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

    fn peer(text: &str) -> SocketAddr {
        text.parse().unwrap()
    }

    #[test]
    fn only_a_peer_on_this_host_is_trusted_with_the_internal_protocol() {
        for trusted in ["127.0.0.1:5000", "127.4.5.6:5000", "[::1]:5000", "[::ffff:127.0.0.1]:5000"] {
            assert!(trusts_internal_dispatch(peer(trusted)), "{trusted} is this host");
        }
        for outside in ["10.0.0.5:5000", "172.31.4.9:5000", "203.0.113.7:5000", "[2001:db8::1]:5000", "[::ffff:10.0.0.5]:5000"] {
            assert!(!trusts_internal_dispatch(peer(outside)), "{outside} is not this host");
        }
    }

    fn admitted(from: &str, path: &str, body: &str) -> Value {
        let uri: Uri = path.parse().unwrap();
        let body = Bytes::from(body.to_string());
        match admit(&limits_from(&[]), peer(from), &Method::POST, &uri, &HeaderMap::new(), &body) {
            Ok(envelope) => envelope,
            Err(_) => panic!("{from} POST {path} was refused before dispatch"),
        }
    }

    // The gap this closes: a public POST to any path the load balancer forwards carried
    // `{"verb": ..., "role": ...}` or `{"read": true}` straight to the kernel, with the
    // caller's own word for its role and no session check.
    #[test]
    fn a_verb_or_read_body_from_outside_this_host_is_an_ordinary_request_not_a_command() {
        for body in [r#"{"verb":"Approve","role":"admin"}"#, r#"{"read":true}"#, r#"{"query":"Pictures::MediaItem.Pictures","args":{}}"#] {
            let envelope = admitted("10.0.0.5:5000", "/webhooks/x", body);

            assert!(
                envelope.get("verb").is_none() && envelope.get("read").is_none() && envelope.get("query").is_none(),
                "{body} must not reach dispatch as a command"
            );
            assert_eq!(envelope["requestContext"]["http"]["method"], "POST");
            assert_eq!(envelope["rawPath"], "/webhooks/x");
            assert_eq!(envelope["body"], body);
        }
    }

    #[test]
    fn a_body_from_outside_this_host_cannot_name_a_different_path_than_the_one_it_hit() {
        let body = r#"{"requestContext":{"http":{"method":"GET"}},"rawPath":"/api/clients","headers":{"cookie":"session=forged"}}"#;
        let envelope = admitted("203.0.113.7:5000", "/webhooks/x", body);

        assert_eq!(envelope["rawPath"], "/webhooks/x");
        assert_eq!(envelope["requestContext"]["http"]["method"], "POST");
        assert!(envelope["headers"].get("cookie").is_none(), "headers come from the real request, not the body");
    }

    #[test]
    fn a_verb_or_read_body_from_this_host_still_reaches_dispatch_unchanged() {
        for body in [r#"{"verb":"Register","to":"r1","with":{}}"#, r#"{"read":true}"#, r#"{"query":"Banking::Customer.Suspended","args":{}}"#] {
            let envelope = admitted("127.0.0.1:5000", "/anything", body);

            assert_eq!(envelope, serde_json::from_str::<Value>(body).unwrap());
        }
    }

    // Pins a real REST client's plain POST, with no Function-URL wrapping: it must
    // synthesize the same shape `web::render`/`checkout_route` read, not error on a
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

    fn sample_version() -> Value {
        version_body("199b08", &"a".repeat(64), Some("build-42"))
    }

    // Serves `version_router` on an ephemeral port, the way the host serves
    // it, so a request travels the real HTTP stack.
    async fn serve_version(body: Value) -> std::net::SocketAddr {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, version_router(body)).await });
        addr
    }

    #[tokio::test]
    async fn version_answers_200_json_with_no_session() {
        let addr = serve_version(sample_version()).await;
        let response = reqwest::get(format!("http://{addr}/version")).await.unwrap();
        assert_eq!(response.status(), 200);
        let content_type = response.headers()["content-type"].to_str().unwrap().to_string();
        assert!(content_type.starts_with("application/json"), "got {content_type}");
        let body: Value = response.json().await.unwrap();
        assert_eq!(body, serde_json::json!({ "era": "199b08", "ir_hash": "a".repeat(64), "build": "build-42" }));
    }

    #[tokio::test]
    async fn version_era_is_a_non_empty_string() {
        let addr = serve_version(sample_version()).await;
        let body: Value = reqwest::get(format!("http://{addr}/version")).await.unwrap().json().await.unwrap();
        assert!(body["era"].as_str().is_some_and(|era| !era.is_empty()));
    }

    #[tokio::test]
    async fn version_is_get_only() {
        let addr = serve_version(sample_version()).await;
        let response = reqwest::Client::new().post(format!("http://{addr}/version")).send().await.unwrap();
        assert_eq!(response.status(), 405);
    }

    fn limits_from(pairs: &[(&str, &str)]) -> Arc<RateLimits> {
        let map: std::collections::HashMap<String, String> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        Arc::new(RateLimits::new(crate::rate_limit::Config::from_lookup(|name| map.get(name).cloned()).0))
    }

    async fn gate_only(
        State(limits): State<Arc<RateLimits>>,
        ConnectInfo(peer): ConnectInfo<SocketAddr>,
        method: Method,
        uri: Uri,
        headers: HeaderMap,
        body: Bytes,
    ) -> Response {
        match admit(&limits, peer, &method, &uri, &headers, &body) {
            Ok(_) => (StatusCode::OK, "admitted").into_response(),
            Err(refusal) => *refusal,
        }
    }

    // A disposable server on an ephemeral port: the real `admit` gate reading the real connection
    // peer, with an acknowledgement standing in for dispatch, which needs Postgres and wasm.
    async fn gated_server(limits: Arc<RateLimits>) -> SocketAddr {
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = Router::new().fallback(any(gate_only)).with_state(limits);
        tokio::spawn(async move { axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await });
        addr
    }

    async fn post(addr: SocketAddr, path: &str, forwarded_for: Option<&str>, body: &str) -> reqwest::Response {
        let mut request = reqwest::Client::new().post(format!("http://{addr}{path}")).body(body.to_string());
        if let Some(forwarded_for) = forwarded_for {
            request = request.header("x-forwarded-for", forwarded_for);
        }
        request.send().await.unwrap()
    }

    const SUBSCRIBE: &str = "/newsletter/subscribers";

    #[tokio::test]
    async fn a_burst_on_a_public_write_route_gets_429_with_retry_after_and_a_json_error() {
        let addr = gated_server(limits_from(&[("HECKS_RATE_LIMIT_SUBSCRIBE", "3")])).await;
        for attempt in 1..=3 {
            assert_eq!(post(addr, SUBSCRIBE, None, r#"{"email":"a@example.com"}"#).await.status(), 200, "request {attempt}");
        }

        let refused = post(addr, SUBSCRIBE, None, r#"{"email":"a@example.com"}"#).await;
        assert_eq!(refused.status(), 429);
        let retry_after: u64 = refused.headers()["retry-after"].to_str().unwrap().parse().unwrap();
        assert!((1..=3600).contains(&retry_after), "got {retry_after}");
        assert!(refused.headers()["content-type"].to_str().unwrap().starts_with("application/json"));
        let body: Value = refused.json().await.unwrap();
        assert_eq!(body, serde_json::json!({ "error": "too many requests, please try again later" }));
    }

    #[tokio::test]
    async fn registrations_are_limited_apart_from_subscribes() {
        let addr = gated_server(limits_from(&[("HECKS_RATE_LIMIT_SUBSCRIBE", "1"), ("HECKS_RATE_LIMIT_REGISTER", "2")])).await;
        assert_eq!(post(addr, SUBSCRIBE, None, "{}").await.status(), 200);
        assert_eq!(post(addr, SUBSCRIBE, None, "{}").await.status(), 429);

        assert_eq!(post(addr, "/registrations", None, "{}").await.status(), 200, "subscribe being spent leaves register alone");
        assert_eq!(post(addr, "/registrations", None, "{}").await.status(), 200);
        assert_eq!(post(addr, "/registrations", None, "{}").await.status(), 429);
    }

    #[tokio::test]
    async fn reads_and_other_routes_are_never_limited() {
        let addr = gated_server(limits_from(&[("HECKS_RATE_LIMIT_SUBSCRIBE", "1"), ("HECKS_RATE_LIMIT_REGISTER", "1")])).await;
        let client = reqwest::Client::new();
        for _ in 0..5 {
            assert_eq!(client.get(format!("http://{addr}{SUBSCRIBE}")).send().await.unwrap().status(), 200);
            assert_eq!(client.get(format!("http://{addr}/registrations/REG-1")).send().await.unwrap().status(), 200);
            assert_eq!(post(addr, "/webhooks/stripe", None, "{}").await.status(), 200);
            assert_eq!(post(addr, "/members", None, "{}").await.status(), 200);
        }
    }

    #[tokio::test]
    async fn a_spoofed_forwarded_header_does_not_buy_a_fresh_allowance() {
        // The test client is the peer at 127.0.0.1 and nothing trusts it, so every header is
        // typed by the caller and the count stays with the connection.
        let addr = gated_server(limits_from(&[("HECKS_RATE_LIMIT_SUBSCRIBE", "1")])).await;
        assert_eq!(post(addr, SUBSCRIBE, Some("1.1.1.1"), "{}").await.status(), 200);
        for spoof in ["2.2.2.2", "3.3.3.3", "4.4.4.4, 5.5.5.5"] {
            assert_eq!(post(addr, SUBSCRIBE, Some(spoof), "{}").await.status(), 429, "{spoof}");
        }
    }

    #[tokio::test]
    async fn behind_a_trusted_proxy_each_visitor_has_their_own_allowance() {
        let addr = gated_server(limits_from(&[("HECKS_RATE_LIMIT_SUBSCRIBE", "1"), ("HECKS_TRUSTED_PROXIES", "127.0.0.1")])).await;
        assert_eq!(post(addr, SUBSCRIBE, Some("1.1.1.1, 203.0.113.7"), "{}").await.status(), 200);
        assert_eq!(post(addr, SUBSCRIBE, Some("2.2.2.2, 203.0.113.7"), "{}").await.status(), 429, "same visitor, new typed entry");
        assert_eq!(post(addr, SUBSCRIBE, Some("2.2.2.2, 198.51.100.4"), "{}").await.status(), 200, "a different visitor");
    }

    #[tokio::test]
    async fn a_body_that_carries_the_function_url_shape_counts_against_the_route_it_names() {
        let addr = gated_server(limits_from(&[("HECKS_RATE_LIMIT_REGISTER", "1")])).await;
        let envelope = r#"{"requestContext":{"http":{"method":"POST"}},"rawPath":"/registrations","body":"{}"}"#;
        assert_eq!(post(addr, "/anything", None, envelope).await.status(), 200);
        assert_eq!(post(addr, "/anything", None, envelope).await.status(), 429);
        assert_eq!(post(addr, "/registrations", None, "{}").await.status(), 429, "the same budget as the real path");
    }

    #[tokio::test]
    async fn a_body_that_is_not_json_is_a_400_and_costs_no_allowance() {
        let addr = gated_server(limits_from(&[("HECKS_RATE_LIMIT_SUBSCRIBE", "1")])).await;
        for _ in 0..3 {
            assert_eq!(post(addr, SUBSCRIBE, None, "not json").await.status(), 400);
        }
        assert_eq!(post(addr, SUBSCRIBE, None, "{}").await.status(), 200);
    }

    #[tokio::test]
    async fn turning_the_limits_off_lets_every_request_through() {
        let addr = gated_server(limits_from(&[("HECKS_RATE_LIMIT", "off"), ("HECKS_RATE_LIMIT_SUBSCRIBE", "1")])).await;
        for _ in 0..10 {
            assert_eq!(post(addr, SUBSCRIBE, None, "{}").await.status(), 200);
        }
    }

    // The real service on an ephemeral port, over a scratch Postgres and a cold copy of the
    // checkout fixture's wasm, so the first request is a real compile.
    async fn fixture_host(database: &str, copy_name: &str) -> (SocketAddr, Arc<PathBuf>) {
        let client = crate::dispatch::tests::scratch_db(database).await;
        crate::dispatch::tests::provision_lineage(&*client.lock().await, "CheckoutFixture", 1, &["Event"]).await;
        let wasm_path = Arc::new(crate::wasm_runner::tests::cold_copy_of_fixture(copy_name));
        let state = ServerState {
            client: Arc::new(client),
            wasm_path: Arc::clone(&wasm_path),
            lineage_config: Arc::new(LineageConfig { domain: "CheckoutFixture".to_string(), era: Some(1), mirrored: None }),
            invoker: Arc::new(crate::lambda_client::NeverInvoker),
            limits: limits_from(&[]),
        };
        let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { serve_on(listener, state, sample_version()).await });
        (addr, wasm_path)
    }

    // `burst` simultaneous reads, each with the protocol's own `{"read": true}` body.
    async fn read_burst(addr: SocketAddr, burst: usize) -> Vec<(StatusCode, Value)> {
        let requests: Vec<_> = (0..burst)
            .map(|_| {
                tokio::spawn(async move {
                    let response = reqwest::Client::new().post(format!("http://{addr}/dispatch")).body(r#"{"read": true}"#).send().await.unwrap();
                    let status = StatusCode::from_u16(response.status().as_u16()).unwrap();
                    (status, response.json::<Value>().await.unwrap())
                })
            })
            .collect();
        let mut answers = Vec::new();
        for request in requests {
            answers.push(tokio::time::timeout(std::time::Duration::from_secs(120), request).await.expect("a read was never answered").unwrap());
        }
        answers
    }

    #[tokio::test]
    async fn a_burst_of_reads_on_a_cold_host_is_answered_from_one_compile() {
        let (addr, wasm_path) = fixture_host("rust_host_serve_cold_burst", "serve_cold").await;

        for (status, answer) in read_burst(addr, 8).await {
            assert_eq!(status, StatusCode::OK, "{answer}");
            assert!(answer["instances"].is_object(), "{answer}");
        }
        assert_eq!(crate::wasm_runner::compile_count(&wasm_path), 1);
    }

    #[tokio::test]
    async fn warming_before_serving_leaves_no_compile_for_the_first_read() {
        let (addr, wasm_path) = fixture_host("rust_host_serve_warmed", "serve_warmed").await;
        warm_wasm(&wasm_path).await;
        assert_eq!(crate::wasm_runner::compile_count(&wasm_path), 1);

        let started = std::time::Instant::now();
        let answers = read_burst(addr, 1).await;
        assert_eq!(answers[0].0, StatusCode::OK, "{}", answers[0].1);
        assert_eq!(crate::wasm_runner::compile_count(&wasm_path), 1);
        assert!(started.elapsed() < std::time::Duration::from_secs(1), "a warmed read took {:?}", started.elapsed());
    }

    #[test]
    fn build_is_the_env_value_when_set() {
        assert_eq!(version_body("e", "h", Some("cms-1"))["build"], "cms-1");
    }

    #[test]
    fn build_falls_back_to_the_crate_version_when_unset_or_empty() {
        assert_eq!(version_body("e", "h", None)["build"], env!("CARGO_PKG_VERSION"));
        assert_eq!(version_body("e", "h", Some(""))["build"], env!("CARGO_PKG_VERSION"));
    }
}

#[cfg(test)]
#[path = "boundary_fuzz/server.rs"]
mod boundary_fuzz;
