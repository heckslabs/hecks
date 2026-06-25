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

