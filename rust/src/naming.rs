
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

pub fn demodulise(type_name: &str) -> &str {
    type_name.rsplit("::").next().unwrap_or(type_name)
}

pub fn reference_key(type_name: &str) -> String {
    snake(demodulise(type_name))
}


pub fn split_dotted(dotted: &str) -> (&str, &str) {
    dotted.split_once('.').unwrap_or((dotted, ""))
}

pub fn qualifier(dotted: &str) -> Option<&str> {
    dotted.split_once('.').map(|(q, _)| q)
}

pub fn unqualified(dotted: &str) -> &str {
    dotted.split_once('.').map(|(_, n)| n).unwrap_or(dotted)
}

pub fn split_verb(verb: &str) -> Option<(&str, &str, &str)> {
    let (path, command) = verb.split_once('.')?;
    let (domain, aggregate) = path.split_once("::")?;
    Some((domain, aggregate, command))
}

#[cfg(test)]
mod tests {
    use super::*;


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

    #[test]
    fn reference_key_agrees_with_the_storage_spelling_on_an_acronym() {
        assert_eq!(reference_key("Banking::ATMCard"), "atm_card");
        assert_eq!(reference_key("ATMCard"), snake("ATMCard"));
    }

    #[test]
    fn split_dotted_splits_a_dotted_name_into_its_two_parts() {
        assert_eq!(split_dotted("Account.Opened"), ("Account", "Opened"));
        assert_eq!(split_dotted("Line.overdue"), ("Line", "overdue"));
    }

    #[test]
    fn split_dotted_reads_a_bare_name_as_the_first_part() {
        assert_eq!(split_dotted("Opened"), ("Opened", ""));
    }

    #[test]
    fn split_dotted_splits_on_the_first_dot_only() {
        assert_eq!(split_dotted("A.B.C"), ("A", "B.C"));
    }

    #[test]
    fn qualifier_names_the_qualifier_or_nothing() {
        assert_eq!(qualifier("Account.Opened"), Some("Account"));
        assert_eq!(qualifier("Opened"), None);
    }

    #[test]
    fn unqualified_strips_any_qualifier_and_keeps_a_bare_name() {
        assert_eq!(unqualified("Account.Opened"), "Opened");
        assert_eq!(unqualified("Opened"), "Opened");
    }

    #[test]
    fn split_verb_reads_a_fully_qualified_verb() {
        assert_eq!(
            split_verb("Pizzas::Pizza.Purchase"),
            Some(("Pizzas", "Pizza", "Purchase"))
        );
    }

    #[test]
    fn split_verb_answers_none_when_not_fully_qualified() {
        assert_eq!(split_verb("Pizza.Purchase"), None);
        assert_eq!(split_verb("Pizzas::Pizza"), None);
        assert_eq!(split_verb(""), None);
    }
}
