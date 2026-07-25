//! policy_eval — the authorization POLICY core : evaluate_policy (deny-by-
//! default, forbid-overrides-permit over the Authorization::Policy rules),
//! explain_authorization (the dry path), value_field, and the middleware/ACL
//! hydration pair (hydrate_middleware, rehydrate_acl). The gates that CALL
//! these live in authz.rs / auth_gates.rs.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/policy_eval.rs — transitional :
//!  evaluates the Authorization/ACL bluebooks ; migrates further into
//!  declaration as the authz surface becomes fully bluebook-driven.]

use super::*;

impl Runtime {
    /// The policy-eval CORE — shared by `authorize_check` (the live gate) and
    /// `explain_authorization` (the dry path). Evaluates the active, unexpired
    /// Policy rules for (auth_id, role) over (action = command_name, resource =
    /// the aggregate), deny-by-default, forbid-overrides-permit. Returns the
    /// verdict + the matched rule descriptions.
    ///
    /// NO System-origin short-circuit lives here — the CALLER decides : the gate
    /// admits System by origin BEFORE calling this ; explain calls it for any
    /// subject so it can show the true policy verdict. Putting the short-circuit
    /// here would break BOTH (a vacuous explain for System AND the lockout proof
    /// moving off the gate side).
    pub(super) fn evaluate_policy(&self, auth_id: &str, role: &str, command_name: &str) -> PolicyOutcome {
        // FQN-resolve the action to the SAME canonical target the dispatch path
        // would execute, then match the policy against the resolution-derived
        // form SET — so a BARE and a fully-qualified dispatch of one command
        // yield the IDENTICAL verdict. Closes the namespace-forbid bypass
        // (SECURITY-gate-matches-raw-not-fqn, 2026-07-03) : matching the raw
        // caller string let `forbid Pizzas::Order.*` be escaped by the bare
        // verb. `resource` is aligned to the same canonical the same way.
        // [antibody-exempt: rust/src/runtime/mod.rs (evaluate_policy) —
        //  kernel-floor authz gate, security fix, authorized by Chris 2026-07-03]
        let canon = command_dispatch::canonical_action(self, command_name);
        let now = crate::clock::now_iso();
        let mut matched: Vec<String> = Vec::new();
        let mut permitted = false;
        for st in self.all("Policy") {
            if Self::value_field(st.get("status")) != "active" {
                continue;
            }
            let exp = Self::value_field(st.get("expires_at"));
            if exp != "-" && !exp.is_empty() && exp <= now {
                continue; // expired
            }
            let p = Self::value_field(st.get("principal"));
            let a = Self::value_field(st.get("action"));
            let r = Self::value_field(st.get("resource"));
            let p_match = p == "*" || p == auth_id || (!role.is_empty() && p == role);
            let a_match = canon
                .action_forms
                .iter()
                .any(|f| middleware::pattern_matches(&a, f));
            let r_match = canon
                .resource_forms
                .iter()
                .any(|f| middleware::pattern_matches(&r, f));
            if !(p_match && a_match && r_match) {
                continue;
            }
            let id = Self::value_field(st.get("id"));
            match Self::value_field(st.get("effect")).as_str() {
                "forbid" => {
                    // forbid overrides permit, regardless of order
                    matched.push(format!("forbid:{}", id));
                    return PolicyOutcome::Forbidden { policy_id: id, matched };
                }
                "permit" => {
                    if Self::value_field(st.get("condition")) == "-" {
                        permitted = true;
                        matched.push(format!("permit:{}", id));
                    } else {
                        // FRONTIER : a conditional permit matches but is INERT
                        // until the `when` grammar lands (Phase 5).
                        matched.push(format!("permit:{} (conditional, inert)", id));
                    }
                }
                _ => {}
            }
        }
        // IMPLICIT PERMIT from the command's own declared role. Reached only
        // PAST the loop, so a matching Forbid already returned (it wins) and
        // any explicit Permit already set `permitted`. A caller acting AS the
        // command's declared role is admitted with no policy authored, so
        // `role "System"` MEANS something ; Policy stays the OVERRIDE. Match
        // EXACTLY (as the `p == role` match above) ; `declared_role` rode in
        // on the same resolution as `action_forms`, so it is the executing
        // command's role.
        if !permitted {
            if let Some(cmd_role) = canon.declared_role.as_deref() {
                if !role.is_empty() && !cmd_role.is_empty() && cmd_role == role {
                    permitted = true;
                    matched.push(format!("permit:command-role:{}", cmd_role));
                }
            }
        }
        if permitted {
            PolicyOutcome::Permitted { matched }
        } else {
            PolicyOutcome::DeniedByDefault { matched }
        }
    }

