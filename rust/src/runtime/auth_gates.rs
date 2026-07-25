//! auth_gates — the before-gate VERDICTS : run_gate (middleware handler ->
//! verdict, fail-closed), service_gate, authenticate_check, authorize_check.
//! The entry layer that calls these lives in authz.rs — one concern, two
//! <=200 casks.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 2).
//!
//! [antibody-exempt: rust/src/runtime/auth_gates.rs — transitional :
//!  enforcement reads the ACL/Authorization bluebooks ; migrates further into
//!  declaration as the authz surface becomes fully bluebook-driven.]

use super::*;

impl Runtime {
    /// Resolve a middleware `handler` lookup key to a before-gate verdict.
    /// `Ok(())` admits the dispatch ; `Err` denies it. An unresolvable handler
    /// FAILS CLOSED (the Gate contract : an attached-but-unresolvable gate must
    /// deny, never silently pass). `handler` is the Storehouse::Primitive
    /// precedent — the bluebook declares the attachment, the runtime owns the
    /// verdict the key names.
    pub(super) fn run_gate(
        &self,
        handler: &str,
        command_name: &str,
        attrs: &HashMap<String, Value>,
    ) -> Result<(), RuntimeError> {
        match handler {
            "authenticate" => self.authenticate_check(command_name, attrs),
            "authorize" => self.authorize_check(command_name, attrs),
            // A check that names a storehouse query (it has a `.`) IS the gate :
            // "it can all be storehouse service". authenticate / authorize
            // are the two conventional shortcuts for the read-model-backed gates ;
            // every OTHER gate is a plain bluebook query, run through the one door.
            fqn if fqn.contains('.') => self.service_gate(fqn, command_name, attrs),
            other => Err(RuntimeError::Unauthorized {
                command: command_name.to_string(),
                required: format!(
                    "a resolvable middleware handler (got unresolvable '{}')",
                    other
                ),
                held: String::new(),
                cause: format!("unresolvable-gate:{}", other),
            }),
        }
    }

    /// A storehouse-service gate — the realization of "a gate is a storehouse
    /// service, not a DSL". The `check` names a QUERY (Domain::Aggregate.
    /// snake_case) ; the runtime runs it READ-ONLY with the caller's principal
    /// (`actor`) and the dispatched `command` as params, and ALLOWS iff the
    /// query returns at least one row — the query expresses the PERMITTED set,
    /// empty means not-permitted means deny. A System origin is admitted by
    /// origin (daemons, cascades, boot), like the built-in gates. No new
    /// grammar : any bluebook query is a gate, declared via Gate.Declare,
    /// resolved through the universal door — convention over configuration.
    pub(super) fn service_gate(
        &self,
        query_fqn: &str,
        command_name: &str,
        attrs: &HashMap<String, Value>,
    ) -> Result<(), RuntimeError> {
        let actor = match acl_readmodel::principal_from_attrs(attrs) {
            acl_readmodel::Principal::System => return Ok(()),
            acl_readmodel::Principal::Agent { auth_identity_id } => auth_identity_id,
        };
        let mut params: HashMap<String, String> = HashMap::new();
        params.insert("actor".to_string(), actor);
        params.insert("command".to_string(), command_name.to_string());
        // The check may be written Aggregate.Query (legible) ; resolve_query
        // matches on the bare query name, so pass the tail after the last `.`.
        let query = query_fqn.rsplit('.').next().unwrap_or(query_fqn);
        // resolve_query returns { aggregate, query, state: [rows] } — the rows
        // are under `state`. ALLOW iff that holds at least one row.
        let result = self.resolve_query(query, &params);
        let permitted = match result.get("state") {
            Some(serde_json::Value::Array(rows)) => !rows.is_empty(),
            Some(serde_json::Value::Object(map)) => !map.is_empty(),
            _ => false,
        };
        if permitted {
            Ok(())
        } else {
            Err(RuntimeError::Unauthorized {
                command: command_name.to_string(),
                required: format!("storehouse-service gate '{}' to permit", query_fqn),
                held: String::new(),
                cause: format!("service-gate-denied:{}", query_fqn),
            })
        }
    }

