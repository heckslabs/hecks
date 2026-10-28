//! Google sign-in and stateless sessions: OAuth, ID-token verification
//! against Google's real JWKS, and HMAC-signed session/account cookies.

use crate::b64;
use crate::crypto::{constant_time_eq, hex_encode};
use crate::dispatch;
use crate::host::Host;
use crate::journal;
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use crate::needs::{Clock, ProcessClock};
use crate::store::{Store, StoreError};
use serde_json::{json, Value};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

mod google_signin;

pub use google_signin::GoogleSignin;
pub use google_signin::{
    clear_header as google_signin_clear_header, read as read_google_signin,
    set_header as google_signin_set_header,
};

const ISSUER: &str = "https://accounts.google.com";

/// A verified Google ID token's claims.
pub struct Claims {
    pub issuer: String,
    pub subject: String,
    pub email: Option<String>,
    pub email_verified: bool,
}

/// A signed-in person, as carried in the session cookie.
pub struct Session {
    pub identity_id: String,
    pub email: String,
    pub name: String,
    pub role: Option<String>,
}

/// The caller a signed-in session dispatches as: the role it carries and the identity
/// Governance holds assignments for. No session is an unidentified caller.
pub fn caller(session: Option<&Session>) -> crate::dispatch::Caller<'_> {
    session.map_or_else(crate::dispatch::Caller::default, |session| {
        crate::dispatch::Caller {
            role: session.role.as_deref(),
            actor_id: Some(session.identity_id.as_str()).filter(|id| !id.is_empty()),
        }
    })
}

/// Google's consent page for one sign-in: `signin`'s `state` comes back on the callback and its
/// `nonce` inside the ID token, and both must match the cookie `/auth/google` set beside them.
pub fn authorization_url(redirect_uri: &str, signin: &GoogleSignin) -> Result<String, String> {
    let client_id = crate::secrets::var("GOOGLE_CLIENT_ID")
        .map_err(|_| "GOOGLE_CLIENT_ID not set".to_string())?;
    Ok(format!(
        "https://accounts.google.com/o/oauth2/v2/auth?client_id={}&redirect_uri={}&response_type=code&scope={}&state={}&nonce={}",
        urlencode(&client_id),
        urlencode(redirect_uri),
        urlencode("openid email profile"),
        urlencode(&signin.state),
        urlencode(&signin.nonce),
    ))
}

pub async fn verify(code: &str, redirect_uri: &str, nonce: &str) -> Result<Claims, String> {
    let client_id = crate::secrets::var("GOOGLE_CLIENT_ID")
        .map_err(|_| "GOOGLE_CLIENT_ID not set".to_string())?;
    let client_secret = crate::secrets::var("GOOGLE_CLIENT_SECRET")
        .map_err(|_| "GOOGLE_CLIENT_SECRET not set".to_string())?;

    let http = crate::http::client();
    let resp = http
        .post("https://oauth2.googleapis.com/token")
        .form(&[
            ("code", code),
            ("client_id", client_id.as_str()),
            ("client_secret", client_secret.as_str()),
            ("redirect_uri", redirect_uri),
            ("grant_type", "authorization_code"),
        ])
        .send()
        .await
        .map_err(|e| format!("token exchange: {e}"))?;

    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("token exchange failed: {body}"));
    }
    let body: Value = resp
        .json()
        .await
        .map_err(|e| format!("token response: {e}"))?;
    let id_token = body
        .get("id_token")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "no id_token in the response".to_string())?;

    verify_id_token(id_token, &client_id, nonce).await
}

// Fetched fresh, never cached: this is a real sign-in, not a hot path,
// and missing Google's own key rotation would be worse than one extra
// HTTPS round trip per login.
async fn verify_id_token(id_token: &str, client_id: &str, nonce: &str) -> Result<Claims, String> {
    let header =
        jsonwebtoken::decode_header(id_token).map_err(|e| format!("bad id_token header: {e}"))?;
    let kid = header
        .kid
        .ok_or_else(|| "id_token header has no kid".to_string())?;

    let http = crate::http::client();
    let jwks: Value = http
        .get("https://www.googleapis.com/oauth2/v3/certs")
        .send()
        .await
        .map_err(|e| format!("fetching Google's JWKS: {e}"))?
        .json()
        .await
        .map_err(|e| format!("parsing Google's JWKS: {e}"))?;

    let key = jwks
        .get("keys")
        .and_then(|k| k.as_array())
        .and_then(|keys| {
            keys.iter()
                .find(|k| k.get("kid").and_then(|v| v.as_str()) == Some(kid.as_str()))
        })
        .ok_or_else(|| format!("no JWKS key matches id_token's kid {kid:?}"))?;
    let n = key
        .get("n")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "JWKS key has no n".to_string())?;
    let e = key
        .get("e")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "JWKS key has no e".to_string())?;
    let decoding_key = jsonwebtoken::DecodingKey::from_rsa_components(n, e)
        .map_err(|err| format!("building decoding key from JWKS: {err}"))?;

    let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::RS256);
    validation.set_audience(&[client_id]);
    validation.set_issuer(&[ISSUER, "accounts.google.com"]);

    let token = jsonwebtoken::decode::<Value>(id_token, &decoding_key, &validation)
        .map_err(|err| format!("id_token signature/claims invalid: {err}"))?;
    let claims = token.claims;
    check_nonce(&claims, nonce)?;

    Ok(Claims {
        issuer: claims
            .get("iss")
            .and_then(|v| v.as_str())
            .unwrap_or(ISSUER)
            .to_string(),
        subject: claims
            .get("sub")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "id_token has no sub".to_string())?
            .to_string(),
        email: claims
            .get("email")
            .and_then(|v| v.as_str())
            .map(std::string::ToString::to_string),
        email_verified: matches!(claims.get("email_verified"), Some(Value::Bool(true)))
            || claims.get("email_verified").and_then(|v| v.as_str()) == Some("true"),
    })
}

// The ID token must carry the nonce this browser's sign-in cookie holds, so a token minted for
// someone else's sign-in cannot finish this one.
fn check_nonce(claims: &Value, expected: &str) -> Result<(), String> {
    let carried = claims.get("nonce").and_then(Value::as_str).unwrap_or("");
    if constant_time_eq(carried.as_bytes(), expected.as_bytes()) {
        Ok(())
    } else {
        Err("id_token nonce does not match this sign-in".to_string())
    }
}

/// The cookie name the account token travels in when a deploy names none.
/// A deploy naming its own uses `HECKS_SESSION_COOKIE` instead.
pub const DEFAULT_ACCOUNT_COOKIE: &str = "hecks_session";

/// Unset or empty means the default; otherwise must be a valid cookie
/// name (letters, digits, `_`, `-`, `.`) since it lands in `Set-Cookie` raw.
pub fn resolve_account_cookie(configured: Option<&str>) -> Result<String, String> {
    match configured {
        None | Some("") => Ok(DEFAULT_ACCOUNT_COOKIE.to_string()),
        Some(name) if name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.')) => Ok(name.to_string()),
        Some(name) => Err(format!(
            "HECKS_SESSION_COOKIE {name:?} is not a valid cookie name (letters, digits, '_', '-' and '.' only)"
        )),
    }
}

/// Reads `HECKS_SESSION_COOKIE`; an invalid value falls back to the
/// default here, but `main` refuses it at boot so it can't go unnoticed.
pub fn account_cookie_name() -> String {
    resolve_account_cookie(std::env::var("HECKS_SESSION_COOKIE").ok().as_deref())
        .unwrap_or_else(|_| DEFAULT_ACCOUNT_COOKIE.to_string())
}

/// A flat, HMAC-signed `email` + expiry claim, verified by /accounts/me
/// and the SSO handoff — deliberately not a `Session` cookie.
pub fn account_token(secret: &str, email: &str, ttl_secs: u64) -> String {
    let payload = json!({"email": email, "exp": now_secs() + ttl_secs});
    let encoded = b64::url_encode(payload.to_string().as_bytes());
    format!("{encoded}.{}", sign(secret, &encoded))
}

pub fn verify_account_token(secret: &str, token: &str) -> Option<String> {
    let payload = verify_sig(secret, token)?;
    let bytes = b64::url_decode(&payload)?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    let exp = value.get("exp")?.as_u64()?;
    if now_secs() > exp {
        return None;
    }
    value
        .get("email")?
        .as_str()
        .map(std::string::ToString::to_string)
}

/// Verifies only for `purpose` (the signing key derives from it, so it
/// can't be replayed elsewhere). `claims` must be a JSON object.
pub fn purpose_token(secret: &str, purpose: &str, claims: Value, ttl_secs: u64) -> String {
    let mut payload = claims;
    payload["purpose"] = json!(purpose);
    payload["exp"] = json!(now_secs() + ttl_secs);
    let encoded = b64::url_encode(payload.to_string().as_bytes());
    format!(
        "{encoded}.{}",
        sign(&purpose_key(secret, purpose), &encoded)
    )
}

