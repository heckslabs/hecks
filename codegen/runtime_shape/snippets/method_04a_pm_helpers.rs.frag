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
        let debug_llm = std::env::var("HECKS_DEBUG_LLM").is_ok();
        if debug_llm {
            eprintln!("[llm:debug] resolve_llm_adapters cmd={} agg_type={} hecksagons={} providers={}",
                command_name, result.aggregate_type, self.hecksagons.len(), self.llm_providers.len());
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
        // routing the LLM reply into a separate RecordX command.
        let adapters: Vec<crate::hecksagon_ir::LlmAdapter> = self.hecksagons.iter()
            .flat_map(|h| h.llm_adapters.iter())
            .filter(|la| la.effective_trigger() == Some(target.as_str()))
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
            let _ = command_dispatch::dispatch_cascade(
                self,
                &cmd_qualified,
                chain_attrs,
                &result.aggregate_type,
                &result.aggregate_id,
            );
        }
    }

