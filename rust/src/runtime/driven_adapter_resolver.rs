//! Sprint 14 first-adapter slice — fires `driven on` adapters declared
//! [antibody-exempt: kernel-floor runtime — spawns driven-adapter run-leaves in-process ; the engine that executes hecksagon adapters, inherently Rust]//! in `<bluebook>/hecksagons/<service>.hecksagon`.
//!
//! Shape:
//!
//! ```text
//! adapter "ShellAdapter" do
//!   driven on "Tools::ShellTool.BashRan" do |event|
//!     canned do
//!       output "ack"
//!       exit_code 0
//!     end
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
//! Sprint 14 memory-canned-defaults + world-wires-real-adapters — the
//! resolver picks the wrapped-call return value for each fire :
//!
//!   - `.world` declares `adapter "Name" do; <key> <value> end`
//!     → use the binding's values ("real backend with config from
//!     that entry")
//!   - no `.world` entry, but the handler has `canned do ... end`
//!     → use the canned values (memory + canned default)
//!   - neither → dispatch only the declared static attrs (legacy)
//!
//! In all three cases the chosen value-source is merged into the
//! follow-on dispatch's attr map ; declared dispatch attrs win on
//! conflict (a literal `dispatch "Y", id: "fixed"` overrides any
//! canned/world `id`). Presence of a `.world` adapter entry IS the
//! signal that switches canned→real ; there is no `backend:` flag
//! and no fake-vs-real adapter distinction. The adapter declaration
//! is identical across deployments ; only `.world` differs.
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
/// Maximum cascade-resolver recursion depth. A driven adapter whose follow-on
/// emits an event that triggers ANOTHER driven adapter chains automatically
/// (e.g. Claim.Acquire → Lease.Grant → worktree_create). This bound
/// hard-stops any cyclic adapter graph (A→B→A…) : cycle protection IS the
/// depth guard, because dispatch_inner carries no counter of its own.
const MAX_CASCADE_DEPTH: usize = 16;

pub fn resolve_driven_adapters(rt: &mut Runtime, event: &Event) {
    resolve_driven_adapters_at_depth(rt, event, 0);
}

