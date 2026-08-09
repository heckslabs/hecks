// GOOGLE SIGN-IN + SESSIONS, IN-PROCESS — the Rust-native counterpart
// to `Ports::Authentication`/`Ports::IdentityResolution`/Embryonaut's
// own `EmbryonautAccessControl` adapter (Ruby, hecksagain +
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
// EMBRYONAUT-SPECIFIC GLUE, MARKED — `member_by_email`/`grant_access`/
// `link_identity`/`session_for_member` all hardcode "Embryonaut::Member"
// as this domain's own membership aggregate the same way rust/Cargo.toml's
// `default = ["embryonaut"]` feature already hardcodes which domain this
// binary serves. A fully generic hecks_web would resolve "which
// aggregate is the membership one" from bluebook config instead
// (embryonaut_access_control.rb's own role in the Ruby version); this
// is the pragmatic, working version for Embryonaut today, same
// maturity level rust/host's own per-domain codegen already has.

use crate::dispatch;
use crate::journal::LineageConfig;
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
// it's permanently `persisted_by("Postgres")` (its rekey/translation
// history needs real SQL, embryonaut.hecksagon's own comment), so it
// was never migrated into rust/host's flat `hecks_lambda_journal` at
// all (bin/bootstrap_lambda_data's own header: "Member is dispatched
// LOCALLY ... against whatever DATABASE_URL names"). Queried straight
// off `member_head` instead -- the SAME era-scoped read view Ruby's
// own `Adapters::Postgres#all`/`#find` already read from
// (`SELECT id, state FROM #{lineage.head_view(table)}`,
// `head_view(name) = "#{name}_head"`, `table = aggregate.storage_name`
// = "member") -- confirmed live against the real deployed database. A
// real, live "google_unlinked" for an ALREADY-linked chris@embryonaut.ai
// caught this: `resolve_identity` correctly found his real identity_id,
// but scanning `instances` for his Member record could never find it.
async fn member_row_by_email(client: &Mutex<Client>, email: &str) -> anyhow::Result<Option<Value>> {
    let guard = client.lock().await;
    let row = guard.query_opt("SELECT state FROM member_head WHERE id = $1", &[&email]).await?;
    Ok(row.map(|r| r.get::<_, Value>(0)))
}

async fn member_rows(client: &Mutex<Client>) -> anyhow::Result<Vec<(String, Value)>> {
    let guard = client.lock().await;
    let rows = guard.query("SELECT id, state FROM member_head", &[]).await?;
    Ok(rows.into_iter().map(|r| (r.get(0), r.get(1))).collect())
}

