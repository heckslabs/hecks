//! Seeded fuzz of the HTTP front entry point (`admit`, `value_to_response`): hostile bodies, methods, URIs
//! and headers must be answered, never panic, and a refused request must leave no trace.
//! Everything here is in-process: `admit` is the whole of what runs before dispatch, so none of
//! it needs Postgres or wasm.

use super::*;
use crate::fuzz_support::*;
use serde_json::json;

fn limits(pairs: &[(&str, &str)]) -> RateLimits {
    let map: std::collections::HashMap<String, String> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    RateLimits::new(crate::rate_limit::Config::from_lookup(|name| map.get(name).cloned()).0)
}

fn peer(text: &str) -> SocketAddr {
    text.parse().unwrap()
}

const PEERS: &[&str] = &["127.0.0.1:5000", "[::1]:5000", "[::ffff:127.0.0.1]:5000", "10.0.0.5:5000", "203.0.113.7:5000", "[2001:db8::1]:5000"];

fn random_method(rng: &mut Rng) -> Method {
    let methods = [Method::GET, Method::POST, Method::PUT, Method::DELETE, Method::PATCH, Method::HEAD, Method::OPTIONS, Method::TRACE, Method::CONNECT];
    if rng.chance(8) {
        Method::from_bytes(b"BREW").unwrap()
    } else {
        rng.pick(&methods).clone()
    }
}

/// A URI that parses: a hostile path built from the pieces, or a fixed route the limiter knows.
fn random_uri(rng: &mut Rng) -> Uri {
    const FIXED: &[&str] = &["/", "/newsletter/subscribers", "/registrations", "/api/me", "/login", "/%00", "/../..", "/a?b=%a", "/x?%", "/a//b", "/a;b", "*"];
    if rng.chance(3) {
        return rng.pick(FIXED).parse().unwrap();
    }
    for _ in 0..8 {
        let path: String = (0..rng.below(4)).map(|_| format!("/{}", rng.pick(PIECES_ASCII))).collect();
        let query = if rng.chance(2) { format!("?{}={}", rng.pick(PIECES_ASCII), rng.pick(PIECES_ASCII)) } else { String::new() };
        if let Ok(uri) = format!("{path}{query}").parse::<Uri>() {
            return uri;
        }
    }
    "/".parse().unwrap()
}

const PIECES_ASCII: &[&str] = &["a", "b", "0", "%41", "%zz", "%", "%00", "..", ".", "-", "_", "id", "api", "me", "newsletter", "subscribers", "x y", "a+b", "=", "&", "a=b"];

fn random_headers(rng: &mut Rng) -> HeaderMap {
    const NAMES: &[&str] = &["x-forwarded-for", "cookie", "content-type", "authorization", "host", "x-real-ip", "x-hecks-proxy-auth", "x-anything", "content-length", "set-cookie"];
    let mut headers = HeaderMap::new();
    for _ in 0..rng.below(5) {
        let name = HeaderName::from_static(rng.pick(NAMES));
        let bytes: Vec<u8> = match rng.below(4) {
            0 => random_text(rng).into_bytes(),
            1 => (0..rng.below(24)).map(|_| rng.next() as u8).collect(),
            2 => b"1.2.3.4, 5.6.7.8, ::1, not-an-ip, [::ffff:127.0.0.1]".to_vec(),
            _ => "x".repeat(rng.below(9000)).into_bytes(),
        };
        // Header values are a restricted byte set; the ones the type refuses never reach `admit`.
        if let Ok(value) = HeaderValue::from_bytes(&bytes) {
            headers.append(name, value);
        }
    }
    headers
}

fn status_of(refusal: &Response) -> u16 {
    refusal.status().as_u16()
}