/// The claims of a token minted by `purpose_token` for the same `purpose`,
/// or `None` when the signature, the purpose or the expiry does not hold.
pub fn verify_purpose_token(secret: &str, purpose: &str, token: &str) -> Option<Value> {
    let payload = verify_sig(&purpose_key(secret, purpose), token)?;
    let claims: Value = serde_json::from_slice(&b64::url_decode(&payload)?).ok()?;
    if claims.get("purpose")?.as_str()? != purpose || now_secs() > claims.get("exp")?.as_u64()? {
        return None;
    }
    Some(claims)
}

fn purpose_key(secret: &str, purpose: &str) -> String {
    format!("{purpose}:{secret}")
}

const HANDOFF_PURPOSE: &str = "google-handoff";
const HANDOFF_TTL_SECS: u64 = 60;

/// A one-minute, single-use stand-in for `email`'s account token. It rides the redirect onto a
/// site on another origin, where a URL is logged and kept in history, and the site trades it for
/// the account token server-to-server (`redeem_handoff_token`).
pub fn handoff_token(secret: &str, email: &str) -> String {
    let jti = uuid::Uuid::new_v4().simple().to_string();
    purpose_token(
        secret,
        HANDOFF_PURPOSE,
        json!({ "email": email, "jti": jti }),
        HANDOFF_TTL_SECS,
    )
}

/// The account token a handoff token stands for, the first time it is redeemed; `None` when it is
/// forged, expired, minted for another purpose, or already spent in `spent`.
pub fn redeem_handoff_token(
    secret: &str,
    token: &str,
    spent: &crate::platform_signin::jti::JtiStore,
) -> Option<String> {
    let claims = verify_purpose_token(secret, HANDOFF_PURPOSE, token)?;
    let email = claims.get("email")?.as_str()?;
    let jti = claims.get("jti")?.as_str()?;
    let expires_at = i64::try_from(claims.get("exp")?.as_u64()?).ok()?;
    let now = i64::try_from(now_secs()).ok()?;
    spent
        .claim(jti, expires_at + 1, now)
        .then(|| account_token(secret, email, SESSION_TTL_SECS))
}

/// How long a session cookie, and the account token minted beside it, stays valid.
pub const SESSION_TTL_SECS: u64 = 60 * 60 * 24 * 14;

pub fn session_cookie(secret: &str, session: &Session) -> String {
    let payload = json!({
        "identity_id": session.identity_id,
        "email": session.email,
        "name": session.name,
        "role": session.role,
        "exp": now_secs() + SESSION_TTL_SECS,
    });
    let encoded = b64::url_encode(payload.to_string().as_bytes());
    format!("{encoded}.{}", sign(secret, &encoded))
}

pub fn parse_session_cookie(secret: &str, cookie: &str) -> Option<Session> {
    let payload = verify_sig(secret, cookie)?;
    let bytes = b64::url_decode(&payload)?;
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    // A cookie with no `exp`, or one in the past, is no session: a signed
    // payload alone would otherwise stay valid until the secret changed.
    if now_secs() > value.get("exp")?.as_u64()? {
        return None;
    }
    Some(Session {
        identity_id: value.get("identity_id")?.as_str()?.to_string(),
        email: value.get("email")?.as_str()?.to_string(),
        name: value.get("name")?.as_str()?.to_string(),
        role: value
            .get("role")
            .and_then(|v| v.as_str())
            .map(std::string::ToString::to_string),
    })
}

/// Looks up `"Identity::ExternalIdentifier#{issuer}:{subject}"` in
/// `instances` — the same key shape used everywhere else there.
pub fn resolve_identity(instances: &Value, issuer: &str, subject: &str) -> Option<String> {
    let key = format!("Identity::ExternalIdentifier#{issuer}:{subject}");
    identity_id_from_state(instances.get(&key)?)
}

fn identity_id_from_state(state: &Value) -> Option<String> {
    state
        .get("identity")
        .and_then(|v| v.as_str().map(str::to_string))
        .or_else(|| {
            state
                .get("identity")
                .and_then(|v| v.get("value"))
                .and_then(|v| v.as_str())
                .map(str::to_string)
        })
        .or_else(|| {
            state
                .get("identity_id")
                .and_then(|v| v.as_str().map(str::to_string))
        })
        .or_else(|| {
            state
                .get("identity_id")
                .and_then(|v| v.get("value"))
                .and_then(|v| v.as_str())
                .map(str::to_string)
        })
}

/// Resolves an external identity the way the Google callback does: the PostgresEra head first,
/// then the flat journal's `instances`. A domain whose Identity bluebook keeps no head of its own
/// (its heads cover its own aggregates and the membership aggregate) holds the link only there.
///
/// # Errors
///
/// Returns the flat journal's read error, except that a missing flat journal means no link there. A
/// head that cannot be read is logged and skipped, as the Google callback does, so the flat journal
/// still gets its turn.
pub async fn resolve_identity_anywhere(
    store: &Store,
    wasm_path: &Path,
    domain_ir: &Value,
    issuer: &str,
    subject: &str,
) -> anyhow::Result<Option<String>> {
    match resolve_identity_from_head(store, domain_ir, issuer, subject).await {
        Ok(Some(found)) => return Ok(Some(found)),
        Ok(None) => {}
        Err(error) => eprintln!("resolve_identity: identity head: {error:#}"),
    }
    let read = match dispatch::read(store, wasm_path).await {
        Ok(read) => read,
        Err(error) if flat_journal_is_absent(&error) => return Ok(None),
        Err(error) => return Err(error),
    };
    Ok(resolve_identity(
        read.get("instances").unwrap_or(&Value::Null),
        issuer,
        subject,
    ))
}

// A store with heads only has no flat journal to read; that is "no link there", not an outage.
fn flat_journal_is_absent(error: &anyhow::Error) -> bool {
    error
        .chain()
        .filter_map(|cause| cause.downcast_ref::<StoreError>())
        .any(StoreError::is_not_provisioned)
}

/// Identity lives in the PostgresEra head, not `dispatch::read`'s
/// `instances` — tries both the domain-qualified and the bare relation name.
pub async fn resolve_identity_from_head(
    store: &Store,
    domain_ir: &Value,
    issuer: &str,
    subject: &str,
) -> anyhow::Result<Option<String>> {
    let Some(_) = crate::ir::identity_provider(domain_ir) else {
        return Ok(None);
    };
    let domain = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let mut names = vec![
        journal::head_view(domain, "external_identifier"),
        journal::head_view("Identity", "external_identifier"),
        "external_identifier_head".to_string(),
    ];
    names.dedup();
    let guard = store.require_lineage()?.lock().await;
    for name in names {
        let sql = format!(
            "SELECT state FROM {} WHERE state->'issuer'->>'value' = $1 AND state->'subject'->>'value' = $2",
            journal::quote_ident(&name)
        );
        match guard.query_opt(&sql, &[&issuer, &subject]).await {
            Ok(Some(row)) => {
                let state: Value = row.get(0);
                return Ok(identity_id_from_state(&state));
            }
            Ok(None) => return Ok(None),
            Err(e) => {
                let e = StoreError::from(e);
                if !e.is_not_provisioned() {
                    return Err(e.into());
                }
            }
        }
    }
    Ok(None)
}

// Member lives in the PostgresEra head, not `dispatch::read`'s journal
// `instances` — reading `instances` for an already-linked member misses
// it entirely, so this queries the head view directly instead.
async fn member_row_by_email(
    store: &Store,
    domain_ir: &Value,
    email: &str,
) -> anyhow::Result<Option<Value>> {
    let (_, storage_name) = membership_aggregate(domain_ir)?;
    // docs/decisions/0059: `head_view` needs the domain name too, the
    // same one `ir.rs`/`web.rs` already extract this way.
    let domain = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let guard = store.require_lineage()?.lock().await;
    journal::read_lineage_head_by_id(&*guard, domain, &storage_name, email).await
}

async fn member_rows(store: &Store, domain_ir: &Value) -> anyhow::Result<Vec<(String, Value)>> {
    let (_, storage_name) = membership_aggregate(domain_ir)?;
    let domain = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let guard = store.require_lineage()?.lock().await;
    journal::read_lineage_head_all(&*guard, domain, &storage_name).await
}

