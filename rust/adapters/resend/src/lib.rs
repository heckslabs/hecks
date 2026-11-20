//! Sends one email through Resend's REST API from inside a Wasm component. It holds the request
//! payload, the retry on 429 and the mapping of Resend's answer to a delivery; the host lends it
//! the API key (`secrets`), the request (`http-out`) and the wait between retries (`clock`).

// The generated export glue takes every record field as an argument.
#![allow(clippy::too_many_arguments)]

wit_bindgen::generate!({
    path: "../../host/wit",
    world: "email-adapter",
});

mod payload;
mod retry;

use hecks::adapters::{clock, http_out, secrets};

/// The secret the API key is read from.
const API_KEY: &str = "RESEND_API_KEY";
/// How long one request may take before the host gives up on it.
const TIMEOUT_MS: u32 = 15_000;
/// How many times one email is tried while Resend answers 429.
const MAX_ATTEMPTS: u32 = 4;

struct Resend;

impl Guest for Resend {
    fn deliver(sender: Sender, message: Message) -> Delivery {
        match api_key() {
            Ok(key) => send(&key, &sender, &message),
            Err(reason) => failed(reason),
        }
    }
}

export!(Resend);

/// The API key the host's grant lends, or why there is none.
fn api_key() -> Result<String, String> {
    match secrets::get(API_KEY) {
        Ok(Some(key)) if !key.is_empty() => Ok(key),
        Ok(_) => Err(format!("{API_KEY} is not set")),
        Err(secrets::Refusal::Undeclared(name)) => Err(format!("secret {name} is not granted")),
        Err(secrets::Refusal::Failed(why)) => Err(why),
    }
}

/// Posts the email, waiting and trying again while Resend answers 429.
fn send(key: &str, sender: &Sender, message: &Message) -> Delivery {
    let call = http_out::Call {
        method: "POST".to_string(),
        url: format!("{}/emails", sender.base_url),
        headers: vec![
            ("authorization".to_string(), format!("Bearer {key}")),
            ("content-type".to_string(), "application/json".to_string()),
        ],
        body: payload::body(sender, message),
        timeout_ms: TIMEOUT_MS,
    };
    for attempt in 1..=MAX_ATTEMPTS {
        let reply = match http_out::request(&call) {
            Ok(reply) => reply,
            Err(refusal) => return failed(unreachable(refusal)),
        };
        if reply.status == 429 && attempt < MAX_ATTEMPTS {
            clock::sleep(retry::delay_ms(&reply.headers));
            continue;
        }
        return answered(&reply);
    }
    failed("resend kept rate limiting this email".to_string())
}

/// The reason a request that never reached Resend gives.
fn unreachable(refusal: http_out::Refusal) -> String {
    match refusal {
        http_out::Refusal::Undeclared(host) => format!("resend unreachable: {host} is not granted"),
        http_out::Refusal::Failed(why) => format!("resend unreachable: {why}"),
    }
}

/// The delivery Resend's final answer comes to.
fn answered(reply: &http_out::Reply) -> Delivery {
    let answer: serde_json::Value =
        serde_json::from_slice(&reply.body).unwrap_or(serde_json::Value::Null);
    if (200..300).contains(&reply.status) {
        return answer.get("id").and_then(|v| v.as_str()).map_or_else(
            || failed("resend accepted the email but returned no id".to_string()),
            |id| Delivery {
                ok: true,
                message_id: Some(id.to_string()),
                reason: None,
            },
        );
    }
    let message = answer
        .get("message")
        .and_then(|v| v.as_str())
        .map(String::from);
    failed(
        message.unwrap_or_else(|| format!("resend answered {}", retry::status_line(reply.status))),
    )
}

fn failed(reason: String) -> Delivery {
    Delivery {
        ok: false,
        message_id: None,
        reason: Some(reason),
    }
}
