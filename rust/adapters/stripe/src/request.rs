//! The requests the component asks the host to make: the method, the URL under the account's
//! base, the key as the bearer, the pinned API version when the call pins one, and a form body.

use crate::hecks::adapters::http_out::Call;
use crate::hecks::adapters::stripe::Account;

/// How long one request may take before the host gives up on it.
const TIMEOUT_MS: u32 = 15_000;

/// A `GET` of `path` as `account`.
pub fn get(account: &Account, path: &str) -> Call {
    call("GET", account, path, Vec::new())
}

/// A form-encoded `POST` of `body` to `path` as `account`.
pub fn post(account: &Account, path: &str, body: &str) -> Call {
    let mut call = call("POST", account, path, body.as_bytes().to_vec());
    call.headers.push((
        "content-type".to_string(),
        "application/x-www-form-urlencoded".to_string(),
    ));
    call
}

/// A `DELETE` of `path` as `account`.
pub fn delete(account: &Account, path: &str) -> Call {
    call("DELETE", account, path, Vec::new())
}

fn call(method: &str, account: &Account, path: &str, body: Vec<u8>) -> Call {
    let mut headers = vec![(
        "authorization".to_string(),
        format!("Bearer {}", account.api_key),
    )];
    if let Some(version) = &account.api_version {
        headers.push(("stripe-version".to_string(), version.clone()));
    }
    Call {
        method: method.to_string(),
        url: format!("{}{path}", account.base_url),
        headers,
        body,
        timeout_ms: TIMEOUT_MS,
    }
}
