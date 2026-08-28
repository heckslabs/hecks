// GOOGLE SIGN-IN + SESSIONS, IN-PROCESS — the Rust-native counterpart
// to `Ports::Authentication`/`Ports::IdentityResolution`/Embryonaut's
// own `EmbryonautAccessControl` adapter (Ruby, hecks +
// embryonaut repos). Ported behavior-for-behavior against those, not
// reinvented: same OAuth scope, same state-CSRF check, same ID-token
// signature verification against Google's real JWKS, same
// Identity::ExternalIdentifier `"#{issuer}:{subject}"` key shape, same
// "GrantAccess happens separately from Admit" provisioning rule.
//
// ONE REAL DIFFERENCE FROM THE RUBY VERSION: no server-side session
// store. `session_cookie`/`parse_session_cookie` are a plain
// HMAC-SHA256-signed, base64url-encoded JSON payload — stateless by
// construction, verified by recomputing the signature, never trusted
// bytes off the wire alone. `SESSION_SECRET` (the same secret
// template.yaml already mints via SecretsManager for the Ruby app)
// signs both this and the OAuth `state` token below.
//
// GENERIC OVER WHICH AGGREGATE IS "MEMBERSHIP," NOT JUST EMBRYONAUT'S —
// `member_row_by_email`/`member_rows`/`append_member_state`/
// `session_for_member_by_identity` used to hardcode "member"/"Member"
// directly; now they resolve through `membership_aggregate`, which reads
// `HECKS_MEMBERSHIP_AGGREGATE` against `ir::lineage_capable_aggregates`
// (that function's own header has the "why an env var, not a bluebook-
// level IR marker" reasoning). Still Embryonaut-shaped in spirit — the
// OAuth flow, the "GrantAccess happens separately from Admit" rule, the
// whole `Session`/provisioning protocol below — just no longer hardcoded
// to Embryonaut's own aggregate NAME. `rust/host` still links no kernel
// crate and has no Cargo feature of its own — `HECKS_DOMAIN`, read once
// at main.rs boot, remains the only runtime domain selector this binary
// has; `HECKS_MEMBERSHIP_AGGREGATE` is a second, independent env var
// naming which of THAT domain's own lineage-capable aggregates this
// module treats as membership.

use crate::dispatch;
use crate::journal;
use crate::journal::LineageConfig;
use crate::lambda_client::LambdaInvoker;
use serde_json::{json, Value};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;
use tokio_postgres::Client;

const ISSUER: &str = "https://accounts.google.com";
const STATE_TTL_SECS: u64 = 600;

pub struct Claims {
    pub issuer: String,
    pub subject: String,
    pub email: Option<String>,
    pub email_verified: bool,
}

pub struct Session {
    pub identity_id: String,
    pub email: String,
    pub name: String,
    pub role: Option<String>,
}

// ---------- OAuth ----------

pub fn authorization_url(redirect_uri: &str, secret: &str) -> Result<String, String> {
    let client_id = std::env::var("GOOGLE_CLIENT_ID").map_err(|_| "GOOGLE_CLIENT_ID not set".to_string())?;
    let payload = now_secs().to_string();
    let state = format!("{payload}.{}", sign(secret, &payload));
    Ok(format!(
        "https://accounts.google.com/o/oauth2/v2/auth?client_id={}&redirect_uri={}&response_type=code&scope={}&state={}",
        urlencode(&client_id),
        urlencode(redirect_uri),
        urlencode("openid email profile"),
        urlencode(&state),
    ))
}

// `expected` is unused beyond "a state was minted at all" — unlike the
// Ruby version (which compares against a server-stashed session value),
// this state IS its own proof: `verify_state` alone (recomputing the
// HMAC) is what a mismatched/forged/expired state actually fails on.
pub fn verify_state(state: &str, secret: &str) -> Result<(), String> {
    let payload = verify_sig(secret, state).ok_or_else(|| "state mismatch".to_string())?;
    let minted: u64 = payload.parse().map_err(|_| "state mismatch".to_string())?;
    if now_secs().saturating_sub(minted) > STATE_TTL_SECS {
        return Err("state expired".to_string());
    }
    Ok(())
}

pub async fn verify(code: &str, redirect_uri: &str) -> Result<Claims, String> {
    let client_id = std::env::var("GOOGLE_CLIENT_ID").map_err(|_| "GOOGLE_CLIENT_ID not set".to_string())?;
    let client_secret =
        std::env::var("GOOGLE_CLIENT_SECRET").map_err(|_| "GOOGLE_CLIENT_SECRET not set".to_string())?;

    let http = reqwest::Client::new();
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
    let body: Value = resp.json().await.map_err(|e| format!("token response: {e}"))?;
    let id_token = body
        .get("id_token")
        .and_then(|v| v.as_str())
        .ok_or_else(|| "no id_token in the response".to_string())?;

    verify_id_token(id_token, &client_id).await
}