// The membership aggregate comes from `ir.json`'s declared `membership`
// key, never an env var or a lookup against lineage_capable_aggregates —
// the bluebook declaration is the fact, same as Governance's authorization.
fn membership_aggregate(domain_ir: &Value) -> anyhow::Result<(String, String)> {
    let provider = crate::ir::membership_provider(domain_ir).ok_or_else(|| {
        anyhow::anyhow!(
            "this domain attaches no bluebook that provides \"membership\" — cannot resolve who may sign in"
        )
    })?;
    Ok(membership_names(&provider.aggregate))
}

fn membership_names(aggregate: &str) -> (String, String) {
    let bare = aggregate
        .rsplit("::")
        .next()
        .unwrap_or(aggregate)
        .to_string();
    let storage_name = crate::journal::snake(&bare);
    (bare, storage_name)
}

// Ported from `Adapters::PostgresEra#append` -- the same journal-insert
// + snapshot-upsert transaction every Member write uses. The advisory
// lock guards a concurrent domain rename, not ordinal uniqueness.
async fn append_member_state(
    store: &Store,
    config: &LineageConfig,
    domain_ir: &Value,
    id: &str,
    state: &Value,
) -> anyhow::Result<()> {
    let (aggregate_name, _) = membership_aggregate(domain_ir)?;
    let mut guard = store.require_lineage()?.lock().await;
    let txn = guard.transaction().await?;

    txn.execute(
        "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
        &[&config.domain],
    )
    .await?;

    journal::append_lineage_mutation(
        &txn,
        config,
        &journal::Mutation {
            aggregate: &aggregate_name,
            id,
            operation: "save",
            state,
        },
    )
    .await?;

    txn.commit().await?;
    Ok(())
}

pub async fn session_for_member_by_identity(
    store: &Store,
    domain_ir: &Value,
    identity_id: &str,
) -> anyhow::Result<Option<Session>> {
    let (_, storage_name) = membership_aggregate(domain_ir)?;
    // docs/decisions/0059 — same domain-qualification as above.
    let domain = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let guard = store.require_lineage()?.lock().await;
    let row = guard
        .query_opt(
            &format!(
                "SELECT state FROM {} WHERE state->'identity_id'->>'value' = $1",
                journal::quote_ident(&journal::head_view(domain, &storage_name))
            ),
            &[&identity_id],
        )
        .await?;
    drop(guard);
    Ok(row.and_then(|r| {
        let state: Value = r.get(0);
        if is_lapsed(&state) {
            return None;
        }
        Some(Session {
            identity_id: identity_id.to_string(),
            email: state.get("email")?.get("value")?.as_str()?.to_string(),
            name: state.get("name")?.get("value")?.as_str()?.to_string(),
            role: state
                .get("role")
                .and_then(|v| v.get("value"))
                .and_then(|v| v.as_str())
                .map(std::string::ToString::to_string),
        })
    }))
}

