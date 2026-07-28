//! Naming — the one place a domain name becomes a machine name.
//!
//! THE COUNTERPART OF `lib/hecksagain/naming.rb`, function for function and
//! name for name. Ruby holds the semantics ; if the two ever disagree, this
//! file is the bug. The spellings are deliberately identical — `snake`,
//! `demodulise`, `reference_key` — so that a rule can be discussed once and
//! found in both runtimes under the same word.
//!
//! WHY IT IS ONE FUNCTION AND NOT SEVEN. The same rule names the .heki file
//! an aggregate is stored in, the SQL table it maps to, and the key a
//! `reference_to` lets a caller say. Those spellings have to be THE SAME WORD
//! or a record is written to one path and looked for at another. Before this
//! module, this side carried seven hand-rolled versions of the rule under
//! three different semantics — `util::snake_case`, `dispatcher::snake_case`,
//! two inline copies of it, two `storage_name`s, and
//! `parser_helpers::to_snake_case`. Only the last agreed with Ruby.
//!
//! The disagreement was invisible because it only shows up on ACRONYMS, and
//! no aggregate in the corpus has one: `LedgerEntry` snakes identically under
//! every version, `ATMCard` does not. A rule the corpus cannot exercise is a
//! rule nobody is checking, which is why the tests below lead with acronyms
//! and why `spec/naming_spec.rb` states the same cases on the Ruby side.
//!
//! Usage:
//!   naming::snake("ATMCard")                  // "atm_card"
//!   naming::demodulise("Banking::ATMCard")    // "ATMCard"
//!   naming::reference_key("Banking::ATMCard") // "atm_card"

/// PascalCase / camelCase to snake_case.
///
/// Matches Ruby's `Naming.snake`, which is ActiveSupport's `#underscore`
/// rule. A RUN OF CAPITALS IS ONE WORD: the break goes before the capital
/// that starts the next word, never between every pair. So `DNAProfile`
/// becomes `dna_profile` and not `d_n_a_profile`.
///
/// An underscore is inserted before an uppercase letter when either:
///   * the previous character is lowercase or a digit — the ordinary word
///     boundary, `CamelCase` -> `camel_case` ; or
///   * the previous character is uppercase AND the next is lowercase — the
///     acronym-ending boundary, the `C` in `ATMCard`.
pub fn snake(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut result = String::with_capacity(s.len() + 4);
    for i in 0..chars.len() {
        let c = chars[i];
        if c.is_uppercase() && i > 0 {
            let prev = chars[i - 1];
            let next = chars.get(i + 1).copied();
            let prev_lower = prev.is_lowercase() || prev.is_ascii_digit();
            let acronym_end = prev.is_uppercase() && next.map(|n| n.is_lowercase()).unwrap_or(false);
            if prev_lower || acronym_end {
                result.push('_');
            }
        }
        result.extend(c.to_lowercase());
    }
    result
}

/// The bare name of a type, whatever arrived — `Pizzas::Pizza` -> `Pizza`.
///
/// The counterpart of Ruby's `Naming.demodulise`. Only the LAST segment
/// survives, however deep the path.
pub fn demodulise(type_name: &str) -> &str {
    type_name.rsplit("::").next().unwrap_or(type_name)
}

/// THE KEY AN AGGREGATE IS ADDRESSED BY, from outside itself — `transfer`
/// for a Transfer, `atm_card` for an ATMCard.
///
/// The counterpart of Ruby's `Naming.reference_key` (which returns a Symbol
/// where this returns a String — the only difference, and it is a language
/// difference, not a rule difference).
///
/// One idea that wore three names on each side before it wore this one:
/// `reference_key` on the command path (what a `reference_to` lets a caller
/// say), `parent_key` on the query path (whose boundary an element came
/// from), and `own_key` in the saga (whether an event's correlation field
/// names its own emitter). All three open-coded the same transformation, and
/// all three open-coded it WRONG — skipping the acronym rule, so an ATMCard
/// keyed as "a_t_m_card" while Ruby's storage name said "atm_card".
pub fn reference_key(type_name: &str) -> String {
    snake(demodulise(type_name))
}

#[cfg(test)]
mod tests {
    use super::*;

