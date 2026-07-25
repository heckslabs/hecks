//! primitive_spawn — the generic Process.Spawn primitive hook : the ONE
//! spawn path every former :exec binding rides (fire -> run via the kernel-
//! floor exec leaf -> cascade (id, output, exit_code, ok) into result_into).
//! Sibling of the compute/mcp/claude_tool/llm hooks in reaction.rs — kept
//! its own cask because the spawn carries the trigger-event env/stdin
//! injection contract.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//! The fn-level [antibody-exempt] marker it always carried travels with it.

use super::*;

impl Runtime {
    /// [antibody-exempt: rust/src/runtime/mod.rs (resolve_primitive_spawn) —
    ///  kernel-floor primitive leaf for the `Primitive::Process.Spawn`
    ///  bluebook command (adapters-as-bluebook first slice). The spawn
    ///  syscall is irreducible imperative ; the surrounding PROTOCOL
    ///  (fire → run → cascade) is now ordinary bluebook policy/cascade.
    ///  Sibling of exec_dispatcher.rs's existing exemption.]
    ///
    /// The generic process-spawn primitive — the adapters-as-bluebook
    /// floor tile that replaced the retired `resolve_exec_adapters`,
    /// driven by ordinary bluebook policy/cascade instead of a bespoke
    /// per-family resolver. Fires when a `Primitive::Process.Spawn`
    /// command dispatches (whether from a top-level dispatch or from
    /// inside a policy / PM cascade). Reads the literal program string
    /// off the dispatch attrs (`cmd`), runs it to completion via the
    /// kernel-floor exec leaf (`exec_dispatcher::dispatch` — reused
    /// unchanged), and cascades (id, output, exit_code, ok) into the
    /// `result_into` target carried on the same dispatch.
    ///
    /// The cascade join key is the `id` attr the dispatch carried (the
    /// originating invocation id, threaded by the firing policy's
    /// event data) — falling back to the Process record's own id. This
    /// is the SAME contract the `:exec` resolver honours : the outcome
    /// record joins the originating invocation by id.
    ///
    /// `resolve_exec_adapters` is RETIRED. Every former `:exec` binding
    /// is now an ordinary bluebook policy firing this primitive : the
    /// fibroblast repair sweep (`on "SweepRan"`), the Gmail poll
    /// (`on "Inbox.InboxChecked"`), and the process-health sweep + heal
    /// (`on "ProcessMacrophage.Swept"` / `on "ProcessMacrophage.HealRequested"`).
    /// The last two need gap #1b — the aggregate-qualified `on` form —
    /// because `Swept` is emitted by both ProcessMacrophage and the
    /// discipline macrophage and is also consumed by the bare
    /// `MarkHangedOnMissingHeartbeat` policy ; the qualifier fires the
    /// sweeper ONLY for ProcessMacrophage's Swept.
    ///
    /// This is the ONLY new imperative leaf : the spawn syscall.
    pub(super) fn resolve_primitive_spawn(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        dispatch_attrs: &HashMap<String, Value>,
        trigger_event: Option<&event_bus::Event>,
    ) {
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        // The primitive matches by aggregate + command, not by a
        // hecksagon binding : the bluebook IS the contract. Anything
        // that dispatches `Process.Spawn` runs the spawn.
        if result.aggregate_type != "Process" || bare_command != "Spawn" {
            return;
        }

        // sprint-14 (storehouse-primitive-conception) — consult the
        // PrimitiveRegistry BEFORE running. The registry's
        // `Storehouse::Primitive` records are the bluebook ground truth
        // for which imperative leaves the runtime carries ; the lookup
        // is logged so a smoke trace can confirm the dispatch routed
        // through it. A miss here is the macrophage's signal that the
        // imperative leaf has no declaration. The hard-coded arm below
        // STAYS in place — the registry is an overlay, not yet a
        // replacement.
        let registry_key = format!("{}.{}", result.aggregate_type, bare_command);
        self.log_primitive_registry_route(&registry_key);

        let cmd = match dispatch_attrs.get("cmd").map(|v| v.to_string()) {
            Some(c) if !c.is_empty() => c,
            _ => {
                println!(
                    "[{}] [primitive:spawn] skipped — missing cmd attr",
                    storehouse_log::now_iso8601(),
                );
                return;
            }
        };
        let result_into = dispatch_attrs.get("result_into").map(|v| v.to_string());

        // The cascade join key is the `id` the dispatch carried (the
        // originating invocation id), falling back to the Process
        // record's own id. Mirrors the retired :exec resolver's
        // invocation_id contract.
        let invocation_id = dispatch_attrs
            .get("id")
            .map(|v| v.to_string())
            .or_else(|| {
                self.find(&result.aggregate_type, &result.aggregate_id)
                    .and_then(|s| s.fields.get("id").map(|v| v.to_string()))
            })
            .unwrap_or_else(|| result.aggregate_id.clone());

        // Inject the triggering event's payload into the child's
        // environment so the spawned process can read the prompt/id
        // without needing to hit the disk heki (which may be stale
        // when the runtime is warm/in-memory). Generic — passes the
        // whole event, not sidequest-specific fields.
        //
        // sq/policy-cmd-bin-wrappers lifts three commonly-needed
        // fields out of the event payload into top-level env vars so
        // wrappers can read them with a bare `$AGG_ID` rather than
        // parse JSON :
        //   AGG_ID     = ev.aggregate_id  (the join key the Record*
        //                cascade lands back on)
        //   AGG_TYPE   = ev.aggregate_type
        //   EVENT_NAME = ev.name
        // The full payload still rides on STOREHOUSE_TRIGGER_EVENT AND
        // on stdin as JSON so scripts that want the whole event can
        // drain it without re-parsing env.
        let (extra_env, stdin_payload): (Vec<(String, String)>, Option<String>) =
            if let Some(ev) = trigger_event {
                let mut data_map = serde_json::Map::new();
                for (k, v) in &ev.data {
                    data_map.insert(k.clone(), match v {
                        Value::Str(s) => serde_json::json!(s),
                        Value::Int(n) => serde_json::json!(n),
                        Value::Bool(b) => serde_json::json!(b),
                        _ => serde_json::json!(v.to_string()),
                    });
                }
                let payload = serde_json::json!({
                    "name": ev.name,
                    "aggregate_type": ev.aggregate_type,
                    "aggregate_id": ev.aggregate_id,
                    "data": serde_json::Value::Object(data_map),
                });
                let payload_str = payload.to_string();
                (
                    vec![
                        ("STOREHOUSE_TRIGGER_EVENT".to_string(), payload_str.clone()),
                        ("AGG_ID".to_string(), ev.aggregate_id.clone()),
                        ("AGG_TYPE".to_string(), ev.aggregate_type.clone()),
                        ("EVENT_NAME".to_string(), ev.name.clone()),
                    ],
                    Some(payload_str),
                )
            } else {
                (vec![], None)
            };

        let exec_result = exec_dispatcher::dispatch(&cmd, &extra_env, stdin_payload.as_deref());
        let err_tail = match (&exec_result.ok, &exec_result.error) {
            (false, Some(msg)) => format!(" error={:?}", msg),
            _ => String::new(),
        };
        println!(
            "[{}] [primitive:spawn] ok={} exit={} output={:?}{}",
            storehouse_log::now_iso8601(),
            exec_result.ok, exec_result.exit_code, exec_result.output, err_tail
        );

        let result_into_target = match result_into.as_deref() {
            Some(s) if !s.is_empty() => s,
            _ => return,
        };
        let mut record_attrs: HashMap<String, Value> = HashMap::new();
        record_attrs.insert("id".to_string(), Value::Str(invocation_id.clone()));
        record_attrs.insert("output".to_string(), Value::Str(exec_result.output.clone()));
        record_attrs.insert("exit_code".to_string(), Value::Int(exec_result.exit_code as i64));
        record_attrs.insert("ok".to_string(), Value::Bool(exec_result.ok));
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
        let _ = cascade_outcome;
    }
}
