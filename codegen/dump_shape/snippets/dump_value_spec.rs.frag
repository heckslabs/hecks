// Snippet: dump_value_spec body. Four ValueSpec variants
// (Literal / FromEvent / FromPm / FromIter) → tagged JSON objects with
// a discriminating "kind" field. Defaults serialise as JSON null when
// absent (serde's Option default behaviour). FromIter is the i221-A
// addition for `for_each:` sweep dispatches — it carries a `field`
// identifier (no default ; sweeps either find the iter record's
// attribute or the runtime surfaces the miss). Mirrors Ruby's
// CanonicalIR.dump_value_spec exactly.
    match spec {
        ValueSpec::Literal { value } => json!({
            "kind": "literal",
            "value": value,
        }),
        ValueSpec::FromEvent { name, default } => json!({
            "kind": "from_event",
            "name": name,
            "default": default,
        }),
        ValueSpec::FromPm { name, default } => json!({
            "kind": "from_pm",
            "name": name,
            "default": default,
        }),
        ValueSpec::FromIter { field } => json!({
            "kind": "from_iter",
            "field": field,
        }),
    }
