//! Mirrors `Hecksagain::Naming` (`lib/hecksagain/naming.rb`) — the small,
//! pure name-shape conversions several other derivations lean on:
//! `pascal` (an attribute name -> a synthesized value-object type name,
//! `closed_sets.rs`), `snake` (a value-object type name -> a minted
//! attribute name, `identity.rs`/`references.rs`), plus `qualifier`/
//! `unqualified` for a policy's `on_event` splitting. Deliberately its own
//! module rather than inlined per-caller, matching the Ruby source's own
//! shape: every derivation that needs a name transform reads it from one
//! place, not a second hand-rolled copy per call site.

#[cfg(test)]
mod tests {
    // Stage 2+, once another build/*.rs module needs a real name
    // transform. Left unimplemented rather than guessed at now — Ruby's
    // own `Naming.pascal`/`Naming.snake` have edge cases (existing
    // capitalization, underscores, pluralization for `has_many`) worth
    // reading in full before this is anything more than a stub.
}
