    /// i221-C (where-fan-out) — inputs threaded into the swept query so
    /// it filters by the triggering event. `where: { worker: from_event
    /// (:worker) }` on the `for_each:` hash ; each ValueSpec resolves
    /// against the event at sweep time -> query attrs -> the input-bound
    /// `where worker: :worker` filters. Empty = parameterless sweep (the
    /// i221-A back-compat default).
