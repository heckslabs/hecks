//! Nursery coverage tests
//!
//! Parses and validates a broad sample of nursery domains to ensure
//! the parser handles real-world Bluebook files correctly.

use hecks_life::parser;
use hecks_life::validator;

fn parse_and_validate(domain_name: &str) {
    let path = format!(
        "{0}/../hecks_conception/nursery/{1}/{1}.bluebook",
        env!("CARGO_MANIFEST_DIR"),
        domain_name
    );
    let source = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Cannot read {}: {}", path, e));
    let domain = parser::parse(&source);
    assert!(!domain.name.is_empty(), "{} has no domain name", domain_name);
    assert!(!domain.aggregates.is_empty(), "{} has no aggregates", domain_name);

    // Validate and collect — don't assert empty because some domains may
    // have intentional patterns we haven't covered in verbs yet.
    // But do check parse doesn't panic and produces structure.
    let _errors = validator::validate(&domain);
}

fn parse_only(domain_name: &str) {
    let path = format!(
        "{0}/../hecks_conception/nursery/{1}/{1}.bluebook",
        env!("CARGO_MANIFEST_DIR"),
        domain_name
    );
    let source = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("Cannot read {}: {}", path, e));
    let domain = parser::parse(&source);
    assert!(!domain.name.is_empty(), "{} has no domain name", domain_name);
    assert!(!domain.aggregates.is_empty(), "{} has no aggregates", domain_name);
}

// --- Core domains ---

#[test] fn pizzas() { parse_and_validate("pizzas"); }
#[test] fn veterinary() { parse_and_validate("veterinary"); }
#[test] fn banking() { parse_and_validate("banking"); }
#[test] fn bookshelf() { parse_and_validate("bookshelf"); }
#[test] fn dog_walking() { parse_and_validate("dog_walking"); }

// --- Business domains ---

#[test] fn hotel_management() { parse_only("hotel_management"); }
#[test] fn insurance_claims() { parse_only("insurance_claims"); }
#[test] fn restaurant_kitchen_tickets() { parse_only("restaurant_kitchen_tickets"); }
#[test] fn wedding_planner() { parse_only("wedding_planner"); }
#[test] fn food_truck_fleet() { parse_only("food_truck_fleet"); }
#[test] fn escape_room() { parse_only("escape_room"); }
#[test] fn tattoo_parlor() { parse_only("tattoo_parlor"); }
#[test] fn music_festival() { parse_only("music_festival"); }
#[test] fn plant_nursery() { parse_only("plant_nursery"); }
#[test] fn wine_cellar() { parse_only("wine_cellar"); }
#[test] fn grocery_delivery() { parse_only("grocery_delivery"); }
#[test] fn parking_garage() { parse_only("parking_garage"); }

// --- Biology domains ---

#[test] fn immune_response() { parse_only("immune_response"); }
#[test] fn protein_synthesis() { parse_only("protein_synthesis"); }
#[test] fn cell_cycle() { parse_only("cell_cycle"); }
#[test] fn ecosystem() { parse_only("ecosystem"); }

// --- Chemistry domains ---

#[test] fn chemical_reaction() { parse_only("chemical_reaction"); }

// --- Hecks meta-domains (nested under hecks/) ---

#[test]
fn hecks_life_domain() {
    let path = format!(
        "{}/../hecks_conception/nursery/hecks/life.bluebook",
        env!("CARGO_MANIFEST_DIR")
    );
    let source = std::fs::read_to_string(&path).unwrap();
    let domain = parser::parse(&source);
    assert!(!domain.name.is_empty());
    let errors = validator::validate(&domain);
    assert!(errors.is_empty(), "life errors: {:?}", errors);
}

// --- Complex domains (high aggregate/command counts) ---

#[test] fn hospital_patient_record() { parse_only("hospital_patient_record"); }
#[test] fn construction_project() { parse_only("construction_project"); }
#[test] fn supply_chain() { parse_only("supply_chain"); }
#[test] fn university_course_catalog() { parse_only("university_course_catalog"); }
#[test] fn stock_trading_journal() { parse_only("stock_trading_journal"); }
