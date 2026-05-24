    /// f4 — aggregate-level invariants. Each is a predicate the runtime
    /// evaluates on the RESULTING state after EVERY command's mutations,
    /// before save. A `given` is checked on one command ; an invariant is
    /// checked on all of them. When any invariant's predicate is false the
    /// command is rejected (InvariantViolation, 0 events) — the same way a
    /// failed `given` rejects. Empty for aggregates that declare none.
