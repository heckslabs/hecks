//! Seeded fuzz of the signed-cookie and token readers: whatever text arrives in a `Cookie`
//! header or a query string, it either verifies as exactly what this host signed or yields
//! nothing. A forged, truncated or tampered token must never read as a session, and none of it
//! may panic.

use super::*;
use crate::fuzz_support::*;

const SECRET: &str = "fuzz-secret";

fn session(rng: &mut Rng) -> Session {
    Session { identity_id: random_text(rng), email: random_text(rng), name: random_text(rng), role: if rng.chance(2) { Some(random_text(rng)) } else { None } }
}

#[test]
fn a_signed_cookie_reads_back_as_the_session_it_was_made_from() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed);
            for _ in 0..30 {
                let original = session(&mut rng);
                let cookie = session_cookie(SECRET, &original);
                let read = parse_session_cookie(SECRET, &cookie).unwrap_or_else(|| panic!("seed {seed}: own cookie for {:?} refused", original.email));
                assert_eq!((read.identity_id, read.email, read.name, read.role), (original.identity_id, original.email, original.name, original.role), "seed {seed}");
                assert!(parse_session_cookie("another-secret", &cookie).is_none(), "seed {seed}: a different secret verified the cookie");
            }
        });
    }
}

#[test]
fn no_arbitrary_or_tampered_token_ever_verifies() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0x70C);
            let genuine_cookie = session_cookie(SECRET, &session(&mut rng));
            let genuine_account = account_token(SECRET, &random_text(&mut rng), 60);
            let genuine_purpose = purpose_token(SECRET, "reset", json!({"email": random_text(&mut rng)}), 60);
            for _ in 0..40 {
                let junk = match rng.below(4) {
                    0 => random_text(&mut rng),
                    1 => format!("{}.{}", random_text(&mut rng), random_text(&mut rng)),
                    2 => ".".repeat(rng.below(4)),
                    _ => String::from_utf8_lossy(&random_bytes(&mut rng)).into_owned(),
                };
                assert!(parse_session_cookie(SECRET, &junk).is_none(), "seed {seed}: {junk:?} read as a session");
                assert!(verify_account_token(SECRET, &junk).is_none(), "seed {seed}: {junk:?} read as an account token");
                assert!(verify_purpose_token(SECRET, "reset", &junk).is_none(), "seed {seed}: {junk:?} read as a purpose token");

                for (genuine, verifies) in [
                    (&genuine_cookie, (|t: &str| parse_session_cookie(SECRET, t).is_some()) as fn(&str) -> bool),
                    (&genuine_account, |t: &str| verify_account_token(SECRET, t).is_some()),
                    (&genuine_purpose, |t: &str| verify_purpose_token(SECRET, "reset", t).is_some()),
                ] {
                    assert!(verifies(genuine), "seed {seed}: the untampered token must verify");
                    let tampered = mutate_text(&mut rng, genuine);
                    assert!(tampered == *genuine || !verifies(&tampered), "seed {seed}: tampered token {tampered:?} verified");
                }
            }
        });
    }
}

#[test]
fn a_token_for_one_purpose_never_verifies_for_another_or_as_an_account_token() {
    let token = purpose_token(SECRET, "reset", json!({"email": "a@example.com"}), 60);
    assert!(verify_purpose_token(SECRET, "reset", &token).is_some());
    for other in ["", "RESET", "reset ", "reset:", "invite", "reset:fuzz-secret"] {
        assert!(verify_purpose_token(SECRET, other, &token).is_none(), "purpose {other:?}");
    }
    assert!(verify_account_token(SECRET, &token).is_none());
    assert!(parse_session_cookie(SECRET, &token).is_none());
}

#[test]
fn an_expired_or_unexpiring_signed_payload_is_not_a_session() {
    let sign_payload = |payload: Value| {
        let encoded = base64_encode(payload.to_string().as_bytes());
        format!("{encoded}.{}", sign(SECRET, &encoded))
    };
    let person = json!({"identity_id": "i", "email": "e", "name": "n"});
    for exp in [json!(0), json!(1), json!(-1), json!(1.5), json!("9999999999"), json!(null), json!(u64::MAX)] {
        let mut payload = person.clone();
        payload["exp"] = exp.clone();
        let verdict = parse_session_cookie(SECRET, &sign_payload(payload)).is_some();
        assert_eq!(verdict, exp == json!(u64::MAX), "exp {exp}");
    }
    assert!(parse_session_cookie(SECRET, &sign_payload(person)).is_none(), "no exp is no session");
    for payload in [json!([]), json!(1), json!("s"), json!(null), json!({"exp": u64::MAX}), json!({"exp": u64::MAX, "identity_id": 1, "email": "e", "name": "n"})] {
        assert!(parse_session_cookie(SECRET, &sign_payload(payload.clone())).is_none(), "{payload}");
        assert!(verify_account_token(SECRET, &sign_payload(payload.clone())).is_none() || payload.get("email").is_some(), "{payload}");
    }
}

#[test]
fn signature_comparison_checks_every_byte_and_the_length() {
    assert!(constant_time_eq(b"", b""));
    assert!(constant_time_eq(b"abc", b"abc"));
    assert!(!constant_time_eq(b"abc", b"abd"));
    assert!(!constant_time_eq(b"abc", b"xbc"));
    assert!(!constant_time_eq(b"abc", b"ab"));
    assert!(!constant_time_eq(b"ab", b"abc"));
}

#[test]
fn base64_decoding_and_cookie_names_take_any_text() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0xBA5E);
            for _ in 0..100 {
                let text = random_text(&mut rng);
                let _ = base64_decode(&text);
                let _ = resolve_account_cookie(Some(&text));
                let bytes = random_bytes(&mut rng);
                assert_eq!(base64_decode(&base64_encode(&bytes)), bytes, "seed {seed}");
            }
        });
    }
}
