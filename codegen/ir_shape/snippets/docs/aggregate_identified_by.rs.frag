    /// Natural primary key — name of the attribute that identifies the
    /// aggregate. When set, dispatch routes by `attrs[identified_by]`
    /// (e.g. `inbox.Item identified_by :ref` → key = the dispatched ref
    /// value). When `None`, the repository mints a fresh u64 id.
    /// Subsumes the old `unique: true` adapter flag — a singleton is
    /// just an aggregate identified by an attribute with one canonical
    /// value, no special case.
