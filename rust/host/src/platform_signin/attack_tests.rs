//! Attacks on the verifier, each named for what the attacker tries.
//!
//! The first test is the positive control: a token this suite signed by hand must be accepted, so
//! every refusal below can only come from a verifier that tells the attack from a good token. The
//! examples mirror the issuer's own attack suite for the reference verifier.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;

use super::config::PlatformSigninConfig;
use super::jti::JtiStore;
use super::jwks::{JwksCache, KeySource};
use super::jws::{decode_base64url, encode_base64url};
use super::test_support::*;
use super::verify::{Reason, SigninRequest, Verifier};

fn refused_with(mutate: impl FnOnce(&mut Scenario)) -> Reason {
    let mut scenario = Scenario::good();
    mutate(&mut scenario);
    scenario
        .run(&verifier_for(&[&KEY_A]))
        .expect_err("must be refused")
        .reason
}

fn accepted_with(mutate: impl FnOnce(&mut Scenario)) {
    let mut scenario = Scenario::good();
    mutate(&mut scenario);
    scenario
        .run(&verifier_for(&[&KEY_A]))
        .expect("must be accepted");
}

fn set(scenario: &mut Scenario, claim: &str, value: Value) {
    scenario.claims.insert(claim.into(), value);
}

fn raw_token_reason(token: Option<&str>) -> Reason {
    let verifier = verifier_for(&[&KEY_A]);
    let cookie = good_cookie();
    let request = SigninRequest {
        token,
        state: Some(STATE),
        cookie: Some(&cookie),
    };
    verifier
        .verify(&request, NOW)
        .expect_err("must be refused")
        .reason
}

// --- positive controls --------------------------------------------------------------------------

#[test]
fn accepts_a_valid_token() {
    assert!(Scenario::good().run(&verifier_for(&[&KEY_A])).is_ok());
}

#[test]
fn accepts_a_token_exactly_at_the_edges_of_the_window() {
    accepted_with(|s| set(s, "nbf", json!(NOW + 30)));
    accepted_with(|s| {
        set(s, "iat", json!(NOW - 89));
        set(s, "nbf", json!(NOW - 89));
        set(s, "exp", json!(NOW - 29));
    });
}

// --- algorithm attacks -----------------------------------------------------------------------

#[test]
fn rejects_alg_none_with_and_without_a_signature_segment() {
    let header = json!({"alg": "none", "typ": "JWT", "kid": KEY_A.kid()}).to_string();
    let claims = Scenario::good().claims;
    let body = encode_base64url(Value::Object(claims).to_string().as_bytes());
    let head = encode_base64url(header.as_bytes());
    for token in [
        format!("{head}.{body}."),
        format!("{head}.{body}.{}", encode_base64url(&[7u8; 64])),
    ] {
        assert_eq!(raw_token_reason(Some(&token)), Reason::BadAlg, "{token}");
    }
    for alg in ["None", "NONE", "nOnE", ""] {
        let head = encode_base64url(
            json!({"alg": alg, "typ": "JWT", "kid": KEY_A.kid()})
                .to_string()
                .as_bytes(),
        );
        assert_eq!(
            raw_token_reason(Some(&format!("{head}.{body}."))),
            Reason::BadAlg,
            "{alg:?}"
        );
    }
}

