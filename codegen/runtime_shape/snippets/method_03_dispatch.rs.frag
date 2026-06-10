    pub fn dispatch(
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
        storehouse_log::dispatch_entry(command_name, &invocation_id, None);

        // i622 verbose — per-attribute trace. One line per attr the
        // caller passed. Gated to the Verbose level inside the logger.
        for (k, v) in &attrs {
            storehouse_log::attribute_trace(
                command_name, &invocation_id, k, &v.to_string()
            );
        }

        // Middleware: before
        let ctx = CommandContext {
            command_name: command_name.to_string(),
            attrs: attrs.clone(),
            result: None,
        };
        self.middleware.run_before(&ctx);

        // Core dispatch
        let result = command_dispatch::dispatch(self, command_name, attrs)?;

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

        // i551 — :claude_tool adapter hook. After the LLM cascade
        // settles, scan loaded hecksagons for any `:claude_tool` io
        // adapter whose `command` option matches the just-dispatched
        // `Aggregate.Command` target. Build the attrs from the just-
        // dispatched aggregate's state UNION the original dispatch
        // attrs (the latter wins on key collision) and call into the
        // kernel-floor dispatcher (claude_tool_dispatcher::dispatch).
        // The native primitive (shell exec, file edit, etc.) runs.
        //
        // The dispatch-attrs overlay matters for tools whose inputs
        // are deliberately event-only payloads (Tools.Edit's
        // old_string/new_string, Tools.Update's content). Those
        // attributes never land on aggregate state by design (the
        // bluebook keeps the heki small), so without the overlay the
        // kernel hook sees `attrs.get("old_string") == None` and
        // returns "missing required attr" — silently, because the
        // log line below didn't surface error messages until i559.
        self.resolve_claude_tool_adapters(&result, command_name, &ctx.attrs);

        // i594 — :mcp adapter hook. Sibling to the :claude_tool arm
        // above. Scans loaded hecksagons for `:mcp` io adapters whose
        // `command` option matches the just-dispatched
        // `Aggregate.Command` target, opens a stdio MCP session
        // against the named server, calls the named tool with the
        // declared args (with {attr} placeholders filled from state
        // ∪ dispatch attrs), and cascades the response into
        // `result_into`. Closes one half of the EmailTool round-trip
        // gap ; the other half is i610's `:gmail` bridge — until that
        // lands, bindings with `server: :gmail` warn (graceful) rather
        // than panic.
        self.resolve_mcp_adapters(&result, command_name, &ctx.attrs);

        // i629 — :exec adapter hook. Sibling to the :claude_tool /
        // :mcp arms above. Scans loaded hecksagons for `:exec` io
        // adapters whose `command` option matches the just-dispatched
        // Aggregate.Command target, runs the adapter's `exec:`
        // program (cwd inherited from the runtime process), and
        // cascades (output, exit_code, ok) into `result_into`. This
        // is what makes `storehouse loop ... Inbox::Inbox.Check` BE
        // the Gmail poll — the dispatch is the fetch.
        self.resolve_exec_adapters(&result, command_name, &ctx.attrs);

        // i-tts - :tts adapter hook. Sibling to the :exec / :mcp /
        // :claude_tool resolvers above. Scans loaded hecksagons for
        // typed :tts adapters whose effective trigger equals the
        // just-dispatched Aggregate.Command target, renders text to
        // audio via the resolved provider (ElevenLabs today),
        // optionally caches + plays. Fire-and-forget per the family
        // contract (`response_field :none`) - no follow-on cascade.
        self.resolve_tts_adapters(&result, command_name, &ctx.attrs);

        Ok(result)
    }