/// Mints Identity/Governance facts for an already-granted Member —
/// never creates one; Admit is a separate, real cap-table event.
#[allow(clippy::too_many_arguments)]
pub async fn provision(
    store: &Store,
    wasm_path: &Path,
    config: &LineageConfig,
    domain_ir: &Value,
    email: &str,
    issuer: &str,
    subject: &str,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<Option<Session>> {
    let Some(member) = member_row_by_email(store, domain_ir, email).await? else {
        return Ok(None);
    };
    if is_lapsed(&member) {
        return Ok(None);
    }
    let role = member
        .get("role")
        .and_then(|v| v.get("value"))
        .and_then(|v| v.as_str());
    let already_linked = member
        .get("identity_id")
        .and_then(|v| v.get("value"))
        .is_some();
    let (Some(role), false) = (role, already_linked) else {
        return Ok(None);
    };

    // Uses this domain's declared identity provider (`ir::identity_provider`),
    // never a hard-coded bluebook. Link's reference field is `identity`, not
    // `identity_id` -- changing this silently breaks linking.
    let Some(identity) = crate::ir::identity_provider(domain_ir) else {
        anyhow::bail!("this domain attaches no bluebook that provides \"identity\" — cannot register or link an identity");
    };

    // Reuse an Identity already registered+linked for this (issuer, subject)
    // instead of always minting a fresh one. Register, link and the Member's
    // own identity_id write below are three separate, non-transactional
    // steps; a process restart or a retried callback between them used to
    // leave an orphaned Identity (registered and externally linked, but
    // never reaching the Member) while a later call minted yet another
    // identity_id for the same Google account and wrote *that* onto the
    // Member instead — the two permanently disagreeing from then on, so
    // every subsequent sign-in resolved an identity_id the Member's
    // already_linked guard above never recognized as unlinked. Resolving
    // first makes a retry converge onto the earlier attempt's identity
    // instead of accumulating another orphan.
    let identity_id = if let Some(existing) =
        resolve_identity_from_head(store, domain_ir, issuer, subject).await?
    {
        existing
    } else {
        let identity_id = uuid::Uuid::new_v4().to_string();

        // `None` on every dispatch below: this is system-initiated
        // provisioning, not a caller-submitted command, so there is no
        // caller role to assert.
        let register = dispatch::handle(
            Host::new(store, wasm_path, config, invoker),
            &identity.register,
            json!({"identity_id": {"value": identity_id}}),
            None,
        )
        .await?;
        if !register.accepted {
            anyhow::bail!("{} refused: {}", identity.register, register.result);
        }

        let link_external = dispatch::handle(
            Host::new(store, wasm_path, config, invoker),
            &identity.link,
            json!({
                "identity": identity_id, "key": {"value": format!("{issuer}:{subject}")},
                "issuer": {"value": issuer}, "subject": {"value": subject},
            }),
            None,
        )
        .await?;
        if !link_external.accepted {
            anyhow::bail!("{} refused: {}", identity.link, link_external.result);
        }

        identity_id
    };

    // The grant verb this domain's declared authorization provider names
    // (`ir::authorization_provider`), never a hard-coded bluebook.
    let Some(provider) = crate::ir::authorization_provider(domain_ir) else {
        anyhow::bail!(
            "this domain attaches no bluebook that provides \"authorization\" — cannot grant a role"
        );
    };
    let assign_role = dispatch::handle(Host::new(store, wasm_path, config, invoker), &provider.grant, json!({
            "actor_id": {"value": identity_id}, "role_name": {"value": role}, "scope": {"value": config.domain.clone()},
            "starts_at": {"value": crate::clock::iso8601_now()},
        }), None).await?;
    if !assign_role.accepted {
        anyhow::bail!("{} refused: {}", provider.grant, assign_role.result);
    }

    // Not dispatch::handle: Member isn't in the flat journal, so a
    // WASM-replay dispatch here would rehydrate no prior steps and
    // refuse. Writes through the same journal+snapshot append instead.
    let mut new_state = member.clone();
    new_state["identity_id"] = json!({"value": identity_id});
    append_member_state(store, config, domain_ir, email, &new_state).await?;

    let name = member
        .get("name")
        .and_then(|v| v.get("value"))
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    Ok(Some(Session {
        identity_id,
        email: email.to_string(),
        name,
        role: Some(role.to_string()),
    }))
}

pub async fn grant_access(
    store: &Store,
    wasm_path: &Path,
    config: &LineageConfig,
    domain_ir: &Value,
    email: &str,
    role: &str,
) -> anyhow::Result<bool> {
    let outcome =
        grant_access_until(store, wasm_path, config, domain_ir, email, role, None).await?;
    Ok(outcome == GrantOutcome::Done)
}

/// What `grant_access_until` decided.
#[derive(Debug, PartialEq, Eq)]
pub enum GrantOutcome {
    /// The role (and window, if any) is now on the person's row.
    Done,
    /// No person with that email exists.
    UnknownPerson,
    /// The change would leave no active admin without an end date.
    LastOpenAdmin,
}

/// Grants `role` like `grant_access`, for a window ending at `expires_at`
/// (an ISO 8601 UTC instant) when one is given. Granting again renews: the
/// new window replaces the old, and `None` clears it, so a plain grant makes
/// the access open-ended. Refused when it would take the site's last
/// open-ended admin off that footing, locked with other membership writes.
pub async fn grant_access_until(
    store: &Store,
    wasm_path: &Path,
    config: &LineageConfig,
    domain_ir: &Value,
    email: &str,
    role: &str,
    expires_at: Option<&str>,
) -> anyhow::Result<GrantOutcome> {
    let _ = wasm_path;
    let (aggregate_name, storage_name) = membership_aggregate(domain_ir)?;
    let domain = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let target = email.trim().to_lowercase();

    let mut guard = store.require_lineage()?.lock().await;
    let txn = guard.transaction().await?;
    txn.execute(
        "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
        &[&config.domain],
    )
    .await?;
    let rows = journal::read_lineage_head_all(&txn, domain, &storage_name).await?;
    let Some((id, member)) = rows.iter().find(|(id, _)| id.to_lowercase() == target) else {
        return Ok(GrantOutcome::UnknownPerson);
    };

    // Same append protocol `provision` uses. GrantAccess's own bluebook
    // command sets only `:role`; the window is a host-side field beside it,
    // like `disabled`, so it needs no bluebook attribute.
    let mut new_state = member.clone();
    new_state["role"] = json!({"value": role});
    match expires_at {
        Some(instant) => new_state[EXPIRY_FIELD] = json!(instant),
        None => {
            if let Some(fields) = new_state.as_object_mut() {
                fields.remove(EXPIRY_FIELD);
            }
        }
    }
    if strands_open_admin(&rows, id, &new_state) {
        return Ok(GrantOutcome::LastOpenAdmin);
    }
    journal::append_lineage_mutation(
        &txn,
        config,
        &journal::Mutation {
            aggregate: &aggregate_name,
            id,
            operation: "save",
            state: &new_state,
        },
    )
    .await?;
    txn.commit().await?;
    Ok(GrantOutcome::Done)
}

/// Admits a new person (name + email), the same state `Admit` sets.
/// Returns `false` without writing when that email already exists.
pub async fn admit_person(
    store: &Store,
    config: &LineageConfig,
    domain_ir: &Value,
    email: &str,
    name: &str,
) -> anyhow::Result<bool> {
    let email = email.to_lowercase();
    let exists = member_rows(store, domain_ir)
        .await?
        .into_iter()
        .any(|(id, _)| id.to_lowercase() == email);
    if exists {
        return Ok(false);
    }
    let state = json!({"name": {"value": name}, "email": {"value": email}});
    append_member_state(store, config, domain_ir, &email, &state).await?;
    Ok(true)
}

// The disabled flag sits beside the role rather than replacing it, so
// enabling a person again restores exactly the role they held.
fn is_disabled(state: &Value) -> bool {
    state
        .get("disabled")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
}

// The row field holding the end of a time-boxed access window, an ISO 8601
// UTC instant. It sits beside `disabled` in the row state, so a grant that
// carries no window leaves the person with open-ended access as before.
const EXPIRY_FIELD: &str = "access_expires_at";

// The window's end as written on the row: a bare string, or a `{"value": ..}`
// wrapper as other timestamp attributes carry.
enum Window {
    // No window is set (absent or null).
    Open,
    // A window ending at this many epoch seconds.
    Ends(i64),
    // A window is set but is not a readable instant; it counts as ended.
    Unreadable,
}

fn window_of(state: &Value) -> Window {
    let Some(raw) = state.get(EXPIRY_FIELD).filter(|v| !v.is_null()) else {
        return Window::Open;
    };
    let text = raw.get("value").unwrap_or(raw).as_str();
    text.and_then(crate::clock::parse_iso_utc)
        .map_or(Window::Unreadable, Window::Ends)
}

// The window's end for display: the stored text, exactly as written.
fn expiry_text(state: &Value) -> Option<String> {
    let raw = state.get(EXPIRY_FIELD).filter(|v| !v.is_null())?;
    let text = raw.get("value").unwrap_or(raw);
    Some(
        text.as_str()
            .map_or_else(|| text.to_string(), str::to_string),
    )
}

// Whether the row's access window has ended at `now` (epoch seconds). An
// unreadable value counts as ended: access fails closed.
fn is_expired_at(state: &Value, now: i64) -> bool {
    match window_of(state) {
        Window::Open => false,
        Window::Unreadable => true,
        Window::Ends(ends) => ends <= now,
    }
}

// Whether the row grants no access right now: disabled, or its window ended.
// Every check that lets a person in or counts an admin asks this, never
// `is_disabled` alone; disabling and enabling keep the raw flag.
fn is_lapsed(state: &Value) -> bool {
    is_lapsed_at(state, ProcessClock.now_secs())
}

fn is_lapsed_at(state: &Value, now: i64) -> bool {
    is_disabled(state) || is_expired_at(state, now)
}

/// The ISO 8601 UTC instant `days` days after `now` (epoch seconds), the
/// value `grant_access_until` stores as the end of a window.
pub fn expiry_after_days_from(days: u32, now: i64) -> String {
    crate::clock::iso_utc((now + i64::from(days) * 86_400).max(0) as u64)
}

/// `expiry_after_days_from` counted from the process clock, which a spec
/// can fix (`needs::set_fixed_clock`).
pub fn expiry_after_days(days: u32) -> String {
    expiry_after_days_from(days, ProcessClock.now_secs())
}

/// The longest window a grant may carry, in days.
pub const MAX_EXPIRY_DAYS: u32 = 365;

// A deleted person's row is never erased (this is an append-only journal,
// same as every other aggregate here) — "deleted" only means all_people
// stops listing it. There is deliberately no undelete route: re-admitting
// the same email starts a fresh row rather than reviving this one.
fn is_deleted(state: &Value) -> bool {
    state
        .get("deleted")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
}

// The role name a membership row holds, if any.
fn role_of(state: &Value) -> Option<&str> {
    state
        .get("role")
        .and_then(|v| v.get("value"))
        .and_then(|v| v.as_str())
}

/// The roles that pass the admin gate. "Owner" is a superset of "Admin" —
/// a person holds one role, so Owner must pass this gate too.
pub const ADMIN_ROLES: [&str; 2] = ["Admin", "Owner"];

/// The roles the grant routes will assign. Granting "Owner" is deliberately
/// open to any admin, because the first Owner has to be granted by an Admin.
pub const GRANTABLE_ROLES: [&str; 3] = ["Admin", "Owner", "Member"];

/// Whether `role` passes the admin gate.
pub fn is_admin_role(role: &str) -> bool {
    ADMIN_ROLES.contains(&role)
}

// Whether the row holds an admin role ("Admin" or "Owner") and is not disabled
// or past its access window.
fn is_active_admin(state: &Value) -> bool {
    role_of(state).is_some_and(is_admin_role) && !is_lapsed(state)
}

// Whether `state` is the only active admin (Admin or Owner) among `rows`.
fn is_last_active_admin(rows: &[(String, Value)], state: &Value) -> bool {
    is_active_admin(state) && rows.iter().filter(|(_, s)| is_active_admin(s)).count() <= 1
}

// Whether the row is an active admin with no end date: the kind of access a
// site keeps at least one of, because a window's lapse cannot be prevented.
fn is_open_admin(state: &Value) -> bool {
    is_active_admin(state) && matches!(window_of(state), Window::Open)
}

// Whether replacing the row `id` with `after` would leave the site with no
// open-ended admin where it had one, or would make the site's first admin one
// with an end date. A site that has admins but none open-ended (it was never
// given one) is not made worse by a change, so this stays false there.
fn strands_open_admin(rows: &[(String, Value)], id: &str, after: &Value) -> bool {
    let had = rows.iter().any(|(_, s)| is_open_admin(s));
    let keeps = is_open_admin(after)
        || rows
            .iter()
            .any(|(other, s)| other.to_lowercase() != id.to_lowercase() && is_open_admin(s));
    let first_admin = !rows
        .iter()
        .any(|(_, s)| role_of(s).is_some_and(is_admin_role));
    let windowed_first = first_admin && role_of(after).is_some_and(is_admin_role) && !keeps;
    (had && !keeps) || windowed_first
}

/// Whether the person with `email` (compared case-insensitively) is an
/// active admin: granted the "Admin" or "Owner" role, not disabled, and not
/// past its access window.
pub async fn caller_is_admin(
    store: &Store,
    domain_ir: &Value,
    email: &str,
) -> anyhow::Result<bool> {
    let email = email.to_lowercase();
    Ok(member_rows(store, domain_ir)
        .await?
        .iter()
        .any(|(id, state)| id.to_lowercase() == email && is_active_admin(state)))
}

/// Whether `email` may hold a session right now: admitted, granted a role,
/// and neither disabled nor past its access window — a signature alone can't
/// tell, since a cookie outlives a later disable or the end of the window.
pub async fn has_access(store: &Store, domain_ir: &Value, email: &str) -> anyhow::Result<bool> {
    let email = email.to_lowercase();
    Ok(member_rows(store, domain_ir)
        .await?
        .iter()
        .any(|(id, state)| {
            id.to_lowercase() == email && role_of(state).is_some() && !is_lapsed(state)
        }))
}

/// The role `email` holds right now, or `None` if unknown, roleless, or
/// disabled or past its window — reads the live membership head, never the
/// session cookie.
pub async fn active_role(
    store: &Store,
    domain_ir: &Value,
    email: &str,
) -> anyhow::Result<Option<String>> {
    let email = email.to_lowercase();
    Ok(member_rows(store, domain_ir)
        .await?
        .iter()
        .find(|(id, state)| id.to_lowercase() == email && !is_lapsed(state))
        .and_then(|(_, state)| role_of(state).map(String::from)))
}

/// The Governance identity id linked to the member with `email`, read from
/// the live membership head. `None` when the member has not signed in yet.
pub async fn member_identity_id(
    store: &Store,
    domain_ir: &Value,
    email: &str,
) -> anyhow::Result<Option<String>> {
    let email = email.to_lowercase();
    Ok(member_rows(store, domain_ir)
        .await?
        .iter()
        .find(|(id, state)| id.to_lowercase() == email && !is_deleted(state))
        .and_then(|(_, state)| linked_identity_id(state)))
}

// The id the sign-in flow wrote onto a Member row, or `None` before then.
fn linked_identity_id(state: &Value) -> Option<String> {
    state
        .get("identity_id")
        .and_then(|v| v.get("value"))
        .and_then(|v| v.as_str())
        .map(str::to_string)
}

/// Every admitted person as a JSON row: name, email, role, `linked`
/// (signed in), `granted` (has access right now), `disabled` (the raw flag),
/// `access_expires_at` (the end of a time-boxed window, `null` when open-ended),
/// `expired` (the window has ended or is unreadable), and `identity_id`
/// (the Governance identity id, `null` until the person has signed in).
pub async fn all_people(store: &Store, domain_ir: &Value) -> anyhow::Result<Vec<Value>> {
    let now = ProcessClock.now_secs();
    Ok(member_rows(store, domain_ir)
        .await?
        .into_iter()
        .filter(|(_, state)| !is_deleted(state))
        .map(|(_, state)| {
            let role = role_of(&state);
            let linked = state
                .get("identity_id")
                .and_then(|v| v.get("value"))
                .is_some();
            let disabled = is_disabled(&state);
            let expired = is_expired_at(&state, now);
            json!({
                "name": state.get("name").and_then(|v| v.get("value")),
                "email": state.get("email").and_then(|v| v.get("value")),
                "role": role,
                "linked": linked,
                "granted": role.is_some() && !disabled && !expired,
                "disabled": disabled,
                "access_expires_at": expiry_text(&state),
                "expired": expired,
                "identity_id": linked_identity_id(&state),
            })
        })
        .collect())
}

/// What `set_person_disabled` decided.
#[derive(Debug, PartialEq, Eq)]
pub enum DisableOutcome {
    /// The person is now in the requested state, whether or not a write was needed.
    Done,
    /// The caller is not an active Admin.
    CallerNotAdmin,
    /// An admin tried to disable themselves.
    SelfDisable,
    /// No person with that email exists.
    UnknownPerson,
    /// Disabling would leave no active Admin.
    LastAdmin,
    /// Disabling would leave no active Admin without an end date.
    LastOpenAdmin,
}

/// Disables or enables `target` for `caller`, keeping role and identity
/// link — locked with other membership writes so concurrent disables can't both win.
pub async fn set_person_disabled(
    store: &Store,
    config: &LineageConfig,
    domain_ir: &Value,
    caller: &str,
    target: &str,
    disable: bool,
) -> anyhow::Result<DisableOutcome> {
    let (aggregate_name, storage_name) = membership_aggregate(domain_ir)?;
    let domain = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let (caller, target) = (caller.trim().to_lowercase(), target.trim().to_lowercase());

    let mut guard = store.require_lineage()?.lock().await;
    let txn = guard.transaction().await?;
    txn.execute(
        "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
        &[&config.domain],
    )
    .await?;
    let rows = journal::read_lineage_head_all(&txn, domain, &storage_name).await?;

    if !rows
        .iter()
        .any(|(id, state)| id.to_lowercase() == caller && is_active_admin(state))
    {
        return Ok(DisableOutcome::CallerNotAdmin);
    }
    if disable && caller == target {
        return Ok(DisableOutcome::SelfDisable);
    }
    let Some((id, state)) = rows.iter().find(|(id, _)| id.to_lowercase() == target) else {
        return Ok(DisableOutcome::UnknownPerson);
    };
    if is_disabled(state) == disable {
        return Ok(DisableOutcome::Done);
    }
    if disable && is_last_active_admin(&rows, state) {
        return Ok(DisableOutcome::LastAdmin);
    }

    let mut new_state = state.clone();
    if disable {
        new_state["disabled"] = json!(true);
    } else if let Some(fields) = new_state.as_object_mut() {
        fields.remove("disabled");
    }
    if strands_open_admin(&rows, id, &new_state) {
        return Ok(DisableOutcome::LastOpenAdmin);
    }
    journal::append_lineage_mutation(
        &txn,
        config,
        &journal::Mutation {
            aggregate: &aggregate_name,
            id,
            operation: "save",
            state: &new_state,
        },
    )
    .await?;
    txn.commit().await?;
    Ok(DisableOutcome::Done)
}

/// What `set_person_deleted` decided.
#[derive(Debug, PartialEq, Eq)]
pub enum DeleteOutcome {
    /// The person is now deleted (or already was).
    Done,
    /// The caller is not an active Admin.
    CallerNotAdmin,
    /// No person with that email exists.
    UnknownPerson,
    /// `target` must be disabled first — deleting an active admin outright
    /// skips the "are you sure" step disabling them already forces.
    NotDisabled,
}

/// Soft-deletes an already-disabled `target` on `caller`'s behalf: the row
/// stays in the journal (nothing here is ever erased) but `all_people` stops
/// listing it. Locked with other membership writes the same as disable/role.
pub async fn set_person_deleted(
    store: &Store,
    config: &LineageConfig,
    domain_ir: &Value,
    caller: &str,
    target: &str,
) -> anyhow::Result<DeleteOutcome> {
    let (aggregate_name, storage_name) = membership_aggregate(domain_ir)?;
    let domain = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let (caller, target) = (caller.trim().to_lowercase(), target.trim().to_lowercase());

    let mut guard = store.require_lineage()?.lock().await;
    let txn = guard.transaction().await?;
    txn.execute(
        "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
        &[&config.domain],
    )
    .await?;
    let rows = journal::read_lineage_head_all(&txn, domain, &storage_name).await?;

    if !rows
        .iter()
        .any(|(id, state)| id.to_lowercase() == caller && is_active_admin(state))
    {
        return Ok(DeleteOutcome::CallerNotAdmin);
    }
    let Some((id, state)) = rows.iter().find(|(id, _)| id.to_lowercase() == target) else {
        return Ok(DeleteOutcome::UnknownPerson);
    };
    if is_deleted(state) {
        return Ok(DeleteOutcome::Done);
    }
    if !is_disabled(state) {
        return Ok(DeleteOutcome::NotDisabled);
    }

    let mut new_state = state.clone();
    new_state["deleted"] = json!(true);
    journal::append_lineage_mutation(
        &txn,
        config,
        &journal::Mutation {
            aggregate: &aggregate_name,
            id,
            operation: "save",
            state: &new_state,
        },
    )
    .await?;
    txn.commit().await?;
    Ok(DeleteOutcome::Done)
}

/// What `set_person_role` decided.
#[derive(Debug, PartialEq, Eq)]
pub enum RoleOutcome {
    /// The person now holds the requested role, whether or not a write was needed.
    Done,
    /// The caller is not an active Admin or Owner.
    CallerNotAdmin,
    /// No person with that email exists.
    UnknownPerson,
    /// The change would leave no active Admin or Owner.
    LastAdmin,
    /// The change would leave no active Admin or Owner without an end date.
    LastOpenAdmin,
}

/// Sets `target`'s role on `caller`'s behalf; any active admin may
/// grant any role, Owner included, locked against concurrent demotions.
pub async fn set_person_role(
    store: &Store,
    config: &LineageConfig,
    domain_ir: &Value,
    caller: &str,
    target: &str,
    role: &str,
) -> anyhow::Result<RoleOutcome> {
    let (aggregate_name, storage_name) = membership_aggregate(domain_ir)?;
    let domain = domain_ir.get("name").and_then(|v| v.as_str()).unwrap_or("");
    let (caller, target) = (caller.trim().to_lowercase(), target.trim().to_lowercase());

    let mut guard = store.require_lineage()?.lock().await;
    let txn = guard.transaction().await?;
    txn.execute(
        "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
        &[&config.domain],
    )
    .await?;
    let rows = journal::read_lineage_head_all(&txn, domain, &storage_name).await?;

    if !rows
        .iter()
        .any(|(id, state)| id.to_lowercase() == caller && is_active_admin(state))
    {
        return Ok(RoleOutcome::CallerNotAdmin);
    }
    let Some((id, state)) = rows.iter().find(|(id, _)| id.to_lowercase() == target) else {
        return Ok(RoleOutcome::UnknownPerson);
    };
    if role_of(state) == Some(role) {
        return Ok(RoleOutcome::Done);
    }
    if !is_admin_role(role) && is_last_active_admin(&rows, state) {
        return Ok(RoleOutcome::LastAdmin);
    }

    let mut new_state = state.clone();
    new_state["role"] = json!({"value": role});
    if strands_open_admin(&rows, id, &new_state) {
        return Ok(RoleOutcome::LastOpenAdmin);
    }
    journal::append_lineage_mutation(
        &txn,
        config,
        &journal::Mutation {
            aggregate: &aggregate_name,
            id,
            operation: "save",
            state: &new_state,
        },
    )
    .await?;
    txn.commit().await?;
    Ok(RoleOutcome::Done)
}

/// Whether `identity_id` holds a live Admin/Owner assignment in this
/// domain's authorization provider; `None` provider means never admin.
pub fn holds_admin(
    instances: &Value,
    identity_id: &str,
    provider: Option<&crate::ir::AuthorizationProvider>,
) -> bool {
    let Some(provider) = provider else {
        return false;
    };
    let prefix = format!("{}#", provider.assignment_aggregate);
    instances.as_object().is_some_and(|obj| {
        obj.iter().any(|(key, state)| {
            key.starts_with(&prefix)
                && state
                    .get("actor_id")
                    .and_then(|v| v.get("value"))
                    .and_then(|v| v.as_str())
                    == Some(identity_id)
                && state
                    .get("role_name")
                    .and_then(|v| v.get("value"))
                    .and_then(|v| v.as_str())
                    .is_some_and(is_admin_role)
                && state.get("ends_at").is_none_or(serde_json::Value::is_null)
        })
    })
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[allow(clippy::expect_used)] // reason: HMAC accepts a key of any length, so construction cannot fail
fn sign(secret: &str, payload: &str) -> String {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    let mut mac =
        Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key length");
    mac.update(payload.as_bytes());
    hex_encode(&mac.finalize().into_bytes())
}

fn verify_sig(secret: &str, token: &str) -> Option<String> {
    let (payload, sig) = token.rsplit_once('.')?;
    if constant_time_eq(sign(secret, payload).as_bytes(), sig.as_bytes()) {
        Some(payload.to_string())
    } else {
        None
    }
}

pub(crate) fn urlencode(s: &str) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => {
                let _ = write!(out, "%{b:02X}"); // writing to a String cannot fail
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signed_token_verifies_with_the_right_secret_and_rejects_tampering() {
        let token = sign_test_token("s3cret", "hello");
        assert_eq!(verify_sig("s3cret", &token), Some("hello".to_string()));
        assert_eq!(verify_sig("wrong-secret", &token), None);

        let tampered = token.replace("hello", "hellp");
        assert_eq!(verify_sig("s3cret", &tampered), None);
    }

    fn sign_test_token(secret: &str, payload: &str) -> String {
        format!("{payload}.{}", sign(secret, payload))
    }

    #[test]
    fn account_token_round_trips_and_rejects_tampering_or_the_wrong_secret() {
        let token = account_token("s3cret", "chris@example.com", 60);
        assert_eq!(
            verify_account_token("s3cret", &token).as_deref(),
            Some("chris@example.com")
        );
        assert_eq!(verify_account_token("wrong-secret", &token), None);
        assert_eq!(
            verify_account_token("s3cret", "garbage.notasignature"),
            None
        );
    }

    #[test]
    fn account_token_rejects_once_expired() {
        // ttl_secs=0 -- now_secs() + 0 is already <= now_secs() by the
        // time verify_account_token's own now_secs() check runs.
        let token = account_token("s3cret", "chris@example.com", 0);
        std::thread::sleep(std::time::Duration::from_secs(1));
        assert_eq!(verify_account_token("s3cret", &token), None);
    }

    // The known-answer vector packages/hecks-client's account token tests
    // check too (test/accountToken.test.mjs): a fixed payload, so both sides
    // agree on the exact bytes a token carries, not only that each round-trips.
    #[test]
    fn account_token_matches_the_known_answer_vector() {
        let payload = r#"{"email":"chris@example.com","exp":4102444800}"#;
        let encoded = b64::url_encode(payload.as_bytes());
        assert_eq!(
            encoded,
            "eyJlbWFpbCI6ImNocmlzQGV4YW1wbGUuY29tIiwiZXhwIjo0MTAyNDQ0ODAwfQ"
        );
        assert_eq!(
            sign("s3cret", &encoded),
            "143ebe224b067f9744b509937358bb39a87ed30df06aaec594934b85a288cade"
        );
        let token = sign_test_token("s3cret", &encoded);
        assert_eq!(
            verify_account_token("s3cret", &token).as_deref(),
            Some("chris@example.com")
        );
        // account_token writes the same payload shape: keys in sorted order, no spaces.
        let minted = account_token("s3cret", "chris@example.com", 60);
        let (minted_payload, _) = minted.rsplit_once('.').unwrap();
        let claims: Value =
            serde_json::from_slice(&b64::url_decode(minted_payload).unwrap()).unwrap();
        assert_eq!(
            String::from_utf8(b64::url_decode(minted_payload).unwrap()).unwrap(),
            format!(r#"{{"email":"chris@example.com","exp":{}}}"#, claims["exp"])
        );
    }

    #[test]
    fn the_account_cookie_defaults_when_unset_or_empty() {
        assert_eq!(
            resolve_account_cookie(None).unwrap(),
            DEFAULT_ACCOUNT_COOKIE
        );
        assert_eq!(
            resolve_account_cookie(Some("")).unwrap(),
            DEFAULT_ACCOUNT_COOKIE
        );
    }

    #[test]
    fn the_default_account_cookie_is_the_neutral_hecks_name() {
        assert_eq!(DEFAULT_ACCOUNT_COOKIE, "hecks_session");
    }

    #[test]
    fn the_account_cookie_takes_a_configured_valid_name() {
        assert_eq!(
            resolve_account_cookie(Some("hecks_session")).unwrap(),
            "hecks_session"
        );
        assert_eq!(
            resolve_account_cookie(Some("app-session.v2")).unwrap(),
            "app-session.v2"
        );
    }

    #[test]
    fn the_account_cookie_refuses_a_name_that_could_break_the_set_cookie_header() {
        for bad in ["a;b", "a=b", "a b", "a\r\nSet-Cookie: x", "sessão"] {
            assert!(
                resolve_account_cookie(Some(bad)).is_err(),
                "{bad:?} should be refused"
            );
        }
    }

    #[test]
    fn session_cookie_round_trips_and_rejects_a_forged_one() {
        let session = Session {
            identity_id: "id-1".to_string(),
            email: "chris@example.com".to_string(),
            name: "Chris Young".to_string(),
            role: Some("Admin".to_string()),
        };
        let cookie = session_cookie("s3cret", &session);
        let parsed =
            parse_session_cookie("s3cret", &cookie).expect("should parse with the right secret");
        assert_eq!(parsed.identity_id, "id-1");
        assert_eq!(parsed.email, "chris@example.com");
        assert_eq!(parsed.role.as_deref(), Some("Admin"));

        assert!(parse_session_cookie("wrong-secret", &cookie).is_none());
        assert!(parse_session_cookie("s3cret", "garbage.notasignature").is_none());
    }

    fn signed_session_cookie(secret: &str, exp: Option<u64>) -> String {
        let mut payload = json!({"identity_id": "id-1", "email": "chris@example.com", "name": "Chris Young", "role": "Admin"});
        if let Some(exp) = exp {
            payload["exp"] = json!(exp);
        }
        let encoded = b64::url_encode(payload.to_string().as_bytes());
        format!("{encoded}.{}", sign(secret, &encoded))
    }

    #[test]
    fn session_cookie_is_refused_once_expired() {
        let expired = signed_session_cookie("s3cret", Some(now_secs() - 1));
        assert!(parse_session_cookie("s3cret", &expired).is_none());
        let live = signed_session_cookie("s3cret", Some(now_secs() + 60));
        assert!(parse_session_cookie("s3cret", &live).is_some());
    }

    #[test]
    fn session_cookie_without_an_expiry_is_refused() {
        let no_exp = signed_session_cookie("s3cret", None);
        assert!(parse_session_cookie("s3cret", &no_exp).is_none());
    }

    #[test]
    fn an_id_token_is_accepted_only_with_the_sign_ins_own_nonce() {
        assert!(check_nonce(&json!({"nonce": "n-123"}), "n-123").is_ok());
        assert!(check_nonce(&json!({"nonce": "n-456"}), "n-123").is_err());
        assert!(check_nonce(&json!({}), "n-123").is_err());
        assert!(check_nonce(&json!({"nonce": 5}), "n-123").is_err());
    }

    #[test]
    fn a_handoff_token_is_redeemed_once_for_the_account_token() {
        let spent = crate::platform_signin::jti::JtiStore::new();
        let handoff = handoff_token("s3cret", "zed@example.com");
        assert_eq!(verify_account_token("s3cret", &handoff), None);
        let account = redeem_handoff_token("s3cret", &handoff, &spent).unwrap();
        assert_eq!(
            verify_account_token("s3cret", &account).as_deref(),
            Some("zed@example.com")
        );
        assert_eq!(redeem_handoff_token("s3cret", &handoff, &spent), None);
    }

    #[test]
    fn an_account_or_foreign_token_is_not_a_handoff_token() {
        let spent = crate::platform_signin::jti::JtiStore::new();
        let account = account_token("s3cret", "zed@example.com", 60);
        assert_eq!(redeem_handoff_token("s3cret", &account, &spent), None);
        let handoff = handoff_token("other-secret", "zed@example.com");
        assert_eq!(redeem_handoff_token("s3cret", &handoff, &spent), None);
    }

    #[test]
    fn the_consent_url_carries_the_sign_ins_state_and_nonce() {
        crate::secrets::provide("GOOGLE_CLIENT_ID", "client-1".to_string());
        let signin = GoogleSignin::fresh();
        let url = authorization_url("https://host.example/auth/google/callback", &signin).unwrap();
        assert!(url.contains(&format!("&state={}", signin.state)), "{url}");
        assert!(url.contains(&format!("&nonce={}", signin.nonce)), "{url}");
    }

    #[test]
    fn resolve_identity_finds_the_linked_external_identifier() {
        let instances = json!({
            "Identity::ExternalIdentifier#google:sub-1": {"identity_id": "id-1", "issuer": {"value": "google"}, "subject": {"value": "sub-1"}},
        });

        let identity_id = resolve_identity(&instances, "google", "sub-1");
        assert_eq!(identity_id.as_deref(), Some("id-1"));
        assert!(resolve_identity(&instances, "google", "nope").is_none());
    }

    #[test]
    fn resolve_identity_finds_a_link_that_only_the_flat_journal_holds() {
        // The shape `ExternalIdentifier.Link` leaves in the flat snapshot of a domain whose Identity
        // bluebook has no head of its own; the key carries the issuer URL and the subject.
        let instances = json!({
            "Identity::ExternalIdentifier#https://accounts.google.com:111": {
                "identity": "471ef402-8609-4fa4-9288-6372fc74650d",
                "key": {"value": "https://accounts.google.com:111"},
                "issuer": {"value": "https://accounts.google.com"},
                "subject": {"value": "111"},
            },
        });
        let read = json!({ "instances": instances });
        assert_eq!(
            resolve_identity(
                read.get("instances").unwrap_or(&Value::Null),
                "https://accounts.google.com",
                "111"
            )
            .as_deref(),
            Some("471ef402-8609-4fa4-9288-6372fc74650d")
        );
        assert!(resolve_identity(
            read.get("instances").unwrap_or(&Value::Null),
            "https://accounts.google.com",
            "112"
        )
        .is_none());
        assert!(resolve_identity(&Value::Null, "https://accounts.google.com", "111").is_none());
    }

    #[test]
    fn resolve_identity_reads_the_2_0_identity_field() {
        let instances = json!({
            "Identity::ExternalIdentifier#https://accounts.google.com:sub-1": {
                "identity": "id-2",
                "issuer": {"value": "https://accounts.google.com"},
                "subject": {"value": "sub-1"},
            },
        });
        assert_eq!(
            resolve_identity(&instances, "https://accounts.google.com", "sub-1").as_deref(),
            Some("id-2")
        );
    }

    #[test]
    fn holds_admin_reads_straight_off_instances() {
        let instances = json!({
            "Governance::RoleAssignment#id-1:Admin": {
                "actor_id": {"value": "id-1"}, "role_name": {"value": "Admin"}, "ends_at": null,
            },
        });

        let provider = crate::ir::AuthorizationProvider {
            grant: "Governance::RoleAssignment.Assign".to_string(),
            assignment_aggregate: "Governance::RoleAssignment".to_string(),
        };
        assert!(holds_admin(&instances, "id-1", Some(&provider)));
        assert!(!holds_admin(&instances, "id-2", Some(&provider)));
        // No declared provider: no assignment can exist, so never admin.
        assert!(!holds_admin(&instances, "id-1", None));
    }

    #[test]
    fn a_window_lapses_exactly_at_its_end_and_a_missing_one_never_does() {
        let ends = crate::clock::parse_iso_utc("2026-10-22T12:00:00Z").unwrap();
        let row = json!({"role": {"value": "Member"}, "access_expires_at": "2026-10-22T12:00:00Z"});
        assert!(!is_lapsed_at(&row, ends - 1), "one second before the end");
        assert!(is_lapsed_at(&row, ends), "the end instant itself is over");
        assert!(is_lapsed_at(&row, ends + 1));
        let open = json!({"role": {"value": "Member"}});
        assert!(!is_lapsed_at(&open, i64::MAX));
        let unreadable = json!({"access_expires_at": "next week"});
        assert!(is_lapsed_at(&unreadable, 0), "unreadable fails closed");
        let disabled = json!({"disabled": true, "access_expires_at": "2099-01-01T00:00:00Z"});
        assert!(
            is_lapsed_at(&disabled, 0),
            "an open window does not undo a disable"
        );
    }

    #[test]
    fn expiry_after_days_counts_whole_days_from_the_given_instant() {
        let start = crate::clock::parse_iso_utc("2026-10-22T08:30:15Z").unwrap();
        assert_eq!(expiry_after_days_from(1, start), "2026-10-23T08:30:15Z");
        assert_eq!(
            expiry_after_days_from(MAX_EXPIRY_DAYS, start),
            "2027-10-22T08:30:15Z"
        );
    }

    #[test]
    fn is_last_active_admin_ignores_an_admin_whose_window_ended() {
        let admin = json!({"role": {"value": "Admin"}});
        let expired =
            json!({"role": {"value": "Admin"}, "access_expires_at": "2020-01-01T00:00:00Z"});
        let rows = |states: &[&Value]| -> Vec<(String, Value)> {
            states
                .iter()
                .map(|s| (String::new(), (*s).clone()))
                .collect()
        };
        assert!(is_last_active_admin(&rows(&[&admin, &expired]), &admin));
        assert!(!is_last_active_admin(&rows(&[&admin, &expired]), &expired));
    }

    #[test]
    fn is_last_active_admin_counts_only_admins_that_are_not_disabled() {
        let admin = json!({"role": {"value": "Admin"}});
        let disabled_admin = json!({"role": {"value": "Admin"}, "disabled": true});
        let member = json!({"role": {"value": "Member"}});
        let rows = |states: &[&Value]| -> Vec<(String, Value)> {
            states
                .iter()
                .enumerate()
                .map(|(i, s)| (i.to_string(), (*s).clone()))
                .collect()
        };

        assert!(
            is_last_active_admin(&rows(&[&admin, &member, &disabled_admin]), &admin),
            "the only active admin"
        );
        assert!(
            !is_last_active_admin(&rows(&[&admin, &admin]), &admin),
            "another active admin remains"
        );
        assert!(
            !is_last_active_admin(&rows(&[&admin, &disabled_admin]), &disabled_admin),
            "a disabled admin is not an active one"
        );
        assert!(
            !is_last_active_admin(&rows(&[&admin, &member]), &member),
            "a non-admin never counts"
        );

        // An Owner is an admin too: it counts toward, and is protected by, the guard.
        let owner = json!({"role": {"value": "Owner"}});
        assert!(
            is_last_active_admin(&rows(&[&owner, &member]), &owner),
            "the only active admin may be an Owner"
        );
        assert!(
            !is_last_active_admin(&rows(&[&owner, &admin]), &admin),
            "an Owner keeps another admin from being the last"
        );
    }

    #[test]
    fn holds_admin_accepts_an_owner_assignment_and_refuses_other_roles() {
        let provider = crate::ir::AuthorizationProvider {
            grant: "G".to_string(),
            assignment_aggregate: "Governance::RoleAssignment".to_string(),
        };
        let assignment = |role: &str| json!({"Governance::RoleAssignment#a": {"actor_id": {"value": "id-1"}, "role_name": {"value": role}, "ends_at": null}});
        assert!(holds_admin(&assignment("Admin"), "id-1", Some(&provider)));
        assert!(holds_admin(&assignment("Owner"), "id-1", Some(&provider)));
        assert!(!holds_admin(&assignment("Member"), "id-1", Some(&provider)));
        assert!(!holds_admin(&assignment("owner"), "id-1", Some(&provider)));
    }

    #[test]
    fn membership_names_snakes_the_bare_aggregate() {
        assert_eq!(
            membership_names("Member"),
            ("Member".to_string(), "member".to_string())
        );
        assert_eq!(
            membership_names("Membership::Person"),
            ("Person".to_string(), "person".to_string())
        );
    }

    #[test]
    fn membership_aggregate_reads_the_declared_capability_not_an_env_var() {
        let domain_ir = json!({
            "name": "Studio",
            "membership": {"provider": "Membership", "aggregate": "Membership::Person"},
        });
        let (aggregate, storage_name) = membership_aggregate(&domain_ir).unwrap();
        assert_eq!(aggregate, "Person");
        assert_eq!(storage_name, "person");

        assert!(membership_aggregate(&json!({"name": "Pizzas"})).is_err());
    }

    // A throwaway Postgres database per test, matching the real
    // `head_view` naming (`qualified_name(domain, "#{storage_name}_head")`,
    // docs/decisions/0059) that the functions under test query directly.
    async fn scratch_member_db(name: &str) -> Store {
        use tokio_postgres::NoTls;
        let (admin, conn) = tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), NoTls)
            .await
            .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        admin
            .batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)"))
            .await
            .unwrap();
        admin
            .batch_execute(&format!("CREATE DATABASE {name}"))
            .await
            .unwrap();

        let (client, conn) = tokio_postgres::connect(&crate::test_pg::conninfo(name), NoTls)
            .await
            .expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        // `acme_member_head` mirrors the real shape: a view over the
        // era-1 snapshot table (`head_compiler.rb`'s `ensure_first_head!`),
        // written through the era-partitioned journal first.
        client
            .batch_execute(
                "CREATE TABLE acme_member_head_snapshot_1 (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL);
                 CREATE VIEW acme_member_head AS SELECT id, state FROM acme_member_head_snapshot_1;
                 CREATE TABLE hecks_journal_acme (
                     ordinal bigserial PRIMARY KEY, era int NOT NULL, aggregate text NOT NULL,
                     aggregate_id text NOT NULL, operation text NOT NULL, state jsonb, mirrors jsonb
                 );",
            )
            .await
            .unwrap();
        Store::postgres(client)
    }

    // A minimal `ir.json`-shaped fixture: one lineage-capable aggregate
    // plus the `membership` key `membership_aggregate` reads.
    fn member_domain_ir() -> Value {
        json!({
            "name": "Acme",
            "lineage": {"capable_aggregates": [{"name": "Member", "storage_name": "member"}]},
            "membership": {"provider": "Acme", "aggregate": "Acme::Member"},
        })
    }

    #[tokio::test]
    async fn member_lookups_query_the_real_member_head_shape() {
        let domain_ir = member_domain_ir();
        let db = scratch_member_db("hecks_host_auth_test_member_lookups").await;
        {
            let guard = db.lock().await;
            guard.execute(
                "INSERT INTO acme_member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 1, $2::jsonb), ($3, 1, $4::jsonb)",
                &[
                    &"chris@example.com",
                    &json!({"name": {"value": "Chris Young"}, "email": {"value": "chris@example.com"},
                            "role": {"value": "Admin"}, "identity_id": {"value": "id-1"}}),
                    &"angie@example.com",
                    &json!({"name": {"value": "Angie Chen"}, "email": {"value": "angie@example.com"},
                            "role": null, "identity_id": null}),
                ],
            ).await.unwrap();
        }

        let chris = member_row_by_email(&db, &domain_ir, "chris@example.com")
            .await
            .unwrap()
            .expect("should find chris");
        assert_eq!(chris["email"]["value"], "chris@example.com");
        assert!(member_row_by_email(&db, &domain_ir, "nobody@example.com")
            .await
            .unwrap()
            .is_none());

        let session = session_for_member_by_identity(&db, &domain_ir, "id-1")
            .await
            .unwrap()
            .expect("should find the linked member");
        assert_eq!(session.email, "chris@example.com");
        assert_eq!(session.role.as_deref(), Some("Admin"));
        assert!(session_for_member_by_identity(&db, &domain_ir, "id-nope")
            .await
            .unwrap()
            .is_none());

        let people = all_people(&db, &domain_ir).await.unwrap();
        assert_eq!(people.len(), 2);
        let chris = people
            .iter()
            .find(|p| p["email"] == "chris@example.com")
            .unwrap();
        assert_eq!(chris["linked"], true);
        assert_eq!(chris["granted"], true);
        assert_eq!(chris["identity_id"], "id-1");
        let angie = people
            .iter()
            .find(|p| p["email"] == "angie@example.com")
            .unwrap();
        assert_eq!(angie["linked"], false);
        assert_eq!(angie["granted"], false);
        assert!(angie["identity_id"].is_null());

        assert_eq!(
            member_identity_id(&db, &domain_ir, "Chris@Example.com")
                .await
                .unwrap()
                .as_deref(),
            Some("id-1")
        );
        assert_eq!(
            member_identity_id(&db, &domain_ir, "angie@example.com")
                .await
                .unwrap(),
            None
        );
        assert_eq!(
            member_identity_id(&db, &domain_ir, "nobody@example.com")
                .await
                .unwrap(),
            None
        );
    }

    #[tokio::test]
    async fn append_member_state_writes_the_journal_and_advances_the_head_snapshot() {
        let domain_ir = member_domain_ir();
        let db = scratch_member_db("hecks_host_auth_test_append_member").await;
        let config = LineageConfig {
            domain: "Acme".to_string(),
            era: Some(1),
            mirrored: None,
            seal_every: None,
        };
        {
            let guard = db.lock().await;
            // ordinal 0 -- below the journal's bigserial sequence (starts
            // at 1). Seeding at 1 instead once collided with the journal's
            // first real insert and masked this guard; pins that regression.
            guard.execute(
                "INSERT INTO acme_member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 0, $2::jsonb)",
                &[
                    &"angie@example.com",
                    &json!({"name": {"value": "Angie Chen"}, "email": {"value": "angie@example.com"},
                            "role": null, "identity_id": null}),
                ],
            ).await.unwrap();
        }

        let granted = json!({"name": {"value": "Angie Chen"}, "email": {"value": "angie@example.com"},
                              "role": {"value": "Admin"}, "identity_id": null});
        append_member_state(&db, &config, &domain_ir, "angie@example.com", &granted)
            .await
            .unwrap();

        // The head view reflects the new state immediately.
        let after = member_row_by_email(&db, &domain_ir, "angie@example.com")
            .await
            .unwrap()
            .expect("still there");
        assert_eq!(after["role"]["value"], "Admin");

        // A real journal row was appended -- not a raw update bypassing it.
        let guard = db.lock().await;
        let journal_rows = guard
            .query(
                "SELECT era, aggregate, aggregate_id, operation, state FROM hecks_journal_acme",
                &[],
            )
            .await
            .unwrap();
        assert_eq!(journal_rows.len(), 1);
        let row = &journal_rows[0];
        let era: i32 = row.get(0);
        let aggregate: String = row.get(1);
        let aggregate_id: String = row.get(2);
        let operation: String = row.get(3);
        let state: Value = row.get(4);
        assert_eq!(era, 1);
        assert_eq!(aggregate, "member");
        assert_eq!(aggregate_id, "angie@example.com");
        assert_eq!(operation, "save");
        assert_eq!(state["role"]["value"], "Admin");

        // The snapshot's own ordinal advanced past the seed row's.
        let ordinal: i64 = guard
            .query_one(
                "SELECT ordinal FROM acme_member_head_snapshot_1 WHERE id = $1",
                &[&"angie@example.com"],
            )
            .await
            .unwrap()
            .get(0);
        assert!(
            ordinal > 0,
            "should have advanced past the seed row's ordinal 0"
        );
        drop(guard);

        // The ordinal-guarded upsert (`WHERE ordinal < EXCLUDED.ordinal`)
        // can't be exercised through normal writes, so this pins it
        // directly: a manual downgrade attempt is a no-op.
        let guard = db.lock().await;
        guard.execute(
            "INSERT INTO acme_member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 1, $2::jsonb) \
             ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, state = EXCLUDED.state \
             WHERE acme_member_head_snapshot_1.ordinal < EXCLUDED.ordinal",
            &[&"angie@example.com", &json!({"role": {"value": "SHOULD_NOT_APPLY"}})],
        ).await.unwrap();
        let state: Value = guard
            .query_one(
                "SELECT state FROM acme_member_head_snapshot_1 WHERE id = $1",
                &[&"angie@example.com"],
            )
            .await
            .unwrap()
            .get(0);
        assert_eq!(
            state["role"]["value"], "Admin",
            "a lower ordinal must never move the snapshot backward"
        );
    }
}

#[cfg(test)]
#[path = "boundary_fuzz/auth.rs"]
mod boundary_fuzz;
