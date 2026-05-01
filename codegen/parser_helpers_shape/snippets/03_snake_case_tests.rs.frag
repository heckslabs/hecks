#[cfg(test)]
mod snake_case_tests {
    use super::to_snake_case;

    #[test]
    fn simple_camel_case() {
        assert_eq!(to_snake_case("CamelCase"), "camel_case");
    }

    #[test]
    fn single_word_pascal() {
        assert_eq!(to_snake_case("Pizza"), "pizza");
    }

    #[test]
    fn all_lowercase_passthrough() {
        assert_eq!(to_snake_case("dreiletter"), "dreiletter");
    }

    #[test]
    fn pascal_with_no_internal_caps() {
        assert_eq!(to_snake_case("Dreiletter"), "dreiletter");
    }

    #[test]
    fn three_letter_leading_acronym() {
        assert_eq!(to_snake_case("DNAProfile"), "dna_profile");
    }

    #[test]
    fn uld_pallet() {
        assert_eq!(to_snake_case("ULDPallet"), "uld_pallet");
    }

    #[test]
    fn cbp_inspection() {
        assert_eq!(to_snake_case("CBPInspection"), "cbp_inspection");
    }

    #[test]
    fn ipm_plan() {
        assert_eq!(to_snake_case("IPMPlan"), "ipm_plan");
    }

    #[test]
    fn hvac_equipment() {
        assert_eq!(to_snake_case("HVACEquipment"), "hvac_equipment");
    }

    #[test]
    fn api_endpoint() {
        assert_eq!(to_snake_case("APIEndpoint"), "api_endpoint");
    }

    #[test]
    fn two_letter_leading_acronym() {
        assert_eq!(to_snake_case("AIAnalysis"), "ai_analysis");
    }

    #[test]
    fn trailing_acronym() {
        assert_eq!(to_snake_case("DigitalID"), "digital_id");
    }

    #[test]
    fn already_snake_case() {
        assert_eq!(to_snake_case("already_snake"), "already_snake");
    }

    #[test]
    fn empty_string() {
        assert_eq!(to_snake_case(""), "");
    }

    #[test]
    fn single_uppercase_letter() {
        assert_eq!(to_snake_case("A"), "a");
    }
}

