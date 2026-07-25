//! authz — the authorization ENTRY layer : record_violation_internal (the
//! Governance::Violation audit row via the ungated path), authorize_entry
//! (the one before-gate every dispatch + gated query enters through), and
//! capture_auth (the principal capture off the reserved actor_* keys). The
//! per-check verdicts live in auth_gates.rs — one concern, two <=200 casks.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 2).
//!
//! [antibody-exempt: rust/src/runtime/authz.rs — transitional : enforcement
//!  reads the ACL/Authorization bluebooks ; migrates further into declaration
//!  as the authz surface becomes fully bluebook-driven.]

use super::*;

impl Runtime {
    /// Record an authorization denial as a `Governance::Violation` via the
    /// UNGATED internal path (`dispatch_impl`, never `Runtime::dispatch`),
    /// so the gate can never recurse. Best-effort: if the Governance domain
    /// is not loaded (a minimal runtime), the denial still stands — we just
    /// don't get an audit row.
    fn record_violation_internal(&mut self, command: &str, gate: &str, cause: &str, reason: &str) {
        let d = crate::clock::now_duration();
        let id = format!("viol_{:x}", (d.subsec_nanos() as u64) ^ d.as_secs());
        let mut attrs: HashMap<String, Value> = HashMap::new();
        attrs.insert("id".to_string(), Value::Str(id));
        attrs.insert("tool_name".to_string(), Value::Str(command.to_string()));
        attrs.insert("reason".to_string(), Value::Str(reason.to_string()));
        attrs.insert("gate".to_string(), Value::Str(gate.to_string()));
        attrs.insert("cause".to_string(), Value::Str(cause.to_string()));
        attrs.insert("occurred_at".to_string(), Value::Str(crate::clock::now_iso()));
        // Record into the FRAMEWORK COLLABORATOR, which always carries the
        // Governance chapter. This used to be `self.dispatch_impl(...)` with the
        // Result discarded : on any runtime that had not merged the Governance
        // conception, the dispatch failed and the denial's audit row was thrown
        // away without a trace. `authorize_pdp_test` boots exactly such a
        // runtime, so every denial it asserts recorded NOTHING.
        //
        // The denial itself always stood — this was never an authorization
        // hole — but "who was refused what, and why" is the entire point of a
        // veto audit, and it was contingent on corpus layout. Still ungated
        // (`dispatch_impl`, never `dispatch`), so recording a denial can never
        // re-enter the gate that produced it.
        let _ = self
            .framework_mut()
            .dispatch_impl("Governance::Violation.Record", attrs);
    }

