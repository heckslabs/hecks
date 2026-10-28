//! Drives `hecks-parse examples` over steps that are not a command run by a person: a port
//! announcing a fact (`the payment gateway receives it`), a query (`Chris runs the available
//! query`), and the outcomes only they have (`1 order is found`, `its name is …`).

// reason: these helpers are test scaffolding outside `#[test]` fns, which clippy.toml does not
// cover; a failed unwrap here is the test failing.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

const HEADER: &str = "\
Examples for: Pizzas

Background:
  Remy is a Chef
  Chris is a Customer

Example: A pizza is made
  Given Remy creates a pizza with name \"Paid For\", price 1200 cents and size \"large\"
";

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../spec/fixtures/sentence/pizzas")
}

/// Compiles an example that opens with `HEADER` and goes on with `rest`.
fn compile(name: &str, rest: &str) -> Output {
    let dir = std::env::temp_dir().join(format!("hecks-outside-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let source = dir.join(format!("{name}.examples"));
    fs::write(&source, format!("{HEADER}{rest}")).unwrap();
    let fixtures = fixtures();
    Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args(["examples", "--bluebook", "Pizzas", "--examples"])
        .arg(&source)
        .arg("--also")
        .arg(fixtures.join("sentence_form_behaviors.hecksagon"))
        .arg(fixtures.join("sentence_form.bluebook"))
        .output()
        .expect("failed to run hecks-parse")
}

fn compiled(name: &str, rest: &str) -> String {
    let output = compile(name, rest);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).to_string()
}

fn refusal(name: &str, rest: &str) -> String {
    let output = compile(name, rest);
    assert!(
        !output.status.success(),
        "{name}: expected a refusal, got: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    String::from_utf8_lossy(&output.stderr).trim().to_string()
}

const GATEWAY: &str =
    "the payment gateway receives it with customer name \"Chris\" and amount 1200 cents";

#[test]
fn a_port_arrival_is_addressed_to_the_record_made_earlier() {
    let text = compiled(
        "arrival",
        &format!("  When {GATEWAY}\n  Then PizzaPaymentReceived is announced\n"),
    );
    assert!(
        text.contains("tests \"Pizzas::Order.PaymentGateway.Receive\""),
        "{text}"
    );
    assert!(
        text.contains(
            "input to: \"Paid For\", with: { customer_name: { value: \"Chris\" }, amount: { cents: 1200 } }"
        ),
        "{text}"
    );
}

#[test]
fn a_port_arrival_announces_what_a_policy_goes_on_to_run() {
    let text = compiled(
        "chain",
        &format!(
            "  When {GATEWAY}\n  Then PizzaPaymentReceived is announced\n  And PizzaPurchased is announced\n"
        ),
    );
    assert!(
        text.contains("expect emits: [\"PizzaPaymentReceived\", \"PizzaPurchased\"]"),
        "{text}"
    );
}

#[test]
fn a_verb_the_port_lacks_is_refused_with_the_wording_that_works() {
    let why = refusal(
        "verb",
        "  When the payment gateway sends it with amount 1200 cents\n  Then PizzaPaymentReceived is announced\n",
    );
    assert!(
        why.contains(
            "the payment gateway does not 'sends'. A step can say: the payment gateway receives it"
        ),
        "{why}"
    );
}

#[test]
fn a_port_arrival_is_never_refused() {
    let why = refusal(
        "tries",
        &format!(
            "  When the payment gateway tries to receive it with {}\n  Then PizzaPaymentReceived is announced\n",
            "amount 1200 cents"
        ),
    );
    assert!(why.contains("a port only announces a fact"), "{why}");
}

#[test]
fn a_port_arrival_is_not_a_given() {
    let why = refusal(
        "given",
        &format!(
            "  And {GATEWAY}\n  When Chris runs the available query\n  Then 1 order is found\n"
        ),
    );
    assert!(
        why.contains("a Given step is a command a person runs"),
        "{why}"
    );
}

#[test]
fn a_query_is_run_by_name_and_counts_what_it_finds() {
    let text = compiled(
        "query",
        "  When Chris runs the costing less than query with ceiling 1000 cents\n  Then 1 order is found\n",
    );
    assert!(
        text.contains("tests \"CostingLessThan\", on: \"Order\", kind: :query"),
        "{text}"
    );
    assert!(text.contains("input ceiling: { cents: 1000 }"), "{text}");
    assert!(text.contains("expect count: 1"), "{text}");
}

#[test]
fn nothing_found_is_a_count_of_none() {
    let text = compiled(
        "none",
        "  When Chris runs the available query\n  Then no orders are found\n",
    );
    assert!(text.contains("expect count: 0"), "{text}");
}

#[test]
fn a_query_that_is_not_there_is_refused_with_the_queries_that_are() {
    let why = refusal(
        "unknown",
        "  When Chris runs the cheap query\n  Then 1 order is found\n",
    );
    assert!(why.contains("'cheap' is not a query here"), "{why}");
    assert!(why.contains("runs the available query"), "{why}");
}

#[test]
fn a_query_needs_the_values_it_takes() {
    let why = refusal(
        "needs",
        "  When Chris runs the costing less than query\n  Then 1 order is found\n",
    );
    assert!(why.contains("costing less than needs a ceiling"), "{why}");
}

#[test]
fn only_a_query_finds_rows() {
    let why = refusal(
        "rows",
        "  When Chris purchases it with amount 1200 cents and customer name \"Chris\"\n  Then 1 order is found\n",
    );
    assert!(why.contains("only a query finds rows"), "{why}");
}

#[test]
fn a_query_announces_nothing() {
    let why = refusal(
        "silent",
        "  When Chris runs the available query\n  Then PizzaPurchased is announced\n",
    );
    assert!(why.contains("available announces nothing"), "{why}");
}

#[test]
fn a_field_is_read_by_its_own_name() {
    let text = compiled(
        "field",
        "  When Chris runs the available query\n  Then its name is \"Paid For\"\n",
    );
    assert!(text.contains("expect name: \"Paid For\""), "{text}");
}

#[test]
fn a_field_that_is_not_set_expects_nothing_there() {
    let text = compiled(
        "unset",
        "  When Remy creates a pizza with name \"Margherita\", price 1200 cents and size \"large\"\n  Then its customer name is not set\n",
    );
    assert!(text.contains("expect customer_name: nil"), "{text}");
}

#[test]
fn a_field_the_record_lacks_is_refused_with_the_fields_it_has() {
    let why = refusal(
        "lacks",
        "  When Chris runs the available query\n  Then its colour is \"red\"\n",
    );
    assert!(why.contains("an order has no 'colour'"), "{why}");
    assert!(
        why.contains("Its fields are: name, pizza, toppings, customer name"),
        "{why}"
    );
}

#[test]
fn a_value_that_is_not_a_text_a_number_or_not_set_is_refused() {
    let why = refusal(
        "value",
        "  When Chris runs the available query\n  Then its name is maybe\n",
    );
    assert!(
        why.contains("write a quoted text, a number, or `not set`"),
        "{why}"
    );
}

#[test]
fn a_port_leaves_no_record_to_read() {
    let why = refusal(
        "record",
        &format!("  When {GATEWAY}\n  Then the order is sold\n"),
    );
    assert!(why.contains("a port announces a fact"), "{why}");
}
