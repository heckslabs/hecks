// Snippet: dump_value_spec body. Three ValueSpec variants
// (Literal / FromEvent / FromPm) → tagged JSON objects with a
// discriminating "kind" field. Defaults serialise as JSON null when
// absent (serde's Option default behaviour). Mirrors
// Ruby's CanonicalIR.dump_value_spec exactly.
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
    }
