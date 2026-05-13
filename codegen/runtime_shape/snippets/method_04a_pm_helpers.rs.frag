    /// Inject a synthetic event into the runtime — drive PMs and
    /// policies as if a command had emitted it, without going through
    /// the full command-dispatch path.
    ///
    /// This is the substrate the PM loop driver uses to fire cadence
    /// events (BodyPulse, HeartTick, etc.) at fixed intervals : the
    /// daemon ticks, calls this with a fresh Event, the PM engine
    /// reacts, dispatches cascade, persistence happens — same machinery
    /// as a real command's emit, just with the upstream command stripped.
    ///
    /// Bus listeners + history capture the event ; projections are
    /// not updated (no aggregate state changed). Returns nothing —
    /// callers wanting cascade results should use `dispatch`.
    pub fn publish_synthetic_event(&mut self, event: Event) {
        self.event_bus.publish(event.clone());
        let result = CommandResult {
            aggregate_id: event.aggregate_id.clone(),
            aggregate_type: event.aggregate_type.clone(),
            event: Some(event),
        };
        self.drain_policies(&result);
    }

    /// Sweep every Repository and reload it from disk if its heki
    /// file has been written by a sibling process since our last
    /// load or save. The kernel-floor implementation of the
    /// `RefreshOnPulse` policy declared in
    /// runtime/storage/storage.bluebook : LoopDriver calls this at
    /// the start of every tick so a long-running daemon's in-memory
    /// store stays current with writes from sibling processes
    /// (e.g. `storehouse sleep` dispatching EnterSleep against a
    /// heki the run-loop daemon will read on its next tick).
    ///
    /// **Opt-in via `HECKS_REFRESH_REPOS=1`** — refresh is off by
    /// default. Production daemons (mindstream / long-running
    /// run-loops) set the env var to pick up cross-process state.
    /// Single-process smoke tests and one-shot dispatches leave it
    /// off so refresh doesn't interact with their in-memory cascade
    /// state (e.g. by re-reading partially-written counter-minted
    /// records and mid-cascade breaking singleton fallback ; see
    /// dream_content_smoke flakiness 2026-05-09).
    ///
    /// Cost when on : one stat() per repo per tick when nothing
    /// changed ; per-repo refresh_from_heki gates the actual read
    /// on mtime advance.
    /// Cost when off : zero — the function returns immediately.
    /// Closes the i517 root cause for the production-daemon path.
    pub fn refresh_repositories_from_heki(&mut self) {
        if std::env::var("HECKS_REFRESH_REPOS").ok().as_deref() != Some("1") {
            return;
        }
        for repo in self.repositories.values_mut() {
            repo.refresh_from_heki();
        }
    }

    /// i221 — scan every loaded hecksagon for an `adapter :llm`
    /// declaration whose effective trigger target matches the just-
    /// dispatched `Aggregate.Command` ; for each match, substitute
    /// the prompt template from the upstream state + attrs, call the
    /// resolved provider, and chain the response as a `dispatch_cascade`
    /// into `response_into_target` carrying `response_into_attr`.
    ///
    /// Adapter resolution is by exact target-string match. The IR
    /// holds `trigger_on` (i228) for the firing target and
    /// `response_into_target` for the response routing target. When
    /// `trigger_on` is None the runtime falls back to
    /// `response_into_target` so the historical self-triggering shape
    /// (trigger == response) keeps working without per-adapter
    /// declaration. We compare against `Aggregate.Command`
    /// reconstructed from `result.aggregate_type` + `command_name`.
    /// Adapters with no effective trigger (both fields None) are inert
    /// — just parse-time descriptors — and are skipped silently.
    fn resolve_llm_adapters(&mut self, result: &CommandResult, command_name: &str) {
        let mut fired: std::collections::HashSet<String> = std::collections::HashSet::new();
        self.resolve_llm_adapters_with_excluded(result, command_name, &mut fired);
    }

    /// gap3 (i220-3) helper — `fired` is the set of adapter NAMES that
    /// have already run in this dispatch chain. The cascade-of-cascade
    /// recursion (an :llm response landing on a different command that
    /// itself triggers another :llm adapter) skips any adapter already
    /// in the set, which prevents infinite loops when an adapter's
    /// effective_trigger matches its own response_into_target (the
    /// historical default trigger=response shape, which the very-first
    /// :llm wiring relied on).
    fn resolve_llm_adapters_with_excluded(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        fired: &mut std::collections::HashSet<String>,
    ) {
        let debug_llm = std::env::var("HECKS_DEBUG_LLM").is_ok();
        if debug_llm {
            eprintln!("[llm:debug] resolve_llm_adapters cmd={} agg_type={} hecksagons={} providers={} fired={}",
                command_name, result.aggregate_type, self.hecksagons.len(), self.llm_providers.len(), fired.len());
        }
        if self.hecksagons.is_empty() {
            if debug_llm { eprintln!("[llm:debug] no hecksagons — returning"); }
            return;
        }
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        let target = format!("{}.{}", result.aggregate_type, bare_command);
        if debug_llm { eprintln!("[llm:debug] target={}", target); }

        // Snapshot adapters that match — we need to walk hecksagons
        // by ref but mutate self.repositories/etc. via dispatch_cascade
        // afterward, so collect the adapter clones first. i228 — match
        // on the effective trigger (trigger_on || response_into_target)
        // so PM-cascade-only adapters fire on a ProduceX command while
        // routing the LLM reply into a separate RecordX command. gap3
        // (i220-3) — also exclude adapters in `fired` to break the
        // cascade-of-cascade loop when trigger == response.
        let adapters: Vec<crate::hecksagon_ir::LlmAdapter> = self.hecksagons.iter()
            .flat_map(|h| h.llm_adapters.iter())
            .filter(|la| la.effective_trigger() == Some(target.as_str()))
            .filter(|la| !fired.contains(&la.name))
            .cloned()
            .collect();
        if debug_llm {
            eprintln!("[llm:debug] matched {} adapters (out of {} total in hecksagons)",
                adapters.len(),
                self.hecksagons.iter().map(|h| h.llm_adapters.len()).sum::<usize>());
        }
        if adapters.is_empty() { return; }

        // Snapshot upstream state for placeholder substitution.
        let state_clone: Option<AggregateState> = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .cloned();

        // Build the attrs map (string-shaped) from the upstream state
        // PLUS every other aggregate's latest state (i218 cross-aggregate
        // scaffolder gap). The lucid_dream :lucid_observe template
        // references {{text_fr}} which lives on Dream, not LucidDream
        // — without cross-aggregate access the substitution silently
        // failed and Claude received literal {{text_fr}} markers.
        //
        // Resolution order : prefixed forms ({{Dream_text_fr}}) first,
        // then bare ({{text_fr}}) so prefixed wins on collision. Bare
        // gets last-write-wins across aggregates, which is fine for
        // singleton aggregates (each field is unique-ish) and harmless
        // when callers reach for the prefixed form.
        let mut attrs: HashMap<String, String> = HashMap::new();
        // Cross-aggregate fields with prefixed keys, plus bare keys
        // for cross-aggregate references (last-write-wins across
        // aggregates). The dispatched aggregate's state then writes
        // over both — its fields are the most specific source.
        let agg_names: Vec<String> = self.repositories.keys().cloned().collect();
        for agg_name in &agg_names {
            let states: Vec<AggregateState> = self.repositories.get(agg_name)
                .map(|r| r.all().into_iter().cloned().collect())
                .unwrap_or_default();
            if let Some(latest) = states.last() {
                for (k, v) in &latest.fields {
                    attrs.insert(format!("{}_{}", agg_name, k), v.to_string());
                    if agg_name != &result.aggregate_type {
                        attrs.entry(k.clone()).or_insert_with(|| v.to_string());
                    }
                }
            }
        }
        // Upstream (dispatched) aggregate's state wins on bare-name keys.
        if let Some(s) = state_clone.as_ref() {
            for (k, v) in &s.fields {
                attrs.insert(k.clone(), v.to_string());
            }
        }

        for adapter in &adapters {
            // Mark this adapter as fired BEFORE the cascade so a
            // recursive resolve sees it in the exclude set. The
            // dispatch_cascade can transitively land on the same
            // target ; without the pre-mark, we'd re-enter for the
            // historical trigger==response case.
            fired.insert(adapter.name.clone());

            // Take ownership of the providers map briefly so we can
            // pass an immutable borrow to the dispatcher without
            // tripping the multi-borrow rule on self. The runtime
            // still owns the providers — we just hand them through.
            let outcome = {
                let providers = &self.llm_providers;
                let providers_arg = if providers.is_empty() { None } else { Some(providers) };
                llm_dispatcher::call(adapter, state_clone.as_ref(), &attrs, providers_arg)
            };

            let result_data = match outcome {
                llm_dispatcher::LlmOutcome::Completed(r) => r,
                llm_dispatcher::LlmOutcome::Skipped(_)   => continue,
            };

            // Chain the response as a cascade dispatch. The target is
            // `response_into_target` (Aggregate.Command) ; the kwarg
            // name is `response_into_attr` ; the value is the
            // response text.
            let (target_agg, target_cmd) = match adapter.response_into_target.as_deref()
                .and_then(llm_dispatcher::split_target) {
                Some(p) => p,
                None    => continue,
            };
            let attr_name = match adapter.response_into_attr.as_deref() {
                Some(s) if !s.is_empty() => s.to_string(),
                _ => continue,
            };

            let mut chain_attrs: HashMap<String, Value> = HashMap::new();
            chain_attrs.insert(attr_name, Value::Str(result_data.response_text.clone()));
            let cmd_qualified = format!("{}.{}", target_agg, target_cmd);
            let cascade_outcome = command_dispatch::dispatch_cascade(
                self,
                &cmd_qualified,
                chain_attrs,
                &result.aggregate_type,
                &result.aggregate_id,
            );
            // gap3 (i220-3) — chain LLM resolution on the response cascade
            // so a second adapter whose effective_trigger matches the
            // response-target command fires too. Concretely : the
            // :dream_image adapter cascades into Dream.RecordImage(text_fr:),
            // which is exactly the trigger of the :dream_translate adapter
            // (response_into Dream.RecordImage with attr text_en — its
            // effective_trigger falls back to the same target). Without
            // this recursion, text_en stays empty in production. The chain
            // is finite because the `fired` exclude-set tracks adapter
            // names across the recursion : an adapter whose trigger ==
            // response (the historical self-cascading shape) only fires
            // once per dispatch tree.
            if let Ok(inner_result) = cascade_outcome {
                self.resolve_llm_adapters_with_excluded(
                    &inner_result, &cmd_qualified, fired,
                );
            }
        }
    }

    /// i551 — `:claude_tool` adapter resolver. Sibling of
    /// `resolve_llm_adapters` for the io-adapter family that binds
    /// `Tools.X` dispatches to native primitives (shell, edit, read,
    /// write, grep, glob). For each adapter declared in a loaded
    /// hecksagon whose `command` option matches the just-dispatched
    /// `Aggregate.Command`, the runtime reads the aggregate state,
    /// stringifies it into `attrs`, and calls
    /// `claude_tool_dispatcher::dispatch`.
    ///
    /// After the kernel-floor primitive returns, the resolver chains
    /// the `ClaudeToolResult` back into the aggregate via a follow-on
    /// `dispatch_cascade` into the adapter's `result_into` target
    /// (typically `Tools.RecordResult`). The cascade carries the
    /// originating invocation `id`, the `tool` kind, captured
    /// `output`, `exit_code`, and `ok` flag — so the outcome becomes
    /// a first-class event (ResultRecorded) the runtime can react to
    /// instead of just a stderr line. The stderr log is preserved for
    /// debug visibility.
    fn resolve_claude_tool_adapters(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        dispatch_attrs: &HashMap<String, Value>,
    ) {
        if self.hecksagons.is_empty() { return; }
        let debug = std::env::var("HECKS_DEBUG_CLAUDE_TOOL").is_ok();
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        let target = format!("{}.{}", result.aggregate_type, bare_command);
        if debug {
            eprintln!("[claude_tool:debug] resolve cmd={} target={} hecksagons={}",
                command_name, target, self.hecksagons.len());
        }

        // Snapshot every `:claude_tool` io adapter whose `command`
        // option matches the dispatched target. Values come from
        // parse_options unprocessed — strings still carry their
        // surrounding quotes, symbols still carry their leading colon
        // — so we strip those before matching. `result_into` carries
        // the follow-on cascade target (e.g. "Tools.RecordResult").
        let matched: Vec<(String, String, Option<String>)> = self.hecksagons.iter()
            .flat_map(|h| h.io_adapters.iter())
            .filter(|a| a.kind == "claude_tool")
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
            eprintln!("[claude_tool:debug] matched {} adapter(s) for target={}",
                matched.len(), target);
        }
        if matched.is_empty() { return; }

        // Snapshot the just-dispatched aggregate's state so we can
        // pass its fields to the kernel-floor primitive. The `id`
        // field flows through here so the follow-on RecordResult
        // cascade lands on the same invocation record.
        let state_clone: Option<AggregateState> = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .cloned();
        let mut attrs: HashMap<String, String> = HashMap::new();
        if let Some(s) = state_clone.as_ref() {
            for (k, v) in &s.fields {
                attrs.insert(k.clone(), v.to_string());
            }
        }
        // i559 — overlay the original dispatch attrs on top of the
        // state-derived ones. Tools.Edit's old_string/new_string and
        // Tools.Update's content are event-only payloads (never
        // persisted onto aggregate state per the Tools bluebook), so
        // the state snapshot above is missing them. The dispatch
        // attrs are the only place they exist at this point in the
        // pipeline. Overlay-after-state means the user-supplied
        // values win over any state echo.
        for (k, v) in dispatch_attrs {
            attrs.insert(k.clone(), v.to_string());
        }
        // The aggregate id is authoritative — fall back to the
        // dispatch result if state didn't carry it explicitly.
        let invocation_id = attrs
            .get("id")
            .cloned()
            .unwrap_or_else(|| result.aggregate_id.clone());

        for (_cmd, tool, result_into) in &matched {
            let tool_result = claude_tool_dispatcher::dispatch(tool, &attrs);
            // Preserve the existing debug-visibility log — useful when
            // a cascade fails or the result_into target is missing.
            // i559 — surface the error message inline when ok=false ;
            // previously the message lived only in `tool_result.error`
            // and never made it to stderr, so silent failures showed
            // as `ok=false exit=1 output=""` with no diagnostic.
            let err_tail = match (&tool_result.ok, &tool_result.error) {
                (false, Some(msg)) => format!(" error={:?}", msg),
                _ => String::new(),
            };
            eprintln!(
                "[claude_tool:{}] ok={} exit={} output={:?}{}",
                tool, tool_result.ok, tool_result.exit_code, tool_result.output, err_tail
            );

            // Chain the result back into the aggregate via the
            // adapter's `result_into` target. Mirror the LLM
            // dispatcher's cascade contract : route through
            // `dispatch_cascade` so depth + cycle protection apply,
            // and pass the originating aggregate as the upstream so
            // the same invocation id is reused.
            let result_into_target = match result_into.as_deref() {
                Some(s) if !s.is_empty() => s,
                _ => {
                    if debug {
                        eprintln!("[claude_tool:debug] no result_into on adapter — skipping cascade");
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
            if debug {
                match &cascade_outcome {
                    Ok(_)  => eprintln!("[claude_tool:debug] cascaded into {} ok", result_into_target),
                    Err(e) => eprintln!("[claude_tool:debug] cascade into {} failed: {:?}", result_into_target, e),
                }
            }
            // Swallow the cascade outcome — failures are observable
            // via the debug eprintln above ; we don't want the
            // tool-side error to bubble through the kernel hook and
            // break the original dispatch's return.
            let _ = cascade_outcome;
        }
    }

    /// i220 sub-gap 5 — compute-adapter resolver. Mirror of
    /// `resolve_llm_adapters` for the `:compute` family. Scans every
    /// loaded hecksagon for an `adapter :compute` declaration whose
    /// effective trigger target matches the just-dispatched
    /// `Aggregate.Command` ; for each match, invokes the named
    /// function from the `compute_functions` registry and chains the
    /// returned String as a `dispatch_cascade` into
    /// `response_into_target` carrying `response_into_attr`.
    ///
    /// Same fallback shape as the LLM resolver : adapters with
    /// neither `trigger_on` nor `response_into_target` are inert
    /// descriptors and are skipped silently. The `fired` exclude-set
    /// breaks self-cascade loops (an adapter whose trigger matches
    /// its own response target only fires once per dispatch tree).
    fn resolve_compute_adapters(&mut self, result: &CommandResult, command_name: &str) {
        let mut fired: std::collections::HashSet<String> = std::collections::HashSet::new();
        self.resolve_compute_adapters_with_excluded(result, command_name, &mut fired);
    }

    fn resolve_compute_adapters_with_excluded(
        &mut self,
        result: &CommandResult,
        command_name: &str,
        fired: &mut std::collections::HashSet<String>,
    ) {
        let debug = std::env::var("HECKS_DEBUG").is_ok();
        if debug {
            eprintln!("[compute:debug] resolve_compute_adapters cmd={} agg_type={} hecksagons={} fired={}",
                command_name, result.aggregate_type, self.hecksagons.len(), fired.len());
        }
        if self.hecksagons.is_empty() {
            return;
        }
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
        let target = format!("{}.{}", result.aggregate_type, bare_command);

        // Snapshot adapters that match — same pattern the LLM
        // resolver uses (walk hecksagons by ref then mutate self
        // through dispatch_cascade after).
        let adapters: Vec<crate::hecksagon_ir::ComputeAdapter> = self.hecksagons.iter()
            .flat_map(|h| h.compute_adapters.iter())
            .filter(|ca| ca.effective_trigger() == Some(target.as_str()))
            .filter(|ca| !fired.contains(&ca.name))
            .cloned()
            .collect();
        if debug {
            eprintln!("[compute:debug] matched {} adapters target={}", adapters.len(), target);
        }
        if adapters.is_empty() { return; }

        // Snapshot upstream state for the function call.
        let state_clone: Option<AggregateState> = self
            .find(&result.aggregate_type, &result.aggregate_id)
            .cloned();

        // Build the attrs map (string-shaped) from the upstream
        // state — same projection the LLM resolver uses, but
        // limited to the dispatched aggregate (compute functions
        // generally don't need cross-aggregate scaffolding ; if
        // they ever do we'll lift the bigger projection).
        let mut attrs: HashMap<String, String> = HashMap::new();
        if let Some(s) = state_clone.as_ref() {
            for (k, v) in &s.fields {
                attrs.insert(k.clone(), v.to_string());
            }
        }

        let data_dir = self.data_dir.clone();
        for adapter in &adapters {
            fired.insert(adapter.name.clone());

            let outcome = compute_dispatcher::call(
                adapter,
                state_clone.as_ref(),
                &attrs,
                data_dir.as_deref(),
            );
            let result_data = match outcome {
                compute_dispatcher::ComputeOutcome::Completed(r) => r,
                compute_dispatcher::ComputeOutcome::Skipped(_)   => continue,
            };

            let (target_agg, target_cmd) = match adapter.response_into_target.as_deref()
                .and_then(compute_dispatcher::split_target) {
                Some(p) => p,
                None    => continue,
            };
            let attr_name = match adapter.response_into_attr.as_deref() {
                Some(s) if !s.is_empty() => s.to_string(),
                _ => continue,
            };

            let mut chain_attrs: HashMap<String, Value> = HashMap::new();
            chain_attrs.insert(attr_name, Value::Str(result_data.response_text.clone()));
            let cmd_qualified = format!("{}.{}", target_agg, target_cmd);
            let cascade_outcome = command_dispatch::dispatch_cascade(
                self,
                &cmd_qualified,
                chain_attrs,
                &result.aggregate_type,
                &result.aggregate_id,
            );
            // Recurse through the compute resolver so a chain of
            // :compute adapters all populating context-fields fires
            // end-to-end before the LLM hook lands. The `fired`
            // exclude-set bounds the recursion.
            if let Ok(inner_result) = cascade_outcome {
                self.resolve_compute_adapters_with_excluded(
                    &inner_result, &cmd_qualified, fired,
                );
            }
        }
    }