// Google's own rotating JWKS (https://www.googleapis.com/oauth2/v3/certs)
// — fetched fresh every call, deliberately not cached: /auth/google/callback
// is a real sign-in, not a hot path, and a stale cached key set failing
// to pick up Google's own rotation would be a worse failure mode than
// one extra HTTPS round trip per login.
async fn verify_id_token(id_token: &str, client_id: &str) -> Result<Claims, String> {
    let header = jsonwebtoken::decode_header(id_token).map_err(|e| format!("bad id_token header: {e}"))?;
    let kid = header.kid.ok_or_else(|| "id_token header has no kid".to_string())?;

    let http = reqwest::Client::new();
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
        .and_then(|keys| keys.iter().find(|k| k.get("kid").and_then(|v| v.as_str()) == Some(kid.as_str())))
        .ok_or_else(|| format!("no JWKS key matches id_token's kid {kid:?}"))?;
    let n = key.get("n").and_then(|v| v.as_str()).ok_or_else(|| "JWKS key has no n".to_string())?;
    let e = key.get("e").and_then(|v| v.as_str()).ok_or_else(|| "JWKS key has no e".to_string())?;
    let decoding_key = jsonwebtoken::DecodingKey::from_rsa_components(n, e)
        .map_err(|err| format!("building decoding key from JWKS: {err}"))?;

    let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::RS256);
    validation.set_audience(&[client_id]);
    validation.set_issuer(&[ISSUER, "accounts.google.com"]);

    let token = jsonwebtoken::decode::<Value>(id_token, &decoding_key, &validation)
        .map_err(|err| format!("id_token signature/claims invalid: {err}"))?;
    let claims = token.claims;

    Ok(Claims {
        issuer: claims.get("iss").and_then(|v| v.as_str()).unwrap_or(ISSUER).to_string(),
        subject: claims
            .get("sub")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "id_token has no sub".to_string())?
            .to_string(),
        email: claims.get("email").and_then(|v| v.as_str()).map(|s| s.to_string()),
        email_verified: matches!(claims.get("email_verified"), Some(Value::Bool(true)))
            || claims.get("email_verified").and_then(|v| v.as_str()) == Some("true"),
    })
}

// ---------- Session cookie ----------

pub fn session_cookie(secret: &str, session: &Session) -> String {
    let payload = json!({
        "identity_id": session.identity_id,
        "email": session.email,
        "name": session.name,
        "role": session.role,
    });
    let encoded = base64_encode(payload.to_string().as_bytes());
    format!("{encoded}.{}", sign(secret, &encoded))
}

pub fn parse_session_cookie(secret: &str, cookie: &str) -> Option<Session> {
    let payload = verify_sig(secret, cookie)?;
    let bytes = base64_decode(&payload);
    let value: Value = serde_json::from_slice(&bytes).ok()?;
    Some(Session {
        identity_id: value.get("identity_id")?.as_str()?.to_string(),
        email: value.get("email")?.as_str()?.to_string(),
        name: value.get("name")?.as_str()?.to_string(),
        role: value.get("role").and_then(|v| v.as_str()).map(|s| s.to_string()),
    })
}

// ---------- Identity resolution + provisioning (Embryonaut::Member glue) ----------

// `Identity::ExternalIdentifier`'s own `identified_by { key.value }` is
// literally `"#{issuer}:#{subject}"` (identity.bluebook) -- a direct
// key lookup, the same shape `dispatch::read`'s own `instances` map
// already uses everywhere else (Adapters::Lambda#instances's own
// "Domain::Aggregate#id" convention, Ruby side).
pub fn resolve_identity(instances: &Value, issuer: &str, subject: &str) -> Option<String> {
    let key = format!("Identity::ExternalIdentifier#{issuer}:{subject}");
    instances
        .get(key)?
        .get("identity_id")?
        .as_str()
        .map(|s| s.to_string())
}

