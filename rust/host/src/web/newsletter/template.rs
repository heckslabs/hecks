// The optional branded confirmation email: an HTML template an operator
// hosts, fetched at send time. Hecks ships no brand; with no template (or
// any trouble with one) the caller keeps the plain-text body.
use super::super::newsletter_send::personalize;
use std::time::Duration;

pub(super) const CONFIRM_TOKEN: &str = "{{CONFIRM_URL}}";
const FETCH_TIMEOUT: Duration = Duration::from_secs(5);
pub(super) const MAX_TEMPLATE_BYTES: usize = 256 * 1024;

// Escapes a URL for an HTML attribute or text position.
fn escape_html(value: &str) -> String {
    value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&#39;")
}

// Fills the placeholders with HTML-escaped URLs. `Err` names why the
// template is unusable: without {{CONFIRM_URL}} the email would carry no
// link. {{UNSUBSCRIBE_URL}} is optional. The result starts at its first
// non-blank character so the mailer sends it as HTML.
pub(super) fn fill_template(template: &str, confirm_url: &str, unsubscribe_url: &str) -> Result<String, &'static str> {
    if !template.contains(CONFIRM_TOKEN) {
        return Err("the template has no {{CONFIRM_URL}} placeholder");
    }
    let filled = template.replace(CONFIRM_TOKEN, &escape_html(confirm_url));
    Ok(personalize(&filled, &escape_html(unsubscribe_url)).trim_start().to_string())
}

// Reads a response body, stopping as soon as it passes the cap.
async fn read_capped(mut response: reqwest::Response) -> Result<String, String> {
    let mut bytes: Vec<u8> = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        bytes.extend_from_slice(&chunk);
        if bytes.len() > MAX_TEMPLATE_BYTES {
            return Err(format!("the template is larger than {MAX_TEMPLATE_BYTES} bytes"));
        }
    }
    String::from_utf8(bytes).map_err(|_| "the template is not UTF-8".to_string())
}

// GETs the template (5 second timeout, size capped); a non-2xx answer or
// any transport trouble is an `Err` with the reason.
async fn fetch_template(url: &str) -> Result<String, String> {
    let http = reqwest::Client::builder().timeout(FETCH_TIMEOUT).build().map_err(|e| e.to_string())?;
    let response = http.get(url).send().await.map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("the template answered {}", response.status()));
    }
    read_capped(response).await
}

// The HTML body when NEWSLETTER_CONFIRMATION_TEMPLATE_URL names a usable
// template; None (after logging why) when the caller should send plain text.
pub(super) async fn branded_body(confirm_url: &str, unsubscribe_url: &str) -> Option<String> {
    let url = std::env::var("NEWSLETTER_CONFIRMATION_TEMPLATE_URL").ok().filter(|u| !u.trim().is_empty())?;
    let template = match fetch_template(url.trim()).await {
        Ok(t) => t,
        Err(e) => {
            eprintln!("newsletter: the confirmation template could not be fetched ({e}), so the plain-text confirmation was sent");
            return None;
        }
    };
    match fill_template(&template, confirm_url, unsubscribe_url) {
        Ok(body) => Some(body),
        Err(e) => {
            eprintln!("newsletter: the confirmation template was rejected ({e}), so the plain-text confirmation was sent");
            None
        }
    }
}
