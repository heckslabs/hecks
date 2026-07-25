//! event_surface — the bus-facing odds of the dispatch path : the statusline
//! breadcrumb phrase (i577 two-segment form), dispatch_isolated (the
//! no-cascade variant behaviors use), and publish_synthetic_event (an event
//! entering the reaction pipeline without a command — the driven-adapter +
//! clock entry).
//!
//! Cask extracted VERBATIM from runtime/mod.rs (shrink-mod phase B, wave 3).
//!
//! [antibody-exempt: rust/src/runtime/event_surface.rs — kernel-floor bus
//!  surface, relocated verbatim from mod.rs blanket.]

use super::*;

impl Runtime {
    /// Render the statusline breadcrumb phrase for a just-resolved
    /// dispatch — the two-segment-plus-dot shape Chris locked
    /// 2026-05-12 :
    ///
    ///   `Domain::Aggregate.Command` (commands, PascalCase)
    ///   `Domain::Aggregate.query_name` (queries, snake_case)
    ///
    /// Where :
    ///
    ///   - **Domain** — the bounded context the aggregate was declared
    ///     in. Prefers `aggregate.context` (the bluebook namespace,
    ///     i.e. `Hecks.bluebook "Name"`), falls back to the merged
    ///     `Domain.category`, finally falls back to the aggregate name
    ///     so the slot never renders empty (matches Chris's
    ///     `Tools.Bash → Tools::Tools.Bash` example).
    ///   - **Aggregate** — the root aggregate name (always the heki
    ///     record being mutated ; entity-targeted dispatches still
    ///     render the aggregate, NOT the entity — the entity slot
    ///     was retired with the 2026-05-12 format correction).
    ///   - **Command** — the bare command name (last `.`-segment of
    ///     the dispatched address ; strips any `Context.` or
    ///     `Aggregate.` prefixes the caller passed).
    ///
    /// Two segments + dot. No entity slot in the path. The earlier
    /// three-segment form (`Tools::Tools::Tools.Bash`) was rejected
    /// for visible duplication ; the dispatcher already knows which
    /// aggregate the command belongs to, the entity layer is an
    /// implementation detail the breadcrumb doesn't surface.
    /// See `hecks_conception/inbox/i577.md` for the spec.
    pub fn format_breadcrumb_phrase(
        &self,
        command_name: &str,
        result: &CommandResult,
    ) -> String {
        let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);

        // Walk aggregates matching the result's type to recover the
        // declared bluebook context. Multiple aggregates may share a
        // name across contexts (the dispatcher disambiguates by
        // qualified address) ; pick the first match whose own
        // commands include the bare name, falling back to a plain
        // name match when no command lookup succeeds.
        let mut domain_name: Option<String> = None;
        for agg in &self.domain.aggregates {
            if agg.name != result.aggregate_type {
                continue;
            }
            let ctx = agg.context.clone()
                .or_else(|| self.domain.category.clone())
                .unwrap_or_else(|| agg.name.clone());
            let owns_command = agg.commands.iter().any(|c| c.name == bare_command)
                || agg.entities.iter().any(|e|
                    e.commands.iter().any(|c| c.name == bare_command));
            if owns_command {
                domain_name = Some(ctx);
                break;
            }
            // Hold the first name-match as a fallback in case no
            // aggregate's commands list owns the bare name (synthetic
            // dispatches, qualified addresses dropping a Context.
            // prefix, etc.).
            if domain_name.is_none() {
                domain_name = Some(ctx);
            }
        }

        // Final fallback : no aggregate IR match at all. Domain
        // defaults to the merged Domain.category when present, else
        // the aggregate name so the slot never empties.
        let domain_name = domain_name.unwrap_or_else(|| {
            self.domain.category.clone()
                .unwrap_or_else(|| result.aggregate_type.clone())
        });

        format!("{}::{}.{}",
            domain_name, result.aggregate_type, bare_command)
    }

    /// Dispatch without firing policy cascades. Used by tests for
    /// SETUP commands so they don't overshoot the test command's
    /// required state. The test command itself dispatches via the
    /// regular `dispatch` so its emit cascade can fire and be
    /// asserted via `expect emits: [...]`.
    pub fn dispatch_isolated(
        &mut self,
        command_name: &str,
        attrs: HashMap<String, Value>,
    ) -> Result<CommandResult, RuntimeError> {
        let result = command_dispatch::dispatch(self, command_name, attrs)?;
        if let Some(ref event) = result.event {
            for proj in &mut self.projections {
                proj.apply(event);
            }
        }
        Ok(result)
    }

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
            // Synthetic events carry no command — no aggregate state changed,
            // so there are no event-sourcing deltas to append.
            deltas: Vec::new(),
        };
        self.drain_policies(&result);
    }
}
