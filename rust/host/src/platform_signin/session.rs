//! Turning a verified token into a signed-in member of this site, or a refusal.
//!
//! The token proves who the issuer says the person is; it never creates a member. The mapping is
//! the one the site's Google sign-in already uses:
//!
//! 1. the token's `(idp_iss, idp_sub)` resolves to an identity that a member is linked to;
//! 2. otherwise the person's email is matched to an existing, enabled member who has a role and
//!    no identity yet, and that member is linked (the one write this flow can cause);
//! 3. otherwise the sign-in is refused. There is no fallback by email alone: the identity pin is
//!    what protects against a recycled or reassigned address.
//!
//! A member without a role is refused as well. The token's role is compared with the member's
//! local role and a difference is logged, never written.

use std::path::Path;

use async_trait::async_trait;
use serde_json::Value;
use tokio::sync::Mutex;
use tokio_postgres::Client;

use super::settings::SigninSettings;
use super::verify::VerifiedClaims;
use super::{cookie, pages};
use crate::auth::{self, Session};
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;

/// Where the account lands after a successful sign-in.
pub const LANDING_PATH: &str = "/admin.html";

/// What the flow needs to know about this site's members.
#[async_trait]
pub trait MemberDirectory: Send + Sync {
    /// Finds the identity registered for a provider's `(issuer, subject)`.
    async fn identity_for(&self, issuer: &str, subject: &str) -> anyhow::Result<Option<String>>;

    /// Finds the enabled member linked to an identity.
    async fn session_for_identity(&self, identity_id: &str) -> anyhow::Result<Option<Session>>;

    /// Links an existing, enabled member with a role and no identity, found by email.
    async fn provision(
        &self,
        email: &str,
        issuer: &str,
        subject: &str,
    ) -> anyhow::Result<Option<Session>>;
}

/// Maps a verified token to the member it may sign in, or `None` to refuse.
///
/// # Errors
///
/// Returns the member store's error; the caller treats it as this side's fault, not a refusal.
pub async fn map_member(
    directory: &dyn MemberDirectory,
    claims: &VerifiedClaims,
) -> anyhow::Result<Option<Session>> {
    let (Some(issuer), Some(subject)) =
        (claims.idp_issuer.as_deref(), claims.idp_subject.as_deref())
    else {
        return Ok(None);
    };
    let by_identity = match directory.identity_for(issuer, subject).await? {
        Some(identity_id) => directory.session_for_identity(&identity_id).await?,
        None => None,
    };
    let session = match by_identity {
        Some(session) => Some(session),
        None => directory.provision(&claims.email, issuer, subject).await?,
    };
    Ok(session.filter(has_role))
}

fn has_role(session: &Session) -> bool {
    session.role.as_deref().is_some_and(|role| !role.is_empty())
}

/// A difference between the role the issuer sent and the member's local role.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoleDrift {
    pub token_role: Option<String>,
    pub local_role: Option<String>,
}

/// Compares the token's role with the member's local one.
pub fn role_drift(claims: &VerifiedClaims, session: &Session) -> Option<RoleDrift> {
    let token_role = claims.roles.first().cloned();
    let local_role = session.role.clone();
    (token_role != local_role).then_some(RoleDrift {
        token_role,
        local_role,
    })
}

/// Builds the signed-in response: the account cookie, the cleared sign-in cookie, and a redirect
/// to the landing page.
pub fn signed_in(settings: &SigninSettings, session: &Session) -> Value {
    let token = auth::account_token(
        &settings.session_secret,
        &session.email,
        auth::SESSION_TTL_SECS,
    );
    // The site address decides Secure: the redirect URI of a Google client may be absent.
    let flags = crate::web::account_cookie_flags("", &settings.site_url);
    let account = format!(
        "{}={token}{flags}; Max-Age={}",
        settings.account_cookie,
        auth::SESSION_TTL_SECS
    );
    pages::redirect(LANDING_PATH, &[account, cookie::clear_header()])
}

/// The host's own member store, reached through the same functions the Google sign-in uses.
pub struct HostMembers<'a> {
    pub client: &'a Mutex<Client>,
    pub domain_ir: &'a Value,
    pub wasm_path: &'a Path,
    pub config: &'a LineageConfig,
    pub invoker: &'a dyn LambdaInvoker,
}

#[async_trait]
impl MemberDirectory for HostMembers<'_> {
    async fn identity_for(&self, issuer: &str, subject: &str) -> anyhow::Result<Option<String>> {
        auth::resolve_identity_from_head(self.client, self.domain_ir, issuer, subject).await
    }

    async fn session_for_identity(&self, identity_id: &str) -> anyhow::Result<Option<Session>> {
        auth::session_for_member_by_identity(self.client, self.domain_ir, identity_id).await
    }

    async fn provision(
        &self,
        email: &str,
        issuer: &str,
        subject: &str,
    ) -> anyhow::Result<Option<Session>> {
        auth::provision(
            self.client,
            self.wasm_path,
            self.config,
            self.domain_ir,
            email,
            issuer,
            subject,
            self.invoker,
        )
        .await
    }
}
