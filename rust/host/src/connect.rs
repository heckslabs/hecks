//! Payment-processor accounts a tenant connects to its site.
//!
//! A tenant links its own processor account through the processor's
//! authorization screen. Only the public account reference is stored; the
//! platform's credentials come from the environment and never reach a
//! tenant. Processors are a closed set of adapters (`Adapter`): adding one
//! is a new variant, and the routes in `web/payments.rs` never name a
//! processor.

use serde_json::Value;

const STRIPE_AUTHORIZE_URL: &str = "https://connect.stripe.com/oauth/authorize";
const STRIPE_TOKEN_URL: &str = "https://connect.stripe.com/oauth/token";
const STRIPE_DEAUTHORIZE_URL: &str = "https://connect.stripe.com/oauth/deauthorize";
const STRIPE_ACCOUNTS_URL: &str = "https://api.stripe.com/v1/accounts";

/// The platform's Stripe credentials, one key and one Connect client id
/// per mode. A mode with either half missing is unavailable.
#[derive(Clone, Debug, Default)]
pub struct StripeCreds {
    pub test_key: String,
    pub live_key: String,
    pub test_client_id: String,
    pub live_client_id: String,
}

impl StripeCreds {
    /// Reads the credentials from `STRIPE_PLATFORM_{TEST,LIVE}_KEY` and
    /// `STRIPE_CONNECT_{TEST,LIVE}_CLIENT_ID`; unset variables read as empty.
    pub fn from_env() -> Self {
        let var = |name: &str| std::env::var(name).unwrap_or_default();
        Self {
            test_key: var("STRIPE_PLATFORM_TEST_KEY"),
            live_key: var("STRIPE_PLATFORM_LIVE_KEY"),
            test_client_id: var("STRIPE_CONNECT_TEST_CLIENT_ID"),
            live_client_id: var("STRIPE_CONNECT_LIVE_CLIENT_ID"),
        }
    }

    /// Returns the platform secret key for `mode`, or `None` when it is unset.
    pub fn key(&self, mode: &str) -> Option<&str> {
        let key = if mode == "live" { &self.live_key } else { &self.test_key };
        (!key.is_empty()).then_some(key.as_str())
    }

    /// Returns the Connect client id for `mode`, or `None` when it is unset.
    pub fn client_id(&self, mode: &str) -> Option<&str> {
        let id = if mode == "live" { &self.live_client_id } else { &self.test_client_id };
        (!id.is_empty()).then_some(id.as_str())
    }

    /// Lists the modes with both a key and a client id configured.
    pub fn modes(&self) -> Vec<&'static str> {
        ["test", "live"]
            .into_iter()
            .filter(|mode| self.key(mode).is_some() && self.client_id(mode).is_some())
            .collect()
    }
}

/// The account a completed authorization produced.
#[derive(Clone, Debug, PartialEq)]
pub struct Connected {
    pub account_ref: String,
    pub display_name: String,
    pub mode: String,
}

/// A processor a tenant can connect.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Adapter {
    /// Stripe Connect (standard OAuth).
    Stripe,
    /// A local stand-in that needs no processor account; never offered in
    /// production.
    Mock,
}

impl Adapter {
    /// Lists the adapters offered to a tenant; `Mock` is left out in production.
    pub fn offered(production: bool) -> Vec<Adapter> {
        if production { vec![Adapter::Stripe] } else { vec![Adapter::Stripe, Adapter::Mock] }
    }

    /// Finds the adapter whose `processor` name matches.
    pub fn from_processor(name: &str) -> Option<Adapter> {
        match name {
            "stripe" => Some(Adapter::Stripe),
            "mock" => Some(Adapter::Mock),
            _ => None,
        }
    }

