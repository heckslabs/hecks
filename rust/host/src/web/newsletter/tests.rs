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
