//! The responses of the sign-in flow: the redirects it makes and the plain pages it refuses with.
//!
//! A refusal is a small static HTML page with a generic sentence and a stable code from a fixed
//! set. Nothing from the request is ever written into it, and no refusal redirects anywhere, so a
//! request cannot steer the browser. Every response to the callback, success or not, deletes the
//! sign-in cookie.

use serde_json::{json, Value};

use super::cookie;

/// Why a sign-in was refused, each with a stable code, a status and a generic sentence.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    /// The browser's sign-in cookie is missing, repeated or unreadable.
    Cookie,
    /// The callback's state is not the one this browser stored.
    State,
    /// The callback's query is missing a value, repeats one, or is unreadable.
    Params,
    /// The token was refused by the verifier, for any reason after the state.
    Token,
    /// The token is genuine but names nobody this site lets in.
    Unlinked,
    /// A fault on this side: the member store or the verification could not run.
    Unavailable,
}

impl Failure {
    /// Every code the flow can show, in a fixed order.
    pub const ALL: [Self; 6] = [
        Self::Cookie,
        Self::State,
        Self::Params,
        Self::Token,
        Self::Unlinked,
        Self::Unavailable,
    ];

    /// Returns the stable code shown on the page and logged.
    pub const fn code(self) -> &'static str {
        match self {
            Self::Cookie => "platform_cookie",
            Self::State => "platform_state",
            Self::Params => "platform_params",
            Self::Token => "platform_token",
            Self::Unlinked => "google_unlinked",
            Self::Unavailable => "platform_unavailable",
        }
    }

    /// Returns the HTTP status.
    pub const fn status(self) -> u16 {
        match self {
            Self::Unlinked => 403,
            Self::Unavailable => 500,
            _ => 400,
        }
    }

    const fn message(self) -> &'static str {
        match self {
            Self::Unlinked => "This account does not have access to this site.",
            Self::Unavailable => "Sign-in is unavailable. Please try again later.",
            _ => "This sign-in link is not valid or has expired. Please start again from the site you came from.",
        }
    }
}

/// Builds the refusal page, which also deletes the sign-in cookie.
pub fn refusal(failure: Failure) -> Value {
    let body = format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Sign-in</title></head>\
         <body><p>{}</p><p>Code: {}</p></body></html>\n",
        failure.message(),
        failure.code()
    );
    json!({
        "statusCode": failure.status(),
        "headers": page_headers(),
        "cookies": [cookie::clear_header()],
        "body": body,
        "isBase64Encoded": false,
    })
}

fn page_headers() -> Value {
    json!({
        "content-type": "text/html; charset=utf-8",
        "cache-control": "no-store",
        "referrer-policy": "no-referrer",
        "x-content-type-options": "nosniff",
        "content-security-policy": "default-src 'none'; frame-ancestors 'none'",
    })
}

/// Builds a redirect that carries `cookies` and is never cached.
pub fn redirect(location: &str, cookies: &[String]) -> Value {
    json!({
        "statusCode": 302,
        "headers": {"location": location, "cache-control": "no-store", "referrer-policy": "no-referrer"},
        "cookies": cookies,
        "body": "",
        "isBase64Encoded": false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cookies(response: &Value) -> Vec<String> {
        response["cookies"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c.as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn codes_are_a_fixed_distinct_set() {
        let codes: Vec<&str> = Failure::ALL.iter().map(|f| f.code()).collect();
        assert_eq!(
            codes,
            [
                "platform_cookie",
                "platform_state",
                "platform_params",
                "platform_token",
                "google_unlinked",
                "platform_unavailable"
            ]
        );
    }

    #[test]
    fn faults_in_the_request_are_400_and_a_refused_person_is_403_and_our_fault_is_500() {
        let statuses: Vec<u16> = Failure::ALL.iter().map(|f| f.status()).collect();
        assert_eq!(statuses, [400, 400, 400, 400, 403, 500]);
    }

    #[test]
    fn every_refusal_deletes_the_sign_in_cookie_and_nothing_else() {
        for failure in Failure::ALL {
            assert_eq!(
                cookies(&refusal(failure)),
                vec![cookie::clear_header()],
                "{failure:?}"
            );
        }
    }

    #[test]
    fn a_refusal_is_html_that_is_never_cached_framed_or_sniffed() {
        let response = refusal(Failure::Token);
        let headers = &response["headers"];
        assert_eq!(response["statusCode"], 400);
        assert_eq!(headers["content-type"], "text/html; charset=utf-8");
        assert_eq!(headers["cache-control"], "no-store");
        assert_eq!(headers["referrer-policy"], "no-referrer");
        assert_eq!(headers["x-content-type-options"], "nosniff");
        assert_eq!(
            headers["content-security-policy"],
            "default-src 'none'; frame-ancestors 'none'"
        );
        assert!(headers.get("location").is_none());
    }

    #[test]
    fn the_page_shows_its_code_and_a_generic_sentence() {
        for failure in Failure::ALL {
            let body = refusal(failure)["body"].as_str().unwrap().to_string();
            assert!(body.contains(failure.code()), "{body}");
            assert!(body.starts_with("<!doctype html>"));
            assert!(!body.contains("<script"));
        }
    }

    #[test]
    fn a_refusal_never_redirects() {
        for failure in Failure::ALL {
            assert_ne!(refusal(failure)["statusCode"], 302);
        }
    }

    #[test]
    fn a_redirect_is_a_302_with_no_store_and_its_cookies_in_order() {
        let response = redirect("/admin.html", &["a=1".to_string(), "b=2".to_string()]);
        assert_eq!(response["statusCode"], 302);
        assert_eq!(response["headers"]["location"], "/admin.html");
        assert_eq!(response["headers"]["cache-control"], "no-store");
        assert_eq!(response["body"], "");
        assert_eq!(cookies(&response), vec!["a=1", "b=2"]);
    }

    #[test]
    fn a_redirect_keeps_the_address_out_of_the_referrer() {
        assert_eq!(
            redirect("/x", &[])["headers"]["referrer-policy"],
            "no-referrer"
        );
    }
}
