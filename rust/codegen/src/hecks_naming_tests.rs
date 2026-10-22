//! Pins `hecks_naming` (the one Rust port of `lib/hecks/naming.rb`, compiled into several Cargo
//! projects) against `spec/fixtures/naming_vectors.json`. `spec/naming_vectors_spec.rb` asserts
//! the same tables against Ruby, so a drift in either runtime fails a test on its own side.
//! Lives beside the shared file, not in it, because the file is std-only and the tests read JSON.

use crate::hecks_naming::{
    demodulise, pascal, plural, reference_key, ruby_downcase, singularize, snake,
};
use crate::json::Json;

fn rows(section: &str) -> Vec<(String, String)> {
    let table = Json::parse(include_str!("../../../spec/fixtures/naming_vectors.json")).unwrap();
    let rows: Vec<(String, String)> = table
        .get(section)
        .unwrap_or_else(|| panic!("{section} table went missing"))
        .each()
        .iter()
        .map(|row| {
            (
                row.get("input").unwrap().to_s(),
                row.get("expected").unwrap().to_s(),
            )
        })
        .collect();
    assert!(!rows.is_empty(), "{section} rows went missing");
    rows
}

fn assert_every_row(section: &str, rule: fn(&str) -> String) {
    for (input, expected) in rows(section) {
        assert_eq!(rule(&input), expected, "{section}({input:?})");
    }
}

#[test]
fn snake_matches_every_shared_row() {
    assert_every_row("snake", snake);
}

#[test]
fn storage_name_is_snake_of_the_demodulised_name() {
    assert_every_row("storage_name", |input| snake(&demodulise(input)));
}

#[test]
fn pascal_matches_every_shared_row() {
    assert_every_row("pascal", pascal);
}

#[test]
fn plural_matches_every_shared_row() {
    assert_every_row("plural", plural);
}

#[test]
fn singularize_matches_every_shared_row() {
    assert_every_row("singularize", singularize);
}

#[test]
fn demodulise_matches_every_shared_row() {
    assert_every_row("demodulise", demodulise);
}

#[test]
fn reference_key_matches_every_shared_row() {
    assert_every_row("reference_key", reference_key);
}

#[test]
fn ruby_downcase_folds_unicode_capitals_one_character_at_a_time() {
    assert_eq!(ruby_downcase("ÉCOLE"), "école");
    assert_eq!(ruby_downcase("ΟΔΥΣΣΕΑΣ"), "οδυσσεασ");
    assert_eq!(ruby_downcase("ascii"), "ascii");
}

#[test]
fn a_boxes_collection_names_the_box_aggregate_again() {
    assert_eq!(singularize(&plural("Box")), "Box");
    assert_eq!(singularize("Invoices"), "Invoice");
}
