use crate::interp_expr::{
    class_of, describe, interpret as resolve_interpret, match_call, numeric_value,
    parse as resolve_parse, Eval, ResolverNode, State,
};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex, OnceLock};

// Six operators, reduced to two primitives (less_than, values_equal) combined
// with a small boolean algebra: compares_less_than/compares_equal choose
// which primitive(s) OR together, negated inverts the result. The same
// algebra Vocabulary::Comparison declares in language/bluebook.bluebook —
// Ruby's copy (Evaluator::OPERATORS) is held equal to the language by
// spec/vocabulary_conformance_spec ; this file's copy is that table's JSON
// export, embedded at compile time so the binary needs no runtime path to
// find it (bin/parity runs the built binary from copied /tmp domains).
// Regenerate with `bin/operators > rust/src/bluebook/expression/operators.json`
// any time Evaluator::OPERATORS changes.
#[derive(Debug, Clone)]
pub(crate) struct Operator {
    pub(crate) symbol: String,
    pub(crate) compares_less_than: bool,
    pub(crate) compares_equal: bool,
    pub(crate) negated: bool,
}

static OPERATORS_JSON: &str = include_str!("operators.json");

// pub(crate) — resolver.rs's sign tests look an Operator up here by symbol,
// so a sign test applies the SAME primitives compare() uses against the
// literal 0, rather than a second hand-written positive?/negative?/zero?.
pub(crate) static OPERATORS: LazyLock<Vec<Operator>> = LazyLock::new(|| {
    let parsed: Value =
        serde_json::from_str(OPERATORS_JSON).expect("operators.json must parse as JSON");
    parsed
        .as_array()
        .expect("operators.json must hold an array")
        .iter()
        .map(|row| Operator {
            symbol: row["symbol"].as_str().expect("symbol").to_string(),
            compares_less_than: row["compares_less_than"]
                .as_bool()
                .expect("compares_less_than"),
            compares_equal: row["compares_equal"].as_bool().expect("compares_equal"),
            negated: row["negated"].as_bool().expect("negated"),
        })
        .collect()
});

// The boolean/comparison grammar an expression parses into. Leaf variants
// (Compare/Include/Resolve) hold already-parsed ResolverNode trees, not raw
// strings — which branch a leaf's grammar takes is, like the boolean/
// comparison grammar above it, a pure function of the string. Only the final
// state/attrs dictionary read, inside resolver::interpret, varies per call.
// Parsing the whole tree once and caching it (AST_CACHE, below) is what makes
// that safe.
#[derive(Debug)]
enum Ast {
    Or(Box<Ast>, Box<Ast>),
    And(Box<Ast>, Box<Ast>),
    Not(Box<Ast>),
    Compare(Operator, ResolverNode, ResolverNode),
    Include(ResolverNode, ResolverNode),
    Resolve(ResolverNode),
}

// Keyed by the exact string `evaluate_given` receives. Canonical text is
// already normalised at DSL-build time, so the same given/invariant's text
// is byte-identical across every dispatch that evaluates it — parsed once
// here, interpreted fresh against each call's own state/attrs. Matches the
// OnceLock<Mutex<..>> idiom already used for router.rs/persistence_adapter.rs'
// process-lifetime globals, even though this binary is single-threaded today.
static AST_CACHE: OnceLock<Mutex<HashMap<String, Arc<Ast>>>> = OnceLock::new();

fn cached_ast(expr: &str) -> Arc<Ast> {
    let cache = AST_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let mut guard = cache.lock().expect("AST_CACHE poisoned");
    if let Some(ast) = guard.get(expr) {
        return ast.clone();
    }
    let ast = Arc::new(parse(expr));
    guard.insert(expr.to_string(), ast.clone());
    ast
}

fn parse(expr: &str) -> Ast {
    let expr = strip_parens(expr.trim());
    let expr = expr.as_str();

    if let Some((left, right)) = split_top_level(expr, "||") {
        return Ast::Or(Box::new(parse(&left)), Box::new(parse(&right)));
    }
    if let Some((left, right)) = split_top_level(expr, "&&") {
        return Ast::And(Box::new(parse(&left)), Box::new(parse(&right)));
    }

    if let Some((haystack, needle)) = match_call(expr, ".include?(") {
        return Ast::Include(resolve_parse(&haystack), resolve_parse(&needle));
    }

    for op in OPERATORS.iter() {
        if let Some((left, right)) = split_comparison(expr, &op.symbol) {
            return Ast::Compare(op.clone(), resolve_parse(&left), resolve_parse(&right));
        }
    }

    if let Some(inner) = expr.strip_prefix('!') {
        return Ast::Not(Box::new(parse(inner)));
    }

    Ast::Resolve(resolve_parse(expr))
}

