//! The two halves of the sign-in flow: starting it, and finishing it on the callback.
//!
//! Starting makes a fresh nonce and state, stores them in the browser's `__Host-signin` cookie
//! and sends the browser to the issuer. Finishing reads that cookie and the callback's `token`
//! and `state`, verifies the token, maps it to a member and, only then, establishes a session.
//! Whatever happens, the sign-in cookie is deleted.
//!
//! ## What it never reads
//!
//! The issuer's address, the site's address and every redirect target come from the validated
//! settings. The handler is never given a `Host` or `X-Forwarded-*` header and reads no parameter
//! other than `token` and `state`, so a request cannot change where the browser is sent.
//!
//! ## What it never logs
//!
//! The token, the nonce, the state and the cookie are never written to a log, and an email only as
//! a short hash. A refusal logs its stable code.

use std::sync::Arc;

use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use super::cookie;
use super::jwks::KeySource;
use super::pages::{self, Failure};
use super::query;
use super::session::{self, MemberDirectory};
use super::settings::SigninSettings;
use super::verify::{Reason, Refusal, SigninCookie, SigninRequest, VerifiedClaims, Verifier};
use crate::auth;

/// The verification the handler needs, so a test can stand in a verifier with fixed keys.
pub trait TokenVerifier: Send + Sync {
    /// Decides whether a token may be used at `now` (Unix seconds).
    fn verify(&self, request: &SigninRequest<'_>, now: i64) -> Result<VerifiedClaims, Refusal>;
}

impl<K: KeySource + Send + Sync> TokenVerifier for Verifier<K> {
    fn verify(&self, request: &SigninRequest<'_>, now: i64) -> Result<VerifiedClaims, Refusal> {
        Verifier::verify(self, request, now)
    }
}

/// Where the flow records what happened. Fields never hold a secret.
pub trait SigninLog: Send + Sync {
    /// Records one event with its identifying fields.
    fn record(&self, event: &str, fields: Value);
}

/// The host's own structured log, one JSON line on stdout.
pub struct StdoutLog;

impl SigninLog for StdoutLog {
    fn record(&self, event: &str, fields: Value) {
        crate::log::info(event, fields);
    }
}

/// Makes one fresh nonce or state value each time it is called.
pub type Random = Box<dyn Fn() -> String + Send + Sync>;
/// Returns the current time in Unix seconds.
pub type Clock = Box<dyn Fn() -> i64 + Send + Sync>;

/// Makes a value of 244 random bits as 43 base64url characters.
pub fn fresh_value() -> String {
    let mut bytes = Vec::with_capacity(32);
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    super::jws::encode_base64url(&bytes)
}

/// Reads the system clock.
pub fn system_clock() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or(0)
}

/// What a callback request carried, already separated from any headers.
#[derive(Debug, Clone, Default)]
pub struct CallbackRequest {
    /// The raw query string, without the leading `?`.
    pub raw_query: String,
    /// Every `name=value` cookie pair the request carried.
    pub cookie_pairs: Vec<String>,
}

/// Starts and finishes sign-ins for one site against one issuer.
pub struct SigninHandler {
    settings: SigninSettings,
    verifier: Arc<dyn TokenVerifier>,
    log: Arc<dyn SigninLog>,
    random: Random,
    clock: Clock,
}

impl SigninHandler {
    /// Builds a handler that uses fresh randomness and the system clock.
    pub fn new(
        settings: SigninSettings,
        verifier: Arc<dyn TokenVerifier>,
        log: Arc<dyn SigninLog>,
    ) -> Self {
        Self {
            settings,
            verifier,
            log,
            random: Box::new(fresh_value),
            clock: Box::new(system_clock),
        }
    }

    /// Replaces the source of nonce and state values.
    pub fn with_random(mut self, random: Random) -> Self {
        self.random = random;
        self
    }

    /// Replaces the clock.
    pub fn with_clock(mut self, clock: Clock) -> Self {
        self.clock = clock;
        self
    }

    /// Returns the validated settings.
    pub fn settings(&self) -> &SigninSettings {
        &self.settings
    }

