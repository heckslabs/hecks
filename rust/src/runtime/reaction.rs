//! Runtime Phase-3 reaction delivery — run the impure adapter edge + the
//! policy/PM/driven cascade for a dispatched command result, and drain the
//! reaction outbox to quiescence.
//!
//! Inherent `impl Runtime` methods in a child module ; they reach Runtime's
//! private `resolve_*` / `drain_policies` helpers + the `outbox` field and the
//! pub `driven_adapter_resolver` module through child-module privacy + the
//! `super::*` glob. `react` / `react_ports` are `pub(super)` because mod.rs's
//! dispatch paths call them.
//!
//! [antibody-exempt: rust/src/runtime/reaction.rs — hand-written runtime
//!  kernel-floor. Was a codegen/runtime_shape artifact ; the shape was retired
//!  2026-06-27 — a .bluebook that only re-emitted imperative Rust captures no
//!  domain, so the runtime kernel is hand-maintained Rust like mod.rs.]

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
        #[cfg(not(target_arch = "wasm32"))]
        self.resolve_web_tool_adapters(result, command_name, attrs);
        self.resolve_primitive_compute(result, command_name, attrs);
        self.resolve_primitive_mcp(result, command_name, attrs);
        self.resolve_primitive_spawn(result, command_name, attrs, None);
        self.resolve_exec_adapters(result, command_name, attrs);
        if let Some(ref event) = result.event {
            let event_clone = event.clone();
            driven_adapter_resolver::resolve_driven_adapters(self, &event_clone);
        }
    }

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
        #[cfg(not(target_arch = "wasm32"))]
        self.resolve_web_tool_adapters(result, command_name, attrs);
        self.resolve_primitive_compute(result, command_name, attrs);
        self.resolve_primitive_mcp(result, command_name, attrs);
        self.resolve_primitive_spawn(result, command_name, attrs, None);
        self.resolve_exec_adapters(result, command_name, attrs);
    }

    /// `:exec` adapter resolver — the HECKSAGON-FIRST impure edge that runs a
    /// program when a command completes. Sibling of the other react_ports
    /// resolvers, but routes through the SINGLE `Process.Spawn` primitive
    /// (`resolve_primitive_spawn`) rather than a bespoke per-family executor :
    /// `adapter :exec, command:, exec:, result_into:` is SUGAR over Process.Spawn.
    /// The hecksagon DECLARES the impure edge ; the one spawn primitive RUNS it.
    /// Matches every `:exec` IoAdapter whose `command:` option equals the just-
    /// dispatched `Aggregate.Command`, firing the spawn with cmd=exec,
    /// result_into, and the originating invocation id as the cascade join key.
    /// Restores the pre-bacc0692f hecksagon surface WITHOUT the retired
    /// `resolve_exec_adapters` bespoke executor (the spawn is the one primitive).
    fn resolve_exec_adapters(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        _dispatch_attrs: &HashMap<String, Value>,
    ) {
        if self.hecksagons.is_empty() {
            return;
        }
        // The command portion is everything after "{aggregate_type}." in the
        // dispatched command_name — preserving ENTITY-SCOPED command names
        // (File.Move, Directory.Remove) so they do not collide on a bare last
        // segment (File.Remove + Directory.Remove both end ".Remove"). Falls
        // back to the last segment when the aggregate prefix is absent.
        let agg_prefix = format!("{}.", result.aggregate_type);
        let command_part = command_name
            .rfind(&agg_prefix)
            .map(|i| &command_name[i + agg_prefix.len()..])
            .unwrap_or_else(|| command_name.rsplit('.').next().unwrap_or(command_name));
        let target = format!("{}.{}", result.aggregate_type, command_part);
        let matched: Vec<(String, Option<String>)> = self
            .hecksagons
            .iter()
            .flat_map(|h| h.io_adapters.iter())
            .filter(|a| a.kind == "exec")
            .filter_map(|a| {
                let mut cmd: Option<String> = None;
                let mut exec: Option<String> = None;
                let mut result_into: Option<String> = None;
                for (k, v) in &a.options {
                    match k.as_str() {
                        "command" => cmd = Some(strip_quotes_or_colon(v)),
                        "exec" => exec = Some(strip_quotes_or_colon(v)),
                        "result_into" => result_into = Some(strip_quotes_or_colon(v)),
                        _ => {}
                    }
                }
                match (cmd, exec) {
                    (Some(c), Some(e)) if c == target => Some((e, result_into)),
                    _ => None,
                }
            })
            .collect();
        if matched.is_empty() {
            return;
        }
        let invocation_id = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .and_then(|s| s.fields.get("id").map(|v| v.to_string()))
            .unwrap_or_else(|| result.aggregate_id.clone());
        for (exec, result_into) in &matched {
            let mut attrs: HashMap<String, Value> = HashMap::new();
            attrs.insert("cmd".to_string(), Value::Str(exec.clone()));
            if let Some(ri) = result_into {
                if !ri.is_empty() {
                    attrs.insert("result_into".to_string(), Value::Str(ri.clone()));
                }
            }
            attrs.insert("id".to_string(), Value::Str(invocation_id.clone()));
            let synth = CommandResult {
                aggregate_id: invocation_id.clone(),
                aggregate_type: "Process".to_string(),
                event: None,
                deltas: Vec::new(),
            };
            self.resolve_primitive_spawn(&synth, "Process.Spawn", &attrs, None);
        }
    }

    /// `:compute` adapter resolver — the HECKSAGON-FIRST local-function edge,
    /// SUGAR over the `Primitive::Compute.Invoke` primitive exactly as `:exec`
    /// is sugar over `Process.Spawn`. The hecksagon DECLARES the edge
    /// (`adapter :compute, function:, trigger_on:, response_into:`) ; the one
    /// compute primitive RUNS it. Replaces the bespoke
    /// `resolve_compute_adapters_with_excluded` resolver retired from
    /// runtime/mod.rs (shrink-mod phase A — the protocol is declared in
    /// primitive.bluebook, only the compute_dispatcher leaf stays imperative).
    /// Chains are preserved : a matched adapter's cascade result re-enters this
    /// resolver, bounded by the `fired` exclude-set exactly as before.
    pub(super) fn resolve_compute_adapters(
        &mut self,
        result: &CommandResult,
        command_name: &str,
    ) {
        let mut fired: std::collections::HashSet<String> = std::collections::HashSet::new();
        self.resolve_compute_adapters_excluded(result, command_name, &mut fired);
    }

    fn resolve_compute_adapters_excluded(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        fired: &mut std::collections::HashSet<String>,
    ) {
        if self.hecksagons.is_empty() {
            return;
        }
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        let target = format!("{}.{}", result.aggregate_type, bare_command);
        let adapters: Vec<crate::hecksagon_ir::ComputeAdapter> = self
            .hecksagons
            .iter()
            .flat_map(|h| h.compute_adapters.iter())
            .filter(|ca| ca.effective_trigger() == Some(target.as_str()))
            .filter(|ca| !fired.contains(&ca.name))
            .cloned()
            .collect();
        if adapters.is_empty() {
            return;
        }
        // The function's attrs are the upstream aggregate's state fields,
        // string-shaped — the same projection the retired resolver built.
        let mut attrs: HashMap<String, String> = HashMap::new();
        if let Some(s) = self.find(&result.aggregate_type, &result.aggregate_id) {
            for (k, v) in &s.fields {
                attrs.insert(k.clone(), v.to_string());
            }
        }
        for adapter in &adapters {
            fired.insert(adapter.name.clone());
            let inner = self.run_compute_invoke(
                &adapter.name,
                &adapter.function_name,
                &attrs,
                adapter.response_into_target.as_deref(),
                adapter.response_into_attr.as_deref(),
                &result.aggregate_type,
                &result.aggregate_id,
            );
            // Recurse so a chain of :compute adapters (A's cascade target
            // triggering B) fires end-to-end before the LLM hook lands —
            // same contract as the retired resolver, bounded by `fired`.
            if let Some(inner_result) = inner {
                let chained = adapter.response_into_target.clone().unwrap_or_default();
                self.resolve_compute_adapters_excluded(&inner_result, &chained, fired);
            }
        }
    }

    /// The generic `Compute.Invoke` primitive hook — sibling of
    /// `resolve_primitive_spawn`. Fires when a `Compute.Invoke` command is
    /// dispatched (a bluebook policy or the :compute sugar above composed it) :
    /// consults the PrimitiveRegistry (audit trail), reads the declared
    /// signature (function_name / response_into_target / response_into_attr —
    /// matching the seeded Storehouse::Primitive record), and runs the invoke
    /// through the one engine below. The bluebook IS the contract — anything
    /// that dispatches `Compute.Invoke` runs the function.
    fn resolve_primitive_compute(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        dispatch_attrs: &HashMap<String, Value>,
    ) {
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        if result.aggregate_type != "Compute" || bare_command != "Invoke" {
            return;
        }
        let registry_key = format!("{}.{}", result.aggregate_type, bare_command);
        match self.primitive_registry.lookup(&registry_key) {
            Some(spec) => {
                println!(
                    "[{}] [primitive:registry] routed name={} kind={} impl={}",
                    storehouse_log::now_iso8601(),
                    spec.name, spec.kind, spec.implementation,
                );
            }
            None => {
                println!(
                    "[{}] [primitive:registry] miss name={} — Storehouse::Primitive declaration absent",
                    storehouse_log::now_iso8601(),
                    registry_key,
                );
            }
        }
        let function = match dispatch_attrs.get("function_name").map(|v| v.to_string()) {
            Some(f) if !f.is_empty() => f,
            _ => {
                println!(
                    "[{}] [primitive:compute] skipped — missing function_name attr",
                    storehouse_log::now_iso8601(),
                );
                return;
            }
        };
        let result_into = dispatch_attrs.get("response_into_target").map(|v| v.to_string());
        let result_attr = dispatch_attrs.get("response_into_attr").map(|v| v.to_string());
        let invocation_id = dispatch_attrs
            .get("id")
            .map(|v| v.to_string())
            .unwrap_or_else(|| result.aggregate_id.clone());
        // The function's attrs are the dispatch attrs, string-shaped.
        let fn_attrs: HashMap<String, String> = dispatch_attrs
            .iter()
            .map(|(k, v)| (k.clone(), v.to_string()))
            .collect();
        let _ = self.run_compute_invoke(
            "compute_invoke",
            &function,
            &fn_attrs,
            result_into.as_deref(),
            result_attr.as_deref(),
            &result.aggregate_type,
            &invocation_id,
        );
    }

    /// The ONE compute engine both paths share — the sugar (hecksagon
    /// `:compute` bindings) and the primitive hook (direct `Compute.Invoke`
    /// dispatches) meet here. Resolves the function through the kernel-floor
    /// `compute_dispatcher` leaf (reused unchanged — the only imperative Rust
    /// on this path), then chains the returned text into the response target
    /// via `dispatch_cascade` so depth + cycle protection apply. Skipped
    /// outcomes (unset / unregistered function) fire no cascade, and a
    /// missing / malformed target skips the chain after the function ran —
    /// both exactly the retired resolver's contract.
    #[allow(clippy::too_many_arguments)]
    fn run_compute_invoke(
        &mut self,
        adapter_name: &str,
        function_name: &str,
        fn_attrs: &HashMap<String, String>,
        result_into: Option<&str>,
        result_attr: Option<&str>,
        upstream_type: &str,
        upstream_id: &str,
    ) -> Option<CommandResult> {
        let adapter = crate::hecksagon_ir::ComputeAdapter {
            name: adapter_name.to_string(),
            function_name: function_name.to_string(),
            trigger_on: None,
            response_into_target: result_into.map(|s| s.to_string()),
            response_into_attr: result_attr.map(|s| s.to_string()),
        };
        let state_clone: Option<AggregateState> =
            self.find(upstream_type, upstream_id).cloned();
        let data_dir = self.data_dir.clone();
        let outcome = compute_dispatcher::call(
            &adapter,
            state_clone.as_ref(),
            fn_attrs,
            data_dir.as_deref(),
        );
        let result_data = match outcome {
            compute_dispatcher::ComputeOutcome::Completed(r) => r,
            compute_dispatcher::ComputeOutcome::Skipped(_) => return None,
        };
        let (target_agg, target_cmd) = adapter
            .response_into_target
            .as_deref()
            .and_then(compute_dispatcher::split_target)?;
        let attr_name = match adapter.response_into_attr.as_deref() {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => return None,
        };
        let mut chain_attrs: HashMap<String, Value> = HashMap::new();
        chain_attrs.insert(attr_name, Value::Str(result_data.response_text.clone()));
        let cmd_qualified = format!("{}.{}", target_agg, target_cmd);
        let cascade_outcome = command_dispatch::dispatch_cascade(
            self,
            &cmd_qualified,
            chain_attrs,
            upstream_type,
            upstream_id,
        );
        storehouse_log::cascade_step(
            &cmd_qualified,
            upstream_id,
            cascade_outcome.is_ok(),
        );
        cascade_outcome.ok()
    }

    /// `:mcp` adapter resolver — the HECKSAGON-FIRST MCP tool-call edge,
    /// SUGAR over the `Primitive::McpTool.Invoke` primitive exactly as `:exec`
    /// is sugar over `Process.Spawn` and `:compute` over `Compute.Invoke`.
    /// The hecksagon DECLARES the edge (`adapter :mcp, command:, server:,
    /// tool:, args:, result_into:`) ; the sugar's COMPOSITION step is the
    /// `{attr}` placeholder substitution against upstream state ∪ dispatch
    /// attrs (the primitive receives the FINAL arguments, never a template) ;
    /// the one mcp primitive RUNS the call. Replaces the bespoke
    /// `resolve_mcp_adapters` resolver retired from runtime/mod.rs
    /// (shrink-mod phase A).
    pub(super) fn resolve_mcp_adapters(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        dispatch_attrs: &HashMap<String, Value>,
    ) {
        if self.hecksagons.is_empty() {
            return;
        }
        let debug = std::env::var("HECKS_DEBUG_MCP").is_ok();
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        let target = format!("{}.{}", result.aggregate_type, bare_command);
        let matched: Vec<(String, String, String, Option<String>)> = self
            .hecksagons
            .iter()
            .flat_map(|h| h.io_adapters.iter())
            .filter(|a| a.kind == "mcp")
            .filter_map(|a| {
                let mut cmd: Option<String> = None;
                let mut server: Option<String> = None;
                let mut tool: Option<String> = None;
                let mut args: String = String::new();
                let mut result_into: Option<String> = None;
                for (k, v) in &a.options {
                    match k.as_str() {
                        "command" => cmd = Some(strip_quotes_or_colon(v)),
                        "server" => server = Some(strip_quotes_or_colon(v)),
                        "tool" => tool = Some(strip_quotes_or_colon(v)),
                        "args" => args = strip_quotes_or_colon(v),
                        "result_into" => result_into = Some(strip_quotes_or_colon(v)),
                        _ => {}
                    }
                }
                match (cmd, server, tool) {
                    (Some(c), Some(s), Some(t)) if binding_command_tail(&c) == target.as_str() => {
                        Some((s, t, args, result_into))
                    }
                    _ => None,
                }
            })
            .collect();
        if debug {
            eprintln!(
                "[mcp:debug] resolve cmd={} target={} matched={}",
                command_name, target, matched.len()
            );
        }
        if matched.is_empty() {
            return;
        }
        // Composition : substitution attrs are upstream state ∪ dispatch attrs
        // — the same projection the retired resolver built.
        let mut attrs: HashMap<String, String> = HashMap::new();
        if let Some(s) = self.find(&result.aggregate_type, &result.aggregate_id) {
            for (k, v) in &s.fields {
                attrs.insert(k.clone(), v.to_string());
            }
        }
        for (k, v) in dispatch_attrs {
            attrs.insert(k.clone(), v.to_string());
        }
        let invocation_id = attrs
            .get("id")
            .cloned()
            .unwrap_or_else(|| result.aggregate_id.clone());
        for (server, tool, args_raw, result_into) in &matched {
            let args_value: serde_json::Value = if args_raw.is_empty() {
                serde_json::Value::Object(Default::default())
            } else {
                match serde_json::from_str(args_raw) {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!(
                            "[mcp:warn] adapter for {} :args is not JSON ({}) — skipping",
                            target, e
                        );
                        continue;
                    }
                }
            };
            let args_substituted = mcp_dispatcher::substitute_value(args_value, &attrs);
            self.run_mcp_invoke(
                server,
                tool,
                &args_substituted,
                result_into.as_deref(),
                &invocation_id,
                &target,
                &result.aggregate_type,
                &result.aggregate_id,
            );
        }
    }

    /// The generic `McpTool.Invoke` primitive hook — sibling of
    /// `resolve_primitive_spawn` / `resolve_primitive_compute`. Fires when an
    /// `McpTool.Invoke` command is dispatched : consults the PrimitiveRegistry
    /// (audit trail), reads the declared signature (server / tool / arguments
    /// — matching the seeded Storehouse::Primitive record — plus result_into),
    /// parses the FINAL arguments JSON, and runs the call through the one
    /// engine below. The bluebook IS the contract.
    fn resolve_primitive_mcp(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        dispatch_attrs: &HashMap<String, Value>,
    ) {
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        if result.aggregate_type != "McpTool" || bare_command != "Invoke" {
            return;
        }
        let registry_key = format!("{}.{}", result.aggregate_type, bare_command);
        match self.primitive_registry.lookup(&registry_key) {
            Some(spec) => {
                println!(
                    "[{}] [primitive:registry] routed name={} kind={} impl={}",
                    storehouse_log::now_iso8601(),
                    spec.name, spec.kind, spec.implementation,
                );
            }
            None => {
                println!(
                    "[{}] [primitive:registry] miss name={} — Storehouse::Primitive declaration absent",
                    storehouse_log::now_iso8601(),
                    registry_key,
                );
            }
        }
        let (server, tool) = match (
            dispatch_attrs.get("server").map(|v| v.to_string()),
            dispatch_attrs.get("tool").map(|v| v.to_string()),
        ) {
            (Some(s), Some(t)) if !s.is_empty() && !t.is_empty() => (s, t),
            _ => {
                println!(
                    "[{}] [primitive:mcp] skipped — missing server/tool attr",
                    storehouse_log::now_iso8601(),
                );
                return;
            }
        };
        let arguments_raw = dispatch_attrs
            .get("arguments")
            .map(|v| v.to_string())
            .unwrap_or_default();
        let args_value: serde_json::Value = if arguments_raw.is_empty() {
            serde_json::Value::Object(Default::default())
        } else {
            match serde_json::from_str(&arguments_raw) {
                Ok(v) => v,
                Err(e) => {
                    println!(
                        "[{}] [primitive:mcp] skipped — arguments is not JSON ({})",
                        storehouse_log::now_iso8601(),
                        e
                    );
                    return;
                }
            }
        };
        let result_into = dispatch_attrs.get("result_into").map(|v| v.to_string());
        let invocation_id = dispatch_attrs
            .get("id")
            .map(|v| v.to_string())
            .unwrap_or_else(|| result.aggregate_id.clone());
        let target = registry_key;
        self.run_mcp_invoke(
            &server,
            &tool,
            &args_value,
            result_into.as_deref(),
            &invocation_id,
            &target,
            &result.aggregate_type,
            &result.aggregate_id,
        );
    }

    /// The ONE mcp engine both paths share — the sugar (hecksagon `:mcp`
    /// bindings) and the primitive hook (direct `McpTool.Invoke` dispatches)
    /// meet here. A `.world`-declared server routes as an
    /// `mcp_dispatch_requested` event to the harness-side transport (host
    /// only) ; a locally-spawnable server runs through the kernel-floor
    /// `mcp_dispatcher` leaf — reused unchanged, the only imperative Rust on
    /// this path ; a server that is neither logs + skips (the dispatch still
    /// lands). The outcome cascades (id, tool, output, exit_code, ok) into
    /// result_into via `dispatch_cascade` — all exactly the retired
    /// resolver's contract.
    #[allow(clippy::too_many_arguments)]
    fn run_mcp_invoke(
        &mut self,
        server: &str,
        tool: &str,
        args_substituted: &serde_json::Value,
        result_into: Option<&str>,
        invocation_id: &str,
        target: &str,
        upstream_type: &str,
        upstream_id: &str,
    ) {
        let debug = std::env::var("HECKS_DEBUG_MCP").is_ok();
        #[cfg(not(target_arch = "wasm32"))]
        if crate::adapter_resolution::mcp::resolve_world_server(
            self,
            server,
            tool,
            args_substituted,
            result_into,
            invocation_id,
            target,
        ) {
            return;
        }
        if !mcp_dispatcher::server_is_registered(server) {
            eprintln!(
                "[mcp:warn] adapter for {} declares server={} which is neither \
                world-declared nor a spawnable server. Dispatch recorded ; MCP call skipped.",
                target, server
            );
            return;
        }
        let tool_result = mcp_dispatcher::dispatch(server, tool, args_substituted);
        let err_tail = if tool_result.error.is_empty() {
            String::new()
        } else {
            format!(" error={:?}", tool_result.error)
        };
        eprintln!(
            "[mcp:{}] server={} ok={} output={:?}{}",
            tool, server, !tool_result.is_error, tool_result.text, err_tail
        );
        let result_into_target = match result_into {
            Some(s) if !s.is_empty() => s,
            _ => {
                if debug {
                    eprintln!("[mcp:debug] no result_into on adapter — skipping cascade");
                }
                return;
            }
        };
        let output_str = if tool_result.text.is_empty() {
            tool_result.structured.clone()
        } else {
            tool_result.text.clone()
        };
        let mut record_attrs: HashMap<String, Value> = HashMap::new();
        record_attrs.insert("id".to_string(), Value::Str(invocation_id.to_string()));
        record_attrs.insert("tool".to_string(), Value::Str(tool.to_string()));
        record_attrs.insert("output".to_string(), Value::Str(output_str));
        record_attrs.insert("exit_code".to_string(), Value::Int(0));
        record_attrs.insert("ok".to_string(), Value::Bool(!tool_result.is_error));
        let cascade_outcome = command_dispatch::dispatch_cascade(
            self,
            result_into_target,
            record_attrs,
            upstream_type,
            upstream_id,
        );
        storehouse_log::cascade_step(
            result_into_target,
            invocation_id,
            cascade_outcome.is_ok(),
        );
        if debug {
            match &cascade_outcome {
                Ok(_) => eprintln!("[mcp:debug] cascaded into {} ok", result_into_target),
                Err(e) => eprintln!(
                    "[mcp:debug] cascade into {} failed: {:?}",
                    result_into_target, e
                ),
            }
        }
        let _ = cascade_outcome;
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

    /// C2 (transactional outbox) — drain the persistent CascadeRun outbox.
    /// Reads every Active run (status running) and delivers its steps: each
    /// step's command is dispatched as its OWN transaction — separate from
    /// the command that enqueued it, on this (later) tick — then the run is
    /// Completed. Idempotent at the run grain: a Completed run is no longer
    /// Active, so it is never re-delivered. Per-step status/retry awaits the
    /// list-element-update primitive (P0.1). Returns the number of runs
    /// drained. The pump is the ONLY thing that turns an outbox entry into a
    /// sibling mutation — across a transaction boundary, never inline.
    pub fn pump_outbox(&mut self) -> usize {
        if !self.domain.aggregates.iter().any(|a| a.name == "CascadeRun") {
            return 0;
        }
        // Flatten multi-hop cascades : deliver every Active run, RE-RECORD
        // each step's own domain reactions to the outbox, and loop until no
        // Active runs remain. Without the loop + re-record, only level-1
        // reactions fire (a policy on a cascaded event never triggers).
        let mut drained = 0;
        let mut guard = 0;
        loop {
            guard += 1;
            if guard > 10_000 {
                eprintln!("[pump_outbox] cascade guard reached — stopping");
                break;
            }
            // (cascade id, target command, its attrs) — one pending cascade run.
            type PendingRun = (String, String, Vec<(String, String)>);
            let runs: Vec<PendingRun> = self
                .all_qualified(Some("CascadeRun"), "CascadeRun")
                .into_iter()
                .filter(|r| {
                    r.fields.get("status").map(|v| v.to_string()).as_deref() == Some("running")
                })
                .map(|r| {
                    let mut steps: Vec<(i64, String, String)> = vec![];
                    if let Some(Value::List(items)) = r.fields.get("steps") {
                        for it in items {
                            if let Value::Map(m) = it {
                                let cmd = m.get("command").map(|v| v.to_string()).unwrap_or_default();
                                let payload =
                                    m.get("payload").map(|v| v.to_string()).unwrap_or_default();
                                let order = match m.get("order") {
                                    Some(Value::Int(n)) => *n,
                                    _ => 0,
                                };
                                steps.push((order, cmd, payload));
                            }
                        }
                    }
                    steps.sort_by_key(|(o, _, _)| *o);
                    // Phase-4 causation : the run's triggering event id (a
                    // {value} VO or plain string). Empty when the trigger
                    // recorded no Log event.
                    let causation = match r.fields.get("causation") {
                        Some(Value::Map(m)) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
                        Some(v) => v.to_string(),
                        None => String::new(),
                    };
                    (
                        r.id.clone(),
                        causation,
                        steps.into_iter().map(|(_, c, p)| (c, p)).collect(),
                    )
                })
                .collect();
            if runs.is_empty() {
                break;
            }
            for (run_id, causation, steps) in runs {
                // Decode the upstream the run_id carries (type::id::event) so each
                // step dispatches against the ORIGINAL triggering aggregate as
                // upstream — exactly the eager path — letting reference_to(target)
                // resolve in dispatch_inner (e.g. Lease.Reclaim's reference_to(Lease)).
                let mut up = run_id.splitn(3, "::");
                let up_type = up.next().unwrap_or("").to_string();
                let up_id = up.next().unwrap_or("").to_string();
                for (command, payload) in steps {
                    if command.is_empty() {
                        continue;
                    }
                    let step_attrs = parse_payload_attrs(&payload);
                    // Phase-4 causation : prime the causation map from the run's
                    // persisted cause before dispatching, so this step's events
                    // stamp causation_id = the triggering event — even in a
                    // process that did not trigger the run (its in-memory map is
                    // empty). Re-primed per step so an intervening same-instance
                    // step can't shift the cause off the original trigger.
                    if !causation.is_empty() {
                        self.note_last_event(&up_type, &up_id, &causation);
                    }
                    // Deliver the step as its own transaction, and RE-RECORD its
                    // own domain reactions so multi-hop cascades flatten across
                    // iterations (level N -> level N+1).
                    let port_attrs = step_attrs.clone();
                    if let Ok(r) = command_dispatch::dispatch_cascade(
                        self, &command, step_attrs, &up_type, &up_id,
                    ) {
                        self.record_cascade_run(&r);
                        // Fire the impure adapter edge (compute / llm / claude_tool
                        // / mcp / web / spawn) for THIS delivered step, exactly
                        // as the top-level eager dispatch does after record_cascade_run
                        // (mod.rs dispatch -> react_ports). Without this, a PM- or
                        // policy-driven step that targets an :llm adapter (e.g. the
                        // Dream PM's `Dream.ProduceImage` -> :dream_image) mutates
                        // aggregate state but NEVER fires its port when delivered via
                        // the outbox pump — the dream is recorded as a pending step
                        // and the reading is never generated. The bare step command
                        // ("Dream.ProduceImage") is the address resolve_* match on.
                        self.react_ports(&r, &command, &port_attrs);
                    }
                }
                let mut ca = HashMap::new();
                ca.insert("run_id".to_string(), Value::Str(run_id.clone()));
                let _ = command_dispatch::dispatch_cascade(
                    self,
                    "Hecks::Framework::Cascade::CascadeRun::CascadeRun.Complete",
                    ca,
                    "CascadeRun",
                    &run_id,
                );
                drained += 1;
            }
        }
        drained
    }

    /// i750 out-of-process-adapter pump — the SECOND arm of the drain. Where
    /// `pump_outbox` delivers the IN-PROCESS CascadeRun outbox (sibling domain
    /// reactions), this drains the OUT-OF-PROCESS `OutboundEvent` outbox — the
    /// messaging-port analog — by DETACH-spawning the named adapter's handler
    /// program. The handler does the impure async edge (the charge, the
    /// synth+play) in its OWN process, re-enters the domain through the door
    /// (`storehouse <root> Order.Authorize …`), and marks the delivery
    /// delivered. The core NEVER waits : spawn-and-return, exactly the
    /// non-blocking guarantee the OutboundEvent bluebook promises.
    ///
    /// Per cycle, for each `pending` OutboundEvent :
    ///   1. **Claim** (pending→claimed) BEFORE spawn — the at-least-once guard.
    ///      A Claim error means another process's pump took it : skip.
    ///   2. Resolve handler+family (`adapter_handler`), the `.world` config
    ///      (`adapter_world_config`), fold them into the child env via
    ///      `adapter_env::map_config` (the field-source convention).
    ///   3. An EMPTY handler = an in-process adapter (heki/memory) — there is
    ///      no program to spawn. Leave it claimed (don't crash, don't loop) and
    ///      log ; the in-process path never reaches the out-of-process outbox in
    ///      practice, but a mis-wired binding shouldn't panic the pump.
    ///   4. DETACH-spawn the handler (`process_group(0)`, stdin=payload,
    ///      stdout/stderr=null, NO wait), passing the re-entry env contract :
    ///      `HECKS_STOREHOUSE_BIN` (this exe, so the handler never needs
    ///      `storehouse` on PATH), `HECKS_ROOT` (the door's aggregates root),
    ///      `HECKS_DELIVERY_ID` / `HECKS_SOURCE_ID` / `HECKS_SOURCE_TYPE` /
    ///      `HECKS_SUCCESS_COMMAND` / `HECKS_FAILURE_COMMAND` (the verdict
    ///      commands, empty for fire-and-forget). The verdict + the
    ///      MarkDelivered ack are the HANDLER's job now, not the pump's.
    ///
    /// v1 scope : Claim-before-spawn + skip-claimed. Stale-claim reclaim (a
    /// crashed handler leaves a row stuck `claimed`) + an attempts cap (a
    /// permanently-missing handler must not hot-loop) are the next increment —
    /// they need a claimed-at timestamp on the bluebook (the outbox has none
    /// today). Returns the number of deliveries spawned this cycle.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn pump_outbound_events(&mut self) -> usize {
        use std::io::Write as _;
        use std::os::unix::process::CommandExt as _;
        use std::process::{Command, Stdio};

        // No presence guard : the outbox lives in the framework collaborator,
        // so every runtime can drain — including the library/test roots that
        // never carried the hexagon framework and silently drained nothing.

        // Snapshot every pending delivery under the immutable borrow, then take
        // &mut self for the Claim+spawn phase — mirrors run_host::pending_deliveries.
        struct Pending {
            delivery_id: String,
            adapter: String,
            source_id: String,
            source_type: String,
            payload: String,
            success_command: String,
            failure_command: String,
        }
        fn fld(r: &serde_json::Value, k: &str) -> String {
            r[k].as_str().unwrap_or("").to_string()
        }
        // The whole undelivered backlog, read through the DECLARED
        // `AllPending` query rather than a hand-written status filter —
        // "pending" is the outbox aggregate's lifecycle knowledge, not the
        // pump's.
        let pending_result =
            self.framework_mut().resolve_query("AllPending", &std::collections::HashMap::new());
        let pending: Vec<Pending> = pending_result["state"]
            .as_array()
            .map(|rows| {
                rows.iter()
                    .map(|r| Pending {
                        delivery_id: fld(r, "delivery_id"),
                        adapter: fld(r, "adapter"),
                        source_id: fld(r, "source_id"),
                        source_type: fld(r, "source_type"),
                        payload: fld(r, "payload"),
                        success_command: fld(r, "success_command"),
                        failure_command: fld(r, "failure_command"),
                    })
                    .collect()
            })
            .unwrap_or_default();
        if pending.is_empty() {
            return 0;
        }

        // The door the handler re-enters through. Absolute storehouse bin from
        // current_exe (the handler never calls bare `storehouse` — the overmind
        // doesn't put it on PATH).
        let storehouse_bin = std::env::current_exe()
            .ok()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|| "storehouse".to_string());
        let root = self.aggregates_root.clone().unwrap_or_default();

        // The CLI door requires the fully-qualified `Context::Aggregate.Command`
        // form — so the pump computes OutboundEvent's FQN (its context comes from
        // the bind directory, e.g. "Framework") and hands the handler the exact
        // verbs to re-enter with. Keeps the handler domain-agnostic : it shells
        // `$HECKS_DELIVERED_COMMAND` / `$HECKS_FAILED_COMMAND`, never a hardcoded
        // context. Falls back to the short form if no context is declared.
        let oe_context = self
            .domain
            .aggregates
            .iter()
            .find(|a| a.name == "OutboundEvent")
            .and_then(|a| a.context.clone());
        let qualify = |cmd: &str| match &oe_context {
            Some(ctx) if !ctx.is_empty() => format!("{}::OutboundEvent.{}", ctx, cmd),
            _ => format!("OutboundEvent.{}", cmd),
        };
        let delivered_command = qualify("MarkDelivered");
        let failed_command = qualify("MarkFailed");

        let mut spawned = 0usize;
        for d in pending {
            // 1. Resolve the handler FIRST. An adapter with NO out-of-process
            //    handler program is still served by an IN-RUNTIME mechanism (e.g.
            //    the dream :dream_image LLM cascade) — leave the delivery PENDING
            //    and untouched (don't claim, don't re-pend) so the in-process path
            //    handles it. Claiming a handler-less delivery would strand it
            //    `claimed` and STARVE the in-runtime adapter (broke dream_content_smoke).
            let (handler, family) = self.adapter_handler(&d.adapter).unwrap_or_default();
            if handler.is_empty() {
                continue;
            }

            // Resolve the handler to ABSOLUTE (a detach-spawn's cwd is undefined ;
            // a relative handler resolves against the aggregates root) and SKIP if
            // the binary doesn't EXIST. A declared-but-unbuilt handler (e.g.
            // dream_image's not-yet-written body/dream/dream-image-handler) stays
            // PENDING for its in-runtime path — claiming + spawning a missing binary
            // would starve that adapter (broke dream_content_smoke).
            let handler_path = {
                let p = std::path::Path::new(&handler);
                if p.is_absolute() {
                    handler.clone()
                } else if !root.is_empty() {
                    std::path::Path::new(&root).join(&handler).to_string_lossy().into_owned()
                } else {
                    handler.clone()
                }
            };
            if !std::path::Path::new(&handler_path).exists() {
                continue;
            }

            // 2. Claim BEFORE spawn — `given status == pending` makes a second
            //    pump's Claim error : skip, it's not ours (another process took it).
            let mut claim = HashMap::new();
            claim.insert("delivery_id".to_string(), Value::Str(d.delivery_id.clone()));
            if self.framework_mut().dispatch_impl("Claim", claim).is_err() {
                continue;
            }

            // 3. Resolve world config + the child env.
            let world = self.adapter_world_config(&d.adapter);
            let env = super::adapter_env::map_config(&family, &world, &self.family_fields(&family));

            // 3. DETACH-spawn (process_group(0), no wait). The verdict + ack are
            //    the handler's job — the pump returns the instant it spawns.
            let mut cmd = Command::new(&handler_path);
            for (k, v) in &env {
                cmd.env(k, v);
            }
            cmd.env("HECKS_STOREHOUSE_BIN", &storehouse_bin)
                .env("HECKS_ROOT", &root)
                .env("HECKS_DELIVERY_ID", &d.delivery_id)
                .env("HECKS_SOURCE_ID", &d.source_id)
                .env("HECKS_SOURCE_TYPE", &d.source_type)
                .env("HECKS_SUCCESS_COMMAND", &d.success_command)
                .env("HECKS_FAILURE_COMMAND", &d.failure_command)
                .env("HECKS_DELIVERED_COMMAND", &delivered_command)
                .env("HECKS_FAILED_COMMAND", &failed_command)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .process_group(0);

            match cmd.spawn() {
                Ok(mut child) => {
                    // Feed the payload on stdin, then drop so the handler sees EOF.
                    if let Some(mut stdin) = child.stdin.take() {
                        let _ = stdin.write_all(d.payload.as_bytes());
                    }
                    // Do NOT wait — fire and forget. The handler owns verdict + ack.
                    spawned += 1;
                }
                Err(e) => {
                    eprintln!(
                        "[pump_outbound_events] cannot spawn handler {} for adapter {} ({}) — left claimed",
                        handler_path, d.adapter, e
                    );
                }
            }
        }
        spawned
    }
}