    /// The `authenticate` gate verdict : admit a dispatch iff its principal is a
    /// known, ACTIVE (verified, non-retired) AuthIdentity. A System origin is
    /// admitted by origin (daemons, cascades, boot) ; an agent principal whose
    /// auth id resolves to no active AuthIdentity FAILS CLOSED. Reads
    /// AuthIdentity state in-memory (never an async query). The gate is
    /// DECLARATION-GATED (not self-seeded), so it costs nothing and enforces
    /// nothing until authn is turned on by declaring a Gate with check
    /// "authenticate" — and the operator must Establish + verify identities
    /// before declaring it, or agent dispatches fail closed.
    pub(super) fn authenticate_check(
        &self,
        command_name: &str,
        attrs: &HashMap<String, Value>,
    ) -> Result<(), RuntimeError> {
        let auth_id = match acl_readmodel::principal_from_attrs(attrs) {
            acl_readmodel::Principal::System => return Ok(()),
            acl_readmodel::Principal::Agent { auth_identity_id } => auth_identity_id,
        };
        let active = self.all("AuthIdentity").into_iter().any(|st| {
            Self::value_field(st.get("status")) == "active"
                && Self::value_field(st.get("id")) == auth_id
        });
        if active {
            Ok(())
        } else {
            Err(RuntimeError::Unauthorized {
                command: command_name.to_string(),
                required: "an active AuthIdentity (authenticate gate)".to_string(),
                held: if auth_id.is_empty() {
                    "<no identity>".to_string()
                } else {
                    auth_id
                },
                cause: "no-active-identity".to_string(),
            })
        }
    }

    /// The `authorize` gate verdict — the externalized PDP (Authorization
    /// context) evaluated IN-PROCESS over the live Policy rule set (read like
    /// the other gates ; no per-dispatch network hop). Cedar-shaped, deny-by-
    /// default, forbid-overrides-permit : map the dispatch to (principal,
    /// action, resource) and ALLOW iff an active, unexpired PERMIT matches and
    /// NO matching FORBID does. System origin admitted by origin. STANDING :
    /// self-seeded ON at every boot (`hydrate_middleware`) unless a Gate named
    /// "authorize" is declared, so the door is deny-by-default from boot. A
    /// command's own declared `role` is an IMPLICIT PERMIT for a caller of
    /// that role, so `role "System"` enforces with no Policy authored ; Policy
    /// is the OVERRIDE (permit another role ; forbid the declared one).
    /// FRONTIER : a PERMIT applies only when unconditional (condition "-") ; a
    /// conditional FORBID is treated as unconditional-deny (fail-closed) until
    /// the `when` grammar lands.
    pub(super) fn authorize_check(
        &self,
        command_name: &str,
        attrs: &HashMap<String, Value>,
    ) -> Result<(), RuntimeError> {
        // GATE-side System admit : returns BEFORE the shared eval core, so the
        // operator (System) is admitted by origin regardless of policy. The
        // `explain` dry path deliberately does NOT short-circuit System (it
        // shows what policy WOULD do for any subject). This short-circuit MUST
        // stay here, never inside evaluate_policy — the lockout proof rests on
        // origin-admit preceding the policy loop.
        let auth_id = match acl_readmodel::principal_from_attrs(attrs) {
            acl_readmodel::Principal::System => return Ok(()),
            acl_readmodel::Principal::Agent { auth_identity_id } => auth_identity_id,
        };
        let role = self
            .acl_read_model
            .role_for_auth(&auth_id)
            .unwrap_or("")
            .to_string();
        let held = if auth_id.is_empty() {
            "<no identity>".to_string()
        } else {
            auth_id.clone()
        };
        match self.evaluate_policy(&auth_id, &role, command_name) {
            PolicyOutcome::Permitted { .. } => Ok(()),
            PolicyOutcome::Forbidden { policy_id, .. } => Err(RuntimeError::Unauthorized {
                command: command_name.to_string(),
                required: format!("not forbidden by authorization policy '{}'", policy_id),
                held,
                cause: format!("forbid:{}", policy_id),
            }),
            PolicyOutcome::DeniedByDefault { .. } => Err(RuntimeError::Unauthorized {
                command: command_name.to_string(),
                required: "an authorization permit (deny-by-default)".to_string(),
                held,
                cause: "deny-by-default".to_string(),
            }),
        }
    }

}
