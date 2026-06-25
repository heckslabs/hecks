/// One on-event handler within a process manager. The transition is
/// always single-entry (validated Ruby-side) ; we surface from→to as
/// two named fields rather than a one-key map so the canonical JSON
/// shape is unambiguous.
///
/// `dispatches` carries the structured list of declarative dispatches
/// declared via the `dispatch "Cmd", with: { ... }` keyword inside
/// `on/transition do ... end` blocks. Empty when the handler used the
/// Ruby-proc form (action body opaque to Rust). Phase 2.b
/// (pm-dispatch-enrichment) lifts bare-string dispatches into
/// `DispatchSpec` carrying per-call attribute flow.
///
/// `set_specs` carries the structured list of `set :attr, value_spec`
/// directives declared inside the on-block. Phase 2.c
/// (pm-attribute-writes) — writes flow into the PM instance's
/// per-instance attributes hash, where future `from_pm(:attr)` reads
/// resolve them. Empty `set_specs` means the handler doesn't write any
/// PM attributes (the most common case ; equivalent to all prior
/// handlers).
