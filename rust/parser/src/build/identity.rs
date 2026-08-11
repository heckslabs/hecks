//! Mirrors `AttributeCollector#resolve_identity_field!`/
//! `#resolve_identity_type!` (`lib/hecksagain/bluebook/dsl/attribute_collector.rb`)
//! — the two DERIVING forms of `identified_by`:
//!
//!   `identified_by :field`            — the bare-field form. `field`'s
//!                                        already-declared attribute names
//!                                        a value object; when that value
//!                                        object holds EXACTLY one
//!                                        attribute, the path is
//!                                        `field.<that attribute>`. More
//!                                        than one field is refused,
//!                                        naming every candidate.
//!   `identified_by ValueObject, as: field` — the bare-type form, mirrors
//!                                        `reference_to`'s own shape: the
//!                                        attribute itself is MINTED (name
//!                                        is `as:` or `Naming.snake(type)`),
//!                                        requires the value object to
//!                                        have exactly one field.
//!
//! The third form — `identified_by { name.value }`, a `source`-shaped
//! block — is NOT a derivation at all: its body IS the identity path,
//! captured as raw text and canonicalized (canonical.rs), never resolved
//! against already-declared attributes the way the two blockless forms
//! are. That's why it lives in parse/*.rs's body-gate handling rather
//! than here.

#[cfg(test)]
mod tests {
    // Stage 2 lands real tests here once parse/aggregate.rs and
    // parse/entity.rs actually call into this module — see this file's
    // own header and build/mod.rs's for why nothing is exercised yet.
}
