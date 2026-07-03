//! acl_readmodel — the boot-hydrated, in-memory RBAC read-model for the
//! authorization gate (Layer-2), plus the `Principal` that classifies a
//! caller at the ENTRY door.
//!
//! [antibody-exempt: rust/src/runtime/acl_readmodel.rs — kernel-floor runtime ;
//!  the in-memory RBAC read-model (auth_identity -> role) the authorize PDP gate
//!  reads, plus the Principal that classifies a caller at the entry door. Sibling
//!  of mod.rs / middleware.rs, themselves exempt. The bluebook is the declared
//!  truth ; this is its imperative leaf. Kernel-floor growth +31 core_runtime
//!  (2026-07-02, Phase 4 authz decouple — rehydrate_acl + repointed hydrate)
//!  authorized by Chris via loc-ratchet-override ; shrink-back on a later arc.]
//!
//! WHY in-memory : the gate must block BEFORE the act, so it resolves over
//! hydrated local state ONLY — never an async bus query for RoleAssignment
//! state (that would break the two-color rule, inject a blocking await, and
//! risk reentrancy, since querying is itself a dispatch). The runtime hydrates
//! this read-model at boot (mirroring how persistence hydrates state before the
//! sync core) and refreshes it when a RoleAssignment lifecycle event applies
//! (plus once after the boot-completion cascade settles — see
//! run_boot/complete.rs, where the authz roster's assignments arrive as
//! cascades the entry-dispatch trigger cannot see).
//!
//! WHAT it holds : only the identity->role binding from
//! `Authorization::RoleAssignment` aggregate STATE — the authz context owns
//! identity↔role since the Phase 4 decouple (2026-07-02) ; Agent carries no
//! auth surface. Role hierarchy is NOT held — the PDP exact-matches the
//! assigned role name against a policy principal (no inheritance), per the
//! RBAC->PDP consolidation. The command's inline `role` is the DDD actor, not
//! enforcement.
//!
//! Usage (inside authorize_check):
//!   match principal_from_attrs(&attrs) {
//!       Principal::System => Ok(()),                  // admitted by origin
//!       Principal::Agent { auth_identity_id } => {    // resolve role, then
//!           let role = rt.acl_read_model.role_for_auth(&auth_identity_id);
//!           ... exact-match `role` against active Policy permits/forbids ...
//!       }
//!   }

use super::{Runtime, Value};
use std::collections::HashMap;

/// Reserved meta-attr keys the door stamps onto a dispatch to declare the
/// caller. Stripped before the command applies (as `actor_caps` was), so they
/// never land on the command or ride the emitted event.
/// Prefixed with `actor_` (like the retired `actor_caps`) so they never
/// collide with a domain attribute — e.g. RoleAssignment.Assign carries its
/// own `auth_identity_id`, which must NOT be read as the caller's identity.
pub const KIND_KEY: &str = "actor_kind";
pub const AUTH_KEY: &str = "actor_auth_id";

/// The origin of a dispatch at the ENTRY door. It is NOT always an agent: most
/// dispatches are system-origin (driver/clock, cascade, adapter verdict,
/// fixture, boot). Only `Agent` is subject to RBAC resolution; `System` is
/// admitted by origin, generalizing the existing cascade bypass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Principal {
    /// A session-bound caller (human/AI/bot/client-app user). Resolved through
    /// the read-model: auth_identity_id -> RoleAssignment -> role_name
    /// (exact match, no inheritance).
    Agent { auth_identity_id: String },
    /// An internal origin. Admitted by ORIGIN; never resolves a session.
    System,
}

/// Classify the caller from the reserved meta attrs. An absent or unrecognised
/// kind defaults to `System` — so existing internal/test dispatches that stamp
/// nothing stay admitted (no regression); the external doors stamp `agent`
/// explicitly to opt a call into RBAC. An `agent` kind with an empty auth id
/// still returns `Agent` (it fails closed in authorize_check).
pub fn principal_from_attrs(attrs: &HashMap<String, Value>) -> Principal {
    let kind = attrs.get(KIND_KEY).map(value_string).unwrap_or_default();
    match kind.as_str() {
        "agent" => Principal::Agent {
            auth_identity_id: attrs.get(AUTH_KEY).map(value_string).unwrap_or_default(),
        },
        _ => Principal::System,
    }
}

/// Stamp the caller principal onto a dispatch's attrs from the environment.
/// An external door (cold CLI / warm MCP serve) calls this before dispatch:
///   HECKS_SESSION_AUTH_ID non-empty -> agent (RBAC resolves its role)
///   otherwise                       -> system (admitted by origin)
/// HECKS_PRINCIPAL_KIND, when set, forces the kind explicitly.
pub fn stamp_principal_from_env(attrs: &mut HashMap<String, Value>) {
    let auth = std::env::var("HECKS_SESSION_AUTH_ID").unwrap_or_default();
    let kind = std::env::var("HECKS_PRINCIPAL_KIND").unwrap_or_default();
    let kind = if !kind.is_empty() {
        kind
    } else if !auth.is_empty() {
        "agent".to_string()
    } else {
        "system".to_string()
    };
    attrs.insert(KIND_KEY.to_string(), Value::Str(kind));
    if !auth.is_empty() {
        attrs.insert(AUTH_KEY.to_string(), Value::Str(auth));
    }
}

