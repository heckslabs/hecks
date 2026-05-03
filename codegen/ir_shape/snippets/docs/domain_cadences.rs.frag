    /// Cadences — declarative scheduled dispatch. Replaces imperative
    /// while-true-sleep-1-dispatch loops in shells (e.g. mindstream.sh)
    /// with a static IR : interval (e.g. "1s") + ordered list of
    /// `Aggregate.Command` dispatches with literal kwargs. Empty for
    /// bluebooks that declare no cadences.
