    /// Process managers — event-driven state machines that coordinate
    /// multi-step business processes across aggregates. Phase 3 of the
    /// dream-study plan ships parser + IR ; runtime instantiation is
    /// Ruby-side. The Rust IR captures only the static shape (name,
    /// correlates_by, starts/ends event types, declared states, and
    /// per-event handlers with their from→to transition). The handler
    /// action body is intentionally NOT captured — that's Ruby code.
