// Implements the Ruby grammar's "pattern_match" expression-operator
// category (projection.json: `.match?`, its one member) — `Resolver::
// MatchesRegex` (resolver.rb's `matches_regex?`), read directly:
// `receiver.match?(/pattern/flags)` against a real Ruby-Regexp-style
// pattern, taken as-is between the slashes (no sub-grammar to recurse
// into, same precedent `pattern`/`flags` on the Ruby struct already set).
//
// THE ONE DEPENDENCY THIS CRATE HAS. Every other file under
// rust/src/kernel/ holds itself to zero Cargo dependencies (ADR 0012 —
// WASM-via-WASI binary size and auditability; see json.rs's and
// arithmetic.rs's own headers for the same constraint stated twice
// already). `regex` is a deliberate, single, documented exception: the
// resolver.rb comment on `MatchesRegex` itself calls `.match?` "the
// SINGLE most impactful corpus-wide dispatch-time gap of the whole
// migration" — email/phone/ISO-8601-timestamp/zip format-validation
// rules, in nearly every value_object across every corpus this
// migration touched — and no hand-rolled subset (character classes,
// anchors, quantifiers, alternation) gets real Ruby-Regexp parity
// without becoming a second regex engine maintained by hand, a far
// larger and more failure-prone undertaking than one well-audited,
// pure-Rust dependency. `regex` itself has no transitive C dependency
// (confirmed via `cargo tree`, the same check rust/host's own Cargo.toml
// comments already lean on for every dependency THAT crate accepts) —
// it does not reopen the cross-compile/aarch64-toolchain problem
// `rust/host/Cargo.toml`'s own comments document at length for crates
// that DO carry one.
//
// `expr.rs`'s `category_of` guarantees `interpret` below is only ever
// called with `MatchesRegex` — see `logical.rs`'s header for why the
// trailing arm is a router-bug guard, not a real refusal path.

use crate::kernel::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::kernel::Refusal;
use regex::RegexBuilder;

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::MatchesRegex { receiver, pattern, flags } = expr else {
        return Err(Refusal::TypeMismatch(format!("pattern_match::interpret called with a non-match? node {expr:?} — a router bug")));
    };

    let text = coerce_text(&eval(receiver, ctx)?)?;

    // `Resolver#matches_regex?`, read directly: `i`/`m`/`x` map straight
    // onto RegexBuilder's own case_insensitive/multi_line/... flags —
    // Ruby's `/x` (extended, whitespace-and-comments-ignored) is the one
    // that needs a name change (`ignore_whitespace` here) since the two
    // libraries spell the same feature differently, not a semantic gap.
    let mut builder = RegexBuilder::new(pattern);
    builder.case_insensitive(flags.contains('i'));
    builder.multi_line(flags.contains('m'));
    builder.ignore_whitespace(flags.contains('x'));

    let re = builder
        .build()
        .map_err(|e| eval_error(format!("match? given an invalid pattern {pattern:?} — {e}")))?;

    Ok(Value::Bool(re.is_match(&text)))
}

/// `Resolver#matches_regex?`'s own `case receiver_value` — String/Symbol
/// (this kernel has no `Symbol` `Value`, so just `Str`), Integer/Float
/// stringified, `nil` as `""`; anything else refuses by name rather than
/// stringifying a shape `.match?` was never meant to receive.
fn coerce_text(v: &Value) -> Result<String, Refusal> {
    match v {
        Value::Str(s) => Ok(s.clone()),
        Value::Int(i) => Ok(i.to_string()),
        Value::Float(f) => Ok(f.to_string()),
        Value::Nil => Ok(String::new()),
        Value::Bool(_) | Value::List(_) | Value::Array(_) => Err(eval_error(format!("match? expects a scalar, got {v:?}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(receiver: Expr, pattern: &str, flags: &str) -> Value {
        let expr = Expr::MatchesRegex { receiver: Box::new(receiver), pattern: pattern.to_string(), flags: flags.to_string() };
        let ctx = EvalContext { args: &crate::kernel::expr::NoFields, instance: &crate::kernel::expr::NoFields };
        eval(&expr, &ctx).expect("evaluates")
    }

    #[test]
    fn matches_a_simple_anchored_pattern() {
        assert_eq!(matches(Expr::Str("12345".to_string()), r"\A\d{5}\z", ""), Value::Bool(true));
        assert_eq!(matches(Expr::Str("1234".to_string()), r"\A\d{5}\z", ""), Value::Bool(false));
    }

    #[test]
    fn the_i_flag_ignores_case() {
        assert_eq!(matches(Expr::Str("HELLO".to_string()), "hello", ""), Value::Bool(false));
        assert_eq!(matches(Expr::Str("HELLO".to_string()), "hello", "i"), Value::Bool(true));
    }

    #[test]
    fn coerces_non_string_scalars_to_text() {
        assert_eq!(matches(Expr::Int(12345), r"\A\d+\z", ""), Value::Bool(true));
        assert_eq!(matches(Expr::Nil, r"\A\z", ""), Value::Bool(true));
    }

    #[test]
    fn an_invalid_pattern_refuses_cleanly() {
        let expr = Expr::MatchesRegex { receiver: Box::new(Expr::Str("x".to_string())), pattern: "(".to_string(), flags: String::new() };
        let ctx = EvalContext { args: &crate::kernel::expr::NoFields, instance: &crate::kernel::expr::NoFields };
        assert!(eval(&expr, &ctx).is_err());
    }
}
