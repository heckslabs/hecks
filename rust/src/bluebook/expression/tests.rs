
use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use serde_json::json;

fn state(fields: serde_json::Value) -> State {
    fields.as_object().cloned().unwrap_or_default()
}

fn check(expression: &str, fields: serde_json::Value) -> bool {
    evaluate_given(expression, &state(fields), &State::new())
        .unwrap_or_else(|error| panic!("{} should have evaluated: {}", expression, error))
}

fn refusal(expression: &str, fields: serde_json::Value) -> String {
    match evaluate_given(expression, &state(fields), &State::new()) {
        Err(message) => message,
        Ok(value) => panic!("{} should have been refused, answered {}", expression, value),
    }
}


#[test]
fn answers_emptiness_for_string_list_and_map() {
    assert!(check("label.empty?", json!({ "label": "" })));
    assert!(!check("label.empty?", json!({ "label": "Hello" })));
    assert!(check("toppings.empty?", json!({ "toppings": [] })));
    assert!(!check("toppings.empty?", json!({ "toppings": ["Basil"] })));
}

#[test]
fn emptiness_reads_an_argument_rather_than_folding_through_size() {
    let passed = state(json!({ "label": "Hello" }));
    assert_eq!(
        evaluate_given("label.empty?", &State::new(), &passed),
        Ok(false)
    );
}

#[test]
fn refuses_emptiness_of_something_that_has_none() {
    assert_eq!(
        refusal("count.empty?", json!({ "count": 3 })),
        "empty? expects a list or string, got 3"
    );
}

#[test]
fn negation_inverts_a_verdict() {
    assert!(check("!ready", json!({ "ready": false })));
    assert!(!check("!ready", json!({ "ready": true })));
}

#[test]
fn negation_uses_rubys_truthiness() {
    assert!(!check("!count", json!({ "count": 0 })));
    assert!(!check("!label", json!({ "label": "" })));
    assert!(check("!missing", json!({ "missing": null })));
}

#[test]
fn negation_disagrees_with_the_predicate_it_negates() {
    let fields = json!({ "label": "Hello" });
    assert!(!check("label.empty?", fields.clone()));
    assert!(check("!label.empty?", fields));
}

#[test]
fn negation_binds_tighter_than_the_binary_operators() {
    assert!(check("!ready && open", json!({ "ready": false, "open": true })));
    assert!(!check("!ready && open", json!({ "ready": true, "open": true })));
    assert!(check("!(a && b)", json!({ "a": true, "b": false })));
}

#[test]
fn renders_scalars_with_to_s_as_ruby_renders_them() {
    assert!(check("count.to_s == \"3\"", json!({ "count": 3 })));
    assert!(check("flag.to_s == \"true\"", json!({ "flag": true })));
    assert!(check("missing.to_s == \"\"", json!({ "missing": null })));
}

#[test]
fn to_s_composes_with_emptiness_and_negation() {
    assert!(check("!target.to_s.empty?", json!({ "target": "ruby" })));
    assert!(!check("!target.to_s.empty?", json!({ "target": null })));
}

#[test]
fn refuses_to_print_a_collection() {
    assert!(refusal("toppings.to_s", json!({ "toppings": ["Basil"] }))
        .starts_with("to_s expects a scalar"));
}

#[test]
fn reads_literals() {
    assert!(check("1 < 2", json!({})));
    assert!(check("\"a\" == \"a\"", json!({})));
    assert!(check("true", json!({})));
    assert!(!check("false", json!({})));
}

#[test]
fn binds_attributes_and_dotted_paths() {
    assert!(check("status == \"available\"", json!({ "status": "available" })));
    assert!(check("price.cents > 1000", json!({ "price": { "cents": 1200 } })));
}

#[test]
fn argument_shadows_state() {
    let stored = state(json!({ "status": "sold" }));
    let passed = state(json!({ "status": "available" }));
    assert_eq!(
        evaluate_given("status == \"available\"", &stored, &passed),
        Ok(true)
    );
}

#[test]
fn every_given_spelling_yields_its_predicate() {
    let src = r##"Hecks.bluebook "GivenForms" do
  aggregate "Thing" do
    attribute :name, String
    attribute :size, Integer

    command "Register" do
      role "Operator"
      attribute :name, String
      attribute :size, Integer

      given("brace given") { !name.to_s.empty? }

      given("multiline given") do
        size > 0
      end

      given("inline do given") do size < 100 end

      emits "ThingRegistered"
    end
  end
end"##;

    let domain = crate::bluebook::parser::parse(src);
    let cmd = &domain.aggregates[0].commands[0];
    let found: Vec<(String, String)> = cmd
        .givens
        .iter()
        .map(|g| (g.message.clone().unwrap_or_default(), g.expression.clone()))
        .collect();

    assert_eq!(
        found,
        vec![
            ("brace given".to_string(), "!name.to_s.empty?".to_string()),
            ("multiline given".to_string(), "size > 0".to_string()),
            ("inline do given".to_string(), "size < 100".to_string()),
        ]
    );

    for given in &cmd.givens {
        assert_ne!(given.expression, given.message.clone().unwrap_or_default());
    }

    assert_eq!(cmd.emits.as_deref(), Some("ThingRegistered"));
}

