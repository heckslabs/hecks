// Snippet: dump_dispatch body. One DispatchSpec → JSON object. The
// with_pairs preamble preserves with-clause ordering by emitting the
// hash as an array of [key, value] pairs ; each value is run through
// dump_value_spec so literal / from_event / from_pm round-trip
// identically with the Ruby canonical_ir.
    let with_pairs: Vec<Value> = d
        .with_spec
        .iter()
        .map(|(k, spec)| json!([k, dump_value_spec(spec)]))
        .collect();
    json!({
        "command_name": d.command_name,
        "with": with_pairs,
    })
