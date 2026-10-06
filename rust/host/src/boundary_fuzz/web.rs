//! Seeded fuzz of the web layer's request decoding: percent-decoding, form and query strings,
//! cookies, base64 bodies, path shaping and the auth gate. Every one takes text an anonymous
//! caller controls, and none may panic on it.

use super::*;
use crate::fuzz_support::*;

#[test]
fn percent_decoding_never_slices_through_a_multi_byte_character() {
    // `%a` followed by a 4-byte character puts the two-digit hex window mid-character.
    for text in ["%a🍕", "%🍕", "%é", "a%é", "%a日", "%%a🍕", "%1é1", "🍕%", "🍕%a", "%a", "%", "%%", "%4", "%41", "x%e6%97%a5y", "%e6%97", "%ff%fe"] {
        for plus_as_space in [true, false] {
            let decoded = percent_decode_impl(text, plus_as_space);
            assert!(decoded.len() < text.len() * 4 + 4, "{text:?}");
        }
    }
    assert_eq!(percent_decode("%41%2f%2F+x"), "A// x");
    assert_eq!(percent_decode_impl("a+b", false), "a+b");
}

#[test]
fn percent_decoding_reads_only_two_hex_digits_never_a_sign() {
    // `u8::from_str_radix` accepts a leading `+`, so `%+1` would decode to byte 0x01.
    assert_eq!(percent_decode_impl("%+1", false), "%+1");
    assert_eq!(percent_decode_impl("%-1", false), "%-1");
    assert_eq!(percent_decode_impl("%4g", false), "%4g");
    assert_eq!(percent_decode_impl("%41", false), "A");
}

#[test]
fn form_and_query_strings_decode_any_text() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed);
            for _ in 0..100 {
                let text = random_text(&mut rng);
                let _ = parse_form(&text);
                let _ = parse_query(&text);
                let _ = percent_decode(&text);
                let _ = auth::urlencode(&text);
                // What the encoder emits, the decoder must read back exactly.
                assert_eq!(percent_decode_impl(&auth::urlencode(&text), false), text, "seed {seed}: {text:?}");
            }
        });
    }
}

#[test]
fn huge_query_strings_decode_in_linear_time() {
    guarded("huge query", || {
        let pairs = (0..200_000).map(|i| format!("k{i}=%41%e6%97%a5")).collect::<Vec<_>>().join("&");
        assert_eq!(parse_query(&pairs).len(), 200_000);
        let _ = parse_form(&"%".repeat(5_000_000));
        let _ = parse_form(&"%a🍕".repeat(1_000_000));
    });
}

#[test]
fn cookie_extraction_reads_any_event_shape() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0xC00C);
            for _ in 0..50 {
                let body = match rng.below(4) {
                    0 => random_value(&mut rng, 0),
                    1 => json!({"cookies": random_value(&mut rng, 2)}),
                    2 => json!({"headers": {"cookie": random_value(&mut rng, 1)}}),
                    _ => json!({"cookies": [random_text(&mut rng), random_text(&mut rng)], "headers": {"cookie": random_text(&mut rng)}}),
                };
                let _ = extract_cookies(&body);
            }
        });
    }
}

#[test]
fn base64_bodies_decode_any_text_without_panicking() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0xB64);
            for _ in 0..100 {
                let text = random_text(&mut rng);
                let _ = base64_decode(&text);
                let _ = String::from_utf8(base64_decode(&text)).unwrap_or_default();
            }
        });
    }
    assert_eq!(base64_decode("aGk="), b"hi");
    assert!(base64_decode("").is_empty());
}

#[test]
fn paths_and_origins_shape_any_text() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0x9A7);
            for _ in 0..100 {
                let path = format!("/{}", random_text(&mut rng));
                let _ = json_shaped(&path);
                let _ = split_format(&path);
                let _ = origin_of(&path);
                let _ = same_origin(&path, &random_text(&mut rng));
                let _ = humanize(&path);
                let _ = esc(&path);
                for authenticated in [true, false] {
                    if let Some(refusal) = auth_gate(&path, authenticated) {
                        let status = refusal["statusCode"].as_u64().expect("a status");
                        assert!(status == 401 || status == 302, "seed {seed}: {path:?} gated with {status}");
                    }
                }
            }
        });
    }
}

#[test]
fn an_unauthenticated_request_is_never_let_past_the_gate_by_a_path_trick() {
    // Only the four sign-in paths are open; near-misses must be gated.
    for path in ["/login/", "/LOGIN", "/login%2f", "//login", "/login/../admin", "/auth/google/", "/auth/google/callback/x", "/logout.json", "/./login", "/login?x", "/login "] {
        assert!(auth_gate(path, false).is_some(), "{path:?} must be gated for an anonymous caller");
    }
    for path in ["/login", "/logout", "/auth/google", "/auth/google/callback"] {
        assert!(auth_gate(path, false).is_none(), "{path:?} is the sign-in path");
    }
}
