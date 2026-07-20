//! A declared `pattern:` reaches the schema, the form and the DOOR.
//!
//! The closed-SHAPE sibling of `one_of`'s closed vocabulary. One declaration in
//! the bluebook must produce three consistent behaviours — otherwise the form
//! refuses a value that `curl` sails through, which is the form/gate split this
//! codebase keeps paying for.
//!
//! The regex a bluebook may DECLARE is restricted to the Ruby∩Rust intersection
//! (`pattern_subset`), so the Rust runtime, the Ruby behaviors runner and the
//! browser all read the same source text the same way.

use std::collections::HashMap;
use storehouse::parser;
use storehouse::runtime::{Runtime, RuntimeError, Value};

const BB: &str = r#"Hecks.bluebook "Directory" do
  aggregate "Contact" do
    identified_by :id
    attribute :id,    ContactId
    attribute :email, Email
    attribute :sku,   String, pattern: '^[A-Z]{3}-\d{4}$'
    value_object "ContactId" do
      attribute :value, String
    end
    value_object "Email" do
      attribute :value, String, pattern: '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    end
    command "Add" do
      role "System"
      attribute :id,    ContactId
      attribute :email, Email
    end
    command "Tag" do
      role "System"
      attribute :id,  ContactId
      attribute :sku, String, pattern: '^[A-Z]{3}-\d{4}$'
    end
  end
end
"#;

fn add(rt: &mut Runtime, email: &str) -> Result<(), RuntimeError> {
    let mut a = HashMap::new();
    a.insert("id".to_string(), Value::Str("c1".to_string()));
    a.insert("email".to_string(), Value::Str(email.to_string()));
    rt.dispatch("Add", a).map(|_| ())
}

#[test]
fn the_door_refuses_a_value_that_does_not_match() {
    let mut rt = Runtime::boot(parser::parse(BB));
    let err = add(&mut rt, "not-an-email").expect_err("must refuse");
    match err {
        RuntimeError::PayloadInvariantViolation { field, value, expression, .. } => {
            assert_eq!(field, "email");
            assert_eq!(value, "not-an-email");
            assert_eq!(expression, "pattern", "the refusal names the RULE that rejected");
        }
        other => panic!("expected a payload refusal, got {:?}", other),
    }
}

#[test]
fn the_door_admits_a_value_that_matches() {
    let mut rt = Runtime::boot(parser::parse(BB));
    add(&mut rt, "ada@example.com").expect("a well-formed address is admitted");
}

#[test]
fn a_pattern_on_the_attribute_itself_is_enforced_too() {
    // Two homes, mirroring one_of : via a wrapper VO (email, above) and
    // directly on the attribute (sku, here).
    let mut rt = Runtime::boot(parser::parse(BB));
    let mut bad = HashMap::new();
    bad.insert("id".to_string(), Value::Str("c1".to_string()));
    bad.insert("sku".to_string(), Value::Str("nope".to_string()));
    assert!(rt.dispatch("Tag", bad).is_err(), "a mis-shaped SKU is refused");

    let mut good = HashMap::new();
    good.insert("id".to_string(), Value::Str("c1".to_string()));
    good.insert("sku".to_string(), Value::Str("ABC-1234".to_string()));
    rt.dispatch("Tag", good).expect("a well-formed SKU is admitted");
}

#[test]
fn absence_still_passes_the_pattern_gate() {
    // Presence is the `required:` arm's concern. A pattern constrains the SHAPE
    // of a value that was sent, never whether one had to be.
    let mut rt = Runtime::boot(parser::parse(BB));
    let mut a = HashMap::new();
    a.insert("id".to_string(), Value::Str("c1".to_string()));
    rt.dispatch("Add", a).expect("an omitted attribute is not a shape violation");
}

#[test]
fn a_declared_hint_reaches_the_schema_for_the_form_to_show() {
    // The hint is guidance, not enforcement : it rides the schema so the form
    // can render it as the input's `title`, but the gate never reads it.
    const WITH_HINT: &str = r#"Hecks.bluebook "Help" do
      aggregate "Row" do
        identified_by :id
        attribute :id,   RowId
        attribute :code, String, pattern: '^[A-Z]{2}$', hint: "two capital letters, like CA"
        value_object "RowId" do
          attribute :value, String
        end
        command "Set" do
          role "System"
          attribute :id,   RowId
          attribute :code, String, pattern: '^[A-Z]{2}$', hint: "two capital letters, like CA"
        end
      end
    end
    "#;
    let domain = parser::parse(WITH_HINT);
    let agg = &domain.aggregates[0];
    let attr = agg.attributes.iter().find(|a| a.name == "code").unwrap();
    assert_eq!(
        attr.hint.as_deref(),
        Some("two capital letters, like CA"),
        "the hint is parsed onto the attribute",
    );
    let cmd_attr = agg.commands.iter().find(|c| c.name == "Set").unwrap()
        .attributes.iter().find(|a| a.name == "code").unwrap();
    let schema = storehouse::projection::json_schema::attr_schema(agg, cmd_attr);
    assert_eq!(
        schema.get("x-hecks-hint").and_then(|h| h.as_str()),
        Some("two capital letters, like CA"),
        "the hint reaches the schema (got {})",
        schema,
    );
}

#[test]
fn the_schema_carries_the_pattern_so_the_form_inherits_it() {
    // The form renders from `attr_schema` and nothing else, so a pattern in the
    // schema IS a pattern on the input. Pinning the schema pins both.
    let domain = parser::parse(BB);
    let agg = &domain.aggregates[0];
    let cmd = agg.commands.iter().find(|c| c.name == "Add").unwrap();
    let attr = cmd.attributes.iter().find(|a| a.name == "email").unwrap();

    let schema = storehouse::projection::json_schema::attr_schema(agg, attr);
    assert_eq!(
        schema.get("pattern").and_then(|p| p.as_str()),
        Some(r"^[^@\s]+@[^@\s]+\.[^@\s]+$"),
        "the wrapper VO's pattern reaches the schema (got {})",
        schema,
    );
}

#[test]
fn a_divergent_pattern_is_refused_at_parse_and_constrains_nothing() {
    // Lookahead works in Ruby and cannot compile in Rust. The parser drops it
    // rather than storing a rule only one engine could honour — so the value is
    // UNCONSTRAINED on both, instead of enforced on one.
    const DIVERGENT: &str = r#"Hecks.bluebook "Risky" do
      aggregate "Account" do
        identified_by :id
        attribute :id, AccountId
        attribute :password, String, pattern: '^(?=.*[A-Z]).+$'
        value_object "AccountId" do
          attribute :value, String
        end
        command "Open" do
          role "System"
          attribute :id, AccountId
          attribute :password, String, pattern: '^(?=.*[A-Z]).+$'
        end
      end
    end
    "#;
    let domain = parser::parse(DIVERGENT);
    let agg = &domain.aggregates[0];
    let attr = agg.attributes.iter().find(|a| a.name == "password").unwrap();
    assert!(
        attr.pattern.is_none(),
        "a lookahead pattern must not reach the IR — it would enforce in Ruby \
         and fail to compile in Rust",
    );

    // And the door lets anything through, identically on both targets.
    let mut rt = Runtime::boot(parser::parse(DIVERGENT));
    let mut a = HashMap::new();
    a.insert("id".to_string(), Value::Str("a1".to_string()));
    a.insert("password".to_string(), Value::Str("no capitals here".to_string()));
    rt.dispatch("Open", a).expect("a refused pattern constrains nothing, it does not half-enforce");
}