#[test]
fn admit_answers_every_hostile_request_without_panicking() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed);
            let limits = limits(&[]);
            for _ in 0..30 {
                let from = peer(rng.pick(PEERS));
                let method = random_method(&mut rng);
                let uri = random_uri(&mut rng);
                let headers = random_headers(&mut rng);
                let body = Bytes::from(random_bytes(&mut rng));

                let parsed = if body.is_empty() { Some(json!({})) } else { serde_json::from_slice::<Value>(&body).ok() };
                let answer = admit(&limits, from, &method, &uri, &headers, &body);
                match (parsed, answer) {
                    (None, Err(refusal)) => assert_eq!(status_of(&refusal), 400, "seed {seed}: a body that is not JSON is a 400, got {}", status_of(&refusal)),
                    (None, Ok(envelope)) => panic!("seed {seed}: admitted a body that is not JSON: {envelope}"),
                    (Some(_), Err(refusal)) => assert_eq!(status_of(&refusal), 429, "seed {seed}: valid JSON is refused only by the limiter, got {}", status_of(&refusal)),
                    (Some(parsed), Ok(envelope)) => {
                        let internal = trusts_internal_dispatch(from) && is_internal_dispatch_shape(&parsed);
                        if internal {
                            assert_eq!(envelope, parsed, "seed {seed}: a trusted internal body passes through untouched");
                        } else {
                            assert_eq!(envelope["requestContext"]["http"]["method"], method.as_str(), "seed {seed}");
                            assert_eq!(envelope["rawPath"], uri.path(), "seed {seed}");
                            assert!(envelope["body"].is_string(), "seed {seed}: the synthesized body is text");
                            assert_eq!(envelope["isBase64Encoded"], false, "seed {seed}");
                        }
                    }
                }
            }
        });
    }
}

#[test]
fn a_public_peer_can_never_smuggle_in_the_internal_dispatch_protocol() {
    // The internal shapes carry a caller's own `role` with no session check; only loopback may use them.
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0xBEEF);
            let limits = limits(&[]);
            for _ in 0..20 {
                let mut internal = serde_json::Map::new();
                for key in ["verb", "role", "actor_id", "args", "read", "query", "to", "with", "requestContext", "cookies"] {
                    if rng.chance(2) {
                        internal.insert(key.to_string(), random_value(&mut rng, 1));
                    }
                }
                let body = Bytes::from(Value::Object(internal).to_string());
                let from = peer(rng.pick(&PEERS[3..]));
                let envelope = admit(&limits, from, &Method::POST, &"/x".parse().unwrap(), &random_headers(&mut rng), &body)
                    .unwrap_or_else(|_| panic!("seed {seed}: valid JSON from a public peer is admitted"));
                let keys: std::collections::BTreeSet<&str> = envelope.as_object().unwrap().keys().map(String::as_str).collect();
                let expected: std::collections::BTreeSet<&str> = ["requestContext", "rawPath", "rawQueryString", "headers", "body", "isBase64Encoded"].into();
                assert_eq!(keys, expected, "seed {seed}: a public peer's body must be wrapped as plain request data");
            }
        });
    }
}

#[test]
fn a_malformed_body_is_refused_before_it_costs_any_rate_limit_budget() {
    let limits = limits(&[("HECKS_RATE_LIMIT_SUBSCRIBE", "1")]);
    let from = peer("203.0.113.7:5000");
    let uri: Uri = "/newsletter/subscribers".parse().unwrap();
    for body in ["{", "not json", "{\"a\":", "\u{0}", "[1,", "{\"a\":1}x", "\u{feff}{}"] {
        for _ in 0..10 {
            let refusal = admit(&limits, from, &Method::POST, &uri, &HeaderMap::new(), &Bytes::from(body.to_string())).err().expect("refused");
            assert_eq!(status_of(&refusal), 400, "{body:?}");
        }
    }
    let spent = |limits: &RateLimits| admit(limits, from, &Method::POST, &uri, &HeaderMap::new(), &Bytes::from("{}")).is_ok();
    assert!(spent(&limits), "the one allowed request still goes through after the refusals");
    assert!(!spent(&limits), "and the next is limited: only the valid request spent budget");
}

