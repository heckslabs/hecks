//! dispatch_core — dispatch_impl, the ONE gated write path : payload gate,
//! auth gates, given enforcement, mutation, event emission, event-log append,
//! outbox record, reaction scheduling. The thin front doors (dispatch /
//! dispatch_deferred) stay in mod.rs ; every one of them funnels here.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/dispatch_core.rs — kernel-floor
//!  dispatch pipeline (the interpreter that runs bluebooks cannot itself be
//!  one), relocated verbatim from mod.rs blanket.]

use super::*;

impl Runtime {
    pub(crate) fn dispatch_impl(
        &mut self,
        command_name: &str,
        attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        // i622 — dispatch entry log. One stdout line per top-level
        // dispatch, gated by STOREHOUSE_LOG. The invocation id is the
        // dispatch's `id` attr when present (matches i613's envelope),
        // falling back to a short hex token derived from the system
        // clock so every dispatch carries SOMETHING addressable.
        let invocation_id = attrs.get("id")
            .map(|v| v.to_string())
            .unwrap_or_else(|| {
                // wasm-safe clock : raw std::time::SystemTime::now()
                // panics "time not implemented" on wasm32 (CF Worker).
                // Route through clock::now_duration (i630).
                let d = crate::clock::now_duration();
                format!("inv_{:x}", d.subsec_nanos() as u64 ^ d.as_secs())
            });

        // i697 — open the rich dispatch-detail scope BEFORE the terse
        // dispatch_entry below, so the dispatch line itself is the first
        // entry in the rich block's event timeline. The scope's Drop
        // emits the full pretty-JSON block (covers the `?` error path
        // too). Cascades go through command_dispatch::dispatch_cascade,
        // not Runtime::dispatch, so exactly one scope is open per
        // top-level dispatch and the timeline forms one clean tree.
        // The log surfaces show the canonical FQN of WHERE the dispatch
            // landed — the full Realm::…::Domain::Aggregate.verb rebuilt from
            // the resolved aggregate's stamped realm_path — not the terse
            // 2-seg the caller typed. `storehouse follow` is realm-explicit,
            // and a mis-resolve is visible instead of hiding behind the short
            // form. Falls back to the raw name when it can't resolve.
            let log_name = command_dispatch::canonical_for_log(self, command_name);
            let args_json = dispatch_detail_args_json(&attrs);
            let mut detail_scope =
                dispatch_detail::DispatchScope::begin(&invocation_id, &log_name, args_json);

            storehouse_log::dispatch_entry(&log_name, &invocation_id, None);

        // i622 verbose — per-attribute trace. One line per attr the
        // caller passed. Gated to the Verbose level inside the logger.
        for (k, v) in &attrs {
            storehouse_log::attribute_trace(
                    &log_name, &invocation_id, k, &v.to_string()
                );
        }

        // Snapshot the command attrs before they move into the dispatch — the
        // deferred react paths (react_ports / outbox) read them after the move.
        let ctx_attrs = attrs.clone();
        // Core dispatch. On error, feed the scope the error message so
        // its Drop emits a bright-red error block, THEN propagate.
        let result = match command_dispatch::dispatch(self, command_name, attrs) {
            Ok(r) => r,
            Err(e) => {
                detail_scope.finish("error", format!("{:?}", e)
                    .chars().map(|c| if c == '"' { '\'' } else { c }).collect::<String>()
                    .lines().next().map(|s| format!("\"{}\"", s)).unwrap_or_else(|| "\"error\"".into()));
                return Err(e);
            }
        };

        // i622 — event emission log. The dispatch produced an event ;
        // emit a one-liner naming the aggregate, event, and the
        // originating invocation id. Suppressed at quiet.
        if let Some(ref ev) = result.event {
            storehouse_log::event_emitted(
                &ev.aggregate_type, &ev.name, &ev.aggregate_id
            );
        }

        // Breadcrumb : write the entry-point command (the top-level
        // dispatch the user / CLI invoked) to a tiny plaintext file
        // under data_dir. The statusline reads it.
        //
        // Two filters keep the statusline glyph showing what's actually
        // INTERESTING, not the constant body-daemon traffic :
        //
        //   1. Top-level only — `drain_policies`'s cascade calls go
        //      through `command_dispatch::dispatch` directly and don't
        //      touch the breadcrumb. Without this, the cascade leaf
        //      (Synapse.DecaySynapse / Awareness.RecordMoment / Mode.
        //      SetAttentive) drowned the entry-point variety.
        //
        //   2. Non-daemon only — when HECKS_DAEMON=1 is set in the
        //      environment, the dispatch is body-cycle plumbing
        //      (mindstream.sh, pulse_organs.sh, heart/breath loops)
        //      and the breadcrumb is suppressed. The statusline glyph
        //      then only updates when a HUMAN-driven dispatch fires
        //      (Antibody.RegisterExemption from the prompt, Mood.
        //      Express, etc.) — exactly the "what are we working on"
        //      signal the bar is for.
        let is_daemon = std::env::var("HECKS_DAEMON").ok().as_deref() == Some("1");
        if !is_daemon {
            if let Some(ref dir) = self.data_dir {
                // wasm-safe clock (i630) — see invocation_id above.
                let now = crate::clock::now_duration().as_secs();
                let path = format!("{}/.last_dispatch", dir.trim_end_matches('/'));
                let phrase = self.format_breadcrumb_phrase(command_name, &result);
                let _ = std::fs::write(&path,
                    format!("{}\n{}\n", phrase, now));
            }
        }

        // Update projections
        if let Some(ref event) = result.event {
            for proj in &mut self.projections {
                proj.apply(event);
            }
        }

        // Phase 3 — outbox + pump. The core mutation above touched ONE
        // aggregate. Its cross-aggregate reactions (policy/PM cascade,
        // IO-edge adapters, hecksagon `driven on`) are enqueued and run by
        // `react` in a SEPARATE pump phase, never inline here. Eager callers
        // auto-pump so the cascade still settles before return;
        // `dispatch_deferred` skips the pump to prove the async seam.
        // Event-out messaging port — record a durable OutboundEvent for every
        // standalone (separate-program) adapter subscribing to this event via
        // an EFFECT binding, so an out-of-process host can consume it. Sync
        // domain bookkeeping on emit (the async charge happens off-core in the
        // host) ; no-op when OutboundEvent isn't loaded or nothing subscribes.
        self.record_effect_outbound(&result);
        // (Event-sourcing append moved into dispatch_inner — the universal
        // door — so cascade reactions, which bypass THIS wrapper via
        // dispatch_cascade, are recorded in the Log too. See command_dispatch.)
        // Transactional outbox — record this command's domain reactions to
        // the persistent CascadeRun outbox. The reaction is delivered ONLY by
        // pump_outbox (its own transaction, on a later tick), never inline.
        if self.record_cascade_run(&result) {
            // Deferred ASYNC path — domain reactions recorded to the persistent
            // outbox (delivered later by pump_outbox, each its own transaction).
            // The impure PORTS fire eagerly here so tools / AI still run in-band.
            self.react_ports(&result, command_name, &ctx_attrs);
        } else {
            // No persistent outbox (CascadeRun not loaded) or nothing to react
            // to — fall back to the in-memory deferred path: enqueue for pump(),
            // which runs the full react() later. Held until pump, never dropped.
            self.outbox.push_back(PendingReaction {
                result: result.clone(),
                command_name: command_name.to_string(),
                attrs: ctx_attrs.clone(),
            });
        }

        // i697 — feed the rich scope the final result state (the
        // aggregate's fields JSON after all adapters settle). The scope's
        // Drop then emits the full coloured block.
        let result_state_json = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .map(dispatch_detail_state_json)
            .unwrap_or_else(|| "{}".to_string());
        detail_scope.finish("ok", result_state_json);

        Ok(result)
    }
}
