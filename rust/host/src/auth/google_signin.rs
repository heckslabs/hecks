//! The browser-bound half of Google sign-in: a fresh `state` and `nonce` kept in a cookie set at
//! `/auth/google`, so only the browser that started a sign-in can finish it.
//!
//! The callback must carry a `state` equal to the cookie's, and Google's ID token must carry the
//! cookie's `nonce`. Someone who starts a sign-in in their own browser and sends the callback link
//! to another person gets nowhere: that person's browser holds no cookie, or a different one.
//!
//! On https the cookie is `__Host-` prefixed, so a browser insists on `Secure`, `Path=/` and no
//! `Domain`, and a sibling subdomain cannot plant one. A plain http host (local development) cannot
//! set a `Secure` cookie, so it uses the bare name. `SameSite=Lax`, not `Strict`: Google's redirect
//! back is a cross-site top-level navigation, and a strict cookie would not be sent on it.

use crate::b64;
use crate::crypto::constant_time_eq;
use std::collections::HashMap;
use std::hash::BuildHasher;

/// How long the browser keeps the cookie, in seconds: long enough to pick a Google account.
pub const MAX_AGE_SECONDS: u32 = 600;

const SECURE_NAME: &str = "__Host-hecks_google";
const PLAIN_NAME: &str = "hecks_google";
const SECURE_ATTRIBUTES: &str = "Path=/; HttpOnly; Secure; SameSite=Lax";
const PLAIN_ATTRIBUTES: &str = "Path=/; HttpOnly; SameSite=Lax";

/// The `state` and `nonce` of one sign-in, as the cookie holds them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoogleSignin {
    pub state: String,
    pub nonce: String,
}

impl GoogleSignin {
    /// A sign-in with a fresh, unguessable `state` and `nonce`.
    pub fn fresh() -> Self {
        Self {
            state: fresh_value(),
            nonce: fresh_value(),
        }
    }

    /// Whether `state`, as the callback carried it, is this sign-in's.
    pub fn state_matches(&self, state: &str) -> bool {
        constant_time_eq(self.state.as_bytes(), state.as_bytes())
    }
}

/// The cookie's name: `__Host-` prefixed when `secure`.
pub const fn cookie_name(secure: bool) -> &'static str {
    if secure {
        SECURE_NAME
    } else {
        PLAIN_NAME
    }
}

/// The `Set-Cookie` value that stores `signin` in the browser.
pub fn set_header(signin: &GoogleSignin, secure: bool) -> String {
    format!(
        "{}={}.{}; Max-Age={MAX_AGE_SECONDS}; {}",
        cookie_name(secure),
        signin.nonce,
        signin.state,
        attributes(secure)
    )
}

/// The `Set-Cookie` value that deletes the cookie, with the attributes that set it.
pub fn clear_header(secure: bool) -> String {
    format!(
        "{}=; Max-Age=0; {}",
        cookie_name(secure),
        attributes(secure)
    )
}

/// The sign-in the request's cookie holds, or `None` when it is absent or not `<nonce>.<state>`.
pub fn read<S: BuildHasher>(
    cookies: &HashMap<String, String, S>,
    secure: bool,
) -> Option<GoogleSignin> {
    let (nonce, state) = cookies.get(cookie_name(secure))?.split_once('.')?;
    let acceptable = |part: &str| {
        (16..=128).contains(&part.len())
            && part
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    };
    (acceptable(nonce) && acceptable(state)).then(|| GoogleSignin {
        state: state.to_string(),
        nonce: nonce.to_string(),
    })
}

const fn attributes(secure: bool) -> &'static str {
    if secure {
        SECURE_ATTRIBUTES
    } else {
        PLAIN_ATTRIBUTES
    }
}

// 244 random bits as 43 base64url characters.
fn fresh_value() -> String {
    let mut bytes = Vec::with_capacity(32);
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    b64::url_encode(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cookies_holding(name: &str, value: &str) -> HashMap<String, String> {
        HashMap::from([(name.to_string(), value.to_string())])
    }

    #[test]
    fn a_fresh_sign_in_differs_every_time_and_reads_back_from_its_own_cookie() {
        let (one, two) = (GoogleSignin::fresh(), GoogleSignin::fresh());
        assert_ne!(one, two);
        assert_ne!(one.state, one.nonce);
        let header = set_header(&one, true);
        let value = header
            .strip_prefix("__Host-hecks_google=")
            .and_then(|rest| rest.split(';').next())
            .unwrap();
        assert_eq!(
            read(&cookies_holding("__Host-hecks_google", value), true),
            Some(one)
        );
    }

    #[test]
    fn the_secure_cookie_is_host_prefixed_with_no_domain_and_lax() {
        let header = set_header(&GoogleSignin::fresh(), true);
        assert!(header.starts_with("__Host-hecks_google="), "{header}");
        for attribute in [
            "Path=/",
            "HttpOnly",
            "Secure",
            "SameSite=Lax",
            "Max-Age=600",
        ] {
            assert!(header.contains(attribute), "{attribute} in {header}");
        }
        assert!(!header.to_ascii_lowercase().contains("domain"));
        assert_eq!(
            clear_header(true),
            "__Host-hecks_google=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax"
        );
    }

    #[test]
    fn a_plain_http_host_uses_the_bare_name_without_secure() {
        let header = set_header(&GoogleSignin::fresh(), false);
        assert!(header.starts_with("hecks_google="), "{header}");
        assert!(!header.contains("Secure"));
    }

    #[test]
    fn a_missing_or_malformed_cookie_reads_as_no_sign_in() {
        let nonce = "n".repeat(43);
        assert_eq!(read(&HashMap::new(), true), None);
        for bad in [nonce.as_str(), "short.short", &format!("{nonce}.{nonce}+")] {
            assert_eq!(
                read(&cookies_holding("__Host-hecks_google", bad), true),
                None
            );
        }
        let good = format!("{nonce}.{nonce}");
        assert_eq!(read(&cookies_holding("hecks_google", &good), true), None);
    }

    #[test]
    fn only_the_cookies_own_state_matches() {
        let signin = GoogleSignin::fresh();
        assert!(signin.state_matches(&signin.state.clone()));
        assert!(!signin.state_matches(&GoogleSignin::fresh().state));
        assert!(!signin.state_matches(""));
    }
}
