    /// Multiplicative scaling — `then_set :strength, multiply: 0.95`.
    /// The `value` field on `Mutation` carries the source-text factor;
    /// the runtime parses it as f64. Float-typed result is stored as a
    /// numeric Str the way `increment_float` does, preserving parity
    /// with the existing fractional path.
