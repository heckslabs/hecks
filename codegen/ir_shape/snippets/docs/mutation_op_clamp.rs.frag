    /// Bound a numeric field to a closed interval — `then_set :strength,
    /// clamp: [0.0, 1.0]`. The `value` field carries the source-text
    /// list literal `[min, max]`. Used by per-tick body math (synapse
    /// strength, focus weight) where overshoot is normal and the shell
    /// previously did the awk-side clamp.