fn resolve_driven_adapters_at_depth(rt: &mut Runtime, event: &Event, depth: usize) {
    if depth >= MAX_CASCADE_DEPTH {
        eprintln!("[driven] cascade depth {} reached at event '''{}''' — stopping (cycle guard)", MAX_CASCADE_DEPTH, event.name);
        return;
    }
    if rt.hecksagons.is_empty() { return; }
    let debug = std::env::var("HECKS_DEBUG_DRIVEN").is_ok();

    // Snapshot matching fires up-front. The follow-on dispatch takes
    // `&mut Runtime`, so we can't keep an immutable borrow of
    // `rt.hecksagons` / `rt.world_adapter_bindings` open across the
    // call. Clone is cheap : driven adapter declarations are small
    // static IR. For each fire we capture (command, declared_attrs,
    // wrapped_call_values) so the merge happens once at the snapshot
    // boundary — the resolver doesn't re-walk the world list per
    // dispatch.
    let mut matched: Vec<(String, Vec<(String, String)>, Vec<(String, String)>)> = Vec::new();
    let mut runs_to_exec: Vec<String> = Vec::new();
    let mut checks_to_run: Vec<(String, String)> = Vec::new();

        for hex in rt.hecksagons.iter() {
        for adapter in hex.driven_adapters.iter() {
            // Sprint 14 world-wires-real-adapters — presence of a
            // `.world` adapter binding with this adapter's name IS the
            // signal to use the binding's values as the wrapped-call
            // return. Absent : fall back to the handler's `canned do`
            // block. Both absent : empty merge (legacy behaviour). The
            // pick is factored into `pick_wrapped_values` so the choice
            // is unit-testable without booting a Runtime.
            let world_values: Option<Vec<(String, String)>> = rt
                .world_adapter_bindings
                .iter()
                .find(|b| b.name == adapter.name)
                .map(|b| b.values.clone());
            for handler in adapter.handlers.iter() {
                if !event_ref_matches(&handler.event_ref, event) { continue; }
                let wrapped = pick_wrapped_values(
                    world_values.as_deref(),
                    handler.canned.as_ref(),
                );
                for dispatch in handler.dispatches.iter() {
                    // i221-C — a `for_each:` clause makes the dispatch a SWEEP ;
                    // a bare dispatch keeps the single-fire path. Both interpolate
                    // `{field}`/`{id}` tokens from the event (and, for a sweep,
                    // record-first from each matched record).
                    match &dispatch.for_each {
                        None => {
                            let interp_attrs: Vec<(String, String)> = dispatch
                                .attrs
                                .iter()
                                .map(|(k, v)| (k.clone(), interpolate_event(v, event)))
                                .collect();
                            matched.push((
                                dispatch.command.clone(),
                                interp_attrs,
                                wrapped.clone(),
                            ));
                        }
                        Some(spec) => {
                            let qattrs = sweep_query_attrs(&spec.query_inputs, event);
                            for record in rt.sweep_records(spec, &qattrs) {
                                let interp_attrs: Vec<(String, String)> = dispatch
                                    .attrs
                                    .iter()
                                    .map(|(k, v)| (k.clone(),
                                        interpolate_event_and_record(v, event, &record)))
                                    .collect();
                                matched.push((
                                    dispatch.command.clone(),
                                    interp_attrs,
                                    wrapped.clone(),
                                ));
                            }
                        }
                    }
                }

                for run_cmd in handler.runs.iter() {
                    runs_to_exec.push(interpolate_event(run_cmd, event));
                }
                for check in handler.checks.iter() {
                    checks_to_run.push((interpolate_event(&check.cmd, event), check.result_into.clone()));
                }            }
        }
    }

    if matched.is_empty() && runs_to_exec.is_empty() && checks_to_run.is_empty() { return; }

    for (command, declared_attrs, wrapped_values) in matched {
        // Merge order : wrapped values first, then declared attrs
        // override on key collision. A literal `dispatch "Y", id: "x"`
        // pins `id` regardless of what canned/world declared. The
        // merge is factored into `merge_wrapped_and_declared` so the
        // override semantics are unit-testable.
        let attr_map = merge_wrapped_and_declared(&wrapped_values, &declared_attrs);
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
        // resolver-on-cascade : if the follow-on emitted an event, drive
        // the next hop of the chain, bounded by MAX_CASCADE_DEPTH. This is
        // what makes a multi-adapter fleet chain run end-to-end —
        // Claim.Acquire → Lease.Grant → worktree_create — instead of stopping
        // after one hop. dispatch_cascade itself still does NOT auto-invoke
        // the resolver ; the recursion is driven HERE, under the depth guard.
        if let Ok(r) = outcome {
                // Cross adapter->policy : an adapter-dispatched command must drain
                // policies too, exactly as Runtime::dispatch does after a top-level
                // dispatch. Without this, accounting policies (e.g. BumpOnTaskReopened)
                // silently never fire when their command is dispatched from a hecksagon.
                rt.drain_policies(&r);
            if let Some(ev) = r.event {
                resolve_driven_adapters_at_depth(rt, &ev, depth + 1);
            }
        }
    }

    // Real in-process external commands declared by `run "..."` on the
    // handler. Spawned directly (argv, no shell, no bin script). This is
    // the adapter actually doing impure work — e.g. `git worktree add`.
    for cmd in runs_to_exec {
        let parts: Vec<String> = split_argv(&cmd);
        if parts.is_empty() { continue; }
        match std::process::Command::new(&parts[0]).args(&parts[1..]).output() {
            Ok(o) => eprintln!("[driven:run] {} -> exit={} stdout={} stderr={}", cmd, o.status.code().unwrap_or(-1), String::from_utf8_lossy(&o.stdout).trim(), String::from_utf8_lossy(&o.stderr).trim()),
            Err(e) => eprintln!("[driven:run] {} -> spawn FAILED: {}", cmd, e),
        }
    }
    // Live-check leaves : run each declared check in-process, arm its flag
    // via result_into with ok = (exit == 0). No bin script, no canned.
    for (cmd, target) in checks_to_run {
        let parts: Vec<String> = split_argv(&cmd);
        if parts.is_empty() { continue; }
        let ok = std::process::Command::new(&parts[0]).args(&parts[1..]).output()
            .map(|o| o.status.success()).unwrap_or(false);
        eprintln!("[driven:check] {} -> ok={} -> {}", cmd, ok, target);
        let mut attrs = HashMap::new();
        attrs.insert("ok".to_string(), Value::Bool(ok));
        let _ = command_dispatch::dispatch_cascade(rt, &target, attrs, &event.aggregate_type, &event.aggregate_id);
    }
}

