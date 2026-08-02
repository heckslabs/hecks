//! The postcondition, in this runtime — the Rust twin of
//! spec/runtime/ensures_spec.rb. `given` is a precondition, `invariant` a
//! class invariant, `ensures` is checked against the SETTLED record, after
//! mutations and the lifecycle move, before anything persists, with `old`
//! naming the state as the givens saw it. Built the same way that spec
//! was: a scratch domain with one command whose postcondition holds and
//! one that breaks its own on purpose — DbC's whole point is a
//! postcondition that never fires in a correct system, so provoking one
//! honestly needs a command built to break its own contract, not a real
//! corpus domain's arithmetic.

use storehouse::dispatcher::Runtime;

fn bluebook_with(commands: &str) -> String {
    format!(
        r#"Hecks.bluebook "Vault" do
  aggregate "Box" do
    identified_by {{ number.value }}
    attribute :number, Number
    attribute :balance, Money, default: {{ cents: 0 }}

    value_object "Number" do
      attribute :value, String
    end

    value_object "Money" do
      attribute :cents, Integer
    end

    command "Open" do
      attribute :number, Number
      emits "Opened"
    end

    query "ByNumber" do
      attribute :number, Number
      where(number: :number)
    end

    {commands}
  end
end
"#
    )
}

// ONE FILE PER SCRATCH DOMAIN, not one per process. cargo test runs tests
// in parallel threads within a single process by default, and a PID-only
// name let two tests racing on the SAME path boot whichever content the
// other had just written — "a_holding_ensures_saves_and_emits" failed
// with "Box has no command Deposit" the first run, having booted the
// OTHER test's Overstate-only source. Hashing the actual content makes
// every distinct scratch domain its own file.
fn boot_with(commands: &str) -> Runtime {
    use std::hash::{Hash, Hasher};
    let source = bluebook_with(commands);
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    source.hash(&mut hasher);
    let path = std::env::temp_dir().join(format!("ensures_test_{:x}.bluebook", hasher.finish()));
    std::fs::write(&path, source).unwrap();
    let runtime = Runtime::boot(&path).expect("a scratch bluebook boots");
    std::fs::remove_file(&path).ok();
    runtime
}

fn open_box(runtime: &mut Runtime) {
    let mut args = serde_json::Map::new();
    args.insert("number".into(), serde_json::json!({ "value": "b1" }));
    runtime
        .dispatch("Vault::Box.Open", &args)
        .expect("Open never refuses");
}

#[test]
fn a_holding_ensures_saves_and_emits() {
    let mut runtime = boot_with(
        r#"command "Deposit" do
      reference_to Box
      attribute :amount, Money
      then_set :balance, increment: :amount
      ensures("the balance grew by exactly the deposit") do
        balance.cents == old.balance.cents + amount.cents
      end
      emits "Deposited"
    end"#,
    );
    open_box(&mut runtime);

    let mut args = serde_json::Map::new();
    args.insert("number".into(), serde_json::json!({ "value": "b1" }));
    args.insert("amount".into(), serde_json::json!({ "cents": 500 }));

    let state = runtime
        .dispatch("Vault::Box.Deposit", &args)
        .expect("a holding postcondition does not refuse");

    assert_eq!(state.get("balance"), Some(&serde_json::json!({ "cents": 500 })));
    // Two: Opened (from open_box) then Deposited — events accumulate
    // across the whole runtime session, not per dispatch.
    assert_eq!(runtime.events.len(), 2, "Opened, then Deposited");
    assert_eq!(runtime.events.last().and_then(|e| e.get("name")), Some(&serde_json::json!("Deposited")));
}

#[test]
fn a_broken_ensures_refuses_in_the_command_s_own_words_and_persists_nothing() {
    let mut runtime = boot_with(
        r#"command "Overstate" do
      reference_to Box
      attribute :amount, Money
      then_set :balance, increment: :amount
      ensures("the balance grew by exactly double the deposit") do
        balance.cents == old.balance.cents + amount.cents + amount.cents
      end
      emits "Deposited"
    end"#,
    );
    open_box(&mut runtime);

    let mut args = serde_json::Map::new();
    args.insert("number".into(), serde_json::json!({ "value": "b1" }));
    args.insert("amount".into(), serde_json::json!({ "cents": 100 }));

    let error = runtime
        .dispatch("Vault::Box.Overstate", &args)
        .expect_err("a broken postcondition refuses");

    assert_eq!(
        error, "Overstate refused — the balance grew by exactly double the deposit",
        "the refusal wording is the byte-exact contract bin/parity diffs"
    );

    // THE REAL CHECK: a fresh QUERY, not the value the failed dispatch
    // would have returned had it succeeded — the same distinction the
    // Ruby spec draws (a repository #find after the refusal, never the
    // Result the raise short-circuited). If the mutation had reached the
    // store despite the refused postcondition, this would read 500.
    let mut query_args = serde_json::Map::new();
    query_args.insert("number".into(), serde_json::json!({ "value": "b1" }));
    let rows = runtime
        .query("Vault::Box.ByNumber", &query_args)
        .expect("a query never refuses");

    assert_eq!(rows.len(), 1, "the box itself was never touched");
    assert_eq!(
        rows[0].get("balance"),
        Some(&serde_json::json!({ "cents": 0 })),
        "a refused ensures must leave the stored record untouched"
    );
}
