//! Seeded fuzz of the invariant interpreter: an `ast` node read from the IR sidecar is parsed
//! and evaluated against a value object's fields, both of which can be wrong in every way
//! (unknown ops, wrong-typed fields, hostile regexes, overflowing arithmetic). The answer is an
//! `Ok` or an `Err(String)`, never a panic or a hang.

use crate::expr_json::{interpret, parse};
use crate::fuzz_support::*;
use serde_json::{json, Value};

const BINARY: &[&str] = &["or", "and", "compare", "include", "add", "modulo"];
const UNARY: &[&str] = &["not", "sign_test", "empty", "to_s", "size", "presence", "assignment", "first", "last", "split", "starts_with", "ends_with", "matches_regex"];

const PATTERNS: &[&str] = &[
    "", "^$", "a", "(a*)*b", "(a|aa)+$", "[", "]", "[]", "[^]", "[a-", "(", ")", "(?", "(?P<x>", "\\", "\\d+", "\\D\\W\\S\\H", "\\Z", "[\\d]", "[\\Z]", "\\p{L}+", "\\p{Nope}",
    "a{1000}", "a{1000}{1000}", "(((a{100}){100}){100})", "(?i)ABC", "(?x) a b", "\\x{110000}", "\\u{1F355}", ".*.*.*.*.*.*.*b", "\\b\\B", "(?<n>a)\\k<n>", "(a)\\1", "^*", "$+", "é+", "🍕{2}",
];

fn leaf(rng: &mut Rng) -> Value {
    match rng.below(9) {
        0 => json!({"op": "int", "value": edge_number(rng)}),
        1 => json!({"op": "float", "value": edge_number(rng)}),
        2 => json!({"op": "str", "value": random_text(rng)}),
        3 => json!({"op": "bool", "value": rng.chance(2)}),
        4 => json!({"op": "nil"}),
        5 => json!({"op": "lookup", "path": (0..1 + rng.below(3)).map(|_| *rng.pick(&["a", "b", "items", "name", "missing", "x", ""])).collect::<Vec<_>>()}),
        6 => json!({"op": "array", "elements": (0..rng.below(4)).map(|_| json!({"op": "int", "value": rng.below(5)})).collect::<Vec<_>>()}),
        7 => json!({"op": "int", "value": i64::MAX}),
        _ => json!({"op": "str", "value": ""}),
    }
}

fn node(rng: &mut Rng, depth: usize) -> Value {
    if depth >= 4 || rng.chance(4) {
        return leaf(rng);
    }
    let cmp = || json!({"less_than": true, "equal": true, "negated": false});
    match rng.below(10) {
        0..=3 => {
            let op = *rng.pick(BINARY);
            let mut value = json!({"op": op, "left": node(rng, depth + 1), "right": node(rng, depth + 1), "receiver": node(rng, depth + 1), "divisor": node(rng, depth + 1), "haystack": node(rng, depth + 1), "needle": node(rng, depth + 1)});
            value["cmp"] = cmp();
            value
        }
        4..=7 => {
            let op = *rng.pick(UNARY);
            let mut value = json!({"op": op, "receiver": node(rng, depth + 1), "expr": node(rng, depth + 1), "negated": rng.chance(2), "separator": random_text(rng), "substring": random_text(rng), "pattern": *rng.pick(PATTERNS), "flags": *rng.pick(&["", "i", "m", "x", "imx", "z"])});
            value["cmp"] = json!({"less_than": rng.chance(2), "equal": rng.chance(2), "negated": rng.chance(2)});
            value
        }
        8 => json!({"op": *rng.pick(&["block_predicate", "find"]), "mode": *rng.pick(&["all", "any", "none", "some"]), "receiver": node(rng, depth + 1), "param": *rng.pick(&["i", "a", ""]), "predicate": node(rng, depth + 1), "path": [*rng.pick(&["a", "x"])]}),
        _ => random_value(rng, 1),
    }
}

