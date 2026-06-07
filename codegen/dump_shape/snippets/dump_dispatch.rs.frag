// Snippet: dump_dispatch body. One DispatchSpec → JSON object. The
// with_pairs preamble preserves with-clause ordering by emitting the
// hash as an array of [key, value] pairs ; each value is run through
// dump_value_spec so literal / from_event / from_pm round-trip
// identically with the Ruby canonical_ir.
//
// i221-A — emits "for_each" key on every DispatchSpec. Some →
// {source_context, source_aggregate, query_name} object ; None → JSON
// null. Bare dispatches (the common case) keep their byte-identical
// shape ; the only addition is one new key whose value is null.
//
// source_context disambiguates same-named aggregates across bluebooks
// (3-part "Context.Aggregate.query" qualified path). Null when the
// 2-part "Aggregate.query" form was used.
    let with_pairs: Vec<Value> = d
        .with_spec
        .iter()
        .map(|(k, spec)| json!([k, dump_value_spec(spec)]))
        .collect();
    let for_each = match &d.for_each {
        Some(fe) => json!({
            "source_context": fe.source_context,
            "source_aggregate": fe.source_aggregate,
            "query_name": fe.query_name,
            "query_inputs": fe.query_inputs.iter()
                .map(|(k, spec)| json!([k, dump_value_spec(spec)]))
                .collect::<Vec<_>>(),
        }),
        None => Value::Null,
    };
    json!({
        "command_name": d.command_name,
        "for_each": for_each,
        "with": with_pairs,
    })