// `Embryonaut::Member` is NOT in `dispatch::read`'s own `instances` --
// it's permanently `persisted_by("PostgresEra")` (its rekey/translation
// history needs real SQL, embryonaut.hecksagon's own comment), so it
// was never migrated into rust/host's flat `hecks_lambda_journal` at
// all (bin/bootstrap_lambda_data's own header: "Member is dispatched
// LOCALLY ... against whatever DATABASE_URL names"). Queried straight
// off `member_head` instead -- the SAME era-scoped read view Ruby's
// own `Adapters::PostgresEra#all`/`#find` already read from
// (`SELECT id, state FROM #{lineage.head_view(table)}`,
// `head_view(name) = "#{name}_head"`, `table = aggregate.storage_name`
// = "member") -- confirmed live against the real deployed database. A
// real, live "google_unlinked" for an ALREADY-linked chris@embryonaut.ai
// caught this: `resolve_identity` correctly found his real identity_id,
// but scanning `instances` for his Member record could never find it.
//
// THIN WRAPPERS, now — `journal::read_lineage_head_by_id`/`_all` are
// the SAME two queries, generalized over `storage_name` instead of
// hard-typed to `"member_head"`, so Member is no longer the only
// aggregate this crate can read this way (see journal.rs's own header
// on the generic pair, and ir.rs's `lineage_capable_aggregates` for how
// a caller learns which OTHER aggregates qualify). Kept as named,
// Member-specific functions here rather than inlined at each call site
// below — every call site still reads "the Member row," not "a lineage
// row for whichever storage name," which is the real shape of what
// auth.rs is doing.
async fn member_row_by_email(client: &Mutex<Client>, domain_ir: &Value, email: &str) -> anyhow::Result<Option<Value>> {
    let (_, storage_name) = membership_aggregate(domain_ir)?;
    let guard = client.lock().await;
    journal::read_lineage_head_by_id(&*guard, &storage_name, email).await
}

async fn member_rows(client: &Mutex<Client>, domain_ir: &Value) -> anyhow::Result<Vec<(String, Value)>> {
    let (_, storage_name) = membership_aggregate(domain_ir)?;
    let guard = client.lock().await;
    journal::read_lineage_head_all(&*guard, &storage_name).await
}

// WHICH LINEAGE-CAPABLE AGGREGATE THIS DEPLOYMENT TREATS AS "THE
// MEMBERSHIP ONE" — `HECKS_MEMBERSHIP_AGGREGATE` names it (bare,
// non-domain-qualified, e.g. "Member"), resolved against `ir::
// lineage_capable_aggregates(domain_ir)` rather than trusted blind, so a
// typo'd env var fails loudly here instead of silently reading/writing
// the wrong (or a nonexistent) table. An env var, not a new bluebook-
// level IR marker: Embryonaut's own bluebook source lives in a separate
// repo not present in this checkout, so an IR-marker design would need
// changes in a repo this crate can't reach or test — the env var keeps
// the whole resolution inside rust/host, consistent with every other
// deploy-time binding this crate already makes as an env var
// (`HECKS_DOMAIN`, `DATABASE_URL`, `SESSION_SECRET`). Resolved lazily,
// at request time, not required at main.rs's own boot — the same
// reasoning `session_secret()`'s own header already gives: not every
// domain uses Google-auth/Member provisioning at all.
fn membership_aggregate(domain_ir: &Value) -> anyhow::Result<(String, String)> {
    let wanted = std::env::var("HECKS_MEMBERSHIP_AGGREGATE").map_err(|_| {
        anyhow::anyhow!(
            "HECKS_MEMBERSHIP_AGGREGATE is required for Member/GrantAccess/provision -- names \
             which lineage-capable aggregate is this domain's own membership record"
        )
    })?;
    resolve_membership_aggregate(&wanted, domain_ir)
}

// Pure and separately unit-tested from the env read above -- same split
// `session_secret()`/`validate_session_secret()` already use, and for
// the same reason: `cargo test` runs this crate's tests concurrently in
// one process, so asserting an env var is UNSET (the real "no value at
// all" case `membership_aggregate` itself refuses) can't be done safely
// against the real process environment without racing every other test
// that might set it. Everything this function actually decides --
// matching against `lineage_capable_aggregates`, refusing an unknown
// name -- is exercised here instead, with no env var involved at all.
fn resolve_membership_aggregate(wanted: &str, domain_ir: &Value) -> anyhow::Result<(String, String)> {
    crate::ir::lineage_capable_aggregates(domain_ir)
        .into_iter()
        .find_map(|(qualified, storage_name)| {
            let bare = qualified.rsplit("::").next().unwrap_or(&qualified).to_string();
            (bare == wanted).then_some((bare, storage_name))
        })
        .ok_or_else(|| {
            anyhow::anyhow!(
                "HECKS_MEMBERSHIP_AGGREGATE={wanted:?} names an aggregate lineage_capable_aggregates \
                 doesn't know about for this domain -- check it's persisted_by an era-capable adapter"
            )
        })
}