fn instance(rng: &mut Rng) -> Value {
    let mut fields = serde_json::Map::new();
    for key in ["a", "b", "items", "name", "x"] {
        if !rng.chance(4) {
            fields.insert(key.to_string(), if rng.chance(2) { random_value(rng, 1) } else { json!([{"x": 1}, {"x": "t"}, 3]) });
        }
    }
    Value::Object(fields)
}

#[test]
fn any_expression_tree_parses_or_refuses_and_evaluates_or_refuses() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed);
            for _ in 0..40 {
                let tree = node(&mut rng, 0);
                let Ok(expr) = parse(&tree) else { continue };
                for _ in 0..3 {
                    let _ = interpret(&expr, &instance(&mut rng));
                }
            }
        });
    }
}

#[test]
fn a_damaged_ast_document_is_refused_not_a_panic() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0xA57);
            for _ in 0..40 {
                let valid = node(&mut rng, 0).to_string();
                let text = mutate_text(&mut rng, &valid);
                if let Ok(tree) = serde_json::from_str::<Value>(&text) {
                    if let Ok(expr) = parse(&tree) {
                        let _ = interpret(&expr, &instance(&mut rng));
                    }
                }
            }
        });
    }
}

#[test]
fn arbitrary_json_is_never_an_expression() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), move || {
            let mut rng = Rng::new(seed ^ 0x77);
            for _ in 0..100 {
                let _ = parse(&random_value(&mut rng, 0));
            }
        });
    }
}

#[test]
fn hostile_regexes_compile_or_refuse_quickly_and_match_without_blowing_up() {
    for pattern in PATTERNS {
        for flags in ["", "i", "mx"] {
            let tree = json!({"op": "matches_regex", "receiver": {"op": "str", "value": "a".repeat(5_000)}, "pattern": pattern, "flags": flags});
            let expr = parse(&tree).expect("a well-formed node");
            guarded(&format!("{pattern:?} {flags:?}"), move || {
                let _ = interpret(&expr, &json!({}));
            });
        }
    }
}

#[test]
fn integer_arithmetic_at_the_limits_refuses_instead_of_overflowing() {
    let int = |n: i64| json!({"op": "int", "value": n});
    let cases = [
        json!({"op": "add", "left": int(i64::MAX), "right": int(1)}),
        json!({"op": "add", "left": int(i64::MIN), "right": int(-1)}),
        json!({"op": "modulo", "receiver": int(i64::MIN), "divisor": int(-1)}),
        json!({"op": "modulo", "receiver": int(i64::MAX), "divisor": int(i64::MIN)}),
        json!({"op": "modulo", "receiver": int(1), "divisor": int(0)}),
        json!({"op": "modulo", "receiver": {"op": "float", "value": 1.5}, "divisor": {"op": "float", "value": 0.0}}),
        json!({"op": "add", "left": {"op": "float", "value": 1.7976931348623157e308}, "right": {"op": "float", "value": 1.7976931348623157e308}}),
    ];
    for tree in cases {
        let expr = parse(&tree).expect("well-formed");
        let _ = interpret(&expr, &json!({}));
    }
    assert!(interpret(&parse(&cases_add_overflow()).unwrap(), &json!({})).is_err(), "i64::MAX + 1 must refuse");
}

fn cases_add_overflow() -> Value {
    json!({"op": "add", "left": {"op": "int", "value": i64::MAX}, "right": {"op": "int", "value": 1}})
}

#[test]
fn a_document_nested_past_the_json_limit_never_reaches_the_interpreter() {
    // The IR is read with serde_json, whose recursion limit refuses what would overflow `parse`.
    let nested = format!("{}{{\"op\":\"nil\"}}{}", "{\"op\":\"not\",\"expr\":".repeat(10_000), "}".repeat(10_000));
    assert!(serde_json::from_str::<Value>(&nested).is_err());
    let within = format!("{}{{\"op\":\"nil\"}}{}", "{\"op\":\"not\",\"expr\":".repeat(60), "}".repeat(60));
    guarded("depth 60", move || {
        let tree: Value = serde_json::from_str(&within).expect("within serde's limit");
        let expr = parse(&tree).expect("well-formed");
        let _ = interpret(&expr, &json!({}));
    });
}