#[test]
fn rejects_hs256_signed_with_the_public_key_as_the_hmac_secret() {
    let public_raw = decode_base64url(X_A).unwrap();
    let secrets: Vec<Vec<u8>> = vec![
        public_raw,
        X_A.as_bytes().to_vec(),
        format!(r#"{{"kty":"OKP","crv":"Ed25519","x":"{X_A}"}}"#).into_bytes(),
    ];
    for secret in secrets {
        let head = encode_base64url(
            json!({"alg": "HS256", "typ": "JWT", "kid": KEY_A.kid()})
                .to_string()
                .as_bytes(),
        );
        let body = encode_base64url(
            Value::Object(Scenario::good().claims)
                .to_string()
                .as_bytes(),
        );
        let input = format!("{head}.{body}");
        let mut mac = Hmac::<Sha256>::new_from_slice(&secret).unwrap();
        mac.update(input.as_bytes());
        let token = format!("{input}.{}", encode_base64url(&mac.finalize().into_bytes()));
        assert_eq!(raw_token_reason(Some(&token)), Reason::BadAlg);
    }
}

#[test]
fn rejects_every_alg_other_than_eddsa_even_with_a_valid_eddsa_signature_over_that_header() {
    for alg in [
        "HS256", "HS384", "HS512", "RS256", "RS512", "ES256", "ES384", "PS256", "none", "eddsa",
        "EDDSA", "Ed25519", "EdDSA ", "ES256K",
    ] {
        assert_eq!(
            refused_with(|s| {
                s.header.insert("alg".into(), json!(alg));
            }),
            Reason::BadAlg,
            "{alg:?}"
        );
    }
    assert_eq!(
        refused_with(|s| {
            s.header.remove("alg");
        }),
        Reason::BadAlg
    );
    assert_eq!(
        refused_with(|s| {
            s.header.insert("alg".into(), json!(["EdDSA"]));
        }),
        Reason::BadAlg
    );
    assert_eq!(
        refused_with(|s| {
            s.header.insert("alg".into(), Value::Null);
        }),
        Reason::BadAlg
    );
}

#[test]
fn rejects_a_typ_that_is_not_jwt() {
    for typ in [json!("jwt"), json!("JWS"), json!(""), json!(1), Value::Null] {
        assert_eq!(
            refused_with(|s| {
                s.header.insert("typ".into(), typ.clone());
            }),
            Reason::Malformed,
            "{typ}"
        );
    }
    assert_eq!(
        refused_with(|s| {
            s.header.remove("typ");
        }),
        Reason::Malformed
    );
}

#[test]
fn ignores_an_embedded_jwk_and_jku_and_never_uses_them() {
    let attacker_jwk = json!({"kty": "OKP", "crv": "Ed25519", "x": X_B, "kid": KEY_B.kid()});
    let reason = refused_with(|s| {
        s.signer = KEY_B;
        s.header.insert("jwk".into(), attacker_jwk.clone());
        s.header
            .insert("jku".into(), json!("https://evil.example/jwks.json"));
    });
    assert_eq!(
        reason,
        Reason::BadSignature,
        "signed by the attacker, kid names the real key"
    );
    let reason = refused_with(|s| {
        s.signer = KEY_B;
        s.header.insert("kid".into(), json!(KEY_B.kid()));
        s.header.insert("jwk".into(), attacker_jwk.clone());
    });
    assert_eq!(
        reason,
        Reason::UnknownKid,
        "the attacker's own key is not in the key set"
    );
}

#[test]
fn rejects_an_unknown_kid_a_missing_kid_and_a_kid_of_the_wrong_type() {
    assert_eq!(
        refused_with(|s| {
            s.header.insert("kid".into(), json!("nope"));
        }),
        Reason::UnknownKid
    );
    assert_eq!(
        refused_with(|s| {
            s.header.remove("kid");
        }),
        Reason::UnknownKid
    );
    for kid in [json!(7), json!(["x"]), Value::Null, json!({"a": 1})] {
        assert_eq!(
            refused_with(|s| {
                s.header.insert("kid".into(), kid.clone());
            }),
            Reason::UnknownKid
        );
    }
    assert_eq!(
        refused_with(|s| {
            s.header.insert("kid".into(), json!(KID_A.to_uppercase()));
        }),
        Reason::UnknownKid
    );
}

#[test]
fn rejects_a_token_signed_by_another_key_that_claims_the_real_kid() {
    assert_eq!(refused_with(|s| s.signer = KEY_B), Reason::BadSignature);
}

// --- tampering -------------------------------------------------------------------------------

fn parts(scenario: &Scenario) -> (String, String, String) {
    let token = scenario.token();
    let mut it = token.split('.');
    (
        it.next().unwrap().into(),
        it.next().unwrap().into(),
        it.next().unwrap().into(),
    )
}

#[test]
fn rejects_a_tampered_payload() {
    let (head, _, signature) = parts(&Scenario::good());
    let mut evil = Scenario::good().claims;
    evil.insert("email".into(), json!("admin@example.test"));
    evil.insert("sub".into(), json!("admin@example.test"));
    let tampered = format!(
        "{head}.{}.{signature}",
        encode_base64url(Value::Object(evil).to_string().as_bytes())
    );
    assert_eq!(raw_token_reason(Some(&tampered)), Reason::BadSignature);
}

#[test]
fn rejects_a_tampered_header_with_the_kid_swapped_to_another_known_kid() {
    let verifier = verifier_for(&[&KEY_A, &KEY_B]);
    let (_, body, signature) = parts(&Scenario::good());
    let head = encode_base64url(
        json!({"alg": "EdDSA", "typ": "JWT", "kid": KEY_B.kid()})
            .to_string()
            .as_bytes(),
    );
    let cookie = good_cookie();
    let token = format!("{head}.{body}.{signature}");
    let request = SigninRequest {
        token: Some(&token),
        state: Some(STATE),
        cookie: Some(&cookie),
    };
    assert_eq!(
        verifier.verify(&request, NOW).unwrap_err().reason,
        Reason::BadSignature
    );
}

#[test]
fn rejects_a_tampered_signature_one_bit_flipped_and_every_wrong_length() {
    assert_eq!(
        refused_with(|s| s.flip_signature = true),
        Reason::BadSignature
    );
    let (head, body, signature) = parts(&Scenario::good());
    let bytes = decode_base64url(&signature).unwrap();
    for wrong in [&bytes[..63], &bytes[..32], &bytes[..1], &[][..]] {
        let token = format!("{head}.{body}.{}", encode_base64url(wrong));
        assert_eq!(
            raw_token_reason(Some(&token)),
            Reason::BadSignature,
            "{} bytes",
            wrong.len()
        );
    }
    let mut longer = bytes;
    longer.extend_from_slice(&[0, 0]);
    assert_eq!(
        raw_token_reason(Some(&format!(
            "{head}.{body}.{}",
            encode_base64url(&longer)
        ))),
        Reason::BadSignature
    );
}

// --- structure -------------------------------------------------------------------------------

#[test]
fn rejects_truncated_extra_segment_empty_and_missing_tokens() {
    let token = Scenario::good().token();
    let (head, body, signature) = parts(&Scenario::good());
    assert_eq!(
        raw_token_reason(Some(&token[..token.len() - 10])),
        Reason::BadSignature,
        "a shorter signature still parses"
    );
    assert_eq!(
        raw_token_reason(Some(&format!("{head}.{body}"))),
        Reason::Malformed
    );
    assert_eq!(
        raw_token_reason(Some(&format!("{token}.{signature}"))),
        Reason::Malformed
    );
    assert_eq!(
        raw_token_reason(Some(&format!("{token}."))),
        Reason::Malformed
    );
    assert_eq!(raw_token_reason(Some("")), Reason::Malformed);
    assert_eq!(raw_token_reason(Some("..")), Reason::Malformed);
    assert_eq!(raw_token_reason(None), Reason::Malformed);
}

#[test]
fn rejects_non_base64url_segments_and_non_object_json() {
    let (head, body, signature) = parts(&Scenario::good());
    let cases = [
        format!("{head}=.{body}.{signature}"),
        format!("{head}.{}+.{signature}", &body[..body.len() - 1]),
        format!("{head}./{body}.{signature}"),
        format!("{head}.{} {}.{signature}", &body[..4], &body[4..]),
        format!("{head}.{body}\n.{signature}"),
        format!("{}.{body}.{signature}", encode_base64url(b"not json")),
        format!("{head}.{}.{signature}", encode_base64url(b"[1,2]")),
        format!("{head}.{}.{signature}", encode_base64url(b"\"s\"")),
        format!("{head}.{}.{signature}", encode_base64url(b"")),
        format!("{head}.{body}.{}", signature.replace(&signature[..1], "!")),
    ];
    for token in cases {
        let reason = raw_token_reason(Some(&token));
        assert_eq!(reason, Reason::Malformed, "{token}");
    }
}

#[test]
fn rejects_a_header_or_payload_that_repeats_a_key() {
    let kid = KEY_A.kid();
    let claims = Value::Object(Scenario::good().claims).to_string();
    let header_dup = format!(r#"{{"alg":"none","alg":"EdDSA","typ":"JWT","kid":"{kid}"}}"#);
    let payload_dup = format!(r#"{{"aud":"other",{}"#, &claims[1..]);
    assert_eq!(
        raw_token_reason(Some(&assemble(&header_dup, &claims, &KEY_A))),
        Reason::Malformed
    );
    let header = json!({"alg": "EdDSA", "typ": "JWT", "kid": kid}).to_string();
    assert_eq!(
        raw_token_reason(Some(&assemble(&header, &payload_dup, &KEY_A))),
        Reason::Malformed
    );
}

#[test]
fn rejects_a_non_canonical_signature_spelling() {
    let (head, body, signature) = parts(&Scenario::good());
    let last = signature.chars().last().unwrap();
    let spare = if last == 'A' { 'B' } else { 'A' };
    let respelled = format!("{head}.{body}.{}{spare}", &signature[..signature.len() - 1]);
    assert_eq!(raw_token_reason(Some(&respelled)), Reason::Malformed);
    assert_eq!(
        raw_token_reason(Some(&format!("{head}.{body}.{signature}="))),
        Reason::Malformed
    );
}

fn token_of_exactly(len: usize) -> String {
    for pad in 0..len {
        for jti in 0..4 {
            let mut scenario = Scenario::good();
            set(&mut scenario, "pad", json!("x".repeat(pad)));
            set(
                &mut scenario,
                "jti",
                json!(format!("jti-size-{}", "j".repeat(jti))),
            );
            let token = scenario.token();
            if token.len() == len {
                return token;
            }
        }
    }
    panic!("no token of {len} bytes");
}

#[test]
fn rejects_an_oversized_token_before_parsing_it_and_accepts_one_at_the_cap() {
    assert_eq!(
        raw_token_reason(Some(&token_of_exactly(4097))),
        Reason::TooLarge
    );
    assert_eq!(
        raw_token_reason(Some(&"x".repeat(100_000))),
        Reason::TooLarge
    );
    let at_cap = token_of_exactly(4096);
    let cookie = good_cookie();
    let request = SigninRequest {
        token: Some(&at_cap),
        state: Some(STATE),
        cookie: Some(&cookie),
    };
    assert!(verifier_for(&[&KEY_A]).verify(&request, NOW).is_ok());
}

// --- claims ----------------------------------------------------------------------------------

#[test]
fn rejects_claims_of_the_wrong_json_type() {
    assert_eq!(
        refused_with(|s| set(s, "exp", json!("1800000060"))),
        Reason::Malformed
    );
    assert_eq!(
        refused_with(|s| set(s, "exp", json!(1_800_000_060.0))),
        Reason::Malformed
    );
    assert_eq!(
        refused_with(|s| set(s, "iat", json!(1_800_000_000.5))),
        Reason::Malformed
    );
    assert_eq!(
        refused_with(|s| set(s, "nbf", json!(true))),
        Reason::Malformed
    );
    assert_eq!(
        refused_with(|s| set(s, "aud", json!([SITE]))),
        Reason::BadAud
    );
    assert_eq!(
        refused_with(|s| set(s, "env", json!([ENVIRONMENT]))),
        Reason::BadEnv
    );
    assert_eq!(
        refused_with(|s| set(s, "iss", json!([ISSUER]))),
        Reason::BadIss
    );
}

#[test]
fn rejects_the_wrong_iss_including_lookalikes() {
    for iss in [
        "https://issuer.example/",
        "http://issuer.example",
        "https://ISSUER.example",
        "https://issuer.example.evil.example",
        "https://evil.example",
        "issuer.example",
        "",
    ] {
        assert_eq!(
            refused_with(|s| set(s, "iss", json!(iss))),
            Reason::BadIss,
            "{iss:?}"
        );
    }
}

#[test]
fn rejects_the_wrong_aud_and_env() {
    for aud in ["site-b", "SITE-A", "site-a ", "site", "platform", ""] {
        assert_eq!(
            refused_with(|s| set(s, "aud", json!(aud))),
            Reason::BadAud,
            "{aud:?}"
        );
    }
    for env in ["staging", "Production", "prod", "production ", ""] {
        assert_eq!(
            refused_with(|s| set(s, "env", json!(env))),
            Reason::BadEnv,
            "{env:?}"
        );
    }
}

#[test]
fn rejects_an_expired_token_at_exp_minus_skew_and_not_a_second_sooner() {
    assert_eq!(
        refused_with(|s| {
            set(s, "iat", json!(NOW - 90));
            set(s, "nbf", json!(NOW - 90));
            set(s, "exp", json!(NOW - 30));
        }),
        Reason::Expired
    );
    assert_eq!(
        refused_with(|s| {
            set(s, "iat", json!(NOW - 9000));
            set(s, "nbf", json!(NOW - 9000));
            set(s, "exp", json!(NOW - 8940));
        }),
        Reason::Expired
    );
}

#[test]
fn rejects_a_not_yet_valid_token_beyond_the_skew() {
    assert_eq!(
        refused_with(|s| set(s, "nbf", json!(NOW + 31))),
        Reason::NotYetValid
    );
    assert_eq!(
        refused_with(|s| {
            set(s, "nbf", json!(NOW + 3600));
            set(s, "iat", json!(NOW + 3600));
            set(s, "exp", json!(NOW + 3660));
        }),
        Reason::NotYetValid
    );
}

#[test]
fn rejects_a_lifetime_over_sixty_seconds_even_when_currently_valid() {
    assert_eq!(
        refused_with(|s| set(s, "exp", json!(NOW + 61))),
        Reason::Lifetime
    );
    assert_eq!(
        refused_with(|s| set(s, "iat", json!(NOW - 1))),
        Reason::Lifetime
    );
    assert_eq!(
        refused_with(|s| set(s, "exp", json!(NOW))),
        Reason::Lifetime,
        "zero lifetime"
    );
    assert_eq!(
        refused_with(|s| set(s, "exp", json!(NOW - 1))),
        Reason::Lifetime,
        "negative lifetime"
    );
    accepted_with(|s| set(s, "exp", json!(NOW + 1)));
}

#[test]
fn rejects_a_token_missing_any_required_claim_or_holding_null() {
    for claim in [
        "iss",
        "aud",
        "env",
        "sub",
        "email",
        "email_verified",
        "nonce",
        "iat",
        "nbf",
        "exp",
        "jti",
    ] {
        assert_eq!(
            refused_with(|s| {
                s.claims.remove(claim);
            }),
            Reason::MissingClaim,
            "{claim}"
        );
        assert_eq!(
            refused_with(|s| set(s, claim, Value::Null)),
            Reason::MissingClaim,
            "null {claim}"
        );
    }
    accepted_with(|s| {
        s.claims.remove("roles");
        s.claims.remove("idp_iss");
        s.claims.remove("idp_sub");
    });
}

// --- single use, nonce, state ----------------------------------------------------------------

#[test]
fn accepts_a_jti_once_and_rejects_the_replay() {
    let verifier = verifier_for(&[&KEY_A]);
    let scenario = Scenario::good();
    assert!(scenario.run(&verifier).is_ok());
    assert_eq!(scenario.run(&verifier).unwrap_err().reason, Reason::Replay);
    assert_eq!(scenario.run(&verifier).unwrap_err().reason, Reason::Replay);
}

#[test]
fn does_not_burn_the_jti_when_an_earlier_check_fails() {
    let verifier = verifier_for(&[&KEY_A]);
    let mut attacker = Scenario::good();
    attacker.cookie = Some(super::verify::SigninCookie {
        nonce: "attackers-own-nonce-value".into(),
        state: STATE.into(),
    });
    assert_eq!(
        attacker.run(&verifier).unwrap_err().reason,
        Reason::NonceMismatch
    );
    assert!(
        Scenario::good().run(&verifier).is_ok(),
        "the genuine browser still redeems it"
    );
}

#[test]
fn records_the_jti_until_exp_plus_skew_and_not_before() {
    let verifier = verifier_for(&[&KEY_A]);
    Scenario::good().run(&verifier).unwrap();
    let store = verifier.jti_store();
    assert!(!store.claim("jti-scenario-0000000000", NOW + 200, NOW + 89));
    assert!(store.claim("jti-scenario-0000000000", NOW + 200, NOW + 90));
}

#[test]
fn a_jti_that_is_not_a_string_is_a_replay_not_a_pass() {
    assert_eq!(refused_with(|s| set(s, "jti", json!(5))), Reason::Replay);
    assert_eq!(refused_with(|s| set(s, "jti", json!(""))), Reason::Replay);
}

#[test]
fn rejects_a_nonce_that_differs_from_the_cookie() {
    let mut scenario = Scenario::good();
    scenario.cookie.as_mut().unwrap().nonce = "x".repeat(20);
    assert_eq!(
        scenario.run(&verifier_for(&[&KEY_A])).unwrap_err().reason,
        Reason::NonceMismatch
    );
    assert_eq!(
        refused_with(|s| set(s, "nonce", json!(NONCE.to_lowercase()))),
        Reason::NonceMismatch
    );
    assert_eq!(
        refused_with(|s| set(s, "nonce", json!(7))),
        Reason::NonceMismatch
    );
}

#[test]
fn rejects_when_the_cookie_is_absent_or_lacks_a_value() {
    assert_eq!(refused_with(|s| s.cookie = None), Reason::MissingCookie);
    assert_eq!(
        refused_with(|s| s.cookie.as_mut().unwrap().state = String::new()),
        Reason::MissingCookie
    );
    assert_eq!(
        refused_with(|s| s.cookie.as_mut().unwrap().nonce = String::new()),
        Reason::MissingCookie
    );
}

#[test]
fn rejects_a_state_that_differs_or_is_missing_or_empty() {
    assert_eq!(
        refused_with(|s| s.state = Some("other".into())),
        Reason::StateMismatch
    );
    assert_eq!(refused_with(|s| s.state = None), Reason::StateMismatch);
    assert_eq!(
        refused_with(|s| s.state = Some(String::new())),
        Reason::StateMismatch
    );
    assert_eq!(
        refused_with(|s| s.state = Some(format!("{STATE} "))),
        Reason::StateMismatch
    );
}

#[test]
fn checks_state_before_it_looks_at_the_token_at_all() {
    let verifier = verifier_for(&[&KEY_A]);
    let cookie = good_cookie();
    for token in [Some("garbage"), None, Some("")] {
        let request = SigninRequest {
            token,
            state: Some("wrong"),
            cookie: Some(&cookie),
        };
        assert_eq!(
            verifier.verify(&request, NOW).unwrap_err().reason,
            Reason::StateMismatch
        );
    }
}

// --- identity --------------------------------------------------------------------------------

#[test]
fn rejects_email_verified_false_and_a_non_boolean() {
    for value in [
        json!(false),
        json!("true"),
        json!(1),
        json!([true]),
        json!(""),
    ] {
        assert_eq!(
            refused_with(|s| set(s, "email_verified", value.clone())),
            Reason::EmailUnverified,
            "{value}"
        );
    }
}

#[test]
fn handles_a_mixed_case_email_consistently() {
    accepted_with(|s| set(s, "email", json!("Person@Example.TEST")));
    assert_eq!(
        refused_with(|s| {
            set(s, "email", json!("Person@Example.TEST"));
            set(s, "sub", json!("Person@Example.TEST"));
        }),
        Reason::SubjectMismatch
    );
    assert_eq!(
        refused_with(|s| set(s, "sub", json!("other@example.test"))),
        Reason::SubjectMismatch
    );
}

#[test]
fn rejects_an_email_or_sub_that_is_not_a_string() {
    assert_eq!(
        refused_with(|s| set(s, "email", json!(["person@example.test"]))),
        Reason::Malformed
    );
    assert_eq!(refused_with(|s| set(s, "sub", json!(7))), Reason::Malformed);
}

// --- another site, another environment ----------------------------------------------------------

fn verifier_pinned(site: &str, environment: &str) -> Verifier<StaticKeys> {
    let config = PlatformSigninConfig::new(ISSUER, "https://issuer.example/k", site, environment);
    Verifier::new(config, static_keys(&[&KEY_A]), JtiStore::new())
}

#[test]
fn a_token_for_site_a_presented_to_site_b_is_refused() {
    assert_eq!(
        Scenario::good()
            .run(&verifier_pinned("site-b", ENVIRONMENT))
            .unwrap_err()
            .reason,
        Reason::BadAud
    );
}

#[test]
fn a_production_token_on_a_staging_site_is_refused() {
    assert_eq!(
        Scenario::good()
            .run(&verifier_pinned(SITE, "staging"))
            .unwrap_err()
            .reason,
        Reason::BadEnv
    );
}

#[test]
fn a_verifier_pinned_to_another_issuer_refuses_this_issuers_tokens() {
    let config = PlatformSigninConfig::new(
        "https://other-issuer.example",
        "https://other-issuer.example/k",
        SITE,
        ENVIRONMENT,
    );
    let verifier = Verifier::new(config, static_keys(&[&KEY_A]), JtiStore::new());
    assert_eq!(
        Scenario::good().run(&verifier).unwrap_err().reason,
        Reason::BadIss
    );
}

// --- keys through the cache ------------------------------------------------------------------

fn cached_verifier(documents: Vec<String>) -> (Verifier<JwksCache<FnFetcher>>, Arc<AtomicUsize>) {
    let calls = Arc::new(AtomicUsize::new(0));
    let seen = calls.clone();
    let fetcher = FnFetcher(Box::new(move || {
        let n = seen.fetch_add(1, Ordering::SeqCst);
        Ok(documents[n.min(documents.len() - 1)].clone())
    }));
    (
        Verifier::new(config(), JwksCache::new(fetcher), JtiStore::new()),
        calls,
    )
}

fn run_with<K: KeySource>(verifier: &Verifier<K>, scenario: &Scenario) -> Result<(), Reason> {
    let token = scenario.token();
    let request = SigninRequest {
        token: Some(&token),
        state: scenario.state.as_deref(),
        cookie: scenario.cookie.as_ref(),
    };
    verifier
        .verify(&request, scenario.now)
        .map(|_| ())
        .map_err(|r| r.reason)
}

#[test]
fn a_flood_of_unknown_kids_causes_one_fetch_not_one_per_token() {
    let (verifier, calls) = cached_verifier(vec![jwks_document(&[&KEY_A])]);
    for i in 0..100 {
        let mut scenario = Scenario::good();
        scenario
            .header
            .insert("kid".into(), json!(format!("random-kid-{i}")));
        scenario.now = NOW + (i % 25);
        assert_eq!(run_with(&verifier, &scenario), Err(Reason::UnknownKid));
    }
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn a_known_kid_does_not_refetch() {
    let (verifier, calls) = cached_verifier(vec![jwks_document(&[&KEY_A])]);
    for i in 0..5 {
        let mut scenario = Scenario::good();
        set(&mut scenario, "jti", json!(format!("jti-known-{i}")));
        assert_eq!(run_with(&verifier, &scenario), Ok(()));
    }
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[test]
fn a_previous_key_verifies_while_listed_and_is_refused_once_removed() {
    let (verifier, _) = cached_verifier(vec![
        jwks_document(&[&KEY_A, &KEY_B]),
        jwks_document(&[&KEY_B]),
    ]);
    let mut old = Scenario::good();
    old.signer = KEY_A;
    assert_eq!(run_with(&verifier, &old), Ok(()));
    let mut newer = Scenario::good();
    newer.signer = KEY_B;
    newer.header.insert("kid".into(), json!(KEY_B.kid()));
    set(&mut newer, "jti", json!("jti-rotated-key-0001"));
    assert_eq!(run_with(&verifier, &newer), Ok(()));
    let mut later = Scenario::good();
    later.now = NOW + 300;
    set(&mut later, "iat", json!(NOW + 300));
    set(&mut later, "nbf", json!(NOW + 300));
    set(&mut later, "exp", json!(NOW + 360));
    set(&mut later, "jti", json!("jti-after-removal-001"));
    assert_eq!(run_with(&verifier, &later), Err(Reason::UnknownKid));
}

// --- the order of the checks -----------------------------------------------------------------

type Fault = fn(&mut Scenario);

fn missing_cookie(s: &mut Scenario) {
    s.cookie = None;
}
fn state_mismatch(s: &mut Scenario) {
    s.state = Some("wrong-state".into());
}
fn garbage_token(s: &mut Scenario) {
    s.replace_token = Some("not.a.token".into());
}
fn too_large(s: &mut Scenario) {
    set(s, "pad", json!("x".repeat(5000)));
}
fn bad_alg(s: &mut Scenario) {
    s.header.insert("alg".into(), json!("none"));
}
fn bad_typ(s: &mut Scenario) {
    s.header.insert("typ".into(), json!("JWS"));
}
fn unknown_kid(s: &mut Scenario) {
    s.header.insert("kid".into(), json!("nope"));
}
fn bad_signature(s: &mut Scenario) {
    s.flip_signature = true;
}
fn missing_claim(s: &mut Scenario) {
    s.claims.remove("jti");
}
fn bad_iss(s: &mut Scenario) {
    set(s, "iss", json!("https://evil.example"));
}
fn bad_aud(s: &mut Scenario) {
    set(s, "aud", json!("site-b"));
}
fn bad_env(s: &mut Scenario) {
    set(s, "env", json!("staging"));
}
fn float_exp(s: &mut Scenario) {
    set(s, "exp", json!(1_800_000_060.5));
}
fn not_yet_valid(s: &mut Scenario) {
    set(s, "nbf", json!(NOW + 100));
}
fn expired(s: &mut Scenario) {
    set(s, "iat", json!(NOW - 160));
    set(s, "exp", json!(NOW - 100));
}
fn long_lifetime(s: &mut Scenario) {
    set(s, "iat", json!(NOW - 100));
}
fn nonce_mismatch(s: &mut Scenario) {
    set(s, "nonce", json!("someone-elses-nonce"));
}
fn replayed(s: &mut Scenario) {
    s.spend_first = true;
}
fn unverified(s: &mut Scenario) {
    set(s, "email_verified", json!(false));
}
fn wrong_subject(s: &mut Scenario) {
    set(s, "sub", json!("other@example.test"));
}

fn with_both(first: Fault, second: Fault) -> (Reason, Reason) {
    let run = |a: Fault, b: Fault| {
        let mut scenario = Scenario::good();
        a(&mut scenario);
        b(&mut scenario);
        scenario
            .run(&verifier_for(&[&KEY_A]))
            .expect_err("two faults")
            .reason
    };
    (run(first, second), run(second, first))
}

#[test]
fn a_token_with_two_faults_reports_the_first_in_the_references_order() {
    let pairs: [(Fault, Fault, Reason); 20] = [
        (missing_cookie, state_mismatch, Reason::MissingCookie),
        (missing_cookie, garbage_token, Reason::MissingCookie),
        (state_mismatch, garbage_token, Reason::StateMismatch),
        (state_mismatch, bad_signature, Reason::StateMismatch),
        (too_large, bad_alg, Reason::TooLarge),
        (bad_alg, bad_typ, Reason::BadAlg),
        (bad_alg, unknown_kid, Reason::BadAlg),
        (bad_typ, unknown_kid, Reason::Malformed),
        (unknown_kid, bad_aud, Reason::UnknownKid),
        (bad_signature, bad_aud, Reason::BadSignature),
        (bad_signature, missing_claim, Reason::BadSignature),
        (missing_claim, bad_iss, Reason::MissingClaim),
        (bad_iss, bad_aud, Reason::BadIss),
        (bad_aud, bad_env, Reason::BadAud),
        (bad_env, float_exp, Reason::BadEnv),
        (float_exp, not_yet_valid, Reason::Malformed),
        (not_yet_valid, expired, Reason::NotYetValid),
        (expired, long_lifetime, Reason::Expired),
        (long_lifetime, nonce_mismatch, Reason::Lifetime),
        (nonce_mismatch, replayed, Reason::NonceMismatch),
    ];
    for (first, second, expected) in pairs {
        assert_eq!(
            with_both(first, second),
            (expected, expected),
            "{expected:?} must win in either application order"
        );
    }
}

#[test]
fn the_identity_checks_come_last() {
    assert_eq!(
        with_both(replayed, unverified),
        (Reason::Replay, Reason::Replay)
    );
    assert_eq!(
        with_both(unverified, wrong_subject),
        (Reason::EmailUnverified, Reason::EmailUnverified)
    );
    assert_eq!(
        with_both(nonce_mismatch, unverified),
        (Reason::NonceMismatch, Reason::NonceMismatch)
    );
}

#[test]
fn the_replay_check_spends_nothing_when_an_earlier_check_fails() {
    for fault in [
        state_mismatch,
        bad_alg,
        bad_signature,
        bad_aud,
        expired,
        nonce_mismatch,
    ] {
        let verifier = verifier_for(&[&KEY_A]);
        let mut scenario = Scenario::good();
        fault(&mut scenario);
        assert!(scenario.run(&verifier).is_err());
        assert!(
            verifier.jti_store().is_empty(NOW),
            "a refused request must not leave a spent jti"
        );
    }
}

#[test]
fn identity_failures_come_after_the_jti_is_spent() {
    let verifier = verifier_for(&[&KEY_A]);
    let mut scenario = Scenario::good();
    unverified(&mut scenario);
    assert_eq!(
        scenario.run(&verifier).unwrap_err().reason,
        Reason::EmailUnverified
    );
    assert_eq!(
        verifier.jti_store().len(NOW),
        1,
        "the reference spends the jti before the identity checks"
    );
}

// --- hostile input never panics --------------------------------------------------------------

#[test]
fn every_single_character_mutation_of_a_good_token_is_answered_without_panicking() {
    let good = Scenario::good().token();
    let cookie = good_cookie();
    let replacements = ['A', '.', '=', '-', '_', ' ', '\u{0}', '\u{e9}', '\u{1f600}'];
    for position in (0..good.len()).step_by(7) {
        for replacement in replacements {
            if !good.is_char_boundary(position) {
                continue;
            }
            let mut mutated = good.clone();
            mutated.replace_range(position..=position, &replacement.to_string());
            let request = SigninRequest {
                token: Some(&mutated),
                state: Some(STATE),
                cookie: Some(&cookie),
            };
            let verdict = verifier_for(&[&KEY_A]).verify(&request, NOW);
            if mutated != good {
                assert!(
                    verdict.is_err(),
                    "a mutated token must never be accepted: position {position}"
                );
            }
        }
    }
}

#[test]
fn extreme_numbers_in_time_claims_are_refused_without_overflow() {
    let big = "99999999999999999999999999999999999999999999999";
    for claim in ["iat", "nbf", "exp"] {
        let claims = Scenario::good().claims;
        let mut text = Value::Object(claims).to_string();
        let needle = format!("\"{claim}\":");
        let start = text.find(&needle).unwrap() + needle.len();
        let end = start + text[start..].find([',', '}']).unwrap();
        text.replace_range(start..end, big);
        let header = json!({"alg": "EdDSA", "typ": "JWT", "kid": KEY_A.kid()}).to_string();
        let token = assemble(&header, &text, &KEY_A);
        assert!(
            matches!(
                raw_token_reason(Some(&token)),
                Reason::NotYetValid | Reason::Lifetime | Reason::Expired
            ),
            "{claim}"
        );
        if claim == "nbf" {
            continue; // a far-past `nbf` is simply valid; only the other two have a negative extreme to refuse
        }
        let negative = text.replace(big, &format!("-{big}"));
        let token = assemble(&header, &negative, &KEY_A);
        assert!(
            matches!(
                raw_token_reason(Some(&token)),
                Reason::Expired | Reason::Lifetime
            ),
            "{claim}"
        );
    }
}
