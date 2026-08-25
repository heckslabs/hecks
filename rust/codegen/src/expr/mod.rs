//! Port of `lib/hecks/bluebook/expression/{evaluator,resolver}.rb`'s
//! own `parse` step ONLY — not `interpret`/`call` (semantics stay in Ruby
//! at dispatch time, and identically in `rust/src/kernel/expr.rs` for the
//! compiled Rust side; this module exists purely so `expr_emitter.rs` can
//! walk the same AST shape `rust/project/expr_emitter.rb` walks, without
//! shelling out to Ruby to get it). See the plan's Stage 7 section and
//! `expr_emitter.rb`'s own header for why this is explicitly in scope:
//! "small, stable, already-solved."
//!
//! This is a straight structural port: every `def parse`/helper in the
//! two Ruby files has a same-named Rust function here, translated
//! statement-for-statement, not redesigned. Read the Ruby source
//! alongside this file if verifying it.

pub mod evaluator;
pub mod resolver;

/// The six comparison operators, in `projection.json`'s own declared
/// order — order matters: `Evaluator.parse`'s `OPERATORS.each` tries them
/// in sequence and the first structural match wins (`>=` must be tried
/// before `>`, `<=` before `<`, so a plain textual scan doesn't misread
/// `>=` as a bare `>` followed by stray `=`).
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

/// Shared by both `evaluator.rb#split_top_level`/`split_comparison` and
/// `resolver.rb#split_addition` — a depth/quote-aware scan for a
/// top-level occurrence of `operator`, mirroring `top_level_index`
/// exactly (including its optional filter block, `accept`).
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
            // `{`/`}` count toward depth exactly as `(`/`)` do — Ruby's
            // own `top_level_index` grew that the day the resolver grew
            // block-taking `.any?`/`.none?`/`.all?`/`.find { |x| … }`,
            // so an operator INSIDE a block's predicate is never a
            // top-level split of the whole expression.
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
