// Snippet: dump_pm_handler body. Phase 2.b PM dispatch enrichment —
// dump_pm_handler now emits both the structured `dispatches` list
// (each carrying a command_name + ordered with-spec) and `set_specs`
// (per-handler attribute mutations modelled as ValueSpec). The
// set_specs preamble runs each value through dump_value_spec so the
// canonical JSON shape matches Ruby's CanonicalIR.dump_pm_handler.
    let set_pairs: Vec<Value> = h
        .set_specs
        .iter()
        .map(|(k, spec)| json!([k, dump_value_spec(spec)]))
        .collect();
    json!({
        "dispatches": h.dispatches.iter().map(dump_dispatch).collect::<Vec<_>>(),
        "event_type": h.event_type,
        "from_state": h.from_state,
        "set_specs": set_pairs,
        "to_state": h.to_state,
    })
