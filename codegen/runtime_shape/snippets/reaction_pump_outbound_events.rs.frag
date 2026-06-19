    /// i750 out-of-process-adapter pump — the SECOND arm of the drain. Where
    /// `pump_outbox` delivers the IN-PROCESS CascadeRun outbox (sibling domain
    /// reactions), this drains the OUT-OF-PROCESS `OutboundEvent` outbox — the
    /// messaging-port analog — by DETACH-spawning the named adapter's handler
    /// program. The handler does the impure async edge (the charge, the TTS
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

        // No OutboundEvent aggregate loaded → nothing to drain (library/test
        // roots that don't carry the hexagon framework).
        if !self.domain.aggregates.iter().any(|a| a.name == "OutboundEvent") {
            return 0;
        }

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
        fn fld(s: &AggregateState, k: &str) -> String {
            s.get(k).as_str().unwrap_or("").to_string()
        }
        let pending: Vec<Pending> = self
            .all("OutboundEvent")
            .into_iter()
            .filter(|s| fld(s, "status") == "pending")
            .map(|s| Pending {
                delivery_id: fld(&s, "delivery_id"),
                adapter: fld(&s, "adapter"),
                source_id: fld(&s, "source_id"),
                source_type: fld(&s, "source_type"),
                payload: fld(&s, "payload"),
                success_command: fld(&s, "success_command"),
                failure_command: fld(&s, "failure_command"),
            })
            .collect();
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
            if self.dispatch("Claim", claim).is_err() {
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