fn val_str(v: &Value) -> String {
    match v {
        Value::Str(s) => s.clone(),
        Value::Int(i) => i.to_string(),
        Value::Bool(b) => b.to_string(),
        _ => String::new(),
    }
}

/// Split a command line into argv, honoring single and double quotes so one
/// argument may contain spaces (e.g. a `--jq` filter). A quoted span groups
/// into the current token and its content is taken literally ; the alternate
/// quote char inside passes through verbatim (so `'if .x=="Y"'` is one arg
/// with the inner double-quotes preserved). No escape processing — sufficient
/// for the git / gh+jq probes the live-check leaves run.
fn split_argv(cmd: &str) -> Vec<String> {
    let mut args: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut has = false;
    let mut chars = cmd.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            ' ' | '\t' | '\n' | '\r' => {
                if has { args.push(std::mem::take(&mut cur)); has = false; }
            }
            '\'' | '"' => {
                has = true;
                let q = c;
                for d in chars.by_ref() {
                    if d == q { break; }
                    cur.push(d);
                }
            }
            _ => { has = true; cur.push(c); }
        }
    }
    if has { args.push(cur); }
    args
}

/// Interpolate `{field}` tokens in a run-command template from the
/// triggering event's data + identity. Identity/event fields only —
/// there are no FK refs here ; `{worktree_path}` is the aggregate's own id.
fn interpolate_event(template: &str, event: &Event) -> String {
    let mut out = template.to_string();
    for (k, v) in event.data.iter() {
        out = out.replace(&format!("{{{}}}", k), &val_str(v));
    }
    out = out.replace("{id}", &event.aggregate_id);
    out = out.replace("{aggregate_id}", &event.aggregate_id);
    // The `{now}` / `{now+N}` / `{now-N}` clock primitive. Resolved LAST
    // so a field literally named `now` (event data) still wins ; only the
    // unresolved clock tokens reach the time resolver. This single call is
    // why the clock reaches every driven write path : the per-record sweep
    // attrs (interpolate_event_and_record) and the query `where` values
    // (sweep_query_attrs) both funnel through interpolate_event.
    out = crate::runtime::storehouse_log::interpolate_now_tokens(&out);
    out
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

/// Sprint 14 — pick the wrapped-call return value source for a fire.
/// World binding wins (when `.world` declares an adapter binding for
/// this adapter's name) ; canned is the memory-default (when the
/// `driven on` handler declares a `canned do ... end` block) ;
/// neither = empty. Factored out of `resolve_driven_adapters` so the
/// canned-vs-real switch is unit-testable without booting a Runtime.
pub fn pick_wrapped_values(
    world: Option<&[(String, String)]>,
    canned: Option<&crate::hecksagon_ir::CannedResponse>,
) -> Vec<(String, String)> {
    if let Some(w) = world { return w.to_vec(); }
    if let Some(c) = canned { return c.values.clone(); }
    Vec::new()
}

/// Sprint 14 — merge a fire's wrapped-call values with the declared
/// dispatch attrs. Wrapped values fill the slot the adapter's wrapped
/// call would produce ; declared attrs override on key collision so a
/// literal `dispatch "Y", id: "fixed"` pins `id` regardless of what
/// canned/world declared. Factored out of `resolve_driven_adapters`
/// so the override semantics are unit-testable.
pub fn merge_wrapped_and_declared(
    wrapped: &[(String, String)],
    declared: &[(String, String)],
) -> HashMap<String, Value> {
    let mut out = build_attr_map(wrapped);
    for (k, v) in build_attr_map(declared) {
        out.insert(k, v);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hecksagon_ir::CannedResponse;

    fn canned(pairs: &[(&str, &str)]) -> CannedResponse {
        CannedResponse {
            values: pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
        }
    }

    fn raw_pairs(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    // Sprint 14 memory-canned-defaults : adapter with `canned do` and no
    // `.world` entry → the canned values ARE the wrapped-call return.
    #[test]
    fn split_argv_keeps_quoted_jq_filter_as_one_arg() {
        // A --jq filter is single-quoted and contains double-quotes + spaces ;
        // it must arrive as ONE argv token with the inner double-quotes intact.
        let cmd = "gh pr view sq/x --jq 'if .a==\"OPEN\" then empty else halt_error(1) end'";
        let parts = split_argv(cmd);
        assert_eq!(parts[0], "gh");
        assert_eq!(parts[3], "sq/x");
        assert_eq!(parts[4], "--jq");
        assert_eq!(parts[5], "if .a==\"OPEN\" then empty else halt_error(1) end");
        assert_eq!(parts.len(), 6, "quoted filter must not be split on its inner spaces");
    }

    #[test]
    fn pick_returns_canned_when_no_world_binding() {
        let c = canned(&[("output", "\"canned-ack\""), ("exit_code", "0")]);
        let picked = pick_wrapped_values(None, Some(&c));
        assert_eq!(
            picked,
            raw_pairs(&[("output", "\"canned-ack\""), ("exit_code", "0")]),
        );
    }

    // Sprint 14 world-wires-real-adapters : adapter with `canned do` AND
    // a `.world` entry → the .world binding's values ARE the wrapped-call
    // return ; canned is bypassed.
    #[test]
    fn pick_returns_world_when_binding_present_canned_ignored() {
        let c = canned(&[("output", "\"canned-ack\"")]);
        let world = raw_pairs(&[("output", "\"real-ack\"")]);
        let picked = pick_wrapped_values(Some(&world), Some(&c));
        assert_eq!(picked, raw_pairs(&[("output", "\"real-ack\"")]));
    }

    // Sprint 14 legacy : adapter with neither canned nor world → empty
    // wrapped-call return ; only the declared dispatch attrs reach the
    // follow-on.
    #[test]
    fn pick_returns_empty_when_neither_present() {
        let picked = pick_wrapped_values(None, None);
        assert!(picked.is_empty());
    }

    // Sprint 14 — declared dispatch attrs override on key collision so
    // `dispatch "Y", id: "fixed"` pins `id` regardless of the canned or
    // world source.
    #[test]
    fn merge_declared_wins_over_wrapped_on_key_collision() {
        let wrapped = raw_pairs(&[("id", "\"canned-id\""), ("output", "\"ack\"")]);
        let declared = raw_pairs(&[("id", "\"fixed\"")]);
        let merged = merge_wrapped_and_declared(&wrapped, &declared);
        // declared wins for `id` ...
        assert_eq!(merged.get("id"), Some(&Value::Str("fixed".to_string())));
        // ... and wrapped survives for keys declared doesn't shadow.
        assert_eq!(merged.get("output"), Some(&Value::Str("ack".to_string())));
    }

    // Sprint 14 — wrapped value reaches the follow-on when declared
    // doesn't shadow the key, so the canned/world source actually wires
    // through to the dispatch.
    #[test]
    fn merge_wrapped_keys_reach_follow_on_when_declared_silent() {
        let wrapped = raw_pairs(&[("output", "\"real-ack\""), ("exit_code", "0")]);
        let declared = raw_pairs(&[]);
        let merged = merge_wrapped_and_declared(&wrapped, &declared);
        assert_eq!(merged.get("output"), Some(&Value::Str("real-ack".to_string())));
        assert_eq!(merged.get("exit_code"), Some(&Value::Int(0)));
    }
}


/// i221-C — resolve a sweep's query inputs against the triggering event
/// into a string attr map the query executor filters on.
fn sweep_query_attrs(
    inputs: &[(String, crate::ir::ValueSpec)],
    event: &Event,
) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for (k, spec) in inputs {
        let v = match spec {
            crate::ir::ValueSpec::Literal { value } => {
                // strip the source-token quotes before interpolating so the
                // filter value matches the (unquoted) stored field.
                interpolate_event(value.trim().trim_matches('"'), event)
            }
            crate::ir::ValueSpec::FromEvent { name, default } => event
                .data
                .get(name)
                .map(val_str)
                .or_else(|| default.clone())
                .unwrap_or_default(),
            _ => String::new(),
        };
        out.insert(k.clone(), v);
    }
    out
}

/// i221-C — interpolate `{field}` tokens record-first (the swept record's
/// fields win), then fall back to the triggering event.
fn interpolate_event_and_record(
    template: &str,
    event: &Event,
    record: &HashMap<String, Value>,
) -> String {
    let mut out = template.to_string();
    for (k, v) in record.iter() {
        out = out.replace(&format!("{{{}}}", k), &val_str(v));
    }
    interpolate_event(&out, event)
}
