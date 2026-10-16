//! The handler end to end with a fake member store, a fixed clock and the shared vectors.

use std::sync::Arc;

use serde_json::Value;

use super::cookie;
use super::handler::{fresh_value, CallbackRequest, SigninHandler};
use super::wiring_support::*;
use crate::auth;

const AUTHORIZE: &str = "https://issuer.example/sso/authorize?site=site-a&env=production";

fn started(log: Arc<Recorder>) -> (SigninHandler, Value) {
    let handler = vector_handler("alongside", log).with_random(scripted_random(&[NONCE_A, STATE_A]));
    let response = handler.start();
    (handler, response)
}

fn admin() -> FakeMembers {
    FakeMembers::resolving(Person::new("person@example.test", Some("Admin")))
}

async fn finish(handler: &SigninHandler, step: &Value, members: &FakeMembers) -> Value {
    handler.callback(&request_for(step), members).await
}

fn status(response: &Value) -> u64 {
    response["statusCode"].as_u64().unwrap()
}

fn page_has_code(response: &Value, code: &str) -> bool {
    response["body"].as_str().unwrap_or("").contains(code)
}

fn only_clears_the_cookie(response: &Value) -> bool {
    cookies_of(response) == vec![cookie::clear_header()]
}

// ---- start ----

#[test]
fn start_redirects_to_the_exact_authorize_url() {
    let (_, response) = started(Arc::new(Recorder::default()));
    assert_eq!(status(&response), 302);
    assert_eq!(response["headers"]["location"], format!("{AUTHORIZE}&nonce={NONCE_A}&state={STATE_A}"));
}

#[test]
fn start_sets_the_exact_cookie_and_nothing_else() {
    let (_, response) = started(Arc::new(Recorder::default()));
    assert_eq!(cookies_of(&response), vec![format!("__Host-signin={NONCE_A}.{STATE_A}; Max-Age=600; Path=/; Secure; HttpOnly; SameSite=Lax")]);
}

#[test]
fn start_is_never_cached() {
    let (_, response) = started(Arc::new(Recorder::default()));
    assert_eq!(response["headers"]["cache-control"], "no-store");
}

#[test]
fn fresh_values_are_long_url_safe_and_different_every_time() {
    let values: Vec<String> = (0..50).map(|_| fresh_value()).collect();
    for value in &values {
        assert!(value.len() >= 22 && value.len() <= 128, "{value}");
        assert!(value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'), "{value}");
    }
    let unique: std::collections::HashSet<_> = values.iter().collect();
    assert_eq!(unique.len(), values.len());
}

#[test]
fn the_real_start_gives_nonce_and_state_that_differ() {
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let response = handler.start();
    let set = cookies_of(&response).remove(0);
    let value = set.split(';').next().unwrap().trim_start_matches("__Host-signin=").to_string();
    let (nonce, state) = value.split_once('.').unwrap();
    assert_ne!(nonce, state);
    assert!(response["headers"]["location"].as_str().unwrap().contains(&format!("nonce={nonce}&state={state}")));
}

#[test]
fn start_logs_neither_the_nonce_nor_the_state() {
    let log = Arc::new(Recorder::default());
    started(log.clone());
    assert!(!log.text().contains(NONCE_A) && !log.text().contains(STATE_A));
}

// ---- callback: success ----

#[tokio::test]
async fn a_genuine_token_signs_the_member_in() {
    let doc = vectors();
    let log = Arc::new(Recorder::default());
    let handler = vector_handler("alongside", log);
    let response = finish(&handler, &single(&doc, "valid"), &admin()).await;
    assert_eq!(status(&response), 302);
    assert_eq!(response["headers"]["location"], "/admin.html");
    let cookies = cookies_of(&response);
    assert_eq!(cookies.len(), 2);
    assert_eq!(cookies[1], cookie::clear_header());
    let account = &cookies[0];
    assert!(account.starts_with(&format!("{}=", auth::DEFAULT_ACCOUNT_COOKIE)));
    let token = account.split(';').next().unwrap().split_once('=').unwrap().1;
    assert_eq!(auth::verify_account_token(SECRET, token).as_deref(), Some("person@example.test"));
}

#[tokio::test]
async fn the_account_cookie_carries_the_hosts_flags_and_lifetime() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let response = finish(&handler, &single(&doc, "valid"), &admin()).await;
    let account = cookies_of(&response).remove(0);
    let attributes: Vec<&str> = account.split("; ").skip(1).collect();
    assert_eq!(attributes, ["Path=/", "HttpOnly", "Secure", "SameSite=Lax", &format!("Max-Age={}", auth::SESSION_TTL_SECS)]);
}

