//! The delivery cases every Resend mailer must pass, native and component alike: each names the
//! fake Resend's canned answers, the email and reply-to, and a check over the delivery and the
//! requests the fake was sent. `run` drives one mailer through them all and names each failure.

#![allow(clippy::unwrap_used, clippy::expect_used)]

use super::{Delivery, Email, Mailer};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex as StdMutex};

/// One canned answer: status line, extra header lines (each ending `\r\n`), body.
pub(super) type Answer = (&'static str, &'static str, &'static str);

/// What a case checks: `Err` with the reason when the delivery or the requests are wrong.
type Check = fn(&Delivery, &[String]) -> Result<(), String>;

/// A mailer under test, built for a fake's base URL and an optional reply-to.
pub(super) type Build = fn(&str, Option<&str>) -> Mailer;

pub(super) struct Case {
    name: &'static str,
    /// `None`: nothing listens at the base URL.
    answers: Option<Vec<Answer>>,
    body: &'static str,
    unsubscribe: bool,
    reply_to: Option<&'static str>,
    check: Check,
}

/// A recording Resend on 127.0.0.1: answers each request with the next canned answer and keeps
/// what it was sent.
pub(super) struct FakeResend {
    pub(super) base: String,
    requests: Arc<StdMutex<Vec<String>>>,
}

impl FakeResend {
    pub(super) fn start(answers: Vec<Answer>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind a local port");
        let base = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(StdMutex::new(Vec::new()));
        let seen = requests.clone();
        std::thread::spawn(move || {
            for (status, headers, body) in answers {
                let Ok((mut stream, _)) = listener.accept() else {
                    return;
                };
                let request = read_request(&mut stream);
                seen.lock().unwrap().push(request);
                let response = format!("HTTP/1.1 {status}\r\ncontent-type: application/json\r\n{headers}content-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
                let _ = stream.write_all(response.as_bytes());
            }
        });
        Self { base, requests }
    }

    pub(super) fn requests(&self) -> Vec<String> {
        self.requests.lock().unwrap().clone()
    }
}

fn read_request(stream: &mut std::net::TcpStream) -> String {
    let mut raw = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = stream.read(&mut chunk).unwrap_or(0);
        raw.extend_from_slice(&chunk[..n]);
        let text = String::from_utf8_lossy(&raw).to_string();
        if let Some((head, body)) = text.split_once("\r\n\r\n") {
            let length = head
                .lines()
                .find_map(|l| {
                    l.to_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|v| v.trim().parse::<usize>().ok())
                })
                .unwrap_or(0);
            if body.len() >= length {
                return text;
            }
        }
        if n == 0 {
            return text;
        }
    }
}