    /// RBAC gate for an ENTRY door. `dispatch` calls this; the cold one-shot
    /// CLI path (which uses dispatch_deferred + a bespoke pump/drain
    /// sequence) calls it explicitly before dispatching. Records a denial as
    /// a governed Violation via the ungated internal path, returns
    /// Err(Unauthorized) when blocked, and strips the reserved principal
    /// attrs on success so they never reach the command or its event.
    pub fn authorize_entry(
        &mut self,
        command_name: &str,
        attrs: &mut HashMap<String, Value>,
    ) -> Result<(), RuntimeError> {
        // Deploy-floor recovery — NOT an in-gate backdoor. The out-of-band
        // HECKS_GOVERNANCE_OFF escape (the same env the PreToolUse governed-
        // door hook honors) stands the dispatch gates down so a bad auth lock
        // is recoverable. It requires deploy/shell access (the physical floor),
        // never a credential, so a stolen session can't ride it. Covers the
        // gated query path too, since `query` routes through here.
        if std::env::var("HECKS_GOVERNANCE_OFF").is_ok() {
            let cap = self.capture_auth(command_name, attrs);
            self.current_auth = Some(cap);
            attrs.remove(acl_readmodel::KIND_KEY);
            attrs.remove(acl_readmodel::AUTH_KEY);
            return Ok(());
        }
        // Run the registered before-middleware gates in order. The Gate registry
        // (aggregates/storehouse/storehouse.bluebook) is the declared truth —
        // which gate, what order, over which dispatches — and the MiddlewareStack
        // is its runtime projection. Each handler key resolves to an in-process
        // verdict function (`run_gate`), mirroring Storehouse::Primitive.
        // implementation. A Deny aborts and records a governed Violation. Collect
        // the matching (name, handler) first so the &self borrow on the stack is
        // released before the &mut self call to record_violation_internal.
        let gates: Vec<(String, String)> = self
            .middleware
            .before_matching(command_name)
            .map(|e| (e.name.clone(), e.handler.clone()))
            .collect();
        for (gate_name, handler) in gates {
            if let Err(e) = self.run_gate(&handler, command_name, attrs) {
                let (reason, cause) = match &e {
                    RuntimeError::Unauthorized { required, held, cause, .. } => (
                        format!("middleware '{}': requires {}, caller {}", gate_name, required, held),
                        cause.clone(),
                    ),
                    other => (format!("middleware '{}': {:?}", gate_name, other), String::new()),
                };
                self.record_violation_internal(command_name, &gate_name, &cause, &reason);
                return Err(e);
            }
        }
        // Capture the verdict this SUCCESS was admitted under BEFORE stripping
        // the principal — the synchronous Log writer stamps it, so a recorded
        // success carries who acted, in what role, under which policy. Closes the
        // asymmetry : denials already sit in Governance::Violation ; successes
        // used to lose their actor to a hardcoded "system".
        let cap = self.capture_auth(command_name, attrs);
        self.current_auth = Some(cap);
        attrs.remove(acl_readmodel::KIND_KEY);
        attrs.remove(acl_readmodel::AUTH_KEY);
        Ok(())
    }

    /// Build the `CapturedAuth` for a command that just PASSED the entry gates.
    /// System origin -> the `system` actor, admitted by origin. An agent -> its
    /// auth id, its role, and the permit that admitted it (re-evaluated in-memory
    /// over the same live Policy set the gate read ; deterministic within one
    /// dispatch). `allowed` is always true : this runs only past a successful
    /// `authorize_entry`.
    fn capture_auth(
        &self,
        command_name: &str,
        attrs: &HashMap<String, Value>,
    ) -> event_sourcing::CapturedAuth {
        match acl_readmodel::principal_from_attrs(attrs) {
            acl_readmodel::Principal::System => event_sourcing::CapturedAuth {
                actor: "system".to_string(),
                role: String::new(),
                policy_id: "system-origin".to_string(),
                allowed: true,
            },
            acl_readmodel::Principal::Agent { auth_identity_id } => {
                let role = self
                    .acl_read_model
                    .role_for_auth(&auth_identity_id)
                    .unwrap_or("")
                    .to_string();
                let policy_id = self.permit_id_for(&auth_identity_id, &role, command_name);
                event_sourcing::CapturedAuth {
                    actor: auth_identity_id,
                    role,
                    policy_id,
                    allowed: true,
                }
            }
        }
    }

    /// The Policy id that PERMITTED this dispatch — the governability breadcrumb
    /// stamped into the Log's verdict. Re-runs the in-memory policy eval
    /// (deterministic over the live rule set the gate just read) and returns the
    /// first UNCONDITIONAL permit's id : a Policy id, the `command-role:<role>`
    /// implicit permit, or "" when admitted with no rule (e.g. the authorize gate
    /// is not declared). Forbidden / denied dispatches never reach here.
    fn permit_id_for(&self, auth_id: &str, role: &str, command_name: &str) -> String {
        match self.evaluate_policy(auth_id, role, command_name) {
            PolicyOutcome::Permitted { matched } => matched
                .iter()
                .find_map(|m| {
                    let id = m.strip_prefix("permit:")?;
                    if id.contains("(conditional") {
                        None
                    } else {
                        Some(id.to_string())
                    }
                })
                .unwrap_or_default(),
            _ => String::new(),
        }
    }
}
