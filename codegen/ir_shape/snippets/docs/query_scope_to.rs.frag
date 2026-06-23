    /// Optional read-authZ row-scope. `scope_to :field` injects a
    /// `where(field == :actor)` clause resolved from the reserved `actor`
    /// dispatch kwarg the edge/ACL supplies — gating which rows a caller sees
    /// by ownership. Field-level scoping is the separate View (i254).
    /// (deciderate Layer 0a)
