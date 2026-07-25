//! The Rust half of the sublanguage contract.
//!
//! Every example here has a twin in spec/expression_spec.rb, asserting the same
//! rule with the same inputs. That pairing is the point: the sublanguage is
//! specified once (language/bluebook/expression.bluebook) and implemented
//! twice, so each implementation needs its own test or the second one is only
//! believed rather than known.
//!
//! bin/parity then proves the two agree end to end on a real domain.

use crate::interp_expr::State;
use crate::interp_givens::evaluate_given;
use serde_json::json;

fn state(fields: serde_json::Value) -> State {
    fields.as_object().cloned().unwrap_or_default()
}

fn check(expression: &str, fields: serde_json::Value) -> bool {
    evaluate_given(expression, &state(fields), &State::new())
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
    assert!(evaluate_given("status == \"available\"", &stored, &passed));
}

#[test]
fn counts_with_size_and_folds_length() {
    let fields = json!({ "toppings": [1, 2] });
    assert!(check("toppings.size < 10", fields.clone()));
    assert!(check("toppings.length < 10", fields.clone()));
    assert!(check("toppings.size == 2", fields));
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

/// A missing attribute resolves to null and would coerce to 0 - reporting
/// zero? as TRUE and quietly satisfying a predicate that should have failed.
#[test]
fn sign_predicates_refuse_a_non_numeric_receiver() {
    assert!(!check("missing.positive?", json!({})));
    assert!(!check("missing.negative?", json!({})));
    assert!(!check("missing.zero?", json!({})));
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
