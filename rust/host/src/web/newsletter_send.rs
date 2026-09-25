use super::{active_session_email, instances_for, last_refusal, percent_decode, respond};
use crate::auth;
use crate::dispatch;
use crate::ir::{newsletter_issues_provider, newsletter_provider, NewsletterIssuesProvider, NewsletterProvider};
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use crate::resend::{Email, Mailer};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

// ---- newsletter: sending an issue ----------------------------------------
// Ported from http_server.rb's POST /newsletter/issues/:slug/send and
// .../send-test, with the outbound half going through resend.rs instead of
// the Ruby RESEND_ADAPTER. Which commands mark an issue sent and record a
// delivery comes from the `newsletter_issues` IR key (`provides
// "newsletter_issues"`); which aggregate holds the subscribers comes from the
// `newsletter` key beside it. A domain that declares neither serves neither
// route.
//
// Unlike the guest routes in newsletter.rs, these sit behind the admin gate:
// sending mail to every subscriber is not something a session-less request, or
// a member with no admin role, may trigger.
//
// `Issue.Send` only records the decision to send (see the Newsletter bluebook's
// own note on it), so the fan-out lives here, in the driving side: one email
// per confirmed subscriber, each recorded as a Delivery when the provider
// accepted it. The issue is marked sent before any email goes out, the same
// order the Ruby route uses: a second click then refuses ("only a draft issue
// can be sent") instead of mailing everyone twice, at the price that a crash
// mid-fan-out leaves an issue marked sent that only some subscribers received.

const UNSUBSCRIBE_TOKEN: &str = "{{UNSUBSCRIBE_URL}}";
const DEFAULT_SITE_URL: &str = "http://localhost:4321";

/// Which of the two send routes a request is for.
#[derive(Debug, PartialEq)]
pub(super) enum IssueAction {
    Send,
    SendTest,
}

/// `POST /newsletter/issues/{slug}/send` or `.../send-test`, with the slug
/// percent-decoded; anything else is not one of these routes.
pub(super) fn issue_action(method: &str, path: &str) -> Option<(String, IssueAction)> {
    if method != "POST" {
        return None;
    }
    let (slug, action) = path.strip_prefix("/newsletter/issues/")?.split_once('/')?;
    if slug.is_empty() {
        return None;
    }
    let action = match action {
        "send" => IssueAction::Send,
        "send-test" => IssueAction::SendTest,
        _ => return None,
    };
    Some((percent_decode(slug), action))
}

/// Answers a send route for an Admin or Owner, or `None` when the path is not
/// one or this domain declares no `newsletter_issues` and `newsletter`.
#[allow(clippy::too_many_arguments)]
pub(super) async fn issue_route(
    method: &str,
    path: &str,
    domain_ir: &Value,
    raw_body: &str,
    cookies: &HashMap<String, String>,
    secret: &str,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Option<Value> {
    let (slug, action) = issue_action(method, path)?;
    let issues = newsletter_issues_provider(domain_ir)?;
    let subscribers = newsletter_provider(domain_ir)?;

    let mailer = match authorize(domain_ir, cookies, secret, client).await {
        Ok(mailer) => mailer,
        Err(response) => return Some(response),
    };
    Some(match action {
        IssueAction::Send => send_issue(&slug, &issues, &subscribers, &mailer, client, wasm_path, config, invoker).await,
        IssueAction::SendTest => send_test(raw_body, &mailer).await,
    })
}

fn json_error(status: u16, message: &str) -> Value {
    respond(status, "application/json", &json!({ "error": message }).to_string())
}

/// The mailer, once the caller is a signed-in Admin or Owner. Email delivery
/// not being configured is refused here, before anything is marked sent.
async fn authorize(domain_ir: &Value, cookies: &HashMap<String, String>, secret: &str, client: &Mutex<Client>) -> Result<Mailer, Value> {
    let email = active_session_email(domain_ir, cookies, secret, client).await?;
    match auth::caller_is_admin(client, domain_ir, &email).await {
        Ok(true) => {}
        Ok(false) => return Err(json_error(403, "only an Admin or Owner can send the newsletter")),
        Err(e) => return Err(json_error(500, &format!("members lookup failed: {e}"))),
    }
    match Mailer::from_env() {
        Ok(Some(mailer)) => Ok(mailer),
        Ok(None) => Err(json_error(503, "email delivery is not configured: set RESEND_API_KEY and RESEND_FROM")),
        Err(e) => Err(json_error(500, &e)),
    }
}

fn site_url() -> String {
    std::env::var("SITE_URL").unwrap_or_else(|_| DEFAULT_SITE_URL.to_string())
}

/// The page a recipient lands on to leave the list, with their address as a
/// query parameter (encoded, so a `+` in the local part survives).
fn unsubscribe_url(site_url: &str, email: &str) -> String {
    let mut url = reqwest::Url::parse(&format!("{site_url}/newsletter-unsubscribed.html")).unwrap_or_else(|_| reqwest::Url::parse("http://invalid.invalid/").unwrap());
    url.query_pairs_mut().append_pair("email", email);
    url.to_string()
}

fn personalize(body: &str, unsubscribe_url: &str) -> String {
    body.replace(UNSUBSCRIBE_TOKEN, unsubscribe_url)
}

/// An aggregate field that is a one-attribute value object: `{"value": ...}`.
fn value_of<'a>(state: &'a Value, field: &str) -> &'a str {
    state.get(field).and_then(|v| v.get("value")).and_then(|v| v.as_str()).unwrap_or("")
}