    /// The `explain` dry path — evaluate policy for a SUBJECT principal over an
    /// action and return the verdict + matched rules, WITHOUT dispatching and
    /// WITHOUT the System-origin short-circuit (so it shows the true policy
    /// verdict even for a System subject ; the live gate's origin-admit is NOTED,
    /// not applied). Read-only ; the CALLER's access is gated by the query path,
    /// so an agent cannot enumerate policy through explain.
    pub(crate) fn explain_authorization(&self, subject_auth_id: &str, action: &str) -> serde_json::Value {
        let role = self
            .acl_read_model
            .role_for_auth(subject_auth_id)
            .unwrap_or("")
            .to_string();
        let (verdict, matched) = match self.evaluate_policy(subject_auth_id, &role, action) {
            PolicyOutcome::Permitted { matched } => ("permit", matched),
            PolicyOutcome::Forbidden { matched, .. } => ("forbid", matched),
            PolicyOutcome::DeniedByDefault { matched } => ("deny-by-default", matched),
        };
        serde_json::json!({
            "query": "explain",
            "subject": subject_auth_id,
            "role": role,
            "action": action,
            "verdict": verdict,
            "matched_rules": matched,
            "note": "policy verdict for the SUBJECT ; at the live gate a System-origin caller is admitted by origin regardless of this verdict",
        })
    }

    /// Read a single-value aggregate field as a plain String — the coercion the
    /// RBAC read-model does over Role/Agent state (raw Str, a Map with a `value`
    /// key, or Null -> empty). Shared by the Gate-projection and authenticate
    /// gate reads ; lives here so this exempt kernel file owns it and
    /// acl_readmodel stays untouched.
    pub(super) fn value_field(v: &Value) -> String {
        match v {
            Value::Str(s) => s.clone(),
            Value::Map(m) => m.get("value").map(Self::value_field).unwrap_or_default(),
            Value::Null => String::new(),
            other => format!("{}", other),
        }
    }

    /// Hydrate the middleware stack — the runtime projection of the Gate registry
    /// (aggregates/storehouse/storehouse.bluebook), the way the Procfile is the
    /// projection of declared Drivers. Reads every declared, active Storehouse::Gate
    /// record (via `all`, the same path the RBAC read-model reads Agent) and
    /// turns each into a MiddlewareEntry. If NO Gate is declared yet — the
    /// `gating on dispatch` parser surface that mints them is a sibling kernel
    /// card — it FALLS BACK to self-seeding the standing authorize (PDP) before-
    /// gate, so the door stays gated regardless of boot-time establishment
    /// (unwired at a real boot today, inbox/boot-establishment-not-wired-
    /// FINDING.md). Called at boot after the RBAC read-model is hydrated, and
    /// re-run when a Gate lifecycle event applies.
    pub(super) fn hydrate_middleware(&mut self) {
        let mut entries: Vec<middleware::MiddlewareEntry> = Vec::new();
        for st in self.all("Gate") {
            if Self::value_field(st.get("status")) == "retired" {
                continue;
            }
            let name = Self::value_field(st.get("name"));
            if name.is_empty() {
                continue;
            }
            let pattern = {
                let p = Self::value_field(st.get("pattern"));
                if p.is_empty() { "*".to_string() } else { p }
            };
            let order = Self::value_field(st.get("order")).parse::<i64>().unwrap_or(100);
            entries.push(middleware::MiddlewareEntry {
                name,
                phase: middleware::Phase::parse(&Self::value_field(st.get("phase"))),
                handler: Self::value_field(st.get("check")),
                pattern,
                order,
            });
        }
        // The authorize (PDP) gate is STANDING : self-seed it unless a Gate of
        // that name is explicitly declared (so declaring OTHER gates never drops
        // authz). Once a Gate named "authorize" is declared, the declared one wins
        // and this self-seed is skipped. Deny-by-default with zero policies ;
        // System is admitted by origin (authorize_check), so the operator is never
        // locked out (fail-closed for future non-System dispatchers, not the floor).
        if !entries.iter().any(|e| e.name == "authorize") {
            entries.push(middleware::MiddlewareEntry {
                name: "authorize".to_string(),
                phase: middleware::Phase::Before,
                handler: "authorize".to_string(),
                pattern: "*".to_string(),
                order: 20,
            });
        }
        self.middleware = middleware::MiddlewareStack::from_entries(entries);
    }

    /// Re-hydrate the RBAC read-model from current RoleAssignment state.
    /// Called after the boot-completion cascade settles (run_boot/complete.rs) :
    /// the entry-dispatch trigger in `dispatch` cannot see cascade-authored
    /// assignments (the entry aggregate is BootRun, not RoleAssignment).
    pub fn rehydrate_acl(&mut self) {
        let m = acl_readmodel::AclReadModel::hydrate(self);
        self.acl_read_model = m;
    }

}
