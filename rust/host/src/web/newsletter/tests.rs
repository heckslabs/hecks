use super::*;

#[test]
fn a_confirm_token_verifies_only_for_the_address_it_was_minted_for() {
    let token = confirm_token("s3cret-value", "a@example.com");
    assert!(confirm_token_matches("s3cret-value", &token, "a@example.com"));
    assert!(!confirm_token_matches("s3cret-value", &token, "b@example.com"));
}

#[test]
fn a_confirm_token_signed_with_another_secret_is_refused() {
    let token = confirm_token("one-secret", "a@example.com");
    assert!(!confirm_token_matches("another-secret", &token, "a@example.com"));
}

#[test]
fn a_token_minted_for_another_purpose_is_not_a_confirm_token() {
    let other = auth::purpose_token("s3cret-value", "account-sso", json!({ "email": "a@example.com" }), 60);
    assert!(!confirm_token_matches("s3cret-value", &other, "a@example.com"));
}

#[test]
fn an_expired_or_garbled_token_is_refused() {
    let expired = auth::purpose_token("s3cret-value", CONFIRM_PURPOSE, json!({ "email": "a@example.com" }), 0);
    std::thread::sleep(std::time::Duration::from_millis(1100));
    assert!(!confirm_token_matches("s3cret-value", &expired, "a@example.com"));
    assert!(!confirm_token_matches("s3cret-value", "not-a-token", "a@example.com"));
    assert!(!confirm_token_matches("s3cret-value", "", "a@example.com"));
}

#[test]
fn the_confirm_url_carries_the_encoded_address_and_the_token() {
    let url = confirm_url("https://example.com", "a+b@example.com", "tok.en");
    assert_eq!(url, "https://example.com/newsletter-confirmed.html?email=a%2Bb%40example.com&token=tok.en");
}

#[test]
fn the_confirmation_email_holds_the_link_and_says_it_can_be_ignored() {
    let body = confirmation_body("https://example.com/newsletter-confirmed.html?email=a%40b.c&token=t");
    assert!(body.contains("https://example.com/newsletter-confirmed.html?email=a%40b.c&token=t"));
    assert!(body.contains("ignore this email"));
}

fn unsubscribe_query(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

fn status_and_error(response: &Value) -> (u64, String) {
    let body: Value = serde_json::from_str(response["body"].as_str().unwrap()).unwrap();
    (response["statusCode"].as_u64().unwrap(), body["error"].as_str().unwrap_or("").to_string())
}

#[test]
fn an_unsubscribe_request_with_a_token_for_its_own_address_is_authorized() {
    let token = unsubscribe_token("s3cret-value", "a@example.com");
    let query = unsubscribe_query(&[("email", "a@example.com"), ("token", &token)]);
    assert_eq!(unsubscribe_authorized(Some("s3cret-value"), &query).unwrap(), "a@example.com");
}

#[test]
fn an_unsubscribe_request_without_a_valid_token_is_a_403() {
    let refusal = "this unsubscribe link is invalid or has expired";
    let own = unsubscribe_token("s3cret-value", "a@example.com");
    let other = unsubscribe_token("s3cret-value", "b@example.com");
    let confirm = confirm_token("s3cret-value", "a@example.com");
    let expired = auth::purpose_token("s3cret-value", "newsletter-unsubscribe", json!({ "email": "a@example.com" }), 0);
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let cases = [
        unsubscribe_query(&[("email", "a@example.com")]),
        unsubscribe_query(&[("email", "a@example.com"), ("token", "")]),
        unsubscribe_query(&[("email", "a@example.com"), ("token", "bogus")]),
        unsubscribe_query(&[("email", "a@example.com"), ("token", &other)]),
        unsubscribe_query(&[("email", "a@example.com"), ("token", &confirm)]),
        unsubscribe_query(&[("email", "a@example.com"), ("token", &expired)]),
        unsubscribe_query(&[("email", "b@example.com"), ("token", &own)]),
    ];
    for query in &cases {
        let err = unsubscribe_authorized(Some("s3cret-value"), query).unwrap_err();
        assert_eq!(status_and_error(&err), (403, refusal.to_string()), "{query:?}");
        assert_eq!(err["body"], json!({ "error": refusal }).to_string());
    }
}

#[test]
fn an_unsubscribe_request_is_refused_when_there_is_no_secret_to_check_against() {
    let token = unsubscribe_token("s3cret-value", "a@example.com");
    let query = unsubscribe_query(&[("email", "a@example.com"), ("token", &token)]);
    assert_eq!(unsubscribe_authorized(None, &query).unwrap_err()["statusCode"], 403);
}

#[test]
fn an_unsubscribe_request_without_an_address_is_a_400() {
    let token = unsubscribe_token("s3cret-value", "a@example.com");
    let err = unsubscribe_authorized(Some("s3cret-value"), &unsubscribe_query(&[("token", &token)])).unwrap_err();
    assert_eq!(err["statusCode"], 400);
}

#[test]
fn a_confirm_token_is_not_an_unsubscribe_token_and_the_reverse() {
    let confirm = confirm_token("s3cret-value", "a@example.com");
    let unsubscribe = unsubscribe_token("s3cret-value", "a@example.com");
    assert!(!unsubscribe_token_matches("s3cret-value", &confirm, "a@example.com"));
    assert!(!confirm_token_matches("s3cret-value", &unsubscribe, "a@example.com"));
}
