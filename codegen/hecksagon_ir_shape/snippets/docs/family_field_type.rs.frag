/// bucket-3 — one config field a family declares. The name a `.world` block
/// keys on, plus where its value comes from (the declaration form sets it) :
///   `field  :timeout_ms`           -> source `direct` : the `.world` value IS the literal.
///   `field  :endpoint, from: :env` -> source `env`    : the `.world` value is an env-var NAME.
///   `secret :token`                -> source `secret` : env-var name, never logged.
