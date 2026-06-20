    let result = CommandResult {
        aggregate_id,
        aggregate_type: aggregate_name,
        event,
        deltas,
    };
    // Event-sourcing : append to the durable Log at the UNIVERSAL door, so
    // every command that passes through storehouse — top-level dispatch AND
    // cascade reaction (which reaches dispatch_inner via dispatch_cascade,
    // bypassing the Runtime::dispatch wrapper) — is recorded. record_event_append
    // guards against recursion (its own Append) and infra (CascadeRun/OutboundEvent).
    rt.record_event_append(&result, command_name);
    Ok(result)
