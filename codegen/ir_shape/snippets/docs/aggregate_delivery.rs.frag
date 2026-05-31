    /// Sprint 14 (migration-coexistence) — per-aggregate event-delivery
    /// mode. Defaults to `Sync` (the historical inline publish path).
    /// `Actor` routes events through the per-aggregate mailbox stub
    /// (`Runtime::enqueue_and_drain`). See the `DeliveryMode` enum for
    /// the full coexistence contract.