    // These mirror spec/naming_spec.rb case for case. Change one, change
    // both, in the same commit — they are one contract written twice because
    // each runtime has to be able to prove it alone.

    #[test]
    fn snake_lowercases_a_single_word() {
        assert_eq!(snake("Pizza"), "pizza");
    }

    #[test]
    fn snake_breaks_on_the_lower_to_upper_boundary() {
        assert_eq!(snake("LedgerEntry"), "ledger_entry");
        assert_eq!(snake("AddTopping"), "add_topping");
        assert_eq!(snake("CreatePizza"), "create_pizza");
    }

    // THE HARD CASES — the ones the retired implementations got wrong.
    #[test]
    fn snake_keeps_a_leading_acronym_whole() {
        assert_eq!(snake("ATMCard"), "atm_card");
        assert_eq!(snake("HTTPGateway"), "http_gateway");
        assert_eq!(snake("APIEndpoint"), "api_endpoint");
        assert_eq!(snake("DNAProfile"), "dna_profile");
    }

    #[test]
    fn snake_keeps_a_trailing_acronym_whole() {
        assert_eq!(snake("DigitalID"), "digital_id");
        assert_eq!(snake("CustomerAPI"), "customer_api");
    }

    #[test]
    fn snake_treats_a_digit_as_part_of_the_word_it_trails() {
        assert_eq!(snake("Base64Encoder"), "base64_encoder");
    }

    #[test]
    fn snake_leaves_an_already_snake_name_alone() {
        assert_eq!(snake("ledger_entry"), "ledger_entry");
        assert_eq!(snake("pizza"), "pizza");
        assert_eq!(snake("already_snake"), "already_snake");
        assert_eq!(snake("dreiletter"), "dreiletter");
    }

    // Inherited from the retired `parser_helpers::to_snake_case` — real
    // aggregate names from domains that pushed on the acronym rule.
    #[test]
    fn snake_handles_the_acronyms_the_corpus_actually_produced() {
        assert_eq!(snake("ULDPallet"), "uld_pallet");
        assert_eq!(snake("CBPInspection"), "cbp_inspection");
        assert_eq!(snake("IPMPlan"), "ipm_plan");
        assert_eq!(snake("HVACEquipment"), "hvac_equipment");
        assert_eq!(snake("AIAnalysis"), "ai_analysis");
    }

    #[test]
    fn snake_survives_the_degenerate_inputs() {
        assert_eq!(snake(""), "");
        assert_eq!(snake("A"), "a");
        assert_eq!(snake("CamelCase"), "camel_case");
        assert_eq!(snake("Dreiletter"), "dreiletter");
    }

    // Ruby lowercases with String#downcase, which is Unicode-aware. So is
    // char::to_lowercase. An ASCII-only rule — which two of the retired
    // implementations used — silently passed non-ASCII capitals through.
    #[test]
    fn snake_lowercases_beyond_ascii() {
        assert_eq!(snake("Über"), "über");
    }

    #[test]
    fn demodulise_drops_the_domain_prefix() {
        assert_eq!(demodulise("Pizzas::Pizza"), "Pizza");
        assert_eq!(demodulise("Banking::ATMCard"), "ATMCard");
    }

    #[test]
    fn demodulise_leaves_a_bare_name_alone() {
        assert_eq!(demodulise("Pizza"), "Pizza");
    }

    #[test]
    fn demodulise_keeps_only_the_last_segment() {
        assert_eq!(demodulise("A::B::C"), "C");
    }

    #[test]
    fn reference_key_is_the_snake_of_the_bare_name() {
        assert_eq!(reference_key("Transfer"), "transfer");
        assert_eq!(reference_key("LedgerEntry"), "ledger_entry");
        assert_eq!(reference_key("Banking::Transfer"), "transfer");
    }

    // The case that proves the open-coded copies were wrong together: the
    // storage spelling and the addressing spelling MUST be the same word.
    #[test]
    fn reference_key_agrees_with_the_storage_spelling_on_an_acronym() {
        assert_eq!(reference_key("Banking::ATMCard"), "atm_card");
        assert_eq!(reference_key("ATMCard"), snake("ATMCard"));
    }
}
