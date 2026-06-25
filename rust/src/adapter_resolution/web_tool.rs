//! :web_tool adapter resolution (i569) — carved out of runtime/mod.rs into
//! the `adapter_resolution` GROW concern. Parallel to the claude_tool / mcp
//! arms ; same field shape (`command`, `tool`, `result_into` — no `server`),
//! the `:web_tool` family declared at
//! `aggregates/framework/adapter_families/web_tool.hecksagon`.
//!
//! [antibody-exempt: rust/src/adapter_resolution/web_tool.rs — kernel-floor
//!  adapter arm. The `:web_tool` resolver is a mechanical projection of the
//!  web_tool adapter-family hecksagon ; it runs the real HTTP primitive and
//!  cascades into RecordResult. No bluebook can describe its own dispatch
//!  driver — this is the kernel arm the bluebook family declares.]

use crate::runtime::{
    command_dispatch, storehouse_log, strip_quotes_or_colon, web_tool_dispatcher,
    AggregateState, CommandResult, Runtime, Value,
};
use std::collections::HashMap;

impl Runtime {
    /// i569 — :web_tool adapter resolver. Parallel to
    /// `resolve_claude_tool_adapters` ; same field shape (`command`,
    /// `tool`, `result_into` — no `server`), different adapter family :
    /// the `:web_tool` family declared at
    /// `aggregates/framework/adapter_families/web_tool.hecksagon`.
    ///
    /// When a hecksagon-loaded `:web_tool` binding's `command` matches
    /// the just-dispatched `Aggregate.Command` (WebTool.WebFetch /
    /// WebTool.WebSearch), this arm reads the binding's `tool` field
    /// (`web_fetch` / `web_search`), calls the kernel-floor
    /// `web_tool_dispatcher::dispatch` which runs the real HTTP GET
    /// (curl) / DuckDuckGo query, surfaces the outcome on stdout (same
    /// `[web_tool:<tool>] ok=… output=…` shape the claude_tool arm
    /// prints), and chains the fetched body into `result_into` as a
    /// `dispatch_cascade` carrying `id`, `tool`, `output`, `exit_code`
    /// (HTTP status), and `ok`.
    ///
    /// HECKS_DEBUG_WEB_TOOL=1 surfaces the resolution + per-binding
    /// fire trace ; same shape as HECKS_DEBUG_CLAUDE_TOOL.
    pub(crate) fn resolve_web_tool_adapters(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        dispatch_attrs: &HashMap<String, Value>,
    ) {
        if self.hecksagons.is_empty() { return; }
        // KEYSTONE SWITCH (slice 2) — shape-derived OOP suppress. When an
        // effect binding subscribes (`on:`) to the EVENT this command emitted
        // and resolves to the `web_tool` family with a verdict, the
        // out-of-process path (effect binding -> OutboundEvent ->
        // drain_outbound_to_quiescence) owns the fetch/search ; suppress this
        // in-process io-adapter path so the two never both fire. No binding
        // (default) keeps this in-process path as the proven fallback.
        if let Some(ref event) = result.event {
            if self.has_effect_binding_for(&event.name, "web_tool") {
                return;
            }
        }
        let debug = std::env::var("HECKS_DEBUG_WEB_TOOL").is_ok();
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        let target = format!("{}.{}", result.aggregate_type, bare_command);
        if debug {
            eprintln!("[web_tool:debug] resolve cmd={} target={} hecksagons={}",
                command_name, target, self.hecksagons.len());
        }

        // Snapshot every `:web_tool` io adapter whose `command` option
        // matches the dispatched target. Same parse-noise stripping as
        // the claude_tool arm (quotes around strings, leading colon on
        // symbols). `result_into` carries the follow-on cascade target.
        let matched: Vec<(String, String, Option<String>)> = self.hecksagons.iter()
            .flat_map(|h| h.io_adapters.iter())
            .filter(|a| a.kind == "web_tool")
            .filter_map(|a| {
                let mut cmd: Option<String> = None;
                let mut tool: Option<String> = None;
                let mut result_into: Option<String> = None;
                for (k, v) in &a.options {
                    match k.as_str() {
                        "command"     => cmd = Some(strip_quotes_or_colon(v)),
                        "tool"        => tool = Some(strip_quotes_or_colon(v)),
                        "result_into" => result_into = Some(strip_quotes_or_colon(v)),
                        _ => {}
                    }
                }
                match (cmd, tool) {
                    (Some(c), Some(t)) if c == target => Some((c, t, result_into)),
                    _ => None,
                }
            })
            .collect();
        if debug {
            eprintln!("[web_tool:debug] matched {} adapter(s) for target={}",
                matched.len(), target);
        }
        if matched.is_empty() { return; }

        // Build the attrs map (state ∪ dispatch ; dispatch wins) so the
        // web primitive sees `url` / `query` whether they landed on
        // aggregate state or only rode in the event payload. The `id`
        // flows through so the RecordResult cascade joins the same
        // invocation record.
        let state_clone: Option<AggregateState> = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .cloned();
        let mut attrs: HashMap<String, String> = HashMap::new();
        if let Some(s) = state_clone.as_ref() {
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

        for (_cmd, tool, result_into) in &matched {
            let tool_result = web_tool_dispatcher::dispatch(tool, &attrs);
            let err_tail = match (&tool_result.ok, &tool_result.error) {
                (false, Some(msg)) => format!(" error={:?}", msg),
                _ => String::new(),
            };
            // Mirror the claude_tool arm : one stdout line per
            // invocation on the single audit stream. This IS the raw
            // binary's “Tool output” surface — the fetched body shows
            // here even when no result_into cascade is declared.
            println!(
                "[{}] [web_tool:{}] ok={} exit={} output={:?}{}",
                storehouse_log::now_iso8601(),
                tool_result.tool, tool_result.ok, tool_result.exit_code,
                tool_result.output, err_tail
            );

            let result_into_target = match result_into.as_deref() {
                Some(s) if !s.is_empty() => s,
                _ => {
                    if debug {
                        eprintln!("[web_tool:debug] no result_into on adapter — skipping cascade");
                    }
                    continue;
                }
            };

            let mut record_attrs: HashMap<String, Value> = HashMap::new();
            record_attrs.insert("id".to_string(), Value::Str(invocation_id.clone()));
            record_attrs.insert("tool".to_string(), Value::Str(tool_result.tool.clone()));
            record_attrs.insert("output".to_string(), Value::Str(tool_result.output.clone()));
            record_attrs.insert("exit_code".to_string(), Value::Int(tool_result.exit_code as i64));
            record_attrs.insert("ok".to_string(), Value::Bool(tool_result.ok));

            let cascade_outcome = command_dispatch::dispatch_cascade(
                self,
                result_into_target,
                record_attrs,
                &result.aggregate_type,
                &result.aggregate_id,
            );
            storehouse_log::cascade_step(
                result_into_target,
                &invocation_id,
                cascade_outcome.is_ok(),
            );
            if debug {
                match &cascade_outcome {
                    Ok(_)  => eprintln!("[web_tool:debug] cascaded into {} ok", result_into_target),
                    Err(e) => eprintln!("[web_tool:debug] cascade into {} failed: {:?}", result_into_target, e),
                }
            }
            let _ = cascade_outcome;
        }
    }
}
