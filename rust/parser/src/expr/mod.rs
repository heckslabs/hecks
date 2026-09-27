//! Port of the `parse` step of `expression/{evaluator,resolver}.rb`; evaluation stays elsewhere.
//! Each Ruby helper has a same-named function here.

pub mod evaluator;
pub mod resolver;

/// A comparison operator. Order in `OPERATORS` matters: the first match wins,
/// so `>=` and `<=` must precede `>` and `<`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Operator {
    pub symbol: &'static str,
    pub compares_less_than: bool,
    pub compares_equal: bool,
    pub negated: bool,
}

pub const OPERATORS: [Operator; 6] = [
    Operator { symbol: ">=", compares_less_than: true, compares_equal: false, negated: true },
    Operator { symbol: "<=", compares_less_than: true, compares_equal: true, negated: false },
    Operator { symbol: "<", compares_less_than: true, compares_equal: false, negated: false },
    Operator { symbol: ">", compares_less_than: true, compares_equal: true, negated: true },
    Operator { symbol: "==", compares_less_than: false, compares_equal: true, negated: false },
    Operator { symbol: "!=", compares_less_than: false, compares_equal: true, negated: true },
];

pub fn find_operator(symbol: &str) -> Operator {
    *OPERATORS.iter().find(|op| op.symbol == symbol).unwrap_or_else(|| panic!("no such comparison operator {symbol:?}"))
}

/// Index of the first top-level (outside quotes and brackets) `operator` that `accept` allows.
pub fn top_level_index(expr: &str, operator: &str, accept: impl Fn(usize) -> bool) -> Option<usize> {
    let bytes = expr.as_bytes();
    let op_bytes = operator.as_bytes();
    let mut depth: i32 = 0;
    let mut quote: Option<u8> = None;
    let mut index = 0usize;

    while index < bytes.len() {
        let ch = bytes[index];
        if let Some(q) = quote {
            if ch == q {
                quote = None;
            }
        } else if ch == b'"' || ch == b'\'' {
            quote = Some(ch);
        } else if ch == b'(' || ch == b'{' {
            // Braces count toward depth so an operator inside a block body is never top-level.
            depth += 1;
        } else if ch == b')' || ch == b'}' {
            depth -= 1;
        } else if depth == 0 && index + op_bytes.len() <= bytes.len() && &bytes[index..index + op_bytes.len()] == op_bytes {
            if accept(index) {
                return Some(index);
            }
        }
        index += 1;
    }
    None
}

pub fn strip_parens(expr: &str) -> String {
    let expr = expr.trim();
    if !(expr.starts_with('(') && expr.ends_with(')')) {
        return expr.to_string();
    }

    let chars: Vec<char> = expr.chars().collect();
    let mut depth: i32 = 0;
    for (index, &c) in chars.iter().enumerate() {
        if c == '(' {
            depth += 1;
        }
        if c == ')' {
            depth -= 1;
        }
        if depth == 0 && index < chars.len() - 1 {
            return expr.to_string();
        }
    }
    let inner: String = chars[1..chars.len() - 1].iter().collect();
    strip_parens(inner.trim())
}

pub mod ast_json;
