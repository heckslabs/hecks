//! The known-answer vectors: tokens made by the issuer's own signer, and the verdict each must get.
//!
//! The file is a byte-for-byte copy of the issuer's vectors, pinned by hash so a change to either
//! copy fails loudly. Each single vector runs against a fresh single-use record; a sequence runs
//! its
//! steps against one record. The clock, the pinned issuer, site and environment, and the key set
//! all come from the file, and nothing touches the network.

use std::collections::HashSet;

use serde_json::Value;
use sha2::{Digest, Sha256};

use super::config::PlatformSigninConfig;
use super::jti::JtiStore;
use super::jwks::{parse_jwks, KeySource, VerifyingKey};
use super::test_support::{object_to_value, StaticKeys};
use super::verify::{Reason, SigninCookie, SigninRequest, Verifier};

const VECTORS_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/fixtures/platform_signin_vectors.json"
);
const PINNED_SHA256: &str = "09fd6d5780042657a7dc4892faa6fce45a652a6019b9e4d5bd3486280b54d94d";

fn bytes() -> Vec<u8> {
    std::fs::read(VECTORS_PATH).expect("the vectors file is checked in")
}

fn document() -> Value {
    serde_json::from_slice(&bytes()).expect("the vectors file is JSON")
}

fn hex(digest: &[u8]) -> String {
    use std::fmt::Write;
    digest.iter().fold(String::new(), |mut out, b| {
        let _ = write!(out, "{b:02x}"); // writing to a String cannot fail
        out
    })
}

fn text<'a>(value: &'a Value, name: &str) -> &'a str {
    value[name]
        .as_str()
        .unwrap_or_else(|| panic!("{name} is a string"))
}

fn whole(value: &Value, name: &str) -> i64 {
    value[name]
        .as_i64()
        .unwrap_or_else(|| panic!("{name} is an integer"))
}

fn verifier_for_document(doc: &Value) -> Verifier<StaticKeys> {
    let pins = &doc["config"];
    let mut config = PlatformSigninConfig::new(
        text(pins, "iss"),
        &format!("{}/.well-known/jwks.json", text(pins, "iss")),
        text(pins, "aud"),
        text(pins, "env"),
    );
    config.skew_seconds = whole(pins, "skew_seconds");
    config.max_lifetime_seconds = whole(pins, "max_lifetime_seconds");
    config.max_token_bytes = whole(pins, "max_token_bytes") as usize;
    let parsed = parse_jwks(&doc["jwks"].to_string()).expect("the key set parses");
    assert!(
        parsed.refused.is_empty(),
        "the key set holds only usable keys"
    );
    Verifier::new(config, StaticKeys(parsed.keys), JtiStore::new())
}

fn cookie_of(step: &Value) -> Option<SigninCookie> {
    let cookie = step.get("cookie").filter(|c| !c.is_null())?;
    let part = |name: &str| {
        cookie
            .get(name)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    Some(SigninCookie {
        nonce: part("nonce"),
        state: part("state"),
    })
}

fn run_step(verifier: &Verifier<StaticKeys>, step: &Value, now: i64, label: &str) {
    let cookie = cookie_of(step);
    let request = SigninRequest {
        token: step["token"].as_str(),
        state: step["state"].as_str(),
        cookie: cookie.as_ref(),
    };
    let verdict = verifier.verify(&request, now);
    match text(step, "expect") {
        "accept" => {
            let claims =
                verdict.unwrap_or_else(|r| panic!("{label}: expected accept, got {}", r.code()));
            assert_eq!(
                object_to_value(&claims.all),
                step["claims"],
                "{label}: the verified claims"
            );
            assert_eq!(
                claims.email,
                text(step, "email"),
                "{label}: the lowercased email"
            );
        }
        "refuse" => {
            let refusal = verdict.err().unwrap_or_else(|| {
                panic!(
                    "{label}: expected refusal {}, got accept",
                    text(step, "refusal")
                )
            });
            assert_eq!(refusal.code(), text(step, "refusal"), "{label}");
        }
        other => panic!("{label}: unknown expectation {other}"),
    }
}

#[test]
fn the_vectors_file_is_the_pinned_copy_byte_for_byte() {
    assert_eq!(hex(&Sha256::digest(bytes())), PINNED_SHA256);
}

#[test]
fn the_file_declares_the_fixed_clock_and_the_issuers_documented_limits() {
    let doc = document();
    assert_eq!(whole(&doc, "version"), 1);
    assert_eq!(whole(&doc, "now"), 1_800_000_000);
    let pins = &doc["config"];
    assert_eq!(
        (
            whole(pins, "skew_seconds"),
            whole(pins, "max_lifetime_seconds"),
            whole(pins, "max_token_bytes")
        ),
        (30, 60, 4096)
    );
}

#[test]
fn every_vector_gets_exactly_its_recorded_verdict() {
    let doc = document();
    let now = whole(&doc, "now");
    let vectors = doc["vectors"].as_array().expect("vectors");
    assert!(!vectors.is_empty());
    for vector in vectors {
        let name = text(vector, "name");
        let verifier = verifier_for_document(&doc);
        match text(vector, "type") {
            "single" => run_step(&verifier, vector, now, name),
            "sequence" => {
                for (index, step) in vector["steps"]
                    .as_array()
                    .expect("steps")
                    .iter()
                    .enumerate()
                {
                    run_step(&verifier, step, now, &format!("{name} step {}", index + 1));
                }
            }
            other => panic!("{name}: unknown vector type {other}"),
        }
    }
}

#[test]
fn the_vectors_exercise_every_reason_and_both_verdicts() {
    let doc = document();
    let mut refusals: HashSet<String> = HashSet::new();
    let mut accepts = 0;
    for vector in doc["vectors"].as_array().unwrap() {
        let steps: Vec<&Value> = match text(vector, "type") {
            "sequence" => vector["steps"].as_array().unwrap().iter().collect(),
            _ => vec![vector],
        };
        for step in steps {
            match text(step, "expect") {
                "accept" => accepts += 1,
                _ => {
                    refusals.insert(text(step, "refusal").to_string());
                }
            }
        }
    }
    assert!(accepts > 0);
    for reason in Reason::ALL {
        assert!(
            refusals.contains(reason.code()),
            "no vector refuses with {}",
            reason.code()
        );
    }
    assert!(
        refusals
            .iter()
            .all(|code| Reason::from_code(code).is_some()),
        "an unknown code in the file"
    );
}

#[test]
fn the_vectors_key_is_the_one_the_unit_tests_sign_with() {
    let doc = document();
    let parsed = parse_jwks(&doc["jwks"].to_string()).unwrap();
    let key: VerifyingKey = parsed
        .keys
        .get(super::test_support::KID_A)
        .cloned()
        .expect("the documented kid");
    assert_eq!(key.x(), super::test_support::X_A);
    assert_eq!(
        StaticKeys(parsed.keys).key_for(super::test_support::KID_A, 0),
        Some(key)
    );
}

#[test]
fn the_ordered_check_vectors_are_present_in_the_file() {
    let doc = document();
    let names: Vec<&str> = doc["vectors"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| text(v, "name"))
        .collect();
    for expected in [
        "order_state_before_token",
        "order_cookie_before_state",
        "order_aud_before_time",
        "order_iss_before_aud",
        "order_signature_before_claims",
        "order_time_before_nonce",
    ] {
        assert!(names.contains(&expected), "{expected}");
    }
}
