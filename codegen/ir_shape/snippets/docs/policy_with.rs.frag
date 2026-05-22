    /// Literal/value-spec args the policy passes to its triggered
    /// command, on top of the upstream event's data. Ordered
    /// (key, ValueSpec) pairs parsed from `with key: "literal"` lines.
    /// The adapters-as-bluebook arc uses this for gap #1 : a policy
    /// firing `Primitive::Process.Spawn` carries the literal `cmd`
    /// and `result_into` the retired :exec resolver used to inline.
    /// For this slice only `ValueSpec::Literal` is produced ; the
    /// state-aware specs (FromState/templating) are deferred.
