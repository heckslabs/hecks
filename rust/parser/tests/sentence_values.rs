//! Drives `hecks-parse examples` over steps that give a value made of parts: a plate that has a
//! weight and a size, a glass that has a size and a number of ounces. A step names the parts in
//! words, and what it names wrongly is refused with the names that would have worked.

// reason: these helpers are test scaffolding outside `#[test]` fns, which clippy.toml does not
// cover; a failed unwrap here is the test failing.
#![allow(clippy::unwrap_used, clippy::expect_used)]
// reason: `{values}` in the example text is a placeholder this file fills, not a format argument.
#![allow(clippy::literal_string_with_formatting_args)]

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

const KITCHEN: &str = "\
Domain: Kitchen
  What the kitchen cooks.

Aggregate: Dish
  A dish on the menu.

  A dish is identified by its name.

  It has:
    a name: dish name
    a plate: plate
    a glass: glass
    a note: dish note, optional

  A dish name has a value: text.

  A dish note has a value: text.

  A weight has:
    a grams: whole number

  A size is one of: small and large.

  A plate has:
    a weight grams: weight
    a size: size

  A glass has:
    a size: size
    an ounces: whole number

  Command: Prepare
    Who: Cook
    It takes:
      a name: dish name
      a plate: plate
      a glass: glass
      a note: dish note, optional
    Then the name, the plate, the glass and the note are set
    And DishPrepared is announced
";

const GIVEN: &str = "\
Examples for: Kitchen

Background:
  Remy is a Cook

Example: A dish is prepared
  When Remy prepares a dish with {values}
  Then DishPrepared is announced
";

const STEP: &str =
    "plate weight 200 grams, plate size \"small\", glass size \"large\" and ounces 12";

fn write(name: &str, source: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("hecks-values-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join(name);
    fs::write(&path, source).unwrap();
    path
}

/// Compiles `GIVEN` with `values` after the `with` of its step.
fn compile(name: &str, values: &str) -> Output {
    let examples = GIVEN.replacen("{values}", values, 1);
    let declaration = write(&format!("{name}.bluebook"), KITCHEN);
    let source = write(&format!("{name}.examples"), &examples);
    Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args([
            "examples",
            "--bluebook",
            "Kitchen",
            "--examples",
            source.to_str().unwrap(),
            declaration.to_str().unwrap(),
        ])
        .output()
        .expect("failed to run hecks-parse")
}

/// The `.behaviors` text for a step that must compile.
fn compiled(name: &str, values: &str) -> String {
    let output = compile(name, values);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).to_string()
}

/// The refusal for a step that must be refused.
fn refusal(name: &str, values: &str) -> String {
    let output = compile(name, values);
    assert!(
        !output.status.success(),
        "{name}: expected a refusal, got: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    String::from_utf8_lossy(&output.stderr).trim().to_string()
}

const WHOLE: &str = "input name: { value: \"Soup\" }, plate: { weight_grams: { grams: 200 }, \
size: { value: \"small\" } }, glass: { size: { value: \"large\" }, ounces: 12 }";

fn with_name(rest: &str) -> String {
    format!("name \"Soup\", {rest}")
}

#[test]
fn a_step_names_the_parts_of_a_value_and_each_lands_where_it_belongs() {
    let text = compiled("whole", &with_name(STEP));
    assert!(text.contains(WHOLE), "{text}");
}

#[test]
fn the_unit_after_a_number_is_optional() {
    let bare =
        with_name("plate weight 200, plate size \"small\", glass size \"large\" and ounces 12");
    assert!(compiled("bare", &bare).contains(WHOLE));
}

#[test]
fn the_whole_name_of_a_part_works_as_well_as_the_short_one() {
    let long = with_name(
        "plate weight grams 200, plate size \"small\", glass size \"large\", glass ounces 12",
    );
    assert!(compiled("long", &long).contains(WHOLE));
}

#[test]
fn a_value_left_out_whole_is_not_asked_for_when_it_is_optional() {
    let text = compiled("optional", &with_name(STEP));
    assert!(!text.contains("note:"), "{text}");
}

#[test]
fn a_name_two_parts_share_is_refused_with_the_whole_names_that_tell_them_apart() {
    let error = refusal("ambiguous", &with_name("plate weight 200, size \"small\""));
    assert!(
        error.contains("'size' could be any of: plate size, glass size. Say which"),
        "{error}"
    );
}

#[test]
fn a_value_that_holds_several_parts_is_refused_with_the_parts_to_name() {
    let error = refusal("group", &with_name("plate \"round\""));
    assert!(
        error.contains("plate holds several values; give each by name: weight, plate size"),
        "{error}"
    );
}

#[test]
fn a_part_that_does_not_exist_lists_the_parts_there_are() {
    let error = refusal("unknown", &with_name("plate crust \"thin\""));
    assert!(
        error.contains(
            "prepare takes no 'plate crust'. It takes: name, weight, plate size, glass size, \
ounces, note"
        ),
        "{error}"
    );
}

#[test]
fn a_part_left_out_is_named() {
    let error = refusal(
        "missing",
        &with_name("plate weight 200, plate size \"small\" and ounces 12"),
    );
    assert!(error.contains("prepare needs a glass size"), "{error}");
}

#[test]
fn a_part_given_twice_is_refused() {
    let twice = with_name("plate weight 200, plate weight 300, plate size \"small\"");
    assert!(refusal("twice", &twice).contains("weight is given twice"));
}

#[test]
fn a_part_given_the_wrong_kind_of_value_says_what_it_takes() {
    let wrong = with_name("plate weight \"heavy\", plate size \"small\"");
    assert!(refusal("wrong", &wrong).contains("weight is a whole number"));
}
