//! Google sign-in bound to the browser that started it, the cross-origin handoff, and logout.

use super::*;

fn cookies_of(response: &Value) -> Vec<String> {
    response["cookies"]
        .as_array()
        .map(|list| {
            list.iter()
                .filter_map(|c| c.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

// The `name=value` pair a `Set-Cookie` value carries, as the browser would send it back.
fn cookie_pair(set_cookie: &str) -> (String, String) {
    let pair = set_cookie.split(';').next().unwrap();
    let (name, value) = pair.split_once('=').unwrap();
    (name.to_string(), value.to_string())
}

fn query_param(url: &str, name: &str) -> String {
    let url = reqwest::Url::parse(url).unwrap();
    url.query_pairs()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.into_owned())
        .unwrap()
}

fn started() -> (Value, HashMap<String, String>) {
    crate::secrets::provide("GOOGLE_CLIENT_ID", "client-1".to_string());
    let response = google_start();
    let set = cookies_of(&response);
    assert_eq!(set.len(), 1, "{response:?}");
    let cookies = HashMap::from([cookie_pair(&set[0])]);
    (response, cookies)
}

#[test]
fn the_start_sets_a_sign_in_cookie_holding_the_state_and_nonce_it_sends_to_google() {
    let (response, cookies) = started();
    let location = response["headers"]["location"].as_str().unwrap();
    let signin = auth::read_google_signin(&cookies, true).expect("the cookie reads back");
    assert_eq!(query_param(location, "state"), signin.state);
    assert_eq!(query_param(location, "nonce"), signin.nonce);
}

#[test]
fn the_callback_is_refused_without_the_browsers_sign_in_cookie() {
    let (response, _) = started();
    let state = query_param(response["headers"]["location"].as_str().unwrap(), "state");
    let query = HashMap::from([("state".to_string(), state)]);
    assert_eq!(google_signin_for(&query, &HashMap::new(), true), None);
}

#[test]
fn the_callback_is_refused_when_its_state_is_another_sign_ins() {
    let (_, victims_cookies) = started();
    let (attackers, _) = started();
    let state = query_param(attackers["headers"]["location"].as_str().unwrap(), "state");
    let query = HashMap::from([("state".to_string(), state)]);
    assert_eq!(google_signin_for(&query, &victims_cookies, true), None);
    assert_eq!(
        google_signin_for(&HashMap::new(), &victims_cookies, true),
        None
    );
}

#[test]
fn the_callback_with_its_own_state_yields_the_nonce_to_check_in_the_id_token() {
    let (response, cookies) = started();
    let location = response["headers"]["location"].as_str().unwrap();
    let query = HashMap::from([("state".to_string(), query_param(location, "state"))]);
    let signin = google_signin_for(&query, &cookies, true).expect("its own state matches");
    assert_eq!(signin.nonce, query_param(location, "nonce"));
}

#[test]
fn a_cookie_added_to_a_response_keeps_the_ones_it_already_set() {
    let response = with_cookie(redirect_with_cookie("/admin.html", "a=1"), "b=; Max-Age=0");
    assert_eq!(cookies_of(&response), ["a=1", "b=; Max-Age=0"]);
    assert_eq!(cookies_of(&with_cookie(redirect("/login"), "b=2")), ["b=2"]);
}

#[test]
fn logout_clears_the_account_cookie_as_well_as_the_session_cookie() {
    let cleared: Vec<String> = cookies_of(&logout_response())
        .iter()
        .filter(|c| c.contains("Max-Age=0"))
        .map(|c| cookie_pair(c).0)
        .collect();
    assert_eq!(
        cleared,
        ["session".to_string(), auth::account_cookie_name()]
    );
}

fn handoff(body: &Value) -> Value {
    google_handoff_route(&body.to_string(), "s3cret")
}

#[test]
fn a_handoff_token_is_traded_once_for_the_account_token() {
    let token = auth::handoff_token("s3cret", "zed@example.com");
    let first = handoff(&json!({ "token": token }));
    assert_eq!(first["statusCode"], 200, "{first:?}");
    let body: Value = serde_json::from_str(first["body"].as_str().unwrap()).unwrap();
    let account = body["token"].as_str().unwrap();
    assert_eq!(
        auth::verify_account_token("s3cret", account).as_deref(),
        Some("zed@example.com")
    );
    assert_eq!(handoff(&json!({ "token": token }))["statusCode"], 401);
}

#[test]
fn an_account_token_or_garbage_is_not_traded() {
    let account = auth::account_token("s3cret", "zed@example.com", 600);
    for body in [
        json!({ "token": account }),
        json!({ "token": "x.y" }),
        json!({}),
    ] {
        assert_eq!(handoff(&body)["statusCode"], 401, "{body}");
    }
    assert_eq!(
        google_handoff_route("not json", "s3cret")["statusCode"],
        401
    );
}
