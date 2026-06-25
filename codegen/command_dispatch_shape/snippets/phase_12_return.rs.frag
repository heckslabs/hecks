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
    // Phase-4 causation : a cascaded dispatch carries its upstream (type, id) ;
    // the cause is the last Log event recorded for that aggregate. Root
    // dispatches (no hint) resolve to empty — where CausationTrace stops.
    let causation_id = rt.cause_for_cascade(&cascade_hint);
    rt.record_event_append(&result, command_name, &causation_id);
    // Event Log consolidation : the Consolidate maintenance command folds this
    // realm's per-process shards into the global ordered event.heki. Hooked
    // HERE (not the Runtime::dispatch wrapper) so it fires on BOTH the manual
    // dispatch path AND the driver's dispatch_cascade fire (storehouse drive).
    // No-op for every other command. Replaces the hand-written run_merge daemon.
    rt.run_consolidate_if(command_name);
    Ok(result)
