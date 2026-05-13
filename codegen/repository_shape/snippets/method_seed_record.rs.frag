
    /// Inject an AggregateState into the in-memory store without going
    /// through the heki write path. Used by callers that hydrate the
    /// repository from an alternate storage backend (e.g. the wasm32
    /// worker's R2 read-on-boot path : `bin-buddy/worker/src/lib.rs`
    /// reads `state/<agg>.heki` from R2 and seeds the Repository here).
    ///
    /// Bumps `next_id` past the seeded id when it parses as a u64 — the
    /// same max-id walk `load_persisted` does for filesystem-backed
    /// boots — so subsequent counter-mints don't collide with the
    /// seeded record.
    pub fn seed_record(&mut self, state: AggregateState) {
        if let Ok(n) = state.id.parse::<u64>() {
            if n >= self.next_id {
                self.next_id = n + 1;
            }
        }
        self.store.insert(state.id.clone(), state);
    }

    /// Current `next_id` counter value. Used by external persistence
    /// layers (the wasm32 worker's R2 `state/_counters.heki` write) to
    /// snapshot counter state across requests so counter-minted ids
    /// don't reset to 1 on every cold boot.
    pub fn next_id_value(&self) -> u64 {
        self.next_id
    }

    /// Restore `next_id` from an external counter snapshot. Companion
    /// to `next_id_value` ; the worker reads `_counters.heki` at boot
    /// and calls this for each aggregate that had a persisted counter.
    /// No-op when `value` is `<=` the current next_id (the seeded
    /// records already pushed it past `value`).
    pub fn set_next_id(&mut self, value: u64) {
        if value > self.next_id {
            self.next_id = value;
        }
    }
