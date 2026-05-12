/// Resolution-aware event builder (i111-J). Entity commands emit
/// events tagged with the parent aggregate's name — that's the
/// addressable record from outside the bounded context — but use
/// the entity command's `emits:` declaration when present.
fn build_event_res(
    rt: &Runtime, res: Resolution,
    aggregate_id: &str, attrs: &HashMap<String, Value>,
) -> Option<Event> {
    let agg_idx = res.agg_idx();
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = cmd_for(rt, res);
    let event_name = cmd.emits.clone().unwrap_or_else(|| default_event_name(&cmd.name));
    Some(Event {
        name: event_name,
        aggregate_type: agg.name.clone(),
        aggregate_id: aggregate_id.to_string(),
        data: attrs.clone(),
    })
}

fn default_event_name(cmd_name: &str) -> String {
    if let Some(rest) = cmd_name.strip_prefix("Create") {
        format!("{}Created", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Add") {
        format!("{}Added", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Place") {
        format!("{}Placed", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Cancel") {
        format!("{}Cancelled", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Update") {
        format!("{}Updated", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Remove") {
        format!("{}Removed", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Delete") {
        format!("{}Deleted", rest)
    } else {
        format!("{}Completed", cmd_name)
    }
}

fn parse_default(default: &str, attr_type: &str) -> Value {
    match attr_type {
        "Integer" => Value::Int(default.parse().unwrap_or(0)),
        "Boolean" => Value::Bool(default == "true"),
        _ => Value::Str(default.trim_matches('"').to_string()),
    }
}

fn to_snake_case(s: &str) -> String {
    crate::parser_helpers::to_snake_case(s)
}

// ============================================================
// Error-message helpers — turn bare error variants into
// caller-actionable diagnostics. Wraps useful corpus context
// (available commands, aggregate names, expected self-ref attr
// names) into the String payload so the existing variant shape
// stays untouched but the caller sees what to fix.
// ============================================================

/// List every aggregate visible in the loaded domains, in
/// `Context.Aggregate` form when a context is set so the caller
/// can disambiguate same-name aggregates across bluebooks.
fn available_aggregate_names(rt: &Runtime) -> Vec<String> {
    let mut names: Vec<String> = rt.domain.aggregates.iter()
        .map(|a| match &a.context {
            Some(ctx) => format!("{}.{}", ctx, a.name),
            None => a.name.clone(),
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

/// List every command declared on a specific aggregate (by name),
/// across every bluebook the aggregate appears in. Returned in
/// `Aggregate.Command` form. Includes entity-owned commands as
/// `Aggregate.Entity.Command` so the caller can see the i111-J
/// addressable surface too.
fn commands_on_aggregate(rt: &Runtime, agg_name: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for agg in rt.domain.aggregates.iter().filter(|a| a.name == agg_name) {
        for cmd in &agg.commands {
            out.push(format!("{}.{}", agg.name, cmd.name));
        }
        for ent in &agg.entities {
            for cmd in &ent.commands {
                out.push(format!("{}.{}.{}", agg.name, ent.name, cmd.name));
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

/// List every command in every aggregate/entity in the corpus, in
/// fully-qualified form. Used as the fallback hint for bare-name
/// dispatch misses where we have no aggregate context to narrow
/// the listing by.
fn all_commands_qualified(rt: &Runtime) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for agg in &rt.domain.aggregates {
        let agg_prefix = match &agg.context {
            Some(ctx) => format!("{}.{}", ctx, agg.name),
            None => agg.name.clone(),
        };
        for cmd in &agg.commands {
            out.push(format!("{}.{}", agg_prefix, cmd.name));
        }
        for ent in &agg.entities {
            for cmd in &ent.commands {
                out.push(format!("{}.{}.{}", agg_prefix, ent.name, cmd.name));
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

/// Truncate a candidates list for the error string. Long
/// listings (1000+ commands across the corpus) would drown the
/// error ; the cap keeps the message useful without hiding
/// information silently — the truncated count is included.
fn join_truncated(items: &[String], cap: usize) -> String {
    if items.len() <= cap {
        items.join(", ")
    } else {
        format!("{}, … ({} more)", items[..cap].join(", "), items.len() - cap)
    }
}

fn unknown_aggregate_message(rt: &Runtime, agg_name: &str) -> String {
    let avail = available_aggregate_names(rt);
    if avail.is_empty() {
        format!("{} — no aggregates loaded in this runtime", agg_name)
    } else {
        format!(
            "{} — no aggregate by that name in the loaded domains. Available: {}",
            agg_name,
            join_truncated(&avail, 40),
        )
    }
}

fn unknown_command_message_3part(
    rt: &Runtime, full: &str, a: &str, b: &str, c: &str,
) -> String {
    // 3-part form means either Context.Aggregate.Command or
    // Aggregate.Entity.Command. The caller almost certainly
    // intended one of those — list commands on each candidate
    // aggregate so they can self-correct.
    let mut hints: Vec<String> = Vec::new();
    // Context.Aggregate.Command : aggregates named `b` in context `a`.
    for agg in rt.domain.aggregates.iter()
        .filter(|agg| agg.name == b && agg.context.as_deref() == Some(a))
    {
        for cmd in &agg.commands {
            hints.push(format!("{}.{}.{}", a, b, cmd.name));
        }
    }
    // Aggregate.Entity.Command : aggregates named `a` with entity `b`.
    for agg in rt.domain.aggregates.iter().filter(|agg| agg.name == a) {
        for ent in agg.entities.iter().filter(|e| e.name == b) {
            for cmd in &ent.commands {
                hints.push(format!("{}.{}.{}", a, b, cmd.name));
            }
        }
    }
    hints.sort();
    hints.dedup();
    if hints.is_empty() {
        // No aggregate context matched at all — fall back to a
        // corpus-wide listing so they see what IS available.
        let all = all_commands_qualified(rt);
        format!(
            "{} — no command at that address. Looked for Context.Aggregate.Command ('{}.{}') and Aggregate.Entity.Command ('{}.{}'); neither matched. Available commands: {}",
            full, a, b, a, b,
            join_truncated(&all, 30),
        )
    } else {
        format!(
            "{} — '{}' not declared at that address. Did you mean: {}",
            full, c, join_truncated(&hints, 20),
        )
    }
}

fn unknown_command_message_2part(
    rt: &Runtime, full: &str, agg_name: &str, cmd_name: &str,
) -> String {
    let on_agg = commands_on_aggregate(rt, agg_name);
    if on_agg.is_empty() {
        // The aggregate part itself doesn't exist.
        let aggs = available_aggregate_names(rt);
        format!(
            "{} — no aggregate '{}' in the loaded domains. Available aggregates: {}",
            full, agg_name, join_truncated(&aggs, 40),
        )
    } else {
        format!(
            "{} — command '{}' not declared on '{}'. Available on this aggregate: {}",
            full, cmd_name, agg_name, join_truncated(&on_agg, 30),
        )
    }
}

fn unknown_command_message_bare(rt: &Runtime, cmd_name: &str) -> String {
    let all = all_commands_qualified(rt);
    if all.is_empty() {
        format!("{} — no commands declared in the loaded domains", cmd_name)
    } else {
        format!(
            "{} — no command by that name in the loaded domains. Available: {}",
            cmd_name, join_truncated(&all, 30),
        )
    }
}

/// Compose the "you need to pass a self-ref kwarg" error message.
/// Names the command and the expected attribute names — both the
/// reference's own `name` (which is what gets passed) and the
/// universal `id` fallback so the caller can pick either form.
fn self_ref_missing_message(
    rt: &Runtime, res: Resolution, command_name: &str, ref_name: &str,
) -> String {
    let cmd = cmd_for(rt, res);
    // Collect the reference target so the message names what's
    // being addressed (e.g. "reference_to Pizza" → mention Pizza).
    let target_hint = cmd.references.iter()
        .find(|r| &r.name == ref_name)
        .map(|r| format!(" (reference_to {})", r.target))
        .unwrap_or_default();
    format!(
        "command '{}' requires self-ref attribute '{}=<id>' or 'id=<id>'{}",
        command_name, ref_name, target_hint,
    )
}

