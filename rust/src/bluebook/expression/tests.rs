//! The Rust half of the sublanguage contract.
//!
//! Every example here has a twin in spec/expression_spec.rb, asserting the same
//! rule with the same inputs. The sublanguage is specified once
//! (lib/hecksagain/grammar/expression.bluebook) and implemented twice, so each
//! implementation needs its own tests or the second is only believed rather
//! than known. bin/parity then proves the two agree end to end.

use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use serde_json::json;

fn state(fields: serde_json::Value) -> State {
    fields.as_object().cloned().unwrap_or_default()
}

/// The verdict, where one is expected.
fn check(expression: &str, fields: serde_json::Value) -> bool {
    evaluate_given(expression, &state(fields), &State::new())
        .unwrap_or_else(|error| panic!("{} should have evaluated: {}", expression, error))
}

/// The refusal, where one is expected.
fn refusal(expression: &str, fields: serde_json::Value) -> String {
    match evaluate_given(expression, &state(fields), &State::new()) {
        Err(message) => message,
        Ok(value) => panic!("{} should have been refused, answered {}", expression, value),
    }
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
fn counts_with_size_and_folds_length() {
    let fields = json!({ "toppings": [1, 2] });
    assert!(check("toppings.size < 10", fields.clone()));
    assert!(check("toppings.length < 10", fields.clone()));
    assert!(check("toppings.size == 2", fields));
}

// ---------------------------------------------------------------------------
// The claim the word SUBLANGUAGE makes: these mean what Ruby means.
// ---------------------------------------------------------------------------

/// Ruby's truthiness. An earlier reading treated 0 and "" as false, so
/// `given { count }` read as "when there are some" and fired when there were
/// none. Both runtimes shared that reading, so parity blessed it.
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

/// Ruby: 1 == 1.0 is true, 1 == "1" is false.
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

/// This once answered FALSE, which was the bug wearing the costume of a guard:
/// a missing attribute coerced to 0, so .zero? reported TRUE and quietly
/// satisfied the rule it was meant to enforce.
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

/// The rule that most needs pinning: a || b && c means a || (b && c) ONLY
/// because || splits first.
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
