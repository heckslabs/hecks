    /// Filter clauses applied in sequence by the runtime executor.
    /// `where(field: value)` parses to a WhereClause where `value` is
    /// either a literal (`"available"`) or a kwarg-ref (`":author"`)
    /// resolved against the query's input attributes at dispatch
    /// time. Multiple wheres compose as logical AND. (i101)
