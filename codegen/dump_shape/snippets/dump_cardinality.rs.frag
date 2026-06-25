    // Emit the multiplicity bounds as a nested { min, max } object. None
    // serialises as JSON null so unbounded collections (has_many) round-
    // trip cleanly through Ruby's hash form.
    json!({
        "min": c.min,
        "max": c.max,
    })
