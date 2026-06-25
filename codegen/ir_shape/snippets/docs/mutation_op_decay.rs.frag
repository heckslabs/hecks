    /// Exponential decay — `then_set :strength, decay: 0.05`. New value
    /// is `current * (1.0 - rate)`. Convenience over `multiply: 0.95`
    /// when expressing the loss rate is more legible than the survival
    /// rate. Both compose: a typical pulse-organs decay step is decay
    /// THEN clamp.
