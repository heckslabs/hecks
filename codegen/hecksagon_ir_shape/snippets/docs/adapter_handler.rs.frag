    /// The standalone handler the adapter-host execs for this adapter
    /// (`bin/stripe-handler`). Set on out-of-process adapters (payment,
    /// report, tts) ; empty for in-process persistence adapters (heki /
    /// memory), which the runtime injects directly and never shells out.
    /// Parsed from the `handler "..."` line of the `*.adapter` declaration.