fn interpret(node: &Ast, state: &State, attrs: &State) -> Eval<bool> {
    match node {
        Ast::Or(left, right) => {
            Ok(interpret(left, state, attrs)? || interpret(right, state, attrs)?)
        }
        Ast::And(left, right) => {
            Ok(interpret(left, state, attrs)? && interpret(right, state, attrs)?)
        }
        Ast::Not(inner) => Ok(!interpret(inner, state, attrs)?),
        Ast::Compare(op, left, right) => compare(op, left, right, state, attrs),
        Ast::Include(haystack, needle) => includes(haystack, needle, state, attrs),
        Ast::Resolve(node) => Ok(truthy(&resolve_interpret(node, state, attrs)?)),
    }
}

pub fn evaluate_given(expr: &str, state: &State, attrs: &State) -> Eval<bool> {
    interpret(&cached_ast(expr), state, attrs)
}

fn compare(
    op: &Operator,
    left: &ResolverNode,
    right: &ResolverNode,
    state: &State,
    attrs: &State,
) -> Eval<bool> {
    let lhs = resolve_interpret(left, state, attrs)?;
    let rhs = resolve_interpret(right, state, attrs)?;

    apply(op, &lhs, &rhs)
}

// The algebra itself, on values already resolved — split out so a sign test
// (SignTest#compares_via names an Operator symbol) can apply the SAME
// primitives compare() uses against the literal 0, rather than re-deriving
// positive?/negative?/zero? by hand a second time.
pub(crate) fn apply(op: &Operator, lhs: &Value, rhs: &Value) -> Eval<bool> {
    let mut result = false;
    if op.compares_less_than {
        result = result || less_than(lhs, rhs)?;
    }
    if op.compares_equal {
        result = result || values_equal(lhs, rhs);
    }
    Ok(if op.negated { !result } else { result })
}

fn less_than(lhs: &Value, rhs: &Value) -> Eval<bool> {
    if let (Some(left), Some(right)) = (numeric_value(lhs), numeric_value(rhs)) {
        return Ok(left < right);
    }
    if let (Value::String(left), Value::String(right)) = (lhs, rhs) {
        return Ok(left < right);
    }
    Err(format!(
        "comparison of {} with {} failed",
        class_of(lhs),
        describe(rhs)
    ))
}

pub fn values_equal(lhs: &Value, rhs: &Value) -> bool {
    match (numeric_value(lhs), numeric_value(rhs)) {
        (Some(left), Some(right)) => left == right,
        _ => lhs == rhs,
    }
}

fn truthy(value: &Value) -> bool {
    !matches!(value, Value::Null | Value::Bool(false))
}

fn includes(
    haystack: &ResolverNode,
    needle: &ResolverNode,
    state: &State,
    attrs: &State,
) -> Eval<bool> {
    let wanted = resolve_interpret(needle, state, attrs)?;

    Ok(match resolve_interpret(haystack, state, attrs)? {
        Value::Array(items) => items.iter().any(|item| values_equal(item, &wanted)),
        Value::String(text) => match &wanted {
            Value::String(part) => text.contains(part.as_str()),
            other => {
                return Err(format!(
                    "no implicit conversion of {} into String",
                    class_of(other)
                ))
            }
        },
        _ => false,
    })
}

fn strip_parens(expr: &str) -> String {
    if !(expr.starts_with('(') && expr.ends_with(')')) {
        return expr.to_string();
    }

    let mut depth = 0i32;
    for (index, character) in expr.char_indices() {
        match character {
            '(' => depth += 1,
            ')' => depth -= 1,
            _ => {}
        }
        if depth == 0 && index < expr.len() - 1 {
            return expr.to_string();
        }
    }
    strip_parens(expr[1..expr.len() - 1].trim())
}

pub fn split_top_level(expr: &str, operator: &str) -> Option<(String, String)> {
    top_level_index(expr, operator, false).map(|index| halves(expr, index, operator))
}

pub fn split_comparison(expr: &str, operator: &str) -> Option<(String, String)> {
    top_level_index(expr, operator, true).map(|index| halves(expr, index, operator))
}

