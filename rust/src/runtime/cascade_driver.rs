//! cascade_driver — the out-of-process drain : drain_outbound_to_quiescence
//! (host — claims pending OutboundEvent deliveries, execs the standalone
//! handler, lands the verdict cascade, drains to quiescence under the
//! MAX_ITERS budget) and its wasm32 structural no-op sibling.
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/cascade_driver.rs — kernel-floor
//!  cascade driver : THE interpreter loop that runs bluebook reactions to
//!  quiescence — no bluebook can describe its own driver. Relocated verbatim
//!  from mod.rs blanket.]

use super::*;

impl Runtime {

    /// PRIMARY-ADAPTER SYNCHRONOUS WAIT (driving-side, Cockburn) — drain the
    /// verdict-bearing OutboundEvent deliveries INLINE, to quiescence, reusing
    /// run_host's primitive (Claim -> exec handler BLOCKING + verdict-capturing
    /// -> dispatch the verdict -> the verdict RE-ENTERS the core, which may emit
    /// more effects -> loop). Returns the number of deliveries drained.
    ///
    /// This is the keystone the serve/dispatch boundary calls UNCONDITIONALLY
    /// (slice 2) so a synchronous caller gets the effect's result back ; it is a
    /// safe no-op when no actionable OutboundEvent exists. The shape-derived
    /// switch (`has_effect_binding_for`) decides OOP-vs-in-process per family.
    /// The CORE never blocks : it has already returned by the time this
    /// runs ; the WAIT is a primary-adapter concern, not a driven-port one.
    ///
    /// Discipline (see docs/driven_port_keystone_api.md) :
    ///   - Claims ONLY verdict-bearing deliveries (success_command non-empty).
    ///     Fire-and-forget (tts) is LEFT for the detach pump
    ///     (pump_outbound_events) — never claimed here, so a slow playback can't
    ///     block the wait and a verdict k=v is never lost to the detach pump's
    ///     Stdio::null().
    ///   - Handler-less deliveries are LEFT PENDING (not claimed, not failed) —
    ///     mirrors pump_outbound_events, NOT run_host_pass (whose mark_failed on
    ///     handler-less would loop forever under this quiescence wrapper).
    ///   - Claim's `given status == pending` is the at-least-once idempotency
    ///     guard : a replay after MarkDelivered finds status != pending, Claim
    ///     errors, the handler is not re-exec'd, the verdict lands exactly once.
    ///   - Bounded by MAX_ITERS (total drain budget). An exec error within the
    ///     budget -> MarkFailed (last_error) -> the delivery returns to pending
    ///     for a bounded retry / dead-letter (compensate-forward).
    // Host-only — execs out-of-process handler binaries via run_host (wasm-gated).
    // The CF Worker has no process host ; the wasm32 sibling below is a no-op.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn drain_outbound_to_quiescence(&mut self) -> usize {
        const MAX_ITERS: usize = 256;
        // The outbox lives in the framework collaborator — always available, so
        // no presence guard.
        let root = self.aggregates_root.clone().unwrap_or_default();

        struct Pending {
            delivery_id: String,
            adapter: String,
            // The ORIGIN aggregate id (OrderPlaced's Order#N). Threaded into
            // the verdict command as its self-reference `id` so an effect
            // verdict (Authorize/Decline) re-enters ON THE SAME aggregate that
            // emitted the trigger — mirrors run_host_pass. Without it, a
            // transition verdict (upsert-on-identity) mints a phantom.
            source_id: String,
            payload: String,
            success_command: String,
            failure_command: String,
        }
        fn fld(r: &serde_json::Value, k: &str) -> String {
            r[k].as_str().unwrap_or("").to_string()
        }