const UNSUBSCRIBE: &str = "https://example.com/newsletter-unsubscribed.html?email=a%40b.com";
const OK: Answer = ("200 OK", "", r#"{"id":"em_123"}"#);
const LIMITED: Answer = (
    "429 Too Many Requests",
    "retry-after: 0\r\n",
    r#"{"message":"Too many requests"}"#,
);

/// The key every case's mailer is built with.
pub(super) const KEY: &str = "re_secret";
/// The from address every case's mailer is built with.
pub(super) const FROM: &str = "News <n@mail.example.com>";

fn expect(holds: bool, what: &str, seen: &impl std::fmt::Debug) -> Result<(), String> {
    holds
        .then_some(())
        .ok_or_else(|| format!("{what}; saw {seen:?}"))
}

fn sent_as(id: &str, delivery: &Delivery) -> Result<(), String> {
    expect(
        *delivery == Delivery::sent(id.to_string()),
        &format!("sent as {id}"),
        delivery,
    )
}

fn failed_with(reason: &str, delivery: &Delivery) -> Result<(), String> {
    expect(
        *delivery == Delivery::failed(reason),
        &format!("failed with {reason:?}"),
        delivery,
    )
}

fn one_request(requests: &[String]) -> Result<&str, String> {
    match requests {
        [only] => Ok(only),
        _ => Err(format!("one request; saw {}", requests.len())),
    }
}

/// The JSON body of a request the fake received.
fn json_body(request: &str) -> serde_json::Value {
    let body = request.split_once("\r\n\r\n").map_or("", |(_, b)| b);
    serde_json::from_str(body).unwrap_or(serde_json::Value::Null)
}

fn posts_with_key_and_returns_id(d: &Delivery, r: &[String]) -> Result<(), String> {
    sent_as("em_123", d)?;
    let request = one_request(r)?.to_lowercase();
    expect(
        request.starts_with("post /emails "),
        "a POST to /emails",
        &request,
    )?;
    expect(
        request.contains("authorization: bearer re_secret"),
        "the bearer key",
        &request,
    )?;
    let body = json_body(one_request(r)?);
    expect(
        body["to"] == serde_json::json!(["a@b.com"]) && body["from"] == FROM,
        "to and from",
        &body,
    )
}

fn html_goes_as_html(d: &Delivery, r: &[String]) -> Result<(), String> {
    sent_as("em_123", d)?;
    let body = json_body(one_request(r)?);
    expect(
        body["html"] == "  <p>hi</p>" && body.get("text").is_none(),
        "html only",
        &body,
    )
}

fn plain_goes_as_text(d: &Delivery, r: &[String]) -> Result<(), String> {
    sent_as("em_123", d)?;
    let body = json_body(one_request(r)?);
    expect(
        body["text"] == "just a link" && body.get("html").is_none(),
        "text only",
        &body,
    )
}

fn list_unsubscribe_rides(d: &Delivery, r: &[String]) -> Result<(), String> {
    sent_as("em_123", d)?;
    let body = json_body(one_request(r)?);
    let header = format!("<{UNSUBSCRIBE}>");
    expect(
        body["headers"]["List-Unsubscribe"] == header.as_str(),
        "List-Unsubscribe",
        &body,
    )
}

fn no_headers_without_unsubscribe(d: &Delivery, r: &[String]) -> Result<(), String> {
    sent_as("em_123", d)?;
    let body = json_body(one_request(r)?);
    expect(body.get("headers").is_none(), "no headers", &body)
}

fn reply_to_rides(d: &Delivery, r: &[String]) -> Result<(), String> {
    sent_as("em_123", d)?;
    let body = json_body(one_request(r)?);
    expect(body["reply_to"] == "replies@example.com", "reply_to", &body)
}

fn no_reply_to_without_one(d: &Delivery, r: &[String]) -> Result<(), String> {
    sent_as("em_123", d)?;
    let body = json_body(one_request(r)?);
    expect(body.get("reply_to").is_none(), "no reply_to", &body)
}

fn refusal_carries_message(d: &Delivery, r: &[String]) -> Result<(), String> {
    one_request(r)?;
    failed_with("The mail.example.com domain is not verified.", d)
}

fn bare_error_names_status(d: &Delivery, r: &[String]) -> Result<(), String> {
    one_request(r)?;
    failed_with("resend answered 500 Internal Server Error", d)
}

fn retried_after_429(d: &Delivery, r: &[String]) -> Result<(), String> {
    sent_as("em_123", d)?;
    expect(r.len() == 2, "two requests", &r.len())
}

fn gives_up_after_four(d: &Delivery, r: &[String]) -> Result<(), String> {
    failed_with("Too many requests", d)?;
    expect(r.len() == 4, "four requests", &r.len())
}

fn unreachable_fails(d: &Delivery, _: &[String]) -> Result<(), String> {
    let reason = d.reason.as_deref().unwrap_or_default();
    expect(
        !d.ok && reason.starts_with("resend unreachable"),
        "resend unreachable",
        d,
    )
}

fn no_id_fails(d: &Delivery, r: &[String]) -> Result<(), String> {
    one_request(r)?;
    failed_with("resend accepted the email but returned no id", d)
}

/// Every case, in the order they run.
pub(super) fn all() -> Vec<Case> {
    let case = |name, answers: Option<Vec<Answer>>, body, check| Case {
        name,
        answers,
        body,
        unsubscribe: true,
        reply_to: None,
        check,
    };
    vec![
        case(
            "posts with the bearer key and returns the id",
            Some(vec![OK]),
            "<p>hi</p>",
            posts_with_key_and_returns_id,
        ),
        case(
            "an html body goes as html",
            Some(vec![OK]),
            "  <p>hi</p>",
            html_goes_as_html,
        ),
        case(
            "a plain body goes as text",
            Some(vec![OK]),
            "just a link",
            plain_goes_as_text,
        ),
        case(
            "the unsubscribe url rides as List-Unsubscribe",
            Some(vec![OK]),
            "x",
            list_unsubscribe_rides,
        ),
        Case {
            unsubscribe: false,
            ..case(
                "no unsubscribe url, no headers",
                Some(vec![OK]),
                "x",
                no_headers_without_unsubscribe,
            )
        },
        Case {
            reply_to: Some("replies@example.com"),
            ..case(
                "a reply-to rides in the payload",
                Some(vec![OK]),
                "x",
                reply_to_rides,
            )
        },
        case(
            "no reply-to is absent from the payload",
            Some(vec![OK]),
            "x",
            no_reply_to_without_one,
        ),
        case(
            "a refusal carries Resend's message",
            Some(vec![(
                "403 Forbidden",
                "",
                r#"{"message":"The mail.example.com domain is not verified.","name":"validation_error"}"#,
            )]),
            "x",
            refusal_carries_message,
        ),
        case(
            "an error without a message names the status",
            Some(vec![("500 Internal Server Error", "", "")]),
            "x",
            bare_error_names_status,
        ),
        case(
            "a 429 waits and is retried",
            Some(vec![LIMITED, OK]),
            "x",
            retried_after_429,
        ),
        case(
            "429 four times gives up with the last answer",
            Some(vec![LIMITED; 4]),
            "x",
            gives_up_after_four,
        ),
        case(
            "an unreachable Resend is a failed delivery",
            None,
            "x",
            unreachable_fails,
        ),
        case(
            "a 200 without an id is a failed delivery",
            Some(vec![("200 OK", "", "{}")]),
            "x",
            no_id_fails,
        ),
    ]
}

/// A base URL nothing listens on.
fn unreachable_base() -> String {
    let unused = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", unused.local_addr().unwrap());
    drop(unused);
    base
}

/// Runs one case against the mailer `build` makes; `Err` names the case and what went wrong.
async fn run_one(build: Build, case: &Case) -> Result<(), String> {
    let fake = case.answers.clone().map(FakeResend::start);
    let base = fake
        .as_ref()
        .map_or_else(unreachable_base, |f| f.base.clone());
    let email = Email {
        to: "a@b.com",
        subject: "Spring news",
        body: case.body,
        unsubscribe_url: case.unsubscribe.then_some(UNSUBSCRIBE),
    };
    let delivery = build(&base, case.reply_to).deliver(&email).await;
    let requests = fake.map(|f| f.requests()).unwrap_or_default();
    (case.check)(&delivery, &requests).map_err(|why| format!("{}: {why}", case.name))
}

/// Every case's failure against the mailer `build` makes; empty when all pass.
pub(super) async fn run(build: Build) -> Vec<String> {
    let mut failures = Vec::new();
    for case in all() {
        if let Err(why) = run_one(build, &case).await {
            failures.push(why);
        }
    }
    failures
}
