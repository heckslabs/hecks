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
