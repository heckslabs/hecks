//! The site's own sign-in cookie, `__Host-signin`, which binds a callback to the browser that
//! started the flow.
//!
//! The value is `<nonce>.<state>`, both base64url, written exactly as the issuer's reference
//! implementation writes it so the two sides agree. The `__Host-` prefix makes a browser insist on
//! `Secure`, `Path=/` and no `Domain`, so a sibling subdomain cannot plant a lookalike. `Secure` is
//! written unconditionally rather than inferred from the request, because the host sits behind
//! proxies that speak plain http to it. `SameSite=Lax`, not `Strict`: the return from the issuer is
//! a cross-site top-level navigation, and a strict cookie would not be sent on it.
//!
//! Reading is strict in the other direction: a cookie that appears twice is refused, because which
//! of two values counts is unknowable.

use serde_json::Value;

use super::verify::SigninCookie;

/// The attributes every write of the cookie carries, the same ones that set it and delete it.
const ATTRIBUTES: &str = "Path=/; Secure; HttpOnly; SameSite=Lax";
/// The cookie's name.
pub const NAME: &str = "__Host-signin";
/// How long the browser keeps the cookie, in seconds.
pub const MAX_AGE_SECONDS: u32 = 600;
/// The shortest nonce or state accepted.
pub const MIN_VALUE_LENGTH: usize = 16;
/// The longest nonce or state accepted.
pub const MAX_VALUE_LENGTH: usize = 128;

/// Why the cookie could not be used.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CookieFault {
    /// The browser sent no such cookie.
    Absent,
    /// The browser sent it more than once.
    Repeated,
    /// The value is not `<nonce>.<state>` of acceptable shape.
    Malformed,
}

/// Returns the `Set-Cookie` value that stores the nonce and state in the browser.
pub fn set_header(cookie: &SigninCookie) -> String {
    format!(
        "{NAME}={}.{}; Max-Age={MAX_AGE_SECONDS}; {ATTRIBUTES}",
        cookie.nonce, cookie.state
    )
}

/// Returns the `Set-Cookie` value that deletes the cookie, with the attributes that set it.
pub fn clear_header() -> String {
    format!("{NAME}=; Max-Age=0; {ATTRIBUTES}")
}

/// Collects every `name=value` pair the request carried, from the event's `cookies` array and its
/// `cookie` header.
pub fn request_pairs(event: &Value) -> Vec<String> {
    let listed = event
        .get("cookies")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str);
    let header = event
        .get("headers")
        .and_then(|h| h.get("cookie"))
        .and_then(Value::as_str)
        .into_iter()
        .flat_map(|h| h.split(';'));
    listed
        .chain(header)
        .map(|pair| pair.trim().to_string())
        .filter(|pair| !pair.is_empty())
        .collect()
}

/// Finds the sign-in cookie among the request's pairs.
///
/// # Errors
///
/// Returns the [`CookieFault`] that says why there is no usable cookie.
pub fn read(pairs: &[String]) -> Result<SigninCookie, CookieFault> {
    let mut values = pairs
        .iter()
        .filter_map(|pair| pair.split_once('='))
        .filter(|(name, _)| name.trim() == NAME)
        .map(|(_, value)| value.trim());
    let value = values.next().ok_or(CookieFault::Absent)?;
    if values.next().is_some() {
        return Err(CookieFault::Repeated);
    }
    parse_value(value).ok_or(CookieFault::Malformed)
}

fn parse_value(value: &str) -> Option<SigninCookie> {
    let (nonce, state) = value.split_once('.')?;
    let acceptable = |part: &str| {
        (MIN_VALUE_LENGTH..=MAX_VALUE_LENGTH).contains(&part.len()) && part.bytes().all(is_url_safe)
    };
    (acceptable(nonce) && acceptable(state)).then(|| SigninCookie {
        nonce: nonce.into(),
        state: state.into(),
    })
}

