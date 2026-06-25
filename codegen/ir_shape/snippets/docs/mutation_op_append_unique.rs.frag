    /// Append an element to a list field only when no value-equal element is
    /// already present — `then_set :permitted, append_unique: {…}`. The
    /// idempotent sibling of `Append` : resolves `value` and pushes it iff the
    /// list does not already contain it, mirroring `Remove`'s value-equality. A
    /// `list_of(VO)` dedupes by FULL value, since a value object has no identity.
    /// Backs idempotent establishment : a re-fired `Permit` re-appends an
    /// identical record as a no-op, so a boot-seeded allow-list survives reboot
    /// without bloating.
