//! `correlates_by` names a SCALAR, now checked rather than trusted — the
//! Rust twin of spec/dsl_spec.rb's whole-document correlation-key specs.
//! `ProcessManagerBuilder#validate!`'s dot check (mirrored in
//! `Runtime::boot` right above this one) only knows the spelling HAS a dot;
//! this walks what the dot actually reaches, against whichever command
//! really emits an event the process manager reacts to, and refuses if it
//! still lands on a value object — RESTART.md's named gap (Ruby keys a
//! saga on the object itself, Rust on its JSON text) never gets the chance
//! to bite if the declaration cannot describe a non-scalar key at all.

use std::fs;
use storehouse::dispatcher::Runtime;

fn boot_with(correlates_by: &str) -> Result<Runtime, String> {
    use std::hash::{Hash, Hasher};
    let source = format!(
        r#"Hecks.bluebook "NonScalarKey" do
  aggregate "Thing" do
    identified_by {{ id.value }}
    attribute :id, ThingId

    value_object "ThingId" do
      attribute :value, String
    end

    value_object "Ref" do
      attribute :amount, Amount
    end

    value_object "Amount" do
      attribute :cents, Integer
    end

    command "Start" do
      attribute :id,  ThingId
      attribute :ref, Ref
      emits "Started"
    end
  end

  process_manager "Broken" do
    correlates_by :"{correlates_by}"
    starts_on "Started"
    state "a"
    state "b"

    on "Started", transition: {{ "a" => "b" }} do
      dispatch "Thing.Start"
    end
  end
end
"#
    );
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    source.hash(&mut hasher);
    let path = std::env::temp_dir().join(format!("correlation_key_test_{:x}.bluebook", hasher.finish()));
    fs::write(&path, source).unwrap();
    let result = Runtime::boot(&path);
    fs::remove_file(&path).ok();
    result
}

#[test]
fn correlates_by_that_resolves_to_a_value_object_refuses_at_boot() {
    // `ref.amount` is a real field on a real value object — `Ref` genuinely
    // declares `amount` — but `amount`'s own type, `Amount`, is ANOTHER
    // value object, not a scalar. The dot ran out one VO short of a real
    // field.
    let error = boot_with("ref.amount").err().expect("a non-scalar correlation key must refuse");
    assert!(
        error.contains("Amount is a value object, not a scalar"),
        "unexpected refusal wording: {error}"
    );
}

#[test]
fn correlates_by_naming_a_field_the_value_object_does_not_have_refuses_at_boot() {
    let error = boot_with("ref.currency").err().expect("an unresolvable field must refuse");
    assert!(error.contains("Ref has no field \"currency\""), "unexpected refusal wording: {error}");
}

#[test]
fn correlates_by_that_resolves_to_a_real_scalar_boots_cleanly() {
    let runtime = boot_with("id.value");
    assert!(runtime.is_ok(), "a scalar correlation key must not refuse: {:?}", runtime.err());
}