const fn is_url_safe(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const NONCE: &str = "Nn0nceNn0nceNn0nceAA";
    const STATE: &str = "StateStateState0123456789";

    fn cookie() -> SigninCookie {
        SigninCookie {
            nonce: NONCE.into(),
            state: STATE.into(),
        }
    }

    fn pairs(items: &[&str]) -> Vec<String> {
        items.iter().map(std::string::ToString::to_string).collect()
    }

    #[test]
    fn the_set_header_matches_the_issuers_reference_exactly() {
        assert_eq!(
            set_header(&cookie()),
            format!("__Host-signin={NONCE}.{STATE}; Max-Age=600; Path=/; Secure; HttpOnly; SameSite=Lax")
        );
    }

    #[test]
    fn the_clear_header_keeps_every_attribute_and_zeroes_the_age() {
        assert_eq!(
            clear_header(),
            "__Host-signin=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax"
        );
    }

    #[test]
    fn neither_header_carries_a_domain_attribute() {
        assert!(!set_header(&cookie())
            .to_ascii_lowercase()
            .contains("domain"));
        assert!(!clear_header().to_ascii_lowercase().contains("domain"));
    }

    #[test]
    fn a_pair_reads_back_into_its_nonce_and_state() {
        let read = read(&pairs(&[&format!("__Host-signin={NONCE}.{STATE}")])).unwrap();
        assert_eq!(read, cookie());
    }

    #[test]
    fn other_cookies_are_ignored_and_a_lookalike_name_is_not_the_cookie() {
        let found = read(&pairs(&[
            "a=b",
            &format!("__Host-signin={NONCE}.{STATE}"),
            "c=d",
        ]))
        .unwrap();
        assert_eq!(found, cookie());
        assert_eq!(
            read(&pairs(&[
                &format!("signin={NONCE}.{STATE}"),
                &format!("x__Host-signin={NONCE}.{STATE}")
            ])),
            Err(CookieFault::Absent)
        );
    }

    #[test]
    fn no_cookie_is_absent() {
        assert_eq!(read(&[]), Err(CookieFault::Absent));
    }

    #[test]
    fn a_repeated_cookie_is_refused_even_when_the_values_agree() {
        let one = format!("__Host-signin={NONCE}.{STATE}");
        assert_eq!(read(&pairs(&[&one, &one])), Err(CookieFault::Repeated));
    }

    #[test]
    fn a_value_of_the_wrong_shape_is_malformed() {
        for bad in [
            "",
            NONCE,
            &format!("{NONCE}."),
            &format!(".{STATE}"),
            &format!("{NONCE}.{STATE}.extra"),
            &format!("short.{STATE}"),
            &format!("{NONCE}.short"),
            &format!("{NONCE}.{}", "s".repeat(129)),
            &format!("{NONCE}.{STATE}+"),
            &format!("{NONCE}.{STATE}="),
            &format!("{NONCE}.sta te0123456789012"),
        ] {
            assert_eq!(
                read(&pairs(&[&format!("__Host-signin={bad}")])),
                Err(CookieFault::Malformed),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn the_longest_acceptable_values_pass() {
        let long = "a".repeat(128);
        let found = read(&pairs(&[&format!("__Host-signin={long}.{long}")])).unwrap();
        assert_eq!(found.nonce.len(), 128);
    }

    #[test]
    fn pairs_come_from_the_cookie_header_and_from_the_cookies_array() {
        let event = json!({"headers": {"cookie": "a=b; __Host-signin=x.y ; c=d"}, "cookies": ["e=f", "g=h"]});
        let all = request_pairs(&event);
        for expected in ["a=b", "__Host-signin=x.y", "c=d", "e=f", "g=h"] {
            assert!(all.iter().any(|p| p == expected), "{expected} in {all:?}");
        }
    }

    #[test]
    fn a_cookie_named_in_both_places_counts_twice() {
        let one = format!("__Host-signin={NONCE}.{STATE}");
        let event = json!({"headers": {"cookie": one}, "cookies": [one]});
        assert_eq!(read(&request_pairs(&event)), Err(CookieFault::Repeated));
    }

    #[test]
    fn an_event_without_cookies_yields_no_pairs() {
        assert!(request_pairs(&json!({})).is_empty());
        assert!(request_pairs(&json!({"headers": {"cookie": 5}, "cookies": "x"})).is_empty());
    }
}