pub async fn session_for_member_by_identity(client: &Mutex<Client>, identity_id: &str) -> anyhow::Result<Option<Session>> {
    let guard = client.lock().await;
    let row = guard
        .query_opt(
            "SELECT state FROM member_head WHERE state->'identity_id'->>'value' = $1",
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
pub async fn provision(
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    email: &str,
    issuer: &str,
    subject: &str,
) -> anyhow::Result<Option<Session>> {
    let member = match member_row_by_email(client, email).await? {
        Some(m) => m,
        None => return Ok(None),
    };
    let role = member.get("role").and_then(|v| v.get("value")).and_then(|v| v.as_str());
    let already_linked = member.get("identity_id").and_then(|v| v.get("value")).is_some();
    let (Some(role), false) = (role, already_linked) else {
        return Ok(None);
    };
    let identity_id = uuid::Uuid::new_v4().to_string();

    let register = dispatch::handle(
        client, wasm_path, "Identity::Identity.Register",
        json!({"identity_id": {"value": identity_id}}), config,
    ).await?;
    if !register.accepted {
        anyhow::bail!("Identity::Identity.Register refused: {}", register.result);
    }

    let link_external = dispatch::handle(
        client, wasm_path, "Identity::ExternalIdentifier.Link",
        json!({
            "identity_id": identity_id, "key": {"value": format!("{issuer}:{subject}")},
            "issuer": {"value": issuer}, "subject": {"value": subject},
        }), config,
    ).await?;
    if !link_external.accepted {
        anyhow::bail!("Identity::ExternalIdentifier.Link refused: {}", link_external.result);
    }

    let assign_role = dispatch::handle(
        client, wasm_path, "Governance::RoleAssignment.Assign",
        json!({
            "actor_id": {"value": identity_id}, "role_name": {"value": role}, "scope": {"value": "Embryonaut"},
            "starts_at": {"value": httpdate_now()},
        }), config,
    ).await?;
    if !assign_role.accepted {
        anyhow::bail!("Governance::RoleAssignment.Assign refused: {}", assign_role.result);
    }

    // NOT dispatch::handle -- Embryonaut::Member isn't in rust/host's
    // flat journal at all (member_row_by_email's own comment on why),
    // so a WASM-replay dispatch here would rehydrate zero prior Member
    // steps and refuse with a confusing "no such record" instead of
    // the real story. Writing this field directly against member_head
    // would work mechanically but skips the SAME transactional,
    // ordinal-tracked journal INSERT `Adapters::Postgres#append`
    // performs for every OTHER write to this table (postgres.rb:141) --
    // a real audit-trail gap for governance/cap-table-adjacent data,
    // not just a style question. Left as a clean, honest failure
    // (Identity/Governance ARE minted above -- only this LAST field
    // write is blocked) until that's deliberately decided, not
    // silently worked around.
    anyhow::bail!(
        "identity {identity_id} minted for {email}, but Embryonaut::Member.LinkIdentity can't run: \
         Member is Postgres-lineage-bound, not reachable through rust/host's flat-journal dispatch"
    );
}

pub async fn grant_access(
    client: &Mutex<Client>,
    wasm_path: &Path,
    config: &LineageConfig,
    email: &str,
    role: &str,
) -> anyhow::Result<bool> {
    if member_row_by_email(client, email).await?.is_none() {
        return Ok(false);
    }

    // Same gap provision()'s own tail hits -- see that comment. Member
    // is confirmed to exist (the check above), but GrantAccess can't
    // actually write role to Postgres-lineage-bound member_head
    // through rust/host's flat-journal dispatch.
    let _ = (wasm_path, config, role);
    anyhow::bail!(
        "found {email} but Embryonaut::Member.GrantAccess can't run: \
         Member is Postgres-lineage-bound, not reachable through rust/host's flat-journal dispatch"
    );
}

pub async fn all_people(client: &Mutex<Client>) -> anyhow::Result<Vec<Value>> {
    Ok(member_rows(client)
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

fn httpdate_now() -> String {
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

fn urlencode(s: &str) -> String {
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

    // A REAL, THROWAWAY POSTGRES DATABASE per test, matching the real
    // shape `head_view` names ("#{storage_name}_head", postgres/
    // lineage.rb) -- member_row_by_email/session_for_member_by_identity/
    // all_people all query this exact table against the real, deployed
    // database (confirmed live via a bastion tunnel: `\dt` + `SELECT id,
    // state FROM member_head` on the real hecksagain-embryonaut RDS
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
        client
            .batch_execute("CREATE TABLE member_head (id text PRIMARY KEY, state jsonb NOT NULL)")
            .await
            .unwrap();
        Mutex::new(client)
    }

    #[tokio::test]
    async fn member_lookups_query_the_real_member_head_shape() {
        let db = scratch_member_db("hecks_host_auth_test_member_lookups").await;
        {
            let guard = db.lock().await;
            guard.execute(
                "INSERT INTO member_head (id, state) VALUES ($1, $2::jsonb), ($3, $4::jsonb)",
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

        let chris = member_row_by_email(&db, "chris@embryonaut.ai").await.unwrap().expect("should find chris");
        assert_eq!(chris["email"]["value"], "chris@embryonaut.ai");
        assert!(member_row_by_email(&db, "nobody@embryonaut.ai").await.unwrap().is_none());

        let session = session_for_member_by_identity(&db, "id-1").await.unwrap().expect("should find the linked member");
        assert_eq!(session.email, "chris@embryonaut.ai");
        assert_eq!(session.role.as_deref(), Some("Admin"));
        assert!(session_for_member_by_identity(&db, "id-nope").await.unwrap().is_none());

        let people = all_people(&db).await.unwrap();
        assert_eq!(people.len(), 2);
        let chris = people.iter().find(|p| p["email"] == "chris@embryonaut.ai").unwrap();
        assert_eq!(chris["linked"], true);
        assert_eq!(chris["granted"], true);
        let angie = people.iter().find(|p| p["email"] == "angie@embryonaut.ai").unwrap();
        assert_eq!(angie["linked"], false);
        assert_eq!(angie["granted"], false);
    }

}
