//! Pure name-shape conversions (mirrors `Hecks::Naming`) shared by the other derivations.

// The name-shape rules are the one shared port of `Hecks::Naming` (rust/codegen/src/hecks_naming.rs).
pub use crate::hecks_naming::{demodulise, pascal, plural, singularize, snake};

/// A bare command constant (`Account::Debit`) becomes `Account.Debit`; strings pass through.
///
/// Only the last `::` is rewritten, so `Banking::Account::Debit` -> `Banking::Account.Debit`.
pub fn command_ref(raw: &str) -> String {
    match crate::ruby_value::read(raw.trim()) {
        crate::ruby_value::Value::Str(s) => s,
        crate::ruby_value::Value::Bare(bare) => match bare.rsplit_once("::") {
            Some((path, command)) => format!("{path}.{command}"),
            None => bare,
        },
        other => crate::ruby_value::to_s(&other),
    }
}

/// Event reference of a process manager: a bare constant chain keeps only its last segment.
///
/// `SagaInterpreter` matches a bare `event.name`, never a `.`-qualified one.
pub fn event_name_ref(raw: &str) -> String {
    match crate::ruby_value::read(raw.trim()) {
        crate::ruby_value::Value::Str(s) => s,
        crate::ruby_value::Value::Bare(bare) => demodulise(&bare),
        other => crate::ruby_value::to_s(&other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pluralizes_a_read_model_head_name() {
        assert_eq!(plural("state_style"), "state_styles");
        assert_eq!(plural("collection"), "collections");
        assert_eq!(plural("company"), "companies");
        assert_eq!(plural("box"), "boxes");
    }

    #[test]
    fn demodulises_a_namespaced_constant() {
        assert_eq!(demodulise("Pizzas::Order"), "Order");
        assert_eq!(demodulise("Order"), "Order");
    }

    #[test]
    fn command_refs_a_bare_constant_by_its_last_namespace_segment() {
        assert_eq!(command_ref("Account::Debit"), "Account.Debit");
        assert_eq!(
            command_ref("Banking::Account::Debit"),
            "Banking::Account.Debit"
        );
        assert_eq!(command_ref("Debit"), "Debit");
    }

    #[test]
    fn command_refs_a_legacy_quoted_string_unchanged() {
        assert_eq!(command_ref("\"Account.Debit\""), "Account.Debit");
    }
}
