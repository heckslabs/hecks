//! Runtime Phase-3 reaction delivery — run the impure adapter edge + the
//! policy/PM/driven cascade for a dispatched command result, and drain the
//! reaction outbox to quiescence. GENERATED from codegen/runtime_shape (the
//! `SplitMethod` rows with file `reaction`) by the runtime-as-bluebook
//! strangler file-split. Do NOT hand-edit ; edit the shape + snippets and run
//! `storehouse specialize reaction --output rust/src/runtime/reaction.rs`.
//!
//! Inherent `impl Runtime` methods in a child module ; they reach Runtime's
//! private `resolve_*` / `drain_policies` helpers + the `outbox` field and the
//! pub `driven_adapter_resolver` module through child-module privacy + the
//! `super::*` glob. `react` / `react_ports` are `pub(super)` because mod.rs's
//! dispatch paths call them.
//!
//! [antibody-exempt: rust/src/runtime/reaction.rs — GENERATED output of the
//!  runtime_shape specializer (runtime-as-bluebook strangler file-split,
//!  cluster 4b). The bluebook shape is the source ; this .rs is a golden-gated
//!  build artifact, not hand-written. Retires at the i78 meta-shape.]

use super::*;
use std::collections::HashMap;

impl Runtime {
    /// Phase 3 — run every reaction for one dispatched command result:
    /// the compute/policy/PM cascade, the IO-edge adapter hooks, and the
    /// hecksagon `driven on` adapters. Invoked ONLY by `pump()`, never
    /// inline in the core dispatch — so the mutation step stays single-
    /// aggregate and the reactions are a separate phase.
    pub(super) fn react(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        attrs: &HashMap<String, Value>,
    ) {
        self.resolve_compute_adapters(result, command_name);
        self.drain_policies(result);
        self.resolve_llm_adapters(result, command_name);
        self.resolve_claude_tool_adapters(result, command_name, attrs);
        self.resolve_mcp_adapters(result, command_name, attrs);
        self.resolve_web_tool_adapters(result, command_name, attrs);
        self.resolve_primitive_spawn(result, command_name, attrs, None);
        #[cfg(not(target_arch = "wasm32"))]
        self.resolve_tts_adapters(result, command_name, attrs);
        if let Some(ref event) = result.event {
            let event_clone = event.clone();
            driven_adapter_resolver::resolve_driven_adapters(self, &event_clone);
        }
    }

    /// C3 cutover — the IMPURE hexagonal edge: adapters that talk to the
    /// outside world (compute / llm / claude_tool / mcp / web / process-spawn
    /// / tts). These fire EAGERLY even on the deferred path — they are ports
    /// (a synchronous request/response at the boundary), not aggregate-to-
    /// aggregate domain reactions. Order matches react()'s adapter prefix.
    pub(super) fn react_ports(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        attrs: &HashMap<String, Value>,
    ) {
        self.resolve_compute_adapters(result, command_name);
        self.resolve_llm_adapters(result, command_name);
        self.resolve_claude_tool_adapters(result, command_name, attrs);
        self.resolve_mcp_adapters(result, command_name, attrs);
        self.resolve_web_tool_adapters(result, command_name, attrs);
        self.resolve_primitive_spawn(result, command_name, attrs, None);
        #[cfg(not(target_arch = "wasm32"))]
        self.resolve_tts_adapters(result, command_name, attrs);
    }

    /// Phase 3 — deliver enqueued reactions. Each pending reaction runs
    /// in a phase separate from the command that produced it. Follow-on
    /// commands dispatched inside `react` (policy/PM cascade, driven
    /// adapters) still cascade synchronously via `dispatch_cascade` for
    /// now; flattening those into the outbox too is the next step. The
    /// loop drains to quiescence so eager callers see a settled cascade.
    pub fn pump(&mut self) {
        while let Some(p) = self.outbox.pop_front() {
            self.react(&p.result, &p.command_name, &p.attrs);
        }
    }
}
