//! The Stripe calls made by the host itself, through its own HTTP client.

use super::{
    Account, AccountRefusal, EmbeddedSession, Endpoint, SessionRequest, WebhookRefusal,
    WebhookRequest,
};
use serde_json::Value;

const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

fn http() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(TIMEOUT)
        .build()
        .map_err(|e| e.to_string())
}

/// `request` as `account`: its key as the bearer, and the API version when the call pins one.
fn authorized(request: reqwest::RequestBuilder, account: &Account<'_>) -> reqwest::RequestBuilder {
    let request = request.bearer_auth(account.api_key);
    match account.api_version {
        Some(version) => request.header("Stripe-Version", version),
        None => request,
    }
}

// The business name Stripe has for an account, when it has one.
fn business_name(account: &Value) -> Option<String> {
    let candidates = [
        account.get("business_profile").and_then(|p| p.get("name")),
        account
            .get("settings")
            .and_then(|s| s.get("dashboard"))
            .and_then(|d| d.get("display_name")),
        account.get("email"),
    ];
    candidates
        .into_iter()
        .flatten()
        .find_map(|v| v.as_str().filter(|s| !s.is_empty()))
        .map(String::from)
}

// `GET /v1/account` with the account's own key; the key is only ever sent as the bearer.
pub(super) async fn read_account(account: &Account<'_>) -> Result<Option<String>, AccountRefusal> {
    let request = http()
        .map_err(|_| AccountRefusal::Unreachable)?
        .get(format!("{}/v1/account", account.base_url));
    let response = authorized(request, account)
        .send()
        .await
        .map_err(|_| AccountRefusal::Unreachable)?;
    let status = response.status();
    if status.as_u16() == 401 {
        return Err(AccountRefusal::KeyRefused);
    }
    if !status.is_success() {
        return Err(AccountRefusal::Declined);
    }
    let body = response.json::<Value>().await.unwrap_or(Value::Null);
    Ok(business_name(&body))
}

// Creates the webhook endpoint in the business's own Stripe account and returns its id and
// signing secret. Only the status is logged.
pub(super) async fn create_webhook(
    account: &Account<'_>,
    wanted: &WebhookRequest,
) -> Result<Endpoint, WebhookRefusal> {
    let mut params: Vec<(String, String)> = vec![
        ("url".into(), wanted.url.clone()),
        ("description".into(), wanted.description.clone()),
    ];
    params.extend(
        wanted
            .events
            .iter()
            .enumerate()
            .map(|(index, event)| (format!("enabled_events[{index}]"), event.clone())),
    );
    let request = http()
        .map_err(|_| WebhookRefusal::Other)?
        .post(format!("{}/v1/webhook_endpoints", account.base_url));
    let response = authorized(request, account)
        .form(&params)
        .send()
        .await
        .map_err(|_| WebhookRefusal::Other)?;
    let status = response.status();
    if matches!(status.as_u16(), 401 | 403) {
        return Err(WebhookRefusal::Permission);
    }
    if !status.is_success() {
        eprintln!("Stripe refused to create the payment webhook ({status})");
        return Err(WebhookRefusal::Other);
    }
    let body: Value = response.json().await.map_err(|_| WebhookRefusal::Other)?;
    let text = |field: &str| {
        body.get(field)
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(String::from)
    };
    match (text("id"), text("secret")) {
        (Some(id), Some(secret)) => Ok(Endpoint { id, secret }),
        _ => Err(WebhookRefusal::Other),
    }
}

// Removes a webhook endpoint from the business's Stripe account, best effort.
pub(super) async fn delete_webhook(account: &Account<'_>, endpoint_id: &str) -> bool {
    let Ok(http) = http() else {
        return false;
    };
    let request = http.delete(format!(
        "{}/v1/webhook_endpoints/{endpoint_id}",
        account.base_url
    ));
    let sent = authorized(request, account).send().await;
    matches!(sent, Ok(response) if response.status().is_success())
}

// Embedded, not Stripe-hosted, so Stripe returns a `client_secret` instead of a `url`. `ui_mode`
// must be `embedded_page`; Stripe rejects the older `embedded` value. No success_url/cancel_url:
// the browser stays on the site and learns of completion from Stripe.js, with the webhook
// settling payment. Errors carry Stripe's message when it refuses, never a secret.
pub(super) async fn create_checkout_session(
    account: &Account<'_>,
    wanted: &SessionRequest,
) -> anyhow::Result<EmbeddedSession> {
    let unit_amount = wanted.price_cents.to_string();
    let expires_at = wanted.expires_at.to_string();
    let params = [
        ("mode", "payment"),
        ("ui_mode", "embedded_page"),
        ("redirect_on_completion", "never"),
        ("expires_at", expires_at.as_str()),
        (
            "line_items[0][price_data][currency]",
            wanted.currency.as_str(),
        ),
        (
            "line_items[0][price_data][unit_amount]",
            unit_amount.as_str(),
        ),
        (
            "line_items[0][price_data][product_data][name]",
            wanted.product_name.as_str(),
        ),
        ("line_items[0][quantity]", "1"),
        ("metadata[registration_id]", wanted.registration_id.as_str()),
    ];

    let request = crate::http::client().post(format!("{}/v1/checkout/sessions", account.base_url));
    let response = authorized(request, account).form(&params).send().await?;

    let status = response.status();
    let body: Value = response.json().await?;
    if !status.is_success() {
        let message = body
            .get("error")
            .and_then(|e| e.get("message"))
            .and_then(|v| v.as_str())
            .unwrap_or("unknown Stripe error");
        anyhow::bail!("Stripe checkout session creation failed ({status}): {message}");
    }

    let text = |field: &str| body.get(field).and_then(|v| v.as_str()).map(String::from);
    match (text("id"), text("client_secret")) {
        (Some(session_id), Some(client_secret)) => Ok(EmbeddedSession {
            session_id,
            client_secret,
        }),
        // The body is left out of the message: it may carry the client secret.
        _ => anyhow::bail!(
            "Stripe's response carried no \"id\" and \"client_secret\" for the embedded session"
        ),
    }
}