// `Adapters::PostgresEra#append`, ported verbatim (postgres_era.rb:176-201) --
// confirmed against the real deployed schema, not just source reading.
// The SAME transactional, ordinal-tracked write EVERY OTHER field-set
// on member_head already goes through (`Member.Admit`,
// `Member.GrantAccess` when dispatched by Ruby -- see
// bin/grant_first_admin) -- not a raw `UPDATE member_head` bypass. One
// real difference from Ruby's own `Entry`/`save?` machinery: this
// function is the WHOLE state-with-one-field-changed, computed by its
// two callers below, not a generic append-any-entry path -- there's
// only ever "save" (never "delete") for Member here, so `entry.
// operation`/`entry.mirrors`'s own branches (always "save"/always nil,
// confirmed by tracing CommandInterpreter -> Postgres#save) collapse
// to literals rather than being reintroduced as unused generality.
// GENERALIZED onto journal::append_lineage_mutation (ADR 0029 step 2) —
// was a hand-rolled duplicate of that function's own journal-insert +
// snapshot-upsert transaction, with "member"/`member_head_snapshot_{era}`
// spelled out by hand instead of derived. The lock below is NOT the
// generalization's job to supply: `journal::append_lineage_mutation`
// deliberately takes no lock of its own (see its own header) — locking
// is a caller concern, and dispatch.rs's caller already holds its own
// (a differently-named, invocation-scoped lock, journal.rs's own
// `hecks_lambda_journal.` advisory lock in dispatch.rs). This caller's
// concern is the one Ruby's own `append` takes right before its
// identical journal insert (postgres_era.rb:253-256) — `hecks_ordinal:`,
// which serializes against a concurrent domain RENAME holding that same
// lock name while repartitioning (postgres_era.rb:181), not against
// ordinal uniqueness (a real Postgres sequence default already owns
// that). Kept here, unchanged, rather than folded into the generic
// function, because a rename is a domain-wide concern every lineage
// write should serialize against — not specific to Member.
async fn append_member_state(client: &Mutex<Client>, config: &LineageConfig, domain_ir: &Value, id: &str, state: &Value) -> anyhow::Result<()> {
    let (aggregate_name, _) = membership_aggregate(domain_ir)?;
    let mut guard = client.lock().await;
    let txn = guard.transaction().await?;

    txn.execute(
        "SELECT pg_advisory_xact_lock(hashtext('hecks_ordinal:' || $1))",
        &[&config.domain],
    )
    .await?;

    journal::append_lineage_mutation(
        &txn,
        config,
        &journal::Mutation { aggregate: &aggregate_name, id, operation: "save", state },
    )
    .await?;

    txn.commit().await?;
    Ok(())
}

pub async fn session_for_member_by_identity(client: &Mutex<Client>, domain_ir: &Value, identity_id: &str) -> anyhow::Result<Option<Session>> {
    let (_, storage_name) = membership_aggregate(domain_ir)?;
    let guard = client.lock().await;
    let row = guard
        .query_opt(
            &format!(
                "SELECT state FROM {} WHERE state->'identity_id'->>'value' = $1",
                journal::quote_ident(&journal::head_view(&storage_name))
            ),
            &[&identity_id],
        )
        .await?;
    drop(guard);
    Ok(row.and_then(|r| {
        let state: Value = r.get(0);
        Some(Session {
            identity_id: identity_id.to_string(),
            email: state.get("email")?.get("value")?.as_str()?.to_string(),
            name: state.get("name")?.get("value")?.as_str()?.to_string(),
            role: state.get("role").and_then(|v| v.get("value")).and_then(|v| v.as_str()).map(|s| s.to_string()),
        })
    }))
}