#[tokio::test]
async fn the_success_redirect_is_not_cached_and_keeps_the_referrer_quiet() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let response = finish(&handler, &single(&doc, "valid"), &admin()).await;
    assert_eq!(response["headers"]["cache-control"], "no-store");
    assert_eq!(response["headers"]["referrer-policy"], "no-referrer");
}

#[tokio::test]
async fn the_session_is_minted_for_the_members_own_email() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let members = FakeMembers::resolving(Person::new("Member.Row@example.test", Some("Admin")));
    let response = finish(&handler, &single(&doc, "valid"), &members).await;
    let account = cookies_of(&response).remove(0);
    let token = account.split(';').next().unwrap().split_once('=').unwrap().1;
    assert_eq!(auth::verify_account_token(SECRET, token).as_deref(), Some("Member.Row@example.test"));
}

// ---- callback: the member mapping ----

#[tokio::test]
async fn a_resolved_identity_never_provisions() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let members = admin();
    finish(&handler, &single(&doc, "valid"), &members).await;
    assert_eq!(members.called(), ["identity_for", "session_for_identity"]);
}

#[tokio::test]
async fn an_unresolved_identity_provisions_by_email_with_the_tokens_identity() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let members = FakeMembers::provisioning(Person::new("person@example.test", Some("Admin")));
    let response = finish(&handler, &single(&doc, "valid"), &members).await;
    assert_eq!(status(&response), 302);
    assert_eq!(members.called().last().unwrap(), "provision person@example.test https://idp.example idp-subject-0001");
}

#[tokio::test]
async fn nothing_resolving_and_nothing_to_link_is_google_unlinked_with_no_session() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let members = FakeMembers::default();
    let response = finish(&handler, &single(&doc, "valid"), &members).await;
    assert_eq!(status(&response), 403);
    assert!(page_has_code(&response, "google_unlinked"));
    assert!(only_clears_the_cookie(&response));
}

#[tokio::test]
async fn there_is_no_fallback_by_email_when_the_identity_does_not_resolve() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let mut members = FakeMembers::default();
    members.linked.insert("identity-1".into(), Person::new("person@example.test", Some("Admin")));
    let response = finish(&handler, &single(&doc, "valid"), &members).await;
    assert_eq!(status(&response), 403);
    assert!(only_clears_the_cookie(&response));
}

#[tokio::test]
async fn a_member_without_a_role_is_refused() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let members = FakeMembers::resolving(Person::new("person@example.test", None));
    let response = finish(&handler, &single(&doc, "valid"), &members).await;
    assert_eq!(status(&response), 403);
    assert!(only_clears_the_cookie(&response));
}

#[tokio::test]
async fn a_disabled_or_unknown_member_the_store_does_not_return_is_refused() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let mut members = FakeMembers::default();
    members.identities.insert(("https://idp.example".into(), "idp-subject-0001".into()), "identity-1".into());
    let response = finish(&handler, &single(&doc, "valid"), &members).await;
    assert_eq!(status(&response), 403);
}

#[tokio::test]
async fn a_store_fault_is_our_fault_not_a_refusal_and_still_clears_the_cookie() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let members = FakeMembers { fail: true, ..FakeMembers::default() };
    let response = finish(&handler, &single(&doc, "valid"), &members).await;
    assert_eq!(status(&response), 500);
    assert!(page_has_code(&response, "platform_unavailable"));
    assert!(only_clears_the_cookie(&response));
}

#[tokio::test]
async fn role_drift_is_logged_and_nothing_is_written() {
    let doc = vectors();
    let log = Arc::new(Recorder::default());
    let handler = vector_handler("alongside", log.clone());
    let members = FakeMembers::resolving(Person::new("person@example.test", Some("Member")));
    let response = finish(&handler, &single(&doc, "valid"), &members).await;
    assert_eq!(status(&response), 302);
    let drift = log.fields_of("platform_signin_role_drift").expect("drift logged");
    assert_eq!(drift["token_role"], "Admin");
    assert_eq!(drift["local_role"], "Member");
    assert_eq!(members.called(), ["identity_for", "session_for_identity"]);
}