#[test]
fn invalid_utf8_and_oversized_bodies_are_answered() {
    let limits = limits(&[]);
    let from = peer("203.0.113.7:5000");
    let uri: Uri = "/x".parse().unwrap();
    let invalid = Bytes::from(vec![0xff, 0xfe, 0xfd]);
    assert_eq!(status_of(&admit(&limits, from, &Method::POST, &uri, &HeaderMap::new(), &invalid).err().unwrap()), 400);

    // A 16 MiB body of valid JSON is admitted as text (a size cap belongs to the listener, not here)
    // and a 16 MiB run of openers is refused by the parser's depth limit rather than overflowing.
    guarded("large bodies", move || {
        let big_string = Bytes::from(format!("\"{}\"", "a".repeat(16 * 1024 * 1024)));
        assert!(admit(&limits, from, &Method::POST, &uri, &HeaderMap::new(), &big_string).is_ok());
        let openers = Bytes::from("[".repeat(16 * 1024 * 1024));
        let refusal = admit(&limits, from, &Method::POST, &uri, &HeaderMap::new(), &openers).err().expect("refused");
        assert_eq!(status_of(&refusal), 400);
        let nested = Bytes::from(format!("{}1{}", "[".repeat(100_000), "]".repeat(100_000)));
        assert_eq!(status_of(&admit(&limits, from, &Method::POST, &uri, &HeaderMap::new(), &nested).err().expect("refused")), 400);
    });
}

#[test]
fn value_to_response_answers_any_shape_of_handler_output() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0xFACE);
            for _ in 0..30 {
                let mut value = serde_json::Map::new();
                for key in ["statusCode", "headers", "cookies", "body", "isBase64Encoded", "extra"] {
                    if rng.chance(4) {
                        continue;
                    }
                    let field = match key {
                        "headers" if rng.chance(2) => {
                            let mut map = serde_json::Map::new();
                            for _ in 0..rng.below(4) {
                                map.insert(random_text(&mut rng), random_value(&mut rng, 2));
                            }
                            Value::Object(map)
                        }
                        "cookies" if rng.chance(2) => Value::Array((0..rng.below(4)).map(|_| random_value(&mut rng, 2)).collect()),
                        "statusCode" if rng.chance(2) => json!(*rng.pick(&[0u64, 99, 100, 199, 200, 204, 299, 301, 404, 599, 600, 999, 65_536, 65_736, u64::MAX])),
                        _ => random_value(&mut rng, 1),
                    };
                    value.insert(key.to_string(), field);
                }
                let response = value_to_response(Value::Object(value));
                // Whatever came in, what goes out is a real status.
                assert!((100..1000).contains(&status_of(&response)), "seed {seed}");
            }
            let plain = value_to_response(random_value(&mut rng, 0));
            assert!((100..1000).contains(&status_of(&plain)), "seed {seed}");
        });
    }
}

#[test]
fn an_out_of_range_status_code_is_a_500_not_a_wrapped_status() {
    // `65736 as u16` is 200: a handler bug must not turn into a success.
    for code in [0u64, 99, 1000, 65_536, 65_736, 131_272, u64::MAX] {
        let response = value_to_response(json!({ "statusCode": code, "body": "x" }));
        assert_eq!(status_of(&response), 500, "statusCode {code}");
    }
    assert_eq!(status_of(&value_to_response(json!({ "statusCode": 204 }))), 204);
}

#[test]
fn control_characters_in_response_headers_and_cookies_are_dropped_not_emitted() {
    let response = value_to_response(json!({
        "statusCode": 200,
        "headers": { "x-ok": "fine", "x-split": "a\r\nSet-Cookie: stolen=1", "bad name": "v" },
        "cookies": ["session=abc; Path=/", "evil=1\r\nX-Injected: yes", "nul=\u{0}"],
        "body": ""
    }));
    assert!(response.headers().get("x-split").is_none());
    assert!(response.headers().get("x-injected").is_none());
    let cookies: Vec<&str> = response.headers().get_all("set-cookie").iter().filter_map(|v| v.to_str().ok()).collect();
    assert_eq!(cookies, vec!["session=abc; Path=/"]);
}
