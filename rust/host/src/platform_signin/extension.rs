//! The host extension that puts the sign-in flow on the site's routes.
//!
//! It is deliberately small and generically named so it can move to the platform later: it knows
//! the routes, the mode and nothing about any one site. With `PLATFORM_SIGNIN` unset it is never
//! installed, so the host answers exactly as before.
//!
//! ## One installed instance per process
//!
//! The single-use record of token identifiers lives in the verifier this extension owns, and the
//! host installs one extension for the life of the process, so the record is process-wide. It does
//! not survive a restart (the replay window that opens is at most the token lifetime plus the
//! skew, 90 seconds) and it is not shared between instances, which is why the settings refuse any
//! process that is not the single long-lived server.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;

use super::fetcher::HttpJwksFetcher;
use super::handler::{CallbackRequest, SigninHandler, StdoutLog};
use super::jti::JtiStore;
use super::jwks::JwksCache;
use super::pages::{self, Failure};
use super::session::{HostMembers, MemberDirectory};
use super::settings::{Mode, SettingsError, SigninSettings};
use super::verify::Verifier;
use super::{cookie, query};
use crate::extension::{Ctx, HostExtension, RateRule};

/// Starts the flow in either mode.
pub const START_PATH: &str = "/auth/platform";
/// Finishes the flow in either mode.
pub const CALLBACK_PATH: &str = "/auth/platform/callback";
/// The site's Google sign-in path, which `default` mode takes over.
pub const GOOGLE_PATH: &str = "/auth/google";

/// Which half of the flow a request is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    Start,
    Callback,
}

/// The platform sign-in extension.
pub struct PlatformSignin {
    handler: SigninHandler,
}

impl PlatformSignin {
    /// Wraps a handler that is already built.
    pub fn new(handler: SigninHandler) -> Self {
        Self { handler }
    }

    /// Builds the extension from an explicit map, or `None` when `PLATFORM_SIGNIN` is unset.
    ///
    /// # Errors
    ///
    /// Returns the setting that is missing or malformed once the switch is on.
    pub fn from_env_map(vars: &HashMap<String, String>) -> Result<Option<Self>, SettingsError> {
        let Some(settings) = SigninSettings::from_env_map(vars)? else {
            return Ok(None);
        };
        let keys = JwksCache::new(HttpJwksFetcher::new(&settings.config.jwks_url));
        let verifier = Verifier::new(settings.config.clone(), keys, JtiStore::new());
        Ok(Some(Self::new(SigninHandler::new(
            settings,
            Arc::new(verifier),
            Arc::new(StdoutLog),
        ))))
    }

    /// Decides which half of the flow, if either, a request is for.
    pub fn classify(&self, event: &Value) -> Option<Route> {
        let method = event
            .pointer("/requestContext/http/method")
            .and_then(Value::as_str)?;
        let path = event.get("rawPath").and_then(Value::as_str)?;
        if method != "GET" {
            return None;
        }
        match path {
            START_PATH => Some(Route::Start),
            CALLBACK_PATH => Some(Route::Callback),
            GOOGLE_PATH if self.takes_over_google(raw_query(event)) => Some(Route::Start),
            _ => None,
        }
    }

    fn takes_over_google(&self, raw_query: &str) -> bool {
        self.handler.settings().mode == Mode::Default
            && !query::has_value(raw_query, "via", "google")
    }

    /// Finishes a sign-in for a callback request against a member store.
    pub async fn finish(&self, request: &CallbackRequest, members: &dyn MemberDirectory) -> Value {
        self.handler.callback(request, members).await
    }

    /// Answers a request that belongs to the flow, or `None` for everything else.
    pub async fn route_event(&self, event: &Value, members: &dyn MemberDirectory) -> Option<Value> {
        match self.classify(event)? {
            Route::Start => Some(self.handler.start()),
            Route::Callback => Some(self.finish(&callback_request(event), members).await),
        }
    }
}

fn raw_query(event: &Value) -> &str {
    event
        .get("rawQueryString")
        .and_then(Value::as_str)
        .unwrap_or("")
}

fn callback_request(event: &Value) -> CallbackRequest {
    CallbackRequest {
        raw_query: raw_query(event).to_string(),
        cookie_pairs: cookie::request_pairs(event),
    }
}

#[async_trait]
impl HostExtension for PlatformSignin {
    async fn guest_route(&self, ctx: &Ctx<'_>) -> Option<Value> {
        let event = ctx.event?;
        match self.classify(event)? {
            Route::Start => Some(self.handler.start()),
            Route::Callback => Some(self.finish_for_host(ctx, event).await),
        }
    }

    fn rate_rules(&self) -> Vec<RateRule> {
        vec![
            RateRule {
                name: "platform_signin_start",
                method: "GET",
                path: START_PATH,
                limit_env: "HECKS_RATE_LIMIT_PLATFORM_SIGNIN_START",
                default_limit: 30,
            },
            RateRule {
                name: "platform_signin_callback",
                method: "GET",
                path: CALLBACK_PATH,
                limit_env: "HECKS_RATE_LIMIT_PLATFORM_SIGNIN_CALLBACK",
                default_limit: 30,
            },
        ]
    }
}

impl PlatformSignin {
    /// Finishes a callback against the host's own member store.
    async fn finish_for_host(&self, ctx: &Ctx<'_>, event: &Value) -> Value {
        let Some(domain_ir) = ctx.domain_ir else {
            return pages::refusal(Failure::Unavailable);
        };
        let members = HostMembers {
            client: ctx.client,
            domain_ir,
            wasm_path: ctx.wasm_path,
            config: ctx.config,
            invoker: ctx.invoker,
        };
        self.finish(&callback_request(event), &members).await
    }
}

/// Refuses the boot because the sign-in settings were switched on and are wrong.
pub struct RefusedSettings(pub SettingsError);

#[async_trait]
impl HostExtension for RefusedSettings {
    fn boot_check(&self, _domain: &str) -> Result<(), String> {
        Err(format!("platform sign-in: {}", self.0))
    }
}

/// The extensions that platform sign-in contributes for these settings: none when it is off, the
/// flow when it is on, and a boot refusal when the settings are wrong.
pub fn extensions_for(vars: &HashMap<String, String>) -> Vec<Arc<dyn HostExtension>> {
    match PlatformSignin::from_env_map(vars) {
        Ok(None) => Vec::new(),
        Ok(Some(extension)) => vec![Arc::new(extension)],
        Err(error) => vec![Arc::new(RefusedSettings(error))],
    }
}
