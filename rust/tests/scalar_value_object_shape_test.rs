//! A SCALAR value-object attribute is a scalar — not an empty list.
//!
//! The locked convention is that list shape is EXPLICIT : `attribute :foos, Foo`
//! is scalar, and a list requires `list_of(X)`. The auto-list heuristic was
//! retired from both parsers, but survived in the runtime's `apply_defaults`,
//! which read `attr.list || vo_names.contains(&attr.attr_type)` and so
//! initialised EVERY value-object-typed attribute as `Value::List(vec![])`.
//!
//! That had a second, quieter victim. `apply_lifecycle_default` only fires when
//! the field is `Value::Null` — so a VO-wrapped lifecycle attribute, already
//! pre-set to an empty list, never received its lifecycle default and read back
//! as the string "[0 items]". `lifecycle_validator` exists to force an explicit
//! `default:` as a workaround for exactly that ; these tests pin the behaviour
//! that makes the workaround unnecessary.
//!
//! Ruby never had the heuristic (`state_resolver.rb` checks `type == "list_of"`
//! explicitly), so this is also a parity guard : Rust had drifted from Ruby,
//! and this keeps it from drifting back.

use std::collections::HashMap;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};

const BB: &str = r#"Hecks.bluebook "Machine" do
  aggregate "Job" do
    identified_by :id
    attribute :id, JobId
    attribute :status, Status
    value_object "JobId" do
      attribute :value, String
    end
    value_object "Status" do
      attribute :value, String
    end
    lifecycle :status, default: "queued" do
      transition "Start" => "running", from: "queued"
    end
    command "Create" do
      role "System"
      attribute :id, JobId
    end
    command "Start" do
      role "System"
      attribute :id, JobId
    end
  end
end
"#;

#[test]
fn vo_wrapped_lifecycle_without_default_gets_the_lifecycle_default() {
    let mut rt = Runtime::boot(parser::parse(BB));
    let mut a = HashMap::new();
    a.insert("id".to_string(), Value::Str("j1".to_string()));
    rt.dispatch("Create", a).expect("Create");

    let job = rt.find("Job", "j1").expect("job exists");
    println!("PROBE status = {:?}", job.get("status"));
    assert_eq!(
        job.get("status"),
        &Value::Str("queued".to_string()),
        "a VO-wrapped lifecycle attr with no explicit default must still receive \
         the LIFECYCLE's default — the auto-list heuristic used to pre-set it to \
         an empty list, defeating apply_lifecycle_default's Null guard",
    );

    // And the transition must then work, which is what actually broke : a field
    // stuck at "[0 items]" matches no `from:` clause.
    let mut s = HashMap::new();
    s.insert("id".to_string(), Value::Str("j1".to_string()));
    rt.dispatch("Start", s).expect("Start transitions from queued");
    assert_eq!(
        rt.find("Job", "j1").unwrap().get("status"),
        &Value::Str("running".to_string()),
        "the lifecycle transition must fire from the defaulted state",
    );
}

/// A scalar VO attribute is NEVER an empty list — the heuristic itself.
const SHAPES: &str = r#"Hecks.bluebook "Shapes" do
  aggregate "Thing" do
    identified_by :id
    attribute :id,    ThingId
    attribute :label, Label
    # `note` is deliberately NOT set by any command — a scalar VO the caller
    # never supplies is the ONLY way to observe apply_defaults' placeholder.
    # A field the command writes would mask the bug by overwriting it.
    attribute :note,  Label
    attribute :tags,  list_of(Label)
    value_object "ThingId" do
      attribute :value, String
    end
    value_object "Label" do
      attribute :value, String
    end
    command "Make" do
      role "System"
      attribute :id,    ThingId
      attribute :label, Label
      then_set :label, to: :label
    end
  end
end
"#;

#[test]
fn a_scalar_value_object_attribute_is_not_an_empty_list() {
    let mut rt = Runtime::boot(parser::parse(SHAPES));
    let mut a = HashMap::new();
    a.insert("id".to_string(), Value::Str("t1".to_string()));
    a.insert("label".to_string(), Value::Str("hello".to_string()));
    rt.dispatch("Make", a).expect("Make");

    let thing = rt.find("Thing", "t1").expect("thing exists");

    // The scalar VO the command SET holds its value.
    assert_eq!(
        thing.get("label"),
        &Value::Str("hello".to_string()),
        "a SCALAR value-object attribute holds a scalar",
    );

    // THE ONE THAT BITES : a scalar VO the command never touches must not be
    // silently turned into an empty list. `label` above cannot catch the
    // heuristic — the command's own mutation overwrites the bad placeholder,
    // which is exactly how this survived retirement unnoticed.
    assert!(
        !matches!(thing.get("note"), Value::List(_)),
        "an untouched SCALAR value-object attribute must not be an empty list — \
         list shape is EXPLICIT (`list_of(X)`), never inferred from the type \
         being a value object (got {:?})",
        thing.get("note"),
    );

    // A DECLARED list still gets its empty-list placeholder — removing the
    // heuristic must not remove the legitimate case.
    assert_eq!(
        thing.get("tags"),
        &Value::List(vec![]),
        "a list_of(...) attribute is still initialised to an empty list",
    );
}