#[tokio::test]
async fn no_drift_is_logged_when_the_roles_agree() {
    let doc = vectors();
    let log = Arc::new(Recorder::default());
    let handler = vector_handler("alongside", log.clone());
    finish(&handler, &single(&doc, "valid"), &admin()).await;
    assert!(log.fields_of("platform_signin_role_drift").is_none());
}

// ---- callback: every vector through the handler ----

fn expected_code(refusal: &str) -> &'static str {
    match refusal {
        "missing_cookie" => "platform_cookie",
        "state_mismatch" => "platform_state",
        _ => "platform_token",
    }
}

#[tokio::test]
async fn every_vector_gets_the_right_status_code_and_never_a_session_when_refused() {
    let doc = vectors();
    for vector in doc["vectors"].as_array().unwrap() {
        let handler = vector_handler("alongside", Arc::new(Recorder::default()));
        let steps: Vec<Value> = match vector["type"].as_str().unwrap() {
            "sequence" => vector["steps"].as_array().unwrap().clone(),
            _ => vec![vector.clone()],
        };
        for step in steps {
            let name = vector["name"].as_str().unwrap();
            let response = finish(&handler, &step, &admin()).await;
            if step["expect"] == "accept" {
                assert_eq!(status(&response), 302, "{name}");
                assert_eq!(cookies_of(&response).len(), 2, "{name}");
            } else {
                let refusal = step["refusal"].as_str().unwrap();
                let params_fault = refusal == "malformed" && step["token"].is_null();
                let code = if params_fault || (step["state"].is_null() && refusal == "state_mismatch") { "platform_params" } else { expected_code(refusal) };
                assert_eq!(status(&response), 400, "{name}");
                assert!(page_has_code(&response, code), "{name}: wanted {code}");
                assert!(only_clears_the_cookie(&response), "{name}");
            }
        }
    }
}

// ---- callback: faults in the request ----

fn good() -> (Value, CallbackRequest) {
    let doc = vectors();
    let step = single(&doc, "valid");
    let request = request_for(&step);
    (step, request)
}

async fn answer(request: CallbackRequest) -> (Value, FakeMembers) {
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let members = admin();
    (handler.callback(&request, &members).await, members)
}

#[tokio::test]
async fn a_missing_cookie_is_refused_before_anything_else() {
    let (_, mut request) = good();
    request.cookie_pairs.clear();
    let (response, members) = answer(request).await;
    assert_eq!(status(&response), 400);
    assert!(page_has_code(&response, "platform_cookie"));
    assert!(only_clears_the_cookie(&response));
    assert!(members.called().is_empty());
}

#[tokio::test]
async fn a_repeated_or_malformed_cookie_is_refused() {
    let (_, request) = good();
    let mut twice = request.clone();
    twice.cookie_pairs.push(request.cookie_pairs[0].clone());
    let mut junk = request.clone();
    junk.cookie_pairs = vec!["__Host-signin=nodot".into()];
    for bad in [twice, junk] {
        let (response, _) = answer(bad).await;
        assert!(page_has_code(&response, "platform_cookie"));
        assert!(only_clears_the_cookie(&response));
    }
}

#[tokio::test]
async fn missing_repeated_oversized_or_undecodable_parameters_are_refused() {
    let (step, request) = good();
    let token = encode(step["token"].as_str().unwrap());
    let state = encode(step["state"].as_str().unwrap());
    for query in [
        format!("state={state}"),
        format!("token={token}"),
        format!("token={token}&token={token}&state={state}"),
        format!("token={token}&state={state}&state={state}"),
        format!("token={token}&state={state}&pad={}", "a".repeat(20_000)),
        format!("token=%zz&state={state}"),
    ] {
        let bad = CallbackRequest { raw_query: query, ..request.clone() };
        let (response, members) = answer(bad).await;
        assert_eq!(status(&response), 400);
        assert!(page_has_code(&response, "platform_params"));
        assert!(only_clears_the_cookie(&response));
        assert!(members.called().is_empty());
    }
}

#[tokio::test]
async fn a_replayed_token_is_refused_the_second_time() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let step = single(&doc, "valid");
    assert_eq!(status(&finish(&handler, &step, &admin()).await), 302);
    let second = finish(&handler, &step, &admin()).await;
    assert_eq!(status(&second), 400);
    assert!(page_has_code(&second, "platform_token"));
    assert!(only_clears_the_cookie(&second));
}