fn halves(expr: &str, index: usize, operator: &str) -> (String, String) {
    (
        expr[..index].trim().to_string(),
        expr[index + operator.len()..].trim().to_string(),
    )
}

fn top_level_index(expr: &str, operator: &str, guard_longer: bool) -> Option<usize> {
    let bytes = expr.as_bytes();
    let mut depth = 0i32;
    let mut quote: Option<u8> = None;
    let mut index = 0usize;

    while index < bytes.len() {
        let character = bytes[index];

        if let Some(open) = quote {
            if character == open {
                quote = None;
            }
        } else if character == b'"' || character == b'\'' {
            quote = Some(character);
        } else if character == b'(' {
            depth += 1;
        } else if character == b')' {
            depth -= 1;
        } else if depth == 0 && expr[index..].starts_with(operator) {
            if !guard_longer || !part_of_longer(expr, index, operator) {
                return Some(index);
            }
        }

        index += 1;
    }
    None
}

fn part_of_longer(expr: &str, index: usize, operator: &str) -> bool {
    let bytes = expr.as_bytes();
    let after = bytes.get(index + operator.len()).copied();
    let before = if index > 0 {
        bytes.get(index - 1).copied()
    } else {
        None
    };

    if after == Some(b'=') && !operator.ends_with('=') {
        return true;
    }
    if operator.starts_with('=')
        && matches!(before, Some(b'<') | Some(b'>') | Some(b'!') | Some(b'='))
    {
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn state(pairs: Value) -> State {
        pairs.as_object().expect("object").clone()
    }

    fn given(expr: &str, bindings: Value) -> Eval<bool> {
        evaluate_given(expr, &state(bindings), &State::new())
    }

    #[test]
    fn a_list_member_is_not_its_string() {
        assert_eq!(
            given("sizes.include?(10)", json!({"sizes": ["10"]})),
            Ok(false)
        );
        assert_eq!(
            given("sizes.include?(\"10\")", json!({"sizes": [10]})),
            Ok(false)
        );
    }

    #[test]
    fn a_list_member_equates_across_numeric_kinds() {
        assert_eq!(
            given("scores.include?(1.0)", json!({"scores": [1]})),
            Ok(true)
        );
        assert_eq!(
            given("scores.include?(1)", json!({"scores": [1.0]})),
            Ok(true)
        );
    }

    #[test]
    fn a_non_string_needle_in_a_string_refuses() {
        assert_eq!(
            given("code.include?(5)", json!({"code": "a5b"})),
            Err("no implicit conversion of Integer into String".to_string())
        );
    }

    #[test]
    fn a_string_needle_still_reads_a_substring() {
        assert_eq!(
            given(
                "address.include?(\"@\")",
                json!({"address": "ada@example.com"})
            ),
            Ok(true)
        );
    }

    // The table-driven formula in `compare` replaced a six-way match, so this
    // exercises the whole OPERATORS table against numeric, string, and
    // incomparable pairs — the cases the boolean algebra (compares_less_than /
    // compares_equal / negated) has to get right in every combination.
    #[test]
    fn every_operator_agrees_with_its_declared_algebra() {
        let cases = [
            (">=", "5 >= 3", Ok(true)),
            (">=", "3 >= 5", Ok(false)),
            (">=", "3 >= 3", Ok(true)),
            ("<=", "3 <= 5", Ok(true)),
            ("<=", "5 <= 3", Ok(false)),
            ("<=", "3 <= 3", Ok(true)),
            ("<", "3 < 5", Ok(true)),
            ("<", "5 < 3", Ok(false)),
            ("<", "3 < 3", Ok(false)),
            (">", "5 > 3", Ok(true)),
            (">", "3 > 5", Ok(false)),
            (">", "3 > 3", Ok(false)),
            ("==", "3 == 3", Ok(true)),
            ("==", "3 == 5", Ok(false)),
            ("!=", "3 != 5", Ok(true)),
            ("!=", "3 != 3", Ok(false)),
            ("<", "\"a\" < \"b\"", Ok(true)),
            (">", "\"b\" > \"a\"", Ok(true)),
            ("==", "\"a\" == \"a\"", Ok(true)),
            (
                "<",
                "\"abc\" < 3",
                Err("comparison of String with 3 failed".to_string()),
            ),
        ];

        for (operator, expr, expected) in cases {
            assert_eq!(given(expr, json!({})), expected, "operator {operator}, expr {expr}");
        }

        assert_eq!(OPERATORS.len(), 6);
    }
}
