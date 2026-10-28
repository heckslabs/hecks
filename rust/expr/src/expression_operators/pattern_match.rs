//! Interprets `.match?` against a Ruby-style pattern with `i`/`m`/`x` flags.
//! `regex` is the kernel's one dependency: a hand-rolled subset cannot reach Ruby parity.

use crate::expr::{eval_error, interpret as eval, EvalContext, Expr, Value};
use crate::rendering;
use crate::Refusal;

/// Evaluates `.match?` against a Ruby regexp.
pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    let Expr::MatchesRegex {
        receiver,
        pattern,
        flags,
    } = expr
    else {
        return Err(Refusal::TypeMismatch(format!(
            "pattern_match::interpret called with a non-match? node {expr:?} — a router bug"
        )));
    };

    let text = coerce_text(&eval(receiver, ctx)?)?;

    let re = ruby_regex(pattern, flags)?;

    Ok(Value::Bool(re.is_match(&text)))
}

/// Text form of a scalar receiver: nil is empty, Bool and lists refuse.
/// Compiles a Ruby `Regexp` source for the `regex` crate.
///
/// Ruby's `\d \w \s \h` are ASCII and its `^ $` are always line anchors, where `regex` reads
/// the classes as Unicode and the anchors as text anchors, so both are rewritten. `m` is
/// Ruby's dot-matches-newline; `\Z` (end, or before a final newline) becomes `\n?\z`.
fn ruby_regex(pattern: &str, flags: &str) -> Result<regex::Regex, Refusal> {
    use std::fmt::Write;
    let mut source = String::new();
    let mut in_class = false;
    let mut class_start = 0;
    let chars: Vec<char> = pattern.chars().collect();
    let mut index = 0;
    while index < chars.len() {
        let c = chars[index];
        if c == '\\' {
            let Some(&next) = chars.get(index + 1) else {
                source.push(c);
                break;
            };
            index += 2;
            let (positive, negative) = match next.to_ascii_lowercase() {
                'd' => ("0-9", "[^0-9]"),
                'w' => ("A-Za-z0-9_", "[^A-Za-z0-9_]"),
                's' => ("\\x20\\t\\r\\n\\f\\x0B", "[^\\x20\\t\\r\\n\\f\\x0B]"),
                'h' => ("0-9a-fA-F", "[^0-9a-fA-F]"),
                _ => {
                    match next {
                        'Z' if !in_class => source.push_str("(?:\\n?\\z)"),
                        _ => {
                            source.push(c);
                            source.push(next);
                        }
                    }
                    continue;
                }
            };
            match (next.is_ascii_uppercase(), in_class) {
                (false, true) => source.push_str(positive),
                (false, false) => {
                    let _ = write!(source, "[{positive}]"); // writing to a String cannot fail
                }
                (true, _) => source.push_str(negative),
            }
            continue;
        }
        if in_class {
            if c == ']' && index != class_start {
                in_class = false;
            }
        } else if c == '[' {
            in_class = true;
            class_start = index + 1;
            if chars.get(class_start) == Some(&'^') {
                class_start += 1;
            }
        } else if c == '^' || c == '$' {
            source.push_str(if c == '^' { "(?m:^)" } else { "(?m:$)" });
            index += 1;
            continue;
        }
        source.push(c);
        index += 1;
    }

    regex::RegexBuilder::new(&source)
        .case_insensitive(flags.contains('i'))
        .dot_matches_new_line(flags.contains('m'))
        .ignore_whitespace(flags.contains('x'))
        .build()
        .map_err(|e| {
            eval_error(format!(
                "match? given an invalid pattern {} — {e}",
                rendering::ruby_inspect(pattern)
            ))
        })
}

/// Text form of a scalar receiver: nil is empty, Bool and lists refuse.
fn coerce_text(v: &Value) -> Result<String, Refusal> {
    match v {
        Value::Str(s) => Ok(s.clone()),
        Value::Int(i) => Ok(i.to_string()),
        Value::Float(f) => Ok(crate::ruby_float::to_s(*f)),
        Value::Nil => Ok(String::new()),
        Value::Bool(_) | Value::List(_) | Value::Array(_) | Value::Object(_) => Err(eval_error(
            format!("match? expects a scalar, got {}", rendering::class_of(v)),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn matches(receiver: Expr, pattern: &str, flags: &str) -> Value {
        let expr = Expr::MatchesRegex {
            receiver: Box::new(receiver),
            pattern: pattern.to_string(),
            flags: flags.to_string(),
        };
        let ctx = EvalContext {
            args: &crate::expr::NoFields,
            instance: &crate::expr::NoFields,
        };
        eval(&expr, &ctx).expect("evaluates")
    }

    #[test]
    fn matches_a_simple_anchored_pattern() {
        assert_eq!(
            matches(Expr::Str("12345".to_string()), r"\A\d{5}\z", ""),
            Value::Bool(true)
        );
        assert_eq!(
            matches(Expr::Str("1234".to_string()), r"\A\d{5}\z", ""),
            Value::Bool(false)
        );
    }

    #[test]
    fn the_i_flag_ignores_case() {
        assert_eq!(
            matches(Expr::Str("HELLO".to_string()), "hello", ""),
            Value::Bool(false)
        );
        assert_eq!(
            matches(Expr::Str("HELLO".to_string()), "hello", "i"),
            Value::Bool(true)
        );
    }

    #[test]
    fn coerces_non_string_scalars_to_text() {
        assert_eq!(matches(Expr::Int(12345), r"\A\d+\z", ""), Value::Bool(true));
        assert_eq!(matches(Expr::Nil, r"\A\z", ""), Value::Bool(true));
    }

    #[test]
    fn an_invalid_pattern_refuses_cleanly() {
        let expr = Expr::MatchesRegex {
            receiver: Box::new(Expr::Str("x".to_string())),
            pattern: "(".to_string(),
            flags: String::new(),
        };
        let ctx = EvalContext {
            args: &crate::expr::NoFields,
            instance: &crate::expr::NoFields,
        };
        assert!(eval(&expr, &ctx).is_err());
    }
}
