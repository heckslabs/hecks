    /// C3 cutover — the IMPURE hexagonal edge: adapters that talk to the
    /// outside world (compute / llm / claude_tool / mcp / web / process-spawn).
    /// These fire EAGERLY even on the deferred path — they are ports
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
    }
