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

use super::handler::{CallbackRequest, SigninHandler};
use super::session::MemberDirectory;
use super::settings::SettingsError;
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
        let _ = vars;
        todo!()
    }

    /// Decides which half of the flow, if either, a request is for.
    pub fn classify(&self, event: &Value) -> Option<Route> {
        let _ = event;
        todo!()
    }

    /// Finishes a sign-in for a callback request against a member store.
    pub async fn finish(&self, request: &CallbackRequest, members: &dyn MemberDirectory) -> Value {
        let _ = (request, members);
        todo!()
    }

    /// Answers a request that belongs to the flow, or `None` for everything else.
    pub async fn route_event(&self, event: &Value, members: &dyn MemberDirectory) -> Option<Value> {
        let _ = (event, members);
        todo!()
    }
}

#[async_trait]
impl HostExtension for PlatformSignin {
    async fn guest_route(&self, ctx: &Ctx<'_>) -> Option<Value> {
        let _ = ctx;
        todo!()
    }

    fn rate_rules(&self) -> Vec<RateRule> {
        todo!()
    }
}

/// Refuses the boot because the sign-in settings were switched on and are wrong.
pub struct RefusedSettings(pub SettingsError);

#[async_trait]
impl HostExtension for RefusedSettings {
    fn boot_check(&self, _domain: &str) -> Result<(), String> {
        todo!()
    }
}

/// The extensions that platform sign-in contributes for these settings: none when it is off, the
/// flow when it is on, and a boot refusal when the settings are wrong.
pub fn extensions_for(vars: &HashMap<String, String>) -> Vec<Arc<dyn HostExtension>> {
    let _ = vars;
    Vec::new()
}
