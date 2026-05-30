    // Emit the authored DSL keyword (belongs_to / has_one / has_many /
    // reference_to) as a bare JSON string. Round-trips through
    // ReferenceKind::as_str so the canonical IR shape carries authored
    // intent rather than a Rust-internal enum tag.
    json!(k.as_str())