// NEVER creates a Member (Admit is a real cap-table event) -- only
// mints Identity/Governance facts for a Member who already has `role`
// set (via GrantAccess) but no `identity_id` yet, matching
// embryonaut_access_control.rb's `provision` exactly.
#[allow(clippy::too_many_arguments)]
pub async fn provision(
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    domain_ir: &Value,
    email: &str,
    issuer: &str,
    subject: &str,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<Option<Session>> {
    let member = match member_row_by_email(client, domain_ir, email).await? {
        Some(m) => m,
        None => return Ok(None),
    };
    let role = member.get("role").and_then(|v| v.get("value")).and_then(|v| v.as_str());
    let already_linked = member.get("identity_id").and_then(|v| v.get("value")).is_some();
    let (Some(role), false) = (role, already_linked) else {
        return Ok(None);
    };
    let identity_id = uuid::Uuid::new_v4().to_string();

    // `None` on all three dispatches below -- this whole function is
    // SYSTEM-INITIATED provisioning (minting Identity/Governance facts
    // for a Member the operator already granted access to via
    // GrantAccess, not a command a logged-in caller is submitting), so
    // there is no caller role to assert here -- matches what every call
    // site in this function has always done.
    let register = dispatch::handle(
        client, wasm_path, "Identity::Identity.Register",
        json!({"identity_id": {"value": identity_id}}), None, config, invoker,
    ).await?;
    if !register.accepted {
        anyhow::bail!("Identity::Identity.Register refused: {}", register.result);
    }

    let link_external = dispatch::handle(
        client, wasm_path, "Identity::ExternalIdentifier.Link",
        json!({
            "identity_id": identity_id, "key": {"value": format!("{issuer}:{subject}")},
            "issuer": {"value": issuer}, "subject": {"value": subject},
        }), None, config, invoker,
    ).await?;
    if !link_external.accepted {
        anyhow::bail!("Identity::ExternalIdentifier.Link refused: {}", link_external.result);
    }

    let assign_role = dispatch::handle(
        client, wasm_path, "Governance::RoleAssignment.Assign",
        json!({
            "actor_id": {"value": identity_id}, "role_name": {"value": role}, "scope": {"value": config.domain.clone()},
            "starts_at": {"value": httpdate_now()},
        }), None, config, invoker,
    ).await?;
    if !assign_role.accepted {
        anyhow::bail!("Governance::RoleAssignment.Assign refused: {}", assign_role.result);
    }

    // NOT dispatch::handle -- Embryonaut::Member isn't in rust/host's
    // flat journal at all (member_row_by_email's own comment on why),
    // so a WASM-replay dispatch here would rehydrate zero prior Member
    // steps and refuse with a confusing "no such record" instead of
    // the real story. `append_member_state` is `Adapters::Postgres
    // #append`'s own transactional, ordinal-tracked protocol instead --
    // the same journal INSERT + head_snapshot upsert every OTHER write
    // to this table already goes through, not a raw UPDATE bypassing
    // it. LinkIdentity's own bluebook command is a single `sets
    // :identity_id, to: :identity_id` with no other invariant beyond
    // "not already linked" -- already checked above -- so the new
    // state is just the current row with that one field replaced.
    let mut new_state = member.clone();
    new_state["identity_id"] = json!({"value": identity_id});
    append_member_state(client, config, domain_ir, email, &new_state).await?;

    let name = member.get("name").and_then(|v| v.get("value")).and_then(|v| v.as_str()).unwrap_or_default().to_string();
    Ok(Some(Session { identity_id, email: email.to_string(), name, role: Some(role.to_string()) }))
}

pub async fn grant_access(
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    domain_ir: &Value,
    email: &str,
    role: &str,
) -> anyhow::Result<bool> {
    let _ = wasm_path;
    let Some(member) = member_row_by_email(client, domain_ir, email).await? else {
        return Ok(false);
    };

    // Same real append protocol provision() uses -- see its own
    // comment. GrantAccess's own bluebook command is a single
    // `sets :role, to: :role`, no other invariant.
    let mut new_state = member;
    new_state["role"] = json!({"value": role});
    append_member_state(client, config, domain_ir, email, &new_state).await?;
    Ok(true)
}

pub async fn all_people(client: &Mutex<Client>, domain_ir: &Value) -> anyhow::Result<Vec<Value>> {
    Ok(member_rows(client, domain_ir)
        .await?
        .into_iter()
        .map(|(_, state)| {
            let role = state.get("role").and_then(|v| v.get("value")).and_then(|v| v.as_str());
            let linked = state.get("identity_id").and_then(|v| v.get("value")).is_some();
            json!({
                "name": state.get("name").and_then(|v| v.get("value")),
                "email": state.get("email").and_then(|v| v.get("value")),
                "role": role,
                "linked": linked,
                "granted": role.is_some(),
            })
        })
        .collect())
}

pub fn holds_admin(instances: &Value, identity_id: &str) -> bool {
    instances.as_object().is_some_and(|obj| {
        obj.iter().any(|(key, state)| {
            key.starts_with("Governance::RoleAssignment#")
                && state.get("actor_id").and_then(|v| v.get("value")).and_then(|v| v.as_str()) == Some(identity_id)
                && state.get("role_name").and_then(|v| v.get("value")).and_then(|v| v.as_str()) == Some("Admin")
                && state.get("ends_at").map(|v| v.is_null()).unwrap_or(true)
        })
    })
}

// ---------- small helpers (no external crate pulled in just for these) ----------

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

// `pub(crate)` — `dispatch.rs`'s own `occurred_at` stamping reuses this
// exact ISO-8601 rendering rather than re-deriving it a second time; see
// this function's own body comment for the format guarantee both call
// sites depend on.
pub(crate) fn httpdate_now() -> String {
    // ISO 8601 UTC, matching Ruby's Time.now.utc.iso8601 -- Governance::
    // RoleAssignment.starts_at only needs to parse as a real instant,
    // never re-derived from or compared against wall-clock time here.
    let secs = now_secs();
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let (y, mo, d) = civil_from_days(days as i64);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}

// Howard Hinnant's days-from-civil algorithm, inverted -- avoids
// pulling in a full date/time crate for one timestamp format.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn sign(secret: &str, payload: &str) -> String {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key length");
    mac.update(payload.as_bytes());
    hex_encode(&mac.finalize().into_bytes())
}

