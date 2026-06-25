    /// The effect-port verdict re-entry commands, named in a `do success
    /// "..." failure "..." end` block on the bind. `success` is dispatched
    /// when the adapter reports success, `failure` on failure. Both empty
    /// for reply / fulfillment binds (no block). The binding is the ONLY
    /// home on the locked surface for these names : the family and adapter
    /// are generic (declared once, used across domains) ; the binding alone
    /// is domain-specific.