    /// Starts a sign-in: a redirect to the issuer and the browser's sign-in cookie.
    pub fn start(&self) -> Value {
        let cookie = SigninCookie {
            nonce: (self.random)(),
            state: (self.random)(),
        };
        let location = self.authorize_url(&cookie);
        self.log.record("platform_signin_started", json!({}));
        pages::redirect(&location, &[cookie::set_header(&cookie)])
    }

    fn authorize_url(&self, cookie: &SigninCookie) -> String {
        let config = &self.settings.config;
        format!(
            "{}/sso/authorize?site={}&env={}&nonce={}&state={}",
            config.issuer_url,
            auth::urlencode(&config.site_id),
            auth::urlencode(&config.environment),
            auth::urlencode(&cookie.nonce),
            auth::urlencode(&cookie.state),
        )
    }

    /// Finishes a sign-in on the callback. Every outcome deletes the sign-in cookie.
    pub async fn callback(
        &self,
        request: &CallbackRequest,
        members: &dyn MemberDirectory,
    ) -> Value {
        match self.finish(request, members).await {
            Ok(response) => response,
            Err(failure) => pages::refusal(failure),
        }
    }

    async fn finish(
        &self,
        request: &CallbackRequest,
        members: &dyn MemberDirectory,
    ) -> Result<Value, Failure> {
        let cookie = cookie::read(&request.cookie_pairs)
            .map_err(|fault| self.refused(Failure::Cookie, &format!("{fault:?}")))?;
        let params = query::parse_callback(&request.raw_query)
            .map_err(|fault| self.refused(Failure::Params, &format!("{fault:?}")))?;
        let claims = self.verified(cookie, params).await?;
        let session = match session::map_member(members, &claims).await {
            Ok(Some(session)) => session,
            Ok(None) => {
                return Err(self.refused_with(Failure::Unlinked, "no_member", Some(&claims.email)))
            }
            Err(error) => {
                return Err(self.refused(Failure::Unavailable, &format!("member_store: {error}")))
            }
        };
        self.log_success(&claims, &session);
        Ok(session::signed_in(&self.settings, &session))
    }

    /// Verifies on a blocking thread: the key set fetch waits on the network.
    async fn verified(
        &self,
        cookie: SigninCookie,
        params: query::CallbackParams,
    ) -> Result<VerifiedClaims, Failure> {
        let verifier = self.verifier.clone();
        let now = (self.clock)();
        let outcome = tokio::task::spawn_blocking(move || {
            let request = SigninRequest {
                token: Some(&params.token),
                state: Some(&params.state),
                cookie: Some(&cookie),
            };
            verifier.verify(&request, now)
        })
        .await
        .map_err(|_| self.refused(Failure::Unavailable, "verification_did_not_finish"))?;
        outcome.map_err(|refusal| self.refused(failure_for(refusal.reason), refusal.code()))
    }

    fn refused(&self, failure: Failure, reason: &str) -> Failure {
        self.refused_with(failure, reason, None)
    }

    fn refused_with(&self, failure: Failure, reason: &str, email: Option<&str>) -> Failure {
        let mut fields = json!({"code": failure.code(), "reason": reason});
        if let Some(email) = email {
            fields["who"] = json!(short_hash(email));
        }
        self.log.record("platform_signin_refused", fields);
        failure
    }

    fn log_success(&self, claims: &VerifiedClaims, session: &auth::Session) {
        if let Some(drift) = session::role_drift(claims, session) {
            let fields = json!({"token_role": drift.token_role, "local_role": drift.local_role, "who": short_hash(&claims.email)});
            self.log.record("platform_signin_role_drift", fields);
        }
        self.log.record(
            "platform_signin_succeeded",
            json!({"who": short_hash(&claims.email)}),
        );
    }
}

/// The page a verifier refusal earns: the browser's own cookie and state are told apart, the rest
/// share one answer so the page teaches nothing about which later check failed.
fn failure_for(reason: Reason) -> Failure {
    match reason {
        Reason::MissingCookie => Failure::Cookie,
        Reason::StateMismatch => Failure::State,
        _ => Failure::Token,
    }
}

/// The first four bytes of the lowercased email's SHA-256, enough to tell people apart in a log.
fn short_hash(email: &str) -> String {
    let digest = Sha256::digest(email.to_lowercase().as_bytes());
    let hex: String = digest.iter().take(4).map(|b| format!("{b:02x}")).collect();
    format!("h:{hex}")
}