fn verify_sig(secret: &str, token: &str) -> Option<String> {
    let (payload, sig) = token.rsplit_once('.')?;
    if sign(secret, payload) == sig {
        Some(payload.to_string())
    } else {
        None
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

const B64: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn base64_encode(input: &[u8]) -> String {
    let mut out = String::new();
    for chunk in input.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
        out.push(B64[(n >> 18) as usize & 0x3f] as char);
        out.push(B64[(n >> 12) as usize & 0x3f] as char);
        if chunk.len() > 1 {
            out.push(B64[(n >> 6) as usize & 0x3f] as char);
        }
        if chunk.len() > 2 {
            out.push(B64[n as usize & 0x3f] as char);
        }
    }
    out
}

fn base64_decode(input: &str) -> Vec<u8> {
    let mut table = [255u8; 256];
    for (i, &c) in B64.iter().enumerate() {
        table[c as usize] = i as u8;
    }
    let mut out = Vec::new();
    let mut buf = 0u32;
    let mut bits = 0u32;
    for c in input.bytes() {
        let v = table[c as usize];
        if v == 255 {
            continue;
        }
        buf = (buf << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
        }
    }
    out
}

pub(crate) fn urlencode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_round_trips_arbitrary_bytes() {
        for input in [b"".as_slice(), b"a", b"ab", b"abc", b"abcd", b"\x00\xff\x10hello world!"] {
            let encoded = base64_encode(input);
            assert!(!encoded.contains('+') && !encoded.contains('/'), "must be URL-safe: {encoded}");
            assert_eq!(base64_decode(&encoded), input, "round trip failed for {input:?}");
        }
    }

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
    fn session_cookie_round_trips_and_rejects_a_forged_one() {
        let session = Session {
            identity_id: "id-1".to_string(),
            email: "chris@embryonaut.ai".to_string(),
            name: "Chris Young".to_string(),
            role: Some("Admin".to_string()),
        };
        let cookie = session_cookie("s3cret", &session);
        let parsed = parse_session_cookie("s3cret", &cookie).expect("should parse with the right secret");
        assert_eq!(parsed.identity_id, "id-1");
        assert_eq!(parsed.email, "chris@embryonaut.ai");
        assert_eq!(parsed.role.as_deref(), Some("Admin"));

        assert!(parse_session_cookie("wrong-secret", &cookie).is_none());
        assert!(parse_session_cookie("s3cret", "garbage.notasignature").is_none());
    }

    #[test]
    fn oauth_state_verifies_fresh_and_rejects_forged_or_expired() {
        let fresh = now_secs().to_string();
        let state = format!("{fresh}.{}", sign("s3cret", &fresh));
        assert!(verify_state(&state, "s3cret").is_ok());
        assert!(verify_state(&state, "wrong-secret").is_err());

        let stale = (now_secs() - STATE_TTL_SECS - 1).to_string();
        let expired = format!("{stale}.{}", sign("s3cret", &stale));
        assert!(verify_state(&expired, "s3cret").is_err());
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
    fn holds_admin_reads_straight_off_instances() {
        let instances = json!({
            "Governance::RoleAssignment#id-1:Admin": {
                "actor_id": {"value": "id-1"}, "role_name": {"value": "Admin"}, "ends_at": null,
            },
        });

        assert!(holds_admin(&instances, "id-1"));
        assert!(!holds_admin(&instances, "id-2"));
    }

    #[test]
    fn resolve_membership_aggregate_matches_by_bare_name_and_refuses_an_unknown_one() {
        let domain_ir = json!({
            "name": "Embryonaut",
            "lineage": {"capable_aggregates": [{"name": "Member", "storage_name": "member"}]},
        });

        let (aggregate, storage_name) = resolve_membership_aggregate("Member", &domain_ir).unwrap();
        assert_eq!(aggregate, "Member");
        assert_eq!(storage_name, "member");

        assert!(resolve_membership_aggregate("Nonexistent", &domain_ir).is_err());
        assert!(resolve_membership_aggregate("Member", &json!({"name": "Embryonaut"})).is_err());
    }

    // A REAL, THROWAWAY POSTGRES DATABASE per test, matching the real
    // shape `head_view` names ("#{storage_name}_head", postgres/
    // lineage.rb) -- member_row_by_email/session_for_member_by_identity/
    // all_people all query this exact table against the real, deployed
    // database (confirmed live via a bastion tunnel: `\dt` + `SELECT id,
    // state FROM member_head` on the real hecks-embryonaut RDS
    // instance). Uniquely named per test, same reasoning dispatch.rs's
    // own `scratch_db` gives itself.
    async fn scratch_member_db(name: &str) -> Mutex<tokio_postgres::Client> {
        use tokio_postgres::NoTls;
        let (admin, conn) = tokio_postgres::connect("host=localhost dbname=postgres", NoTls)
            .await
            .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        admin.batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)")).await.unwrap();
        admin.batch_execute(&format!("CREATE DATABASE {name}")).await.unwrap();

        let (client, conn) = tokio_postgres::connect(&format!("host=localhost dbname={name}"), NoTls)
            .await
            .expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        // The REAL shape, confirmed live against the deployed database
        // (`\dt` + `SELECT id, state FROM member_head` via a bastion
        // tunnel): `member_head` is a VIEW over the era-1 snapshot
        // table (postgres/lineage/head_compiler.rb's `ensure_first_head!`,
        // `CREATE OR REPLACE VIEW "member_head" AS SELECT id, state FROM
        // "member_head_snapshot_1"`), and every write goes through the
        // domain's own era-partitioned journal table first
        // (`hecks_journal_embryonaut`) -- `append_member_state`'s own
        // target, exercised by the test below.
        client
            .batch_execute(
                "CREATE TABLE member_head_snapshot_1 (id text PRIMARY KEY, ordinal bigint NOT NULL, state jsonb NOT NULL);
                 CREATE VIEW member_head AS SELECT id, state FROM member_head_snapshot_1;
                 CREATE TABLE hecks_journal_embryonaut (
                     ordinal bigserial PRIMARY KEY, era int NOT NULL, aggregate text NOT NULL,
                     aggregate_id text NOT NULL, operation text NOT NULL, state jsonb, mirrors jsonb
                 );",
            )
            .await
            .unwrap();
        Mutex::new(client)
    }

    // A minimal `ir.json`-shaped fixture naming exactly one lineage-
    // capable aggregate, "Member" (storage_name "member") -- everything
    // `resolve_membership_aggregate`/`lineage_capable_aggregates`
    // actually reads. `HECKS_MEMBERSHIP_AGGREGATE=Member` set once,
    // never unset -- both real-DB integration tests below want the
    // identical value, and nothing else in this file's own test module
    // ever reads this env var, so setting (never clearing) it carries
    // none of the cross-test race risk `resolve_membership_aggregate`'s
    // own unit tests are deliberately structured to avoid.
    fn member_domain_ir() -> Value {
        json!({
            "name": "Embryonaut",
            "lineage": {"capable_aggregates": [{"name": "Member", "storage_name": "member"}]},
        })
    }

    #[tokio::test]
    async fn member_lookups_query_the_real_member_head_shape() {
        std::env::set_var("HECKS_MEMBERSHIP_AGGREGATE", "Member");
        let domain_ir = member_domain_ir();
        let db = scratch_member_db("hecks_host_auth_test_member_lookups").await;
        {
            let guard = db.lock().await;
            guard.execute(
                "INSERT INTO member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 1, $2::jsonb), ($3, 1, $4::jsonb)",
                &[
                    &"chris@embryonaut.ai",
                    &json!({"name": {"value": "Chris Young"}, "email": {"value": "chris@embryonaut.ai"},
                            "role": {"value": "Admin"}, "identity_id": {"value": "id-1"}}),
                    &"angie@embryonaut.ai",
                    &json!({"name": {"value": "Angie Chen"}, "email": {"value": "angie@embryonaut.ai"},
                            "role": null, "identity_id": null}),
                ],
            ).await.unwrap();
        }

        let chris = member_row_by_email(&db, &domain_ir, "chris@embryonaut.ai").await.unwrap().expect("should find chris");
        assert_eq!(chris["email"]["value"], "chris@embryonaut.ai");
        assert!(member_row_by_email(&db, &domain_ir, "nobody@embryonaut.ai").await.unwrap().is_none());

        let session = session_for_member_by_identity(&db, &domain_ir, "id-1").await.unwrap().expect("should find the linked member");
        assert_eq!(session.email, "chris@embryonaut.ai");
        assert_eq!(session.role.as_deref(), Some("Admin"));
        assert!(session_for_member_by_identity(&db, &domain_ir, "id-nope").await.unwrap().is_none());

        let people = all_people(&db, &domain_ir).await.unwrap();
        assert_eq!(people.len(), 2);
        let chris = people.iter().find(|p| p["email"] == "chris@embryonaut.ai").unwrap();
        assert_eq!(chris["linked"], true);
        assert_eq!(chris["granted"], true);
        let angie = people.iter().find(|p| p["email"] == "angie@embryonaut.ai").unwrap();
        assert_eq!(angie["linked"], false);
        assert_eq!(angie["granted"], false);
    }

    #[tokio::test]
    async fn append_member_state_writes_the_journal_and_advances_the_head_snapshot() {
        std::env::set_var("HECKS_MEMBERSHIP_AGGREGATE", "Member");
        let domain_ir = member_domain_ir();
        let db = scratch_member_db("hecks_host_auth_test_append_member").await;
        let config = LineageConfig { domain: "Embryonaut".to_string(), era: Some(1) };
        {
            let guard = db.lock().await;
            // ordinal 0 -- BELOW anything the fresh journal's own
            // bigserial sequence will ever produce (starts at 1), the
            // same way a REAL seed row's ordinal is always lower than
            // any later real write's. Seeding this at 1 created a
            // genuine collision with the journal's first real insert
            // (also ordinal 1) and made the guard correctly refuse to
            // advance -- caught live by this very test, not a
            // hypothetical.
            guard.execute(
                "INSERT INTO member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 0, $2::jsonb)",
                &[
                    &"angie@embryonaut.ai",
                    &json!({"name": {"value": "Angie Chen"}, "email": {"value": "angie@embryonaut.ai"},
                            "role": null, "identity_id": null}),
                ],
            ).await.unwrap();
        }

        let granted = json!({"name": {"value": "Angie Chen"}, "email": {"value": "angie@embryonaut.ai"},
                              "role": {"value": "Admin"}, "identity_id": null});
        append_member_state(&db, &config, &domain_ir, "angie@embryonaut.ai", &granted).await.unwrap();

        // The head view reflects the new state immediately.
        let after = member_row_by_email(&db, &domain_ir, "angie@embryonaut.ai").await.unwrap().expect("still there");
        assert_eq!(after["role"]["value"], "Admin");

        // A real journal row was appended -- not a raw UPDATE bypassing it.
        let guard = db.lock().await;
        let journal_rows = guard
            .query("SELECT era, aggregate, aggregate_id, operation, state FROM hecks_journal_embryonaut", &[])
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
        assert_eq!(aggregate_id, "angie@embryonaut.ai");
        assert_eq!(operation, "save");
        assert_eq!(state["role"]["value"], "Admin");

        // The snapshot's own ordinal advanced past the seed row's.
        let ordinal: i64 = guard
            .query_one("SELECT ordinal FROM member_head_snapshot_1 WHERE id = $1", &[&"angie@embryonaut.ai"])
            .await
            .unwrap()
            .get(0);
        assert!(ordinal > 0, "should have advanced past the seed row's ordinal 0");
        drop(guard);

        // The SAME ordinal-guarded upsert Ruby's own append() uses
        // (`WHERE ordinal < EXCLUDED.ordinal`) refuses to move the
        // snapshot backward -- append a second, EARLIER-looking write
        // isn't possible through this function (ordinal always comes
        // from the SAME sequence the journal INSERT just used), but
        // the guard itself is directly testable: a manual attempt to
        // downgrade the snapshot with a smaller ordinal is a no-op.
        let guard = db.lock().await;
        guard.execute(
            "INSERT INTO member_head_snapshot_1 (id, ordinal, state) VALUES ($1, 1, $2::jsonb) \
             ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, state = EXCLUDED.state \
             WHERE member_head_snapshot_1.ordinal < EXCLUDED.ordinal",
            &[&"angie@embryonaut.ai", &json!({"role": {"value": "SHOULD_NOT_APPLY"}})],
        ).await.unwrap();
        let state: Value = guard
            .query_one("SELECT state FROM member_head_snapshot_1 WHERE id = $1", &[&"angie@embryonaut.ai"])
            .await
            .unwrap()
            .get(0);
        assert_eq!(state["role"]["value"], "Admin", "a lower ordinal must never move the snapshot backward");
    }
}
