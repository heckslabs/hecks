    pub fn dispatch(
        &mut self,
        command_name: &str,
        attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        // Middleware: before
        let ctx = CommandContext {
            command_name: command_name.to_string(),
            attrs: attrs.clone(),
            result: None,
        };
        self.middleware.run_before(&ctx);

        // Core dispatch
        let result = command_dispatch::dispatch(self, command_name, attrs)?;

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
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs()).unwrap_or(0);
                let path = format!("{}/.last_dispatch", dir.trim_end_matches('/'));
                let _ = std::fs::write(&path,
                    format!("{}.{}\n{}\n", result.aggregate_type, command_name, now));
            }
        }

        // Middleware: after
        let ctx = CommandContext {
            command_name: command_name.to_string(),
            attrs: ctx.attrs,
            result: Some(CommandResult {
                aggregate_id: result.aggregate_id.clone(),
                aggregate_type: result.aggregate_type.clone(),
                event: result.event.clone(),
            }),
        };
        self.middleware.run_after(&ctx);

        // Update projections
        if let Some(ref event) = result.event {
            for proj in &mut self.projections {
                proj.apply(event);
            }
        }

        // i220 sub-gap 5 — resolve `:compute` adapters BEFORE the
        // policy cascade drains. Compute adapters populate context
        // fields (e.g. recent_musings_summary) that downstream
        // policy-driven dispatches (and the LLM hook below) read.
        // Firing them first means a single top-level dispatch
        // produces the fully-populated downstream chain.
        self.resolve_compute_adapters(&result, command_name);

        // Drain policy triggers — recursively, so chains cascade fully
        self.drain_policies(&result);

        // i221 — LLM dispatcher hook. After the cascade settles,
        // scan loaded hecksagons for any `:llm` adapter whose
        // `response_into_target` matches `Aggregate.Command` (the
        // command the user just dispatched). When one matches,
        // substitute its prompt template from the upstream
        // aggregate's state + the dispatched attrs, call the
        // resolved provider, and chain the response as a real
        // dispatch back into the target with `response_into_attr`
        // carrying the response text. The chain is finite by
        // discipline : the response-driven dispatch has the
        // populated attr already so its givens fall through (no
        // re-entry), exactly as the Ruby surface relies on.
        self.resolve_llm_adapters(&result, command_name);

        Ok(result)
    }

