//! Sends one newsletter email through Resend's REST API. The Rust host is the only
//! implementation of this `deliver` answer; there is no Ruby adapter beside it. It is answered
//! natively (`live`) or by the Resend Wasm component (`component`), which hold the same payload,
//! retry and mapping and are held to one shared case list (`cases`).

mod component;
mod live;

use std::time::Duration;

const API_BASE: &str = "https://api.resend.com";
const TIMEOUT: Duration = Duration::from_secs(15);
/// The address the mock refuses, and (in `mock_deliver`) the reason it gives. Adapter-side test
/// vocabulary: the domain names neither (ADR 0099).
const MOCK_BOUNCE_ADDRESS: &str = "bounce@example.com";

/// One email to one recipient.
pub struct Email<'a> {
    pub to: &'a str,
    pub subject: &'a str,
    /// HTML when it opens with a tag (a rendered issue), plain text otherwise.
    pub body: &'a str,
    /// Where the recipient leaves the list; sent as `List-Unsubscribe` so
    /// mail clients can offer their own unsubscribe button.
    pub unsubscribe_url: Option<&'a str>,
}

/// What handing an email to the provider came to. A refusal or outage for one
/// recipient is `ok: false` with a reason (never an `Err`), so a fan-out can carry on.
#[derive(Debug, PartialEq, Eq)]
pub struct Delivery {
    pub ok: bool,
    pub message_id: Option<String>,
    pub reason: Option<String>,
}

impl Delivery {
    const fn sent(message_id: String) -> Self {
        Self {
            ok: true,
            message_id: Some(message_id),
            reason: None,
        }
    }

    fn failed(reason: impl Into<String>) -> Self {
        Self {
            ok: false,
            message_id: None,
            reason: Some(reason.into()),
        }
    }
}

/// Where Resend is reached and as whom: the key, the from address, an optional reply-to and the
/// API's base URL (Resend's, or a stand-in in tests).
#[derive(Clone)]
pub struct Account {
    api_key: String,
    from: String,
    reply_to: Option<String>,
    base_url: String,
}

/// How email leaves the host: through Resend natively, through the Resend Wasm component, or
/// logged and dropped.
pub enum Mailer {
    Live {
        http: reqwest::Client,
        account: Account,
    },
    /// The same delivery run by `rust/adapters/resend` as a component, for a deploy whose
    /// hecksagon wires it to the `email` port: the IR's `components` names its module and grant.
    /// Slice 5 of docs/plans/wasm-adapters.md deletes `Live` once this is the default.
    Component {
        account: Account,
        wiring: component::Wiring,
    },
    Mock,
}

impl Mailer {
    /// `Ok(None)` when nothing is configured; `Err` when a key is set without `RESEND_FROM` —
    /// marking an issue sent is irreversible, so a missing key must refuse before that happens —
    /// and when the IR wires a component the host cannot load. The IR's wiring picks the
    /// component; without it mail goes out natively.
    pub fn from_env() -> Result<Option<Self>, String> {
        let var = |name: &str| crate::secrets::var(name).unwrap_or_default();
        let wiring = component::wired(crate::ir::ir())?;
        let mailer = Self::configured(
            &var("RESEND_API_KEY"),
            &var("RESEND_FROM"),
            &var("RESEND_MOCK"),
            wiring,
        )?;
        Ok(mailer.map(|mailer| mailer.replying_to(&var("RESEND_REPLY_TO"))))
    }

    fn configured(
        api_key: &str,
        from: &str,
        mock: &str,
        wiring: Option<component::Wiring>,
    ) -> Result<Option<Self>, String> {
        if !api_key.is_empty() {
            if from.is_empty() {
                return Err("RESEND_API_KEY is set but RESEND_FROM is not — Resend needs a from address on a verified domain".to_string());
            }
            if let Some(wiring) = wiring {
                let account = Account::new(api_key, from, API_BASE);
                return Ok(Some(Self::Component { account, wiring }));
            }
            return Ok(Some(Self::live(api_key, from, API_BASE)));
        }
        // Mock requires an explicit opt-in, unlike checkout's mock-by-default.
        Ok((mock == "1").then_some(Self::Mock))
    }

    /// A native mailer that posts to `base_url` (Resend's API, or a stand-in in tests).
    #[allow(clippy::expect_used)] // reason: startup config; a client with only a timeout set always builds
    pub fn live(api_key: &str, from: &str, base_url: &str) -> Self {
        let http = reqwest::Client::builder()
            .timeout(TIMEOUT)
            .build()
            .expect("a reqwest client with a timeout always builds");
        Self::Live {
            http,
            account: Account::new(api_key, from, base_url),
        }
    }

    /// A mailer that hands each email to the committed Resend component, posting to `base_url`,
    /// granted the account's key and the base URL's host.
    #[cfg(test)]
    pub fn component(api_key: &str, from: &str, base_url: &str) -> Self {
        let account = Account::new(api_key, from, base_url);
        let wiring = component::committed::wiring(&account);
        Self::Component { account, wiring }
    }

    /// Sets where replies go (`Reply-To`), when the address people reply to is not the one the mail
    /// is sent from. Blank leaves replies going to the From address. A mock mailer has no replies.
    pub fn replying_to(self, reply_to: &str) -> Self {
        let reply_to = (!reply_to.trim().is_empty()).then(|| reply_to.trim().to_string());
        match self {
            Self::Live { http, account } => Self::Live {
                http,
                account: Account {
                    reply_to,
                    ..account
                },
            },
            Self::Component { account, wiring } => Self::Component {
                account: Account {
                    reply_to,
                    ..account
                },
                wiring,
            },
            mock @ Self::Mock => mock,
        }
    }

    #[cfg(test)]
    pub const fn is_mock(&self) -> bool {
        matches!(self, Self::Mock)
    }

    pub async fn deliver(&self, email: &Email<'_>) -> Delivery {
        match self {
            Self::Mock => mock_deliver(email),
            Self::Live { http, account } => live::deliver(http, account, email).await,
            Self::Component { account, wiring } => component::deliver(account, wiring, email).await,
        }
    }
}

impl Account {
    fn new(api_key: &str, from: &str, base_url: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            from: from.to_string(),
            reply_to: None,
            base_url: base_url.to_string(),
        }
    }
}

fn mock_deliver(email: &Email<'_>) -> Delivery {
    if email.to == MOCK_BOUNCE_ADDRESS {
        return Delivery::failed("bounced");
    }
    println!(
        "[mock resend] to={} subject={:?}\n{}",
        email.to, email.subject, email.body
    );
    Delivery::sent(format!("re_{}", uuid::Uuid::new_v4().simple()))
}

#[cfg(test)]
mod cases;
#[cfg(test)]
mod tests;