/// Stamp a SYSTEM principal (driver/clock, adapter re-entry, boot). Admitted
/// by origin without a session. Use on internal re-entry doors that must NOT
/// inherit an ambient HECKS_SESSION_AUTH_ID.
pub fn stamp_system(attrs: &mut HashMap<String, Value>) {
    attrs.insert(KIND_KEY.to_string(), Value::Str("system".to_string()));
}

/// The HTTP serve door's posture — a per-deployment `.world` `door` block
/// value (`door do posture "governed" end`). `Open` (the default, and what an
/// absent block means) keeps today's behavior byte-identical : a header-less
/// caller stamps as System, admitted by origin — Miette's local studio
/// unbroken. `Governed` is what a shipped client deployment declares : a
/// header-less caller stamps as an identity-LESS Agent and fails closed at
/// the gate, and the raw introspection routes answer 403 wholesale.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DoorPosture {
    #[default]
    Open,
    Governed,
}

impl DoorPosture {
    /// Parse a `.world` `door` block's `posture` value. Only the ratified
    /// "governed" flips the door ; anything else (including absence) is Open.
    pub fn parse(s: &str) -> DoorPosture {
        if s == "governed" { DoorPosture::Governed } else { DoorPosture::Open }
    }
}

/// Stamp the caller principal from an HTTP REQUEST (the resident serve door).
/// Per-REQUEST where `stamp_principal_from_env` is per-PROCESS — one warm
/// HTTP server serves MANY callers, so the `Authorization: Bearer <token>`
/// header carries the caller's identity. The bearer IS the auth_identity_id
/// (first cut) ; opaque-token / JWT-sub mapping arrives with the future
/// Session chapter. Same reserved keys, explicit source :
///   Some(token)      -> agent (RBAC resolves its role)
///   None + Open      -> system (today's behavior, admitted by origin)
///   None + Governed  -> agent with NO identity -> fails closed at the gate
pub fn stamp_principal_from_request(
    attrs: &mut HashMap<String, Value>,
    bearer: Option<&str>,
    posture: DoorPosture,
) {
    match bearer {
        Some(token) => {
            attrs.insert(KIND_KEY.to_string(), Value::Str("agent".to_string()));
            attrs.insert(AUTH_KEY.to_string(), Value::Str(token.to_string()));
        }
        None => match posture {
            DoorPosture::Open => stamp_system(attrs),
            DoorPosture::Governed => {
                attrs.insert(KIND_KEY.to_string(), Value::Str("agent".to_string()));
            }
        },
    }
}

/// In-memory RBAC read-model. Built from `Authorization::RoleAssignment`
/// aggregate state — never from Agent, which carries no auth surface since
/// the Phase 4 decouple.
#[derive(Debug, Clone, Default)]
pub struct AclReadModel {
    /// auth_identity_id -> role_name, active (non-retired) assignments only.
    role_for_auth: HashMap<String, String>,
}

impl AclReadModel {
    pub fn empty() -> Self {
        Self::default()
    }

    /// Build from current RoleAssignment aggregate state. Synchronous,
    /// in-memory; reads via `Runtime::all` (lazy-loads the repository on first
    /// touch). Role hierarchy is NOT read — the PDP exact-matches the assigned
    /// role name (no inheritance), per the RBAC->PDP consolidation.
    pub fn hydrate(rt: &Runtime) -> Self {
        // Assignments: auth_identity_id -> role_name, active only.
        let mut role_for_auth: HashMap<String, String> = HashMap::new();
        for st in rt.all("RoleAssignment") {
            if value_string(st.get("status")) == "retired" {
                continue;
            }
            let auth = value_string(st.get("auth_identity_id"));
            let role = value_string(st.get("role_name"));
            if auth.is_empty() || role.is_empty() {
                continue;
            }
            // identified_by :auth_identity_id makes duplicates structurally
            // unrepresentable ; last-wins stays as defense in depth.
            role_for_auth.insert(auth, role);
        }

        AclReadModel { role_for_auth }
    }

    /// The role_name assigned to an authenticated identity, if any (active
    /// assignments only — a retired assignment resolves to no role).
    pub fn role_for_auth(&self, auth_id: &str) -> Option<&str> {
        self.role_for_auth.get(auth_id).map(|s| s.as_str())
    }
}

/// Read a single-value field as a plain String. Handles the raw `Value::Str`
/// form (how create + lifecycle store single-value VO attrs), a `Value::Map`
/// with a `value` key (defensive), and `Null` (missing) -> empty string.
fn value_string(v: &Value) -> String {
    match v {
        Value::Str(s) => s.clone(),
        Value::Map(m) => m.get("value").map(value_string).unwrap_or_default(),
        Value::Null => String::new(),
        other => format!("{}", other),
    }
}
