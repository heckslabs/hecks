/// Sentinel describing how a single `with:` attribute resolves at
/// dispatch time. Mirrors the Ruby
/// `Behavior::ProcessManager::ValueSpec` shape exactly so canonical
/// IR is byte-equal across both halves.
///
/// - `Literal` — pass `value` through unchanged.
/// - `FromEvent` — read `event.data[name]` ; fall back to `default`.
/// - `FromPm` — read `pm_instance.data[name]` ; fall back to `default`.
/// - `FromIter` — i221-A — read `iter_record.data[field]` during a
///   `for_each:` sweep dispatch.
///
/// `default` is `None` when omitted in the DSL ; runtime treats a
/// `None` default as "leave the key unset on the dispatched command's
/// input" (the receiving aggregate will see no key, exactly as if the
/// dispatch never named it).
