    /// Record-level deletion — `then_delete` (no field, no value). When
    /// applied, marks the aggregate state for removal so the dispatcher
    /// calls `Repository::delete` instead of `Repository::save`. The
    /// `field` and `value` slots on `Mutation` are empty strings ; the
    /// op type alone carries the intent. Used by retire-style commands
    /// (e.g. Antibody.RetireExemption) that close out a record after
    /// emitting their event.
