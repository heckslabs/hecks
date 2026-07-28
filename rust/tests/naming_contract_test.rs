use serde_json::Value;
use std::path::PathBuf;

fn contract() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("repo root above rust/")
        .join("spec/parity/fixtures/naming.json");

    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("naming contract unreadable at {path:?}: {e}"));

    serde_json::from_str(&text).expect("naming contract is valid JSON")
}

fn rows(contract: &Value, rule: &str) -> Vec<Value> {
    contract
        .get(rule)
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("naming contract carries no rule {rule:?}"))
        .clone()
}

fn input(row: &Value) -> &str {
    row["in"].as_str().expect("every case has a string input")
}

#[test]
fn the_contract_carries_every_rule_this_runtime_implements() {
    let contract = contract();
    let mut rules: Vec<&str> = contract
        .as_object()
        .expect("contract is an object")
        .keys()
        .map(String::as_str)
        .collect();
    rules.sort_unstable();

    assert_eq!(
        rules,
        vec![
            "demodulise",
            "qualifier",
            "reference_key",
            "snake",
            "split_dotted",
            "split_verb",
            "unqualified",
        ]
    );
}

#[test]
fn snake_matches_the_contract() {
    for row in rows(&contract(), "snake") {
        let given = input(&row);
        let want = row["out"].as_str().expect("snake answers a string");
        assert_eq!(storehouse::naming::snake(given), want, "snake({given:?})");
    }
}

#[test]
fn demodulise_matches_the_contract() {
    for row in rows(&contract(), "demodulise") {
        let given = input(&row);
        let want = row["out"].as_str().expect("demodulise answers a string");
        assert_eq!(
            storehouse::naming::demodulise(given),
            want,
            "demodulise({given:?})"
        );
    }
}

#[test]
fn reference_key_matches_the_contract() {
    for row in rows(&contract(), "reference_key") {
        let given = input(&row);
        let want = row["out"].as_str().expect("reference_key answers a string");
        assert_eq!(
            storehouse::naming::reference_key(given),
            want,
            "reference_key({given:?})"
        );
    }
}

#[test]
fn split_dotted_matches_the_contract() {
    for row in rows(&contract(), "split_dotted") {
        let given = input(&row);
        let want = row["out"].as_array().expect("split_dotted answers two parts");
        let want = (
            want[0].as_str().expect("first part"),
            want[1].as_str().expect("second part"),
        );
        assert_eq!(
            storehouse::naming::split_dotted(given),
            want,
            "split_dotted({given:?})"
        );
    }
}

#[test]
fn qualifier_matches_the_contract() {
    for row in rows(&contract(), "qualifier") {
        let given = input(&row);
        let want = row["out"].as_str();
        assert_eq!(
            storehouse::naming::qualifier(given),
            want,
            "qualifier({given:?})"
        );
    }
}

#[test]
fn unqualified_matches_the_contract() {
    for row in rows(&contract(), "unqualified") {
        let given = input(&row);
        let want = row["out"].as_str().expect("unqualified answers a string");
        assert_eq!(
            storehouse::naming::unqualified(given),
            want,
            "unqualified({given:?})"
        );
    }
}

#[test]
fn split_verb_matches_the_contract() {
    for row in rows(&contract(), "split_verb") {
        let given = input(&row);
        let want = row["out"].as_array().map(|parts| {
            (
                parts[0].as_str().expect("domain"),
                parts[1].as_str().expect("aggregate"),
                parts[2].as_str().expect("command"),
            )
        });
        assert_eq!(
            storehouse::naming::split_verb(given),
            want,
            "split_verb({given:?})"
        );
    }
}
