//! acl_readmodel — the boot-hydrated, in-memory RBAC read-model for the
//! authorization gate (Layer-2), plus the `Principal` that classifies a
//! caller at the ENTRY door.
//!
//! WHY in-memory : the gate must block BEFORE the act, so it resolves over
//! hydrated local state ONLY — never an async bus query for Role/Agent state
//! (that would break the two-color rule, inject a blocking await, and risk
//! reentrancy, since querying Role is itself a dispatch). The runtime hydrates
//! this read-model at boot (mirroring how persistence hydrates state before the
//! sync core) and refreshes it when a Role/Agent lifecycle event applies.
//!
//! WHAT it holds : only the data that comes from aggregate STATE (role
//! hierarchy + retirement, agent auth->role). The command's required role is
//! NOT held here — it is read on demand from the in-memory IR (`self.domain`),
//! since the inline `role` on each command is the source of truth.
//!
//! Usage (inside acl_check):
//!   match principal_from_attrs(&attrs) {
//!       Principal::System => Ok(()),                  // admitted by origin
//!       Principal::Agent { auth_identity_id } => {    // resolve + check
//!           let role = rt.acl_read_model.role_for_auth(&auth_identity_id);
//!           ... rt.acl_read_model.role_satisfies(role, required_role) ...
//!       }
//!   }

use super::{Runtime, Value};
use std::collections::{HashMap, HashSet};

/// Reserved meta-attr keys the door stamps onto a dispatch to declare the
/// caller. Stripped before the command applies (as `actor_caps` was), so they
/// never land on the command or ride the emitted event.
/// Prefixed with `actor_` (like the retired `actor_caps`) so they never
/// collide with a domain attribute — e.g. Agent.LinkAuthIdentity carries its
/// own `auth_identity_id`, which must NOT be read as the caller's identity.
pub const KIND_KEY: &str = "actor_kind";
pub const AUTH_KEY: &str = "actor_auth_id";

/// The origin of a dispatch at the ENTRY door. It is NOT always an agent: most
/// dispatches are system-origin (driver/clock, cascade, adapter verdict,
/// fixture, boot). Only `Agent` is subject to RBAC resolution; `System` is
/// admitted by origin, generalizing the existing cascade bypass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Principal {
    /// A session-bound caller (human/AI/bot). Resolved through the read-model:
    /// auth_identity_id -> Agent -> role -> ancestor chain.
    Agent { auth_identity_id: String },
    /// An internal origin. Admitted by ORIGIN; never resolves a session.
    System,
}

/// Classify the caller from the reserved meta attrs. An absent or unrecognised
/// kind defaults to `System` — so existing internal/test dispatches that stamp
/// nothing stay admitted (no regression); the external doors stamp `agent`
/// explicitly to opt a call into RBAC. An `agent` kind with an empty auth id
/// still returns `Agent` (it fails closed in acl_check).
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

/// In-memory RBAC read-model. Built from Role + Agent aggregate state.
#[derive(Debug, Clone, Default)]
pub struct AclReadModel {
    /// auth_identity_id -> role_name, active (non-retired) agents only.
    role_for_auth: HashMap<String, String>,
    /// role_name -> its flattened ancestor chain (parents..., retired excluded).
    /// The role itself is NOT included.
    ancestors: HashMap<String, Vec<String>>,
    /// retired role names — excluded from chains and from a direct bind.
    retired_roles: HashSet<String>,
}

impl AclReadModel {
    pub fn empty() -> Self {
        Self::default()
    }

    /// Build from current Role + Agent aggregate state. Synchronous, in-memory;
    /// reads via `Runtime::all` (lazy-loads the repository on first touch).
    pub fn hydrate(rt: &Runtime) -> Self {
        // Roles: name -> parent, plus the retired set.
        let mut parent_of: HashMap<String, String> = HashMap::new();
        let mut retired_roles: HashSet<String> = HashSet::new();
        for st in rt.all("Role") {
            let name = value_string(st.get("name"));
            if name.is_empty() {
                continue;
            }
            if value_string(st.get("status")) == "retired" {
                retired_roles.insert(name.clone());
            }
            let parent = value_string(st.get("parent_name"));
            if !parent.is_empty() {
                parent_of.insert(name.clone(), parent);
            }
        }

        // Flatten ancestor chains — cycle-safe (in-progress set), missing-parent
        // safe (loop ends), retired ancestors excluded from the resolved chain.
        let mut ancestors: HashMap<String, Vec<String>> = HashMap::new();
        for role in parent_of.keys() {
            let mut chain: Vec<String> = Vec::new();
            let mut seen: HashSet<String> = HashSet::new();
            seen.insert(role.clone());
            let mut cur = role.clone();
            while let Some(parent) = parent_of.get(&cur) {
                if seen.contains(parent) {
                    break; // cycle guard
                }
                seen.insert(parent.clone());
                if !retired_roles.contains(parent) {
                    chain.push(parent.clone());
                }
                cur = parent.clone();
            }
            ancestors.insert(role.clone(), chain);
        }

        // Agents: auth_identity_id -> role_name, active only.
        let mut role_for_auth: HashMap<String, String> = HashMap::new();
        for st in rt.all("Agent") {
            if value_string(st.get("status")) == "retired" {
                continue;
            }
            let auth = value_string(st.get("auth_identity_id"));
            let role = value_string(st.get("role_name"));
            if auth.is_empty() || role.is_empty() {
                continue;
            }
            role_for_auth.insert(auth, role); // last-wins on duplicate auth id
        }

        AclReadModel {
            role_for_auth,
            ancestors,
            retired_roles,
        }
    }

    /// The role_name bound to an authenticated identity, if any (active agents).
    pub fn role_for_auth(&self, auth_id: &str) -> Option<&str> {
        self.role_for_auth.get(auth_id).map(|s| s.as_str())
    }

    /// True iff `required_role` is the caller's `held` role or one of its
    /// non-retired ancestors, and `held` itself is not retired. A child role
    /// inherits its parents: Manager(parent Employee) satisfies a command
    /// requiring Employee.
    pub fn role_satisfies(&self, held: &str, required_role: &str) -> bool {
        if self.retired_roles.contains(held) {
            return false;
        }
        if held == required_role {
            return true;
        }
        self.ancestors
            .get(held)
            .map(|chain| chain.iter().any(|r| r == required_role))
            .unwrap_or(false)
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