#[test]
fn counts_with_size_and_folds_length() {
    let fields = json!({ "toppings": [1, 2] });
    assert!(check("toppings.size < 10", fields.clone()));
    assert!(check("toppings.length < 10", fields.clone()));
    assert!(check("toppings.size == 2", fields));
}


#[test]
fn zero_and_empty_string_are_true_as_in_ruby() {
    assert!(check("count", json!({ "count": 0 })));
    assert!(check("label", json!({ "label": "" })));
}

#[test]
fn only_nil_and_false_are_falsy_as_in_ruby() {
    assert!(!check("flag", json!({ "flag": false })));
    assert!(!check("flag", json!({ "flag": null })));
}

#[test]
fn a_number_does_not_equal_its_string_as_in_ruby() {
    assert!(!check("count == \"1\"", json!({ "count": 1 })));
    assert!(check("count == 1", json!({ "count": 1 })));
    assert!(check("count == 1.0", json!({ "count": 1 })));
}

#[test]
fn orders_strings_against_strings() {
    assert!(check("label < \"b\"", json!({ "label": "a" })));
    assert!(!check("label < \"b\"", json!({ "label": "c" })));
}

#[test]
fn refuses_an_incomparable_ordering_as_ruby_does() {
    assert_eq!(
        refusal("label < 3", json!({ "label": "abc" })),
        "comparison of String with 3 failed"
    );
}

#[test]
fn answers_the_sign_predicates() {
    assert!(check("amount.positive?", json!({ "amount": 3 })));
    assert!(!check("amount.positive?", json!({ "amount": 0 })));
    assert!(!check("amount.positive?", json!({ "amount": -1 })));

    assert!(check("amount.negative?", json!({ "amount": -1 })));
    assert!(check("amount.zero?", json!({ "amount": 0 })));
    assert!(!check("amount.zero?", json!({ "amount": 3 })));
}

#[test]
fn sign_predicates_compose_with_size() {
    assert!(check("toppings.size.positive?", json!({ "toppings": [1] })));
    assert!(!check("toppings.size.positive?", json!({ "toppings": [] })));
}

#[test]
fn refuses_a_name_it_cannot_resolve() {
    for test in ["positive?", "negative?", "zero?"] {
        assert_eq!(
            refusal(&format!("missing.{}", test), json!({})),
            "cannot resolve \"missing\" \u{2014} no such attribute or argument"
        );
    }
    assert_eq!(
        refusal("mispelled_attribute > 0", json!({})),
        "cannot resolve \"mispelled_attribute\" \u{2014} no such attribute or argument"
    );
}

#[test]
fn refuses_a_sign_predicate_without_a_number() {
    assert_eq!(
        refusal("label.positive?", json!({ "label": "abc" })),
        "positive? expects a number, got \"abc\""
    );
}

#[test]
fn refuses_size_on_something_with_no_size() {
    assert_eq!(
        refusal("count.size", json!({ "count": 3 })),
        "size expects a list or string, got 3"
    );
}

#[test]
fn resolves_a_declared_attribute_that_is_nil() {
    assert!(check("customer_name == nil", json!({ "customer_name": null })));
}

#[test]
fn binds_or_looser_than_and() {
    assert!(check("true || false && false", json!({})));
    assert!(!check("(true || false) && false", json!({})));
}

#[test]
fn keeps_parens_that_do_not_wrap_the_whole_expression() {
    assert!(check("(1 < 2) && (3 < 4)", json!({})));
    assert!(!check("(1 < 2) && (4 < 3)", json!({})));
}

#[test]
fn does_not_mistake_longer_operators() {
    assert!(check("2 >= 2", json!({})));
    assert!(!check("2 > 2", json!({})));
    assert!(check("2 <= 2", json!({})));
    assert!(!check("2 < 2", json!({})));
    assert!(check("2 != 3", json!({})));
}

#[test]
fn tests_membership() {
    let fields = json!({ "names": ["Basil", "Olive"] });
    assert!(check("names.include?(\"Basil\")", fields.clone()));
    assert!(!check("names.include?(\"Anchovy\")", fields));
}