#[tokio::test]
async fn an_expired_token_is_refused_by_the_clock_the_handler_was_given() {
    let doc = vectors();
    let now = doc["now"].as_i64().unwrap();
    let handler = vector_handler("alongside", Arc::new(Recorder::default())).with_clock(Box::new(move || now + 3600));
    let response = finish(&handler, &single(&doc, "valid"), &admin()).await;
    assert_eq!(status(&response), 400);
    assert!(only_clears_the_cookie(&response));
}

#[tokio::test]
async fn the_member_store_is_not_asked_until_the_token_has_verified() {
    let doc = vectors();
    for name in ["state_mismatch", "nonce_mismatch", "wrong_aud_1", "wrong_env_1", "expired", "payload_tampered", "cookie_absent"] {
        let handler = vector_handler("alongside", Arc::new(Recorder::default()));
        let members = admin();
        let response = finish(&handler, &single(&doc, name), &members).await;
        assert_eq!(status(&response), 400, "{name}");
        assert!(members.called().is_empty(), "{name}");
    }
}

// ---- callback: logging ----

#[tokio::test]
async fn no_log_line_ever_holds_a_token_nonce_state_or_full_email() {
    let doc = vectors();
    let log = Arc::new(Recorder::default());
    let handler = vector_handler("alongside", log.clone());
    for name in ["valid", "valid", "state_mismatch", "nonce_mismatch", "wrong_aud_1", "payload_tampered", "expired"] {
        let step = single(&doc, name);
        finish(&handler, &step, &FakeMembers::resolving(Person::new("person@example.test", Some("Member")))).await;
        finish(&handler, &step, &FakeMembers::default()).await;
        let text = log.text();
        for secret in [step["token"].as_str().unwrap_or("-"), step["state"].as_str().unwrap_or("-"), "Nn0nceNn0nceNn0nceAA", "StateStateState0123456789", "person@example.test"] {
            assert!(!text.contains(secret), "{name} leaked {secret}");
        }
    }
    assert!(!log.events().is_empty());
}

#[tokio::test]
async fn a_refusal_is_logged_by_its_stable_code() {
    let doc = vectors();
    let log = Arc::new(Recorder::default());
    let handler = vector_handler("alongside", log.clone());
    finish(&handler, &single(&doc, "nonce_mismatch"), &admin()).await;
    assert_eq!(log.fields_of("platform_signin_refused").unwrap()["reason"], "nonce_mismatch");
}

// ---- L6: attack mirror at the handler ----

#[test]
fn a_start_request_cannot_choose_where_it_goes() {
    let (handler, plain) = started(Arc::new(Recorder::default()));
    let _ = handler;
    let location = plain["headers"]["location"].as_str().unwrap();
    assert!(location.starts_with("https://issuer.example/sso/authorize?"));
    assert!(!location.contains("evil"));
}

#[tokio::test]
async fn open_redirect_parameters_on_the_callback_are_ignored() {
    let (step, request) = good();
    let token = encode(step["token"].as_str().unwrap());
    let state = encode(step["state"].as_str().unwrap());
    let query = format!("return=https%3A%2F%2Fevil.example&token={token}&next=//evil.example&redirect_uri=https://evil.example&state={state}&callback=//e");
    let (response, _) = answer(CallbackRequest { raw_query: query, ..request }).await;
    assert_eq!(response["headers"]["location"], "/admin.html");
}

#[tokio::test]
async fn a_cookie_planted_by_someone_else_does_not_match_the_victims_callback() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let mut request = request_for(&single(&doc, "valid"));
    request.cookie_pairs = vec![format!("__Host-signin={NONCE_B}.{STATE_B}")];
    let response = handler.callback(&request, &admin()).await;
    assert_eq!(status(&response), 400);
    assert!(page_has_code(&response, "platform_state"));
}

#[tokio::test]
async fn a_cookie_with_no_matching_state_param_is_refused() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let mut request = request_for(&single(&doc, "valid"));
    request.raw_query = request.raw_query.split('&').filter(|p| !p.starts_with("state=")).collect::<Vec<_>>().join("&");
    let response = handler.callback(&request, &admin()).await;
    assert_eq!(status(&response), 400);
}

#[tokio::test]
async fn a_refusal_page_never_echoes_request_values() {
    let doc = vectors();
    let handler = vector_handler("alongside", Arc::new(Recorder::default()));
    let mut request = request_for(&single(&doc, "valid"));
    request.raw_query = "token=<script>alert(1)</script>&state=<b>x</b>".into();
    let response = handler.callback(&request, &admin()).await;
    let body = response["body"].as_str().unwrap();
    assert!(!body.contains("alert") && !body.contains("<b>"));
}
