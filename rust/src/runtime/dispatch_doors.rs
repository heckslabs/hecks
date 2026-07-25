//! dispatch_doors — the thin dispatch FRONT DOORS : `dispatch` (the gated
//! synchronous entry every caller uses) and `dispatch_deferred` (the C3
//! deferred variant). Both funnel to dispatch_core::dispatch_impl — no
//! logic lives here, only the public doorway.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/dispatch_doors.rs — kernel-floor
//!  dispatch doorway, relocated verbatim from mod.rs blanket.]

use super::*;

impl Runtime {
    pub fn dispatch(
        &mut self,
        command_name: &str,
        mut attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        // RBAC authorization gates the ENTRY dispatch (not cascades, which
        // use dispatch_cascade). Records a denial as a governed Violation
        // and strips the reserved principal attrs on success. The cold
        // one-shot CLI path (dispatch_deferred) calls authorize_entry too.
        self.authorize_entry(command_name, &mut attrs)?;
        // Structural cutover : `dispatch` IS the async outbox path. The core
        // mutation touches ONE aggregate ; cross-aggregate reactions go to the
        // outbox and are delivered by the pump as SEPARATE transactions, then
        // the cycle guard resets. It settles in-process (pump before return) so
        // callers still see a settled cascade — but no reaction ever runs
        // inline with the command. Roots without the CascadeRun outbox fall
        // back to the in-memory pump (== the prior synchronous react), so
        // behaviour is preserved there. Synchronous-between-aggregates is now
        // structurally unrepresentable : there is no inline-reaction path left.
        let r = self.dispatch_impl(command_name, attrs)?;
        self.pump_outbox();
        self.pump();
        self.policy_engine.reset_in_flight();
        // Refresh the RBAC read-model when a RoleAssignment lifecycle command
        // applied — keyed off the RESOLVED aggregate type, so it fires for
        // bare- and qualified-name dispatch alike (a bare "Assign" carries no
        // FQN prefix). An Assign/Retire is reflected on the next gate. NOTE :
        // this sees ENTRY dispatches only — cascade-authored assignments (the
        // boot roster) are covered by the post-settle `rehydrate_acl` in
        // run_boot/complete.rs and by boot-time hydration in boot_with_*.
        if r.aggregate_type == "RoleAssignment" {
            let m = acl_readmodel::AclReadModel::hydrate(self);
            self.acl_read_model = m;
        }
        // Re-hydrate the middleware stack when a Gate lifecycle command
        // applied — a Declare/Retire is reflected on the next dispatch's
        // gates, so the door is driven by the live Gate registry.
        if r.aggregate_type == "Gate" {
            self.hydrate_middleware();
        }
        Ok(r)
    }

    /// Phase 3 — enqueue a command's reactions WITHOUT running the pump.
    /// The core mutation touches ONE aggregate and returns; the cross-
    /// aggregate reactions sit in the outbox until `pump()` delivers each
    /// as its own phase. Proves the async seam: a sibling aggregate is
    /// unchanged after this returns and only changes once `pump()` runs.
    pub fn dispatch_deferred(
        &mut self,
        command_name: &str,
        attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        self.dispatch_impl(command_name, attrs)
    }
}