    /// Returns the name stored on the connection and shown to the site.
    pub fn processor(&self) -> &'static str {
        match self {
            Adapter::Stripe => "stripe",
            Adapter::Mock => "mock",
        }
    }

    /// Returns the name a Payment records as its processor. It differs from
    /// `processor` for the mock, whose payments settle through the local
    /// checkout page.
    pub fn payment_processor(&self) -> &'static str {
        match self {
            Adapter::Stripe => "stripe",
            Adapter::Mock => "mock_stripe",
        }
    }

    /// Returns the human-readable name shown on the Payments page.
    pub fn label(&self) -> &'static str {
        match self {
            Adapter::Stripe => "Stripe",
            Adapter::Mock => "Mock processor (local development)",
        }
    }

    /// Lists the modes this adapter can connect in.
    pub fn modes(&self, creds: &StripeCreds) -> Vec<&'static str> {
        match self {
            Adapter::Stripe => creds.modes(),
            Adapter::Mock => vec!["test"],
        }
    }

    /// Builds the URL that sends the tenant to the processor's
    /// authorization screen.
    ///
    /// # Errors
    ///
    /// Returns a message when `mode` has no credentials configured.
    pub fn authorize_url(&self, creds: &StripeCreds, mode: &str, state: &str, redirect_uri: &str) -> Result<String, String> {
        match self {
            Adapter::Stripe => {
                let client_id = creds.client_id(mode).ok_or_else(|| format!("Stripe has no Connect client id for {mode} mode"))?;
                let mut url = reqwest::Url::parse(STRIPE_AUTHORIZE_URL).expect("constant URL parses");
                url.query_pairs_mut()
                    .append_pair("response_type", "code")
                    .append_pair("client_id", client_id)
                    .append_pair("scope", "read_write")
                    .append_pair("state", state)
                    .append_pair("redirect_uri", redirect_uri);
                Ok(url.to_string())
            }
            Adapter::Mock => {
                let mut url = reqwest::Url::parse(redirect_uri).map_err(|e| format!("bad redirect_uri: {e}"))?;
                let code = format!("mock_{}", &uuid::Uuid::new_v4().simple().to_string()[..12]);
                url.query_pairs_mut().append_pair("code", &code).append_pair("state", state);
                Ok(url.to_string())
            }
        }
    }

    /// Exchanges the authorization `code` for the tenant's account.
    ///
    /// # Errors
    ///
    /// Returns a message when the processor refuses the code or authorized
    /// an account in a different mode than requested.
    pub async fn complete(&self, http: &reqwest::Client, creds: &StripeCreds, mode: &str, code: &str) -> Result<Connected, String> {
        match self {
            Adapter::Mock => Ok(Connected {
                account_ref: format!("acct_mock_{}", &uuid::Uuid::new_v4().simple().to_string()[..8]),
                display_name: "Mock Business".to_string(),
                mode: "test".to_string(),
            }),
            Adapter::Stripe => {
                let key = creds.key(mode).ok_or_else(|| format!("Stripe has no platform key for {mode} mode"))?;
                let response = http
                    .post(STRIPE_TOKEN_URL)
                    .bearer_auth(key)
                    .form(&[("grant_type", "authorization_code"), ("code", code)])
                    .send()
                    .await
                    .map_err(|e| e.to_string())?;
                let status = response.status();
                let body: Value = response.json().await.map_err(|e| e.to_string())?;
                let account_ref = parse_token_response(status.is_success(), &body, mode)?;
                let display_name = self.fetch_display_name(http, key, &account_ref).await;
                Ok(Connected { account_ref, display_name, mode: mode.to_string() })
            }
        }
    }

    // A name for the account is a nicety: any failure to read it falls
    // back to the account reference rather than failing the connection.
    async fn fetch_display_name(&self, http: &reqwest::Client, key: &str, account_ref: &str) -> String {
        let account = match http.get(format!("{STRIPE_ACCOUNTS_URL}/{account_ref}")).bearer_auth(key).send().await {
            Ok(response) if response.status().is_success() => response.json::<Value>().await.unwrap_or(Value::Null),
            _ => Value::Null,
        };
        display_name_from(&account, account_ref)
    }

    /// Revokes the platform's access to the tenant's account, best effort.
    ///
    /// Returns whether the processor confirmed the revocation.
    pub async fn disconnect(&self, http: &reqwest::Client, creds: &StripeCreds, account_ref: &str, mode: &str) -> bool {
        match self {
            Adapter::Mock => true,
            Adapter::Stripe => {
                let (Some(key), Some(client_id)) = (creds.key(mode), creds.client_id(mode)) else { return false };
                let sent = http
                    .post(STRIPE_DEAUTHORIZE_URL)
                    .bearer_auth(key)
                    .form(&[("client_id", client_id), ("stripe_user_id", account_ref)])
                    .send()
                    .await;
                matches!(sent, Ok(response) if response.status().is_success())
            }
        }
    }
}

/// Reads the connected account's reference out of Stripe's token response.
///
/// # Errors
///
/// Returns Stripe's own message for a refused code, or a mismatch message
/// when the authorized account's mode differs from `requested_mode`.
pub fn parse_token_response(ok: bool, body: &Value, requested_mode: &str) -> Result<String, String> {
    if !ok {
        let message = body
            .get("error_description")
            .or_else(|| body.get("error"))
            .and_then(|v| v.as_str())
            .unwrap_or("Stripe refused the authorization");
        return Err(message.to_string());
    }
    let account_ref = body.get("stripe_user_id").and_then(|v| v.as_str()).ok_or("Stripe's response carried no account id")?;
    let live = body.get("livemode").and_then(|v| v.as_bool()).unwrap_or(false);
    let actual = if live { "live" } else { "test" };
    if actual != requested_mode {
        return Err(format!("Stripe authorized a {actual} account but {requested_mode} was requested"));
    }
    Ok(account_ref.to_string())
}