        let mut drained = 0usize;
        let mut iters = 0usize;
        loop {
            iters += 1;
            if iters > MAX_ITERS {
                eprintln!("[drain_outbound_to_quiescence] budget reached — stopping");
                break;
            }
            // Snapshot pending VERDICT-BEARING deliveries with a built
            // handler. WHICH deliveries are undelivered comes from the
            // declared `AllPending` query (the aggregate owns its own
            // lifecycle vocabulary) ; the verdict-bearing narrowing stays
            // here because it is a DRAIN concern, not a lifecycle one —
            // this loop only drives edges that re-enter with a verdict.
            let pending_result =
                self.framework_mut().resolve_query("AllPending", &std::collections::HashMap::new());
            let pending: Vec<Pending> = pending_result["state"]
                .as_array()
                .map(|rows| {
                    rows.iter()
                        .filter(|r| !fld(r, "success_command").is_empty())
                        .map(|r| Pending {
                            delivery_id: fld(r, "delivery_id"),
                            adapter: fld(r, "adapter"),
                            source_id: fld(r, "source_id"),
                            payload: fld(r, "payload"),
                            success_command: fld(r, "success_command"),
                            failure_command: fld(r, "failure_command"),
                        })
                        .collect()
                })
                .unwrap_or_default();

            // Keep only deliveries whose adapter has a built handler binary —
            // a handler-less / unbuilt-binary delivery is LEFT PENDING for its
            // in-runtime path (mirrors pump_outbound_events ; never mark_failed).
            let actionable: Vec<Pending> = pending
                .into_iter()
                .filter(|d| {
                    let (handler, _) = self.adapter_handler(&d.adapter).unwrap_or_default();
                    if handler.is_empty() {
                        return false;
                    }
                    let abs = resolve_handler_path(&root, &handler);
                    std::path::Path::new(&abs).exists()
                })
                .collect();

            if actionable.is_empty() {
                break; // quiescent
            }

            for d in actionable {
                // Claim BEFORE exec — the at-least-once guard. A second drainer
                // (or the daemon) Claiming the same delivery errors here : skip.
                let mut claim = HashMap::new();
                claim.insert("delivery_id".to_string(), Value::Str(d.delivery_id.clone()));
                if self.framework_mut().dispatch_impl("Claim", claim).is_err() {
                    continue;
                }
                drained += 1;

                // Resolve handler + fold the .world config onto the canonical env.
                let (handler, family) = self.adapter_handler(&d.adapter).unwrap_or_default();
                let handler_path = resolve_handler_path(&root, &handler);
                let world = self.adapter_world_config(&d.adapter);
                let env = adapter_env::map_config(
                    &family, &world, &self.family_fields(&family),
                );

                // EXEC the handler BLOCKING, capturing the k=v verdict + exit
                // branch — run_host's primitive, reused verbatim.
                match crate::run_host::exec::run_handler(&handler_path, &d.payload, &env) {
                    Err(e) => {
                        // Spawn / I/O error — a retryable transport failure, not a
                        // verdict. MarkFailed returns it to pending (dead-letter on
                        // budget exhaustion). last_error captured.
                        let mut mf = HashMap::new();
                        mf.insert("delivery_id".to_string(), Value::Str(d.delivery_id.clone()));
                        mf.insert("error".to_string(), Value::Str(e));
                        let _ = self.framework_mut().dispatch_impl("MarkFailed", mf);
                    }
                    Ok(outcome) => {
                        let verdict = if outcome.success {
                            &d.success_command
                        } else {
                            &d.failure_command
                        };
                        if !verdict.is_empty() {
                            // Thread the handler's stdout k=v pairs into the verdict
                            // command. THE VERDICT RE-ENTERS THE CORE — it may emit
                            // more effects, drained on the next loop iteration
                            // (drain-to-quiescence).
                            let mut vattrs: HashMap<String, Value> = HashMap::new();
                            for (k, v) in &outcome.verdict_pairs {
                                vattrs.insert(k.clone(), Value::Str(v.clone()));
                            }
                            // Async-boundary verdict identity — an effect verdict
                            // re-enters BY CONTRACT on the SAME aggregate that
                            // emitted the trigger. Inject the origin source_id as
                            // the verdict's universal-id self-reference so a
                            // transition (upsert-on-identity, e.g. Order.Authorize)
                            // transitions the REAL order instead of minting a
                            // phantom. Twin of run_host_pass's identical inject.
                            vattrs.insert("id".to_string(), Value::Str(d.source_id.clone()));
                            let _ = self.dispatch(verdict, vattrs);
                        }
                        // Reached a verdict == HANDLED -> MarkDelivered (terminal).
                        let mut md = HashMap::new();
                        md.insert("delivery_id".to_string(), Value::Str(d.delivery_id.clone()));
                        let _ = self.framework_mut().dispatch_impl("MarkDelivered", md);
                    }
                }
            }
        }
        drained
    }

    /// On wasm32 the Worker has no out-of-process handler host (no process
    /// spawning in a CF Worker), so the out-of-process drain is a structural
    /// no-op. Two-color stub : same signature, host runs the real drain.
    #[cfg(target_arch = "wasm32")]
    pub fn drain_outbound_to_quiescence(&mut self) -> usize { 0 }
}
