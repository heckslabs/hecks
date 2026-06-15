    /// Sprint 14 — fire every `driving on cron` adapter handler attached
    /// to this runtime. v1 fires every cron handler unconditionally on
    /// each call (no expression evaluation yet) ; live `storehouse loop`
    /// runs invoke this from `LoopDriver::tick_once`, behaviors tests
    /// invoke it via `kind: :driving_tick`. Pure delegation to the
    /// resolver module ; kept on Runtime so callers don't need to import
    /// the resolver path.
    pub fn fire_driving_cron_ticks(&mut self) {
        driving_adapter_resolver::fire_driving_cron_ticks(self);
    }