/// Picks the first present name from a Stripe account object, falling
/// back to `account_ref`.
pub fn display_name_from(account: &Value, account_ref: &str) -> String {
    [
        account.pointer("/business_profile/name"),
        account.pointer("/settings/dashboard/display_name"),
        account.get("email"),
    ]
    .into_iter()
    .flatten()
    .filter_map(|v| v.as_str())
    .find(|s| !s.is_empty())
    .unwrap_or(account_ref)
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn creds() -> StripeCreds {
        StripeCreds {
            test_key: "sk_test_x".into(),
            live_key: String::new(),
            test_client_id: "ca_test".into(),
            live_client_id: "ca_live".into(),
        }
    }

    #[test]
    fn a_stripe_mode_needs_both_a_key_and_a_client_id() {
        // live has a client id but no key, so only test is offered.
        assert_eq!(creds().modes(), vec!["test"]);
        assert_eq!(StripeCreds::default().modes(), Vec::<&str>::new());
    }

    #[test]
    fn the_mock_is_not_offered_in_production() {
        assert_eq!(Adapter::offered(true), vec![Adapter::Stripe]);
        assert_eq!(Adapter::offered(false), vec![Adapter::Stripe, Adapter::Mock]);
    }

    #[test]
    fn processors_round_trip_by_name() {
        for adapter in [Adapter::Stripe, Adapter::Mock] {
            assert_eq!(Adapter::from_processor(adapter.processor()), Some(adapter));
        }
        assert_eq!(Adapter::from_processor("paypal"), None);
    }

    #[test]
    fn a_mock_payment_records_the_mock_stripe_processor() {
        assert_eq!(Adapter::Mock.payment_processor(), "mock_stripe");
        assert_eq!(Adapter::Stripe.payment_processor(), "stripe");
    }

    #[test]
    fn the_stripe_authorize_url_carries_the_client_id_state_and_redirect() {
        let url = Adapter::Stripe.authorize_url(&creds(), "test", "st ate", "https://site.test/api/cb").unwrap();
        assert!(url.starts_with("https://connect.stripe.com/oauth/authorize?"));
        assert!(url.contains("client_id=ca_test"));
        assert!(url.contains("state=st+ate"));
        assert!(url.contains("redirect_uri=https%3A%2F%2Fsite.test%2Fapi%2Fcb"));
        assert!(url.contains("scope=read_write"));
    }

    #[test]
    fn the_stripe_authorize_url_is_refused_for_an_unconfigured_mode() {
        let none = StripeCreds::default();
        assert!(Adapter::Stripe.authorize_url(&none, "live", "s", "https://site.test/cb").is_err());
    }

    #[test]
    fn the_mock_authorize_url_calls_straight_back_with_a_code_and_the_state() {
        let url = Adapter::Mock.authorize_url(&creds(), "test", "the-state", "https://site.test/api/cb").unwrap();
        assert!(url.starts_with("https://site.test/api/cb?code=mock_"));
        assert!(url.ends_with("&state=the-state"));
    }

    #[test]
    fn a_token_response_yields_the_account_reference() {
        let body = json!({"stripe_user_id": "acct_123", "livemode": false});
        assert_eq!(parse_token_response(true, &body, "test").unwrap(), "acct_123");
    }

    #[test]
    fn a_token_response_in_the_wrong_mode_is_refused() {
        let body = json!({"stripe_user_id": "acct_123", "livemode": true});
        let err = parse_token_response(true, &body, "test").unwrap_err();
        assert_eq!(err, "Stripe authorized a live account but test was requested");
    }

    #[test]
    fn a_refused_code_surfaces_stripes_own_message() {
        let body = json!({"error": "invalid_grant", "error_description": "Authorization code expired"});
        assert_eq!(parse_token_response(false, &body, "test").unwrap_err(), "Authorization code expired");
    }

    #[test]
    fn the_display_name_prefers_the_business_name_and_falls_back_to_the_reference() {
        let named = json!({"business_profile": {"name": "Lifeadelics"}, "email": "a@b.co"});
        assert_eq!(display_name_from(&named, "acct_1"), "Lifeadelics");
        let email_only = json!({"business_profile": {"name": ""}, "email": "a@b.co"});
        assert_eq!(display_name_from(&email_only, "acct_1"), "a@b.co");
        assert_eq!(display_name_from(&Value::Null, "acct_1"), "acct_1");
    }

    #[tokio::test]
    async fn completing_a_mock_authorization_yields_a_mock_account() {
        let connected = Adapter::Mock.complete(&reqwest::Client::new(), &creds(), "test", "mock_abc").await.unwrap();
        assert!(connected.account_ref.starts_with("acct_mock_"));
        assert_eq!(connected.display_name, "Mock Business");
        assert_eq!(connected.mode, "test");
    }
}
