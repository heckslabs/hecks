//! Sprint 14 first-adapter slice — fires `driven on` adapters declared
//! in `<bluebook>/hecksagons/<service>.hecksagon`.
//!
//! Shape:
//!
//! ```text
//! adapter "ShellAdapter" do
//!   driven on "Tools::ShellTool.BashRan" do |event|
//!     dispatch "Tools::TaskTool.Get", id: "shell-adapter-smoke"
//!   end
//! end
//! ```
//!
//! The parser captures these as `DrivenAdapter` IR entries on each
//! attached `Hecksagon`. This resolver runs after `Runtime::dispatch`
//! (and `Runtime::dispatch_isolated`) publishes an event : it scans
//! every attached hecksagon for handlers whose `event_ref` matches
//! the just-emitted event, then dispatches each handler's follow-on
//! commands through `command_dispatch::dispatch_cascade`.
//!
//! Sibling of `resolve_claude_tool_adapters` / `resolve_web_tool_adapters`
//! / `resolve_mcp_adapters` — same registration shape, but triggered by
//! event emission rather than command name. The follow-on uses the
//! cascade path so the second dispatch's emit lands on the event bus and
//! `expect emits: [...]` assertions see the full chain.
//!
//! Cycle protection : the resolver is wired into `dispatch` and
//! `dispatch_isolated` only, NOT into `dispatch_cascade`. A follow-on
//! that itself emits an event won't recursively fire driven adapters —
//! the cascade path is one-shot per driven trigger. (Mirror of the same
//! rule applied to `resolve_claude_tool_adapters`.)

use std::collections::HashMap;
use crate::runtime::{Runtime, Value, command_dispatch};
use crate::runtime::event_bus::Event;

/// Scan attached hecksagons for `driven on` handlers matching the
/// just-published event, and dispatch each declared follow-on via the
/// cascade path. No-op when no hecksagons are attached (the historical
/// `Runtime::boot` path), no driven adapters declared, or no handler
/// matches the event.
pub fn resolve_driven_adapters(rt: &mut Runtime, event: &Event) {
    if rt.hecksagons.is_empty() { return; }
    let debug = std::env::var("HECKS_DEBUG_DRIVEN").is_ok();

    // Snapshot matching dispatches up-front. The follow-on dispatch
    // takes `&mut Runtime`, so we can't keep an immutable borrow of
    // `rt.hecksagons` open across the call. Clone is cheap : driven
    // adapter declarations are small static IR.
    let matched: Vec<(String, Vec<(String, String)>)> = rt.hecksagons.iter()
        .flat_map(|h| h.driven_adapters.iter())
        .flat_map(|a| a.handlers.iter())
        .filter(|h| event_ref_matches(&h.event_ref, event))
        .flat_map(|h| h.dispatches.iter())
        .map(|d| (d.command.clone(), d.attrs.clone()))
        .collect();

    if matched.is_empty() { return; }

    for (command, attrs) in matched {
        let attr_map = build_attr_map(&attrs);
        // Cascade dispatch so the follow-on's emit reaches the bus AND
        // depth / cycle protection from the dispatch_inner stack apply.
        // Same shape as the claude_tool resolver's chain into
        // `result_into` ; the upstream id/type are the event's so the
        // cascade can preserve the invocation handle.
        let outcome = command_dispatch::dispatch_cascade(
            rt,
            &command,
            attr_map,
            &event.aggregate_type,
            &event.aggregate_id,
        );
        if debug {
            match &outcome {
                Ok(r) => eprintln!("[driven:debug] cascaded into {} ok agg={} id={}", command, r.aggregate_type, r.aggregate_id),
                Err(e) => eprintln!("[driven:debug] cascade into {} FAILED: {:?}", command, e),
            }
        }
        let _ = outcome;
    }
}

/// True when the handler's declared `event_ref` (e.g.
/// `"Tools::ShellTool.BashRan"`) refers to the event that just fired.
/// Accepts three forms : `Context::Aggregate.Event`, `Aggregate.Event`,
/// or bare `Event`. The event itself carries `name` (the event token)
/// and `aggregate_type` (the aggregate that emitted it).
fn event_ref_matches(event_ref: &str, event: &Event) -> bool {
    let (ctx_agg, evt_name) = match event_ref.rsplit_once('.') {
        Some((head, tail)) => (head, tail),
        None => return event_ref == event.name,
    };
    if evt_name != event.name { return false; }
    // `ctx_agg` is either `Context::Aggregate` or just `Aggregate`.
    let agg_only = ctx_agg.rsplit("::").next().unwrap_or(ctx_agg);
    agg_only == event.aggregate_type
}

/// Convert the parser's source-token attrs (string values still carry
/// surrounding quotes, ints stay as digit strings) into the runtime's
/// dynamic Value form. Mirrors behaviors_runner's `parse_value`.
fn build_attr_map(attrs: &[(String, String)]) -> HashMap<String, Value> {
    let mut out = HashMap::new();
    for (k, raw) in attrs {
        let v = raw.trim();
        if let Ok(n) = v.parse::<i64>() {
            out.insert(k.clone(), Value::Int(n));
        } else if v == "true" {
            out.insert(k.clone(), Value::Bool(true));
        } else if v == "false" {
            out.insert(k.clone(), Value::Bool(false));
        } else {
            // Strip surrounding quotes when present (string literal form).
            let s = if v.starts_with('"') && v.ends_with('"') && v.len() >= 2 {
                v[1..v.len() - 1].to_string()
            } else {
                v.to_string()
            };
            out.insert(k.clone(), Value::Str(s));
        }
    }
    out
}
