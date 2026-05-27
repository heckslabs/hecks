/// f4 — one declared aggregate-level invariant. `name` is the rule's
/// stable identifier (the string passed to `invariant "..."`) ; it doubles
/// as the human-readable message when the rule is violated. `expression`
/// is the source text of the `holds_when { ... }` predicate — the same
/// single-line predicate grammar a `given` carries, evaluated against the
/// post-mutation state. Round-trips byte-identically through
/// canonical_ir.rb / dump.rs.
