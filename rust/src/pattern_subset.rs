// [antibody-exempt: rust/src/pattern_subset.rs — kernel-floor grammar guard.
//  Decides which regex constructs a bluebook may declare, so the Ruby and Rust
//  engines cannot disagree. A rule about what the LANGUAGE admits cannot itself
//  be expressed in that language without circularity.]
//! The regex subset a `pattern:` may use — the intersection of Ruby's `Regexp`
//! and Rust's `regex` crate.
//!
//! A bluebook is executed by TWO engines : the Rust runtime and the Ruby
//! behaviors runner. They must agree, and their regex dialects do not.
//! Rust's `regex` crate omits lookaround and backreferences BY DESIGN — they
//! cannot be matched in guaranteed linear time. Ruby's `Regexp` has both.
//!
//! So `^(?=.*[A-Z])` — an ordinary password rule — compiles in Ruby and FAILS
//! in Rust. One declaration, two behaviours. That is the drift this codebase
//! has paid for repeatedly (a fixtures file that said `shrink` while the gate
//! did `grow` ; a query shape that differed between the two targets ; an
//! auto-list heuristic retired from the parsers and still live in the runtime).
//!
//! The answer is not to test for it. It is to REFUSE the constructs that could
//! diverge, at authoring time, so a bluebook cannot express them. What remains
//! — anchors, classes, quantifiers, alternation, plain groups — is identical
//! under both engines, which is exactly what a domain needs for an SKU, a
//! postal code or a phone number.

/// Why a pattern was refused. Carries the offending construct so the message
/// can name it rather than say "invalid".
#[derive(Debug, Clone, PartialEq)]
pub struct PatternRejection {
    pub construct: &'static str,
    pub reason: &'static str,
}

impl PatternRejection {
    fn new(construct: &'static str, reason: &'static str) -> Self {
        Self { construct, reason }
    }
}

/// Refuse any construct whose meaning differs between Ruby and Rust.
///
/// Returns `Ok(())` for a pattern both engines treat identically. The check is
/// SYNTACTIC — it inspects the pattern text rather than compiling it — so it
/// gives the same verdict in the parser, the validator and the Ruby side, and
/// needs no engine to run.
pub fn validate_pattern_subset(pattern: &str) -> Result<(), PatternRejection> {
    let bytes = pattern.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        // An escape consumes its next char : `\(` is a literal paren, not a
        // group, and `\1` inside a character class is not a backreference.
        if bytes[i] == b'\\' {
            if let Some(next) = bytes.get(i + 1) {
                // A backreference is \1..\9 OUTSIDE an escape of a digit class.
                if next.is_ascii_digit() && *next != b'0' {
                    return Err(PatternRejection::new(
                        "backreference",
                        "Rust's regex crate has no backreferences (they cannot be \
                         matched in linear time) ; Ruby does, so the two engines \
                         would disagree",
                    ));
                }
                if matches!(next, b'k' | b'g') {
                    return Err(PatternRejection::new(
                        "named backreference",
                        "Rust's regex crate has no backreferences ; Ruby does",
                    ));
                }
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        // Group openers : `(?=`, `(?!`, `(?<=`, `(?<!` are lookaround.
        if bytes[i] == b'(' && bytes.get(i + 1) == Some(&b'?') {
            match bytes.get(i + 2) {
                Some(b'=') | Some(b'!') => {
                    return Err(PatternRejection::new(
                        "lookahead",
                        "Rust's regex crate has no lookahead (it cannot be matched \
                         in linear time) ; Ruby does, so the two engines would \
                         disagree",
                    ));
                }
                Some(b'<') if matches!(bytes.get(i + 3), Some(b'=') | Some(b'!')) => {
                    return Err(PatternRejection::new(
                        "lookbehind",
                        "Rust's regex crate has no lookbehind ; Ruby does",
                    ));
                }
                _ => {}
            }
        }
        // Ruby's \A \z \Z and (?<name>) are fine ; possessive / atomic groups
        // are Ruby-only and would be a syntax error in Rust.
        if bytes[i] == b'(' && bytes.get(i + 1) == Some(&b'?') && bytes.get(i + 2) == Some(&b'>') {
            return Err(PatternRejection::new(
                "atomic group",
                "Ruby-only : Rust's regex crate rejects `(?>` as a syntax error",
            ));
        }
        // Possessive quantifiers (`a*+`, `a++`, `a?+`) are Ruby-only.
        if matches!(bytes[i], b'*' | b'+' | b'?') && bytes.get(i + 1) == Some(&b'+') {
            return Err(PatternRejection::new(
                "possessive quantifier",
                "Ruby-only : Rust's regex crate rejects it as a syntax error",
            ));
        }
        i += 1;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rejected(p: &str) -> &'static str {
        validate_pattern_subset(p).expect_err("should be refused").construct
    }

    #[test]
    fn the_shapes_a_domain_actually_needs_are_admitted() {
        // Every one of these means the same thing in Ruby and Rust.
        for p in [
            r"^[A-Z]{3}-\d{4}$",                    // SKU
            r"^\d{5}(-\d{4})?$",                    // US postal
            r"^\+?[0-9 ()-]{7,20}$",                // phone
            r"^[^@\s]+@[^@\s]+\.[^@\s]+$",          // email
            r"^(red|green|blue)$",                  // alternation
            r"^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$", // uuid
            r"",                                    // empty is permissive, not invalid
        ] {
            assert!(
                validate_pattern_subset(p).is_ok(),
                "must admit the common case: {}",
                p
            );
        }
    }

    #[test]
    fn constructs_that_would_diverge_are_refused() {
        assert_eq!(rejected(r"^(?=.*[A-Z]).+$"), "lookahead");
        assert_eq!(rejected(r"^(?!foo).+$"), "lookahead");
        assert_eq!(rejected(r"(?<=a)b"), "lookbehind");
        assert_eq!(rejected(r"(?<!a)b"), "lookbehind");
        assert_eq!(rejected(r"(a)\1"), "backreference");
        assert_eq!(rejected(r"(?<x>a)\k<x>"), "named backreference");
        assert_eq!(rejected(r"(?>ab)"), "atomic group");
        assert_eq!(rejected(r"a*+"), "possessive quantifier");
    }

    #[test]
    fn an_escaped_construct_is_a_literal_not_a_violation() {
        // `\(` is a literal paren — refusing it would reject a legitimate
        // pattern for text that CONTAINS "(?=".
        assert!(validate_pattern_subset(r"\(\?=").is_ok());
        // A named GROUP is fine ; only a named BACKreference is not.
        assert!(validate_pattern_subset(r"(?<year>\d{4})").is_ok());
        // `\0` is a null escape, not a backreference.
        assert!(validate_pattern_subset(r"\0").is_ok());
    }

    #[test]
    fn the_rejection_names_the_construct_and_says_why() {
        let err = validate_pattern_subset(r"^(?=x)").unwrap_err();
        assert_eq!(err.construct, "lookahead");
        assert!(
            err.reason.contains("Ruby") && err.reason.contains("linear"),
            "the message must explain the DIVERGENCE, not just say invalid: {}",
            err.reason
        );
    }
}
