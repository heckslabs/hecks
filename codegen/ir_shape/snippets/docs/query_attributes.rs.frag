    /// Query input parameters. When the DSL declares `attribute :author,
    /// String` inside a query block, that attribute becomes a kwarg the
    /// caller supplies at dispatch time. Where-clauses can reference
    /// these attributes by their symbol form (`:author`) and the runtime
    /// resolves the kwarg to a literal at filter time. (i101)