/// Every confirmed subscriber's address, alphabetical so a send is repeatable.
fn confirmed_emails(subscribers: &[(String, Value)]) -> Vec<String> {
    let mut emails: Vec<String> = subscribers
        .iter()
        .filter(|(_, s)| s.get("status").and_then(|v| v.as_str()) == Some("confirmed"))
        .map(|(email, _)| email.clone())
        .collect();
    emails.sort();
    emails
}

fn unix_now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

#[allow(clippy::too_many_arguments)]
async fn send_issue(
    slug: &str,
    issues: &NewsletterIssuesProvider,
    subscribers: &NewsletterProvider,
    mailer: &Mailer,
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> Value {
    let read = match dispatch::read(client, wasm_path).await {
        Ok(r) => r,
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
    };
    let Some((_, issue)) = instances_for(&read, &issues.issue_prefix()).into_iter().find(|(id, _)| id == slug) else {
        return json_error(404, "no such issue");
    };
    let subject = value_of(&issue, "subject").to_string();
    let body = value_of(&issue, "body").to_string();
    let recipients = confirmed_emails(&instances_for(&read, &subscribers.instance_prefix()));

    match dispatch::handle_routed(client, wasm_path, &issues.send_issue, json!(slug), json!({ "sent_at": { "value": unix_now() } }), None, config, invoker).await {
        Err(e) => return respond(500, "text/plain", &format!("{e:#}")),
        Ok(outcome) if !outcome.accepted => return respond(422, "application/json", &last_refusal(&outcome.result).to_string()),
        Ok(_) => {}
    }

    let site = site_url();
    let mut sent = 0;
    let mut unrecorded = 0;
    let mut failures: Vec<Value> = Vec::new();
    for email in &recipients {
        let unsubscribe = unsubscribe_url(&site, email);
        let personalized = personalize(&body, &unsubscribe);
        let delivery = mailer.deliver(&Email { to: email, subject: &subject, body: &personalized, unsubscribe_url: Some(&unsubscribe) }).await;
        if !delivery.ok {
            failures.push(json!({ "email": email, "reason": delivery.reason }));
            continue;
        }
        sent += 1;

        let facts = json!({
            "delivery_id": { "value": format!("{slug}:{email}") },
            "issue_slug": { "value": slug },
            "subscriber_email": { "value": email },
            "message_id": { "value": delivery.message_id.unwrap_or_default() },
        });
        match dispatch::handle_facts(client, wasm_path, &issues.record_delivery, facts, None, config, invoker).await {
            Ok(outcome) if outcome.accepted => {}
            other => {
                // The email went out; only its record is missing. Surface it
                // in the response and the log rather than fail the whole send.
                unrecorded += 1;
                eprintln!("newsletter send {slug}: delivered to {email} but could not record it: {}", other.map(|o| last_refusal(&o.result).to_string()).unwrap_or_else(|e| format!("{e:#}")));
            }
        }
    }

    respond(200, "application/json", &json!({ "slug": slug, "sent": sent, "failed": failures.len(), "failures": failures, "unrecorded": unrecorded }).to_string())
}

/// One email to one address, to see what a subscriber would get. Never touches
/// the issue's own state: `Issue.Send` is irreversible, so a test cannot reuse
/// it, and this renders whatever subject and body the caller supplies.
async fn send_test(raw_body: &str, mailer: &Mailer) -> Value {
    let body: Value = match serde_json::from_str(raw_body) {
        Ok(v) => v,
        Err(e) => return json_error(400, &format!("invalid JSON: {e}")),
    };
    let field = |name: &str| body.get(name).and_then(|v| v.as_str());
    let (Some(to), Some(subject), Some(text)) = (field("to"), field("subject"), field("body")) else {
        return json_error(400, "to, subject and body are required");
    };

    let unsubscribe = unsubscribe_url(&site_url(), to);
    let subject = format!("[TEST] {subject}");
    let delivery = mailer.deliver(&Email { to, subject: &subject, body: &personalize(text, &unsubscribe), unsubscribe_url: Some(&unsubscribe) }).await;
    if delivery.ok {
        respond(200, "application/json", &json!({ "to": to }).to_string())
    } else {
        respond(502, "application/json", &json!({ "error": "delivery failed", "reason": delivery.reason }).to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn send_and_send_test_are_the_only_issue_routes() {
        assert_eq!(issue_action("POST", "/newsletter/issues/spring/send"), Some(("spring".to_string(), IssueAction::Send)));
        assert_eq!(issue_action("POST", "/newsletter/issues/spring/send-test"), Some(("spring".to_string(), IssueAction::SendTest)));
        assert_eq!(issue_action("GET", "/newsletter/issues/spring/send"), None);
        assert_eq!(issue_action("POST", "/newsletter/issues/spring/edit"), None);
        assert_eq!(issue_action("POST", "/newsletter/issues//send"), None);
        assert_eq!(issue_action("POST", "/newsletter/issues/spring"), None);
        assert_eq!(issue_action("POST", "/newsletter/subscribers"), None);
    }

    #[test]
    fn the_slug_is_percent_decoded() {
        assert_eq!(issue_action("POST", "/newsletter/issues/spring%20news/send").unwrap().0, "spring news");
    }

    #[test]
    fn the_unsubscribe_token_is_replaced_wherever_it_appears() {
        let out = personalize("<a href=\"{{UNSUBSCRIBE_URL}}\">leave</a> {{UNSUBSCRIBE_URL}}", "https://x/u");
        assert_eq!(out, "<a href=\"https://x/u\">leave</a> https://x/u");
    }

    #[test]
    fn the_unsubscribe_url_carries_the_encoded_address() {
        assert_eq!(unsubscribe_url("https://example.com", "a+b@example.com"), "https://example.com/newsletter-unsubscribed.html?email=a%2Bb%40example.com");
    }

    #[test]
    fn only_confirmed_subscribers_are_recipients_in_alphabetical_order() {
        let subscribers = vec![
            ("zed@example.com".to_string(), json!({ "status": "confirmed" })),
            ("pending@example.com".to_string(), json!({ "status": "pending" })),
            ("amy@example.com".to_string(), json!({ "status": "confirmed" })),
            ("gone@example.com".to_string(), json!({ "status": "unsubscribed" })),
        ];
        assert_eq!(confirmed_emails(&subscribers), vec!["amy@example.com".to_string(), "zed@example.com".to_string()]);
    }

    #[test]
    fn value_object_fields_read_through_their_value() {
        let issue = json!({ "subject": { "value": "Spring" }, "body": { "value": "<p>hi</p>" } });
        assert_eq!(value_of(&issue, "subject"), "Spring");
        assert_eq!(value_of(&issue, "missing"), "");
    }

    #[tokio::test]
    async fn a_test_send_without_its_fields_is_a_400() {
        let response = send_test(r#"{"to":"a@b.com"}"#, &Mailer::Mock).await;
        assert_eq!(response["statusCode"], 400);
    }

    #[tokio::test]
    async fn a_test_send_goes_to_the_one_address_with_a_test_subject() {
        let response = send_test(r#"{"to":"a@b.com","subject":"Spring","body":"<p>hi</p>"}"#, &Mailer::Mock).await;
        assert_eq!(response["statusCode"], 200);
        assert_eq!(serde_json::from_str::<Value>(response["body"].as_str().unwrap()).unwrap(), json!({ "to": "a@b.com" }));
    }

    #[tokio::test]
    async fn a_test_send_the_provider_refuses_is_a_502() {
        let response = send_test(r#"{"to":"bounce@example.com","subject":"Spring","body":"x"}"#, &Mailer::Mock).await;
        assert_eq!(response["statusCode"], 502);
    }
}
