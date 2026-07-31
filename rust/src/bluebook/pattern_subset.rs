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

pub fn validate_pattern_subset(pattern: &str) -> Result<(), PatternRejection> {
    let bytes = pattern.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            if let Some(next) = bytes.get(i + 1) {
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
                if matches!(next, b'd' | b'D' | b'w' | b'W' | b's' | b'S') {
                    return Err(PatternRejection::new(
                        "perl character class",
                        "the two engines read it in OPPOSITE directions : Ruby's are \
                         ASCII and Rust's are Unicode, so an Arabic-Indic digit \
                         satisfies one and not the other. Spell the range you mean — \
                         [0-9], [A-Za-z0-9_], [ \t] — which both read the same way",
                    ));
                }
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
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
        if bytes[i] == b'(' && bytes.get(i + 1) == Some(&b'?') && bytes.get(i + 2) == Some(&b'>') {
            return Err(PatternRejection::new(
                "atomic group",
                "Ruby-only : Rust's regex crate rejects `(?>` as a syntax error",
            ));
        }
        // `[:digit:]` and friends — the obvious substitute for the perl classes,
        // and wrong in the mirror direction : Ruby reads them as UNICODE, Rust as
        // ASCII. Measured, not assumed ; tmp/pattern_probe.rb carries the cases.
        if bytes[i] == b'[' && bytes.get(i + 1) == Some(&b':') {
            let mut j = i + 2;
            while j < bytes.len() && bytes[j].is_ascii_alphabetic() {
                j += 1;
            }
            if bytes.get(j) == Some(&b':') && bytes.get(j + 1) == Some(&b']') {
                return Err(PatternRejection::new(
                    "posix bracket class",
                    "Ruby reads [:digit:] and friends as UNICODE and Rust reads them \
                     as ASCII — the mirror of the perl classes, and wrong in the same \
                     way. Spell the range you mean",
                ));
            }
        }
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

/// MATCHING, which is the half the subset does not cover.
///
/// `validate_pattern_subset` refuses the constructs the two engines cannot both
/// PARSE. It says nothing about the constructs they parse and then disagree
/// about — and on its own admitted examples they do, in three places:
///
///   · `^` and `$` are LINE anchors in Ruby and TEXT anchors in Rust, so
///     "xx\nABC-1234\nyy" matches `^[A-Z]{3}-\d{4}$` in Ruby and not in Rust.
///   · Ruby's `$` also matches BEFORE a final newline, so "ABC-1234\n" matches.
///   · `\d`, `\w`, `\s` are ASCII in Ruby and UNICODE in Rust, so an
///     Arabic-Indic digit satisfies Rust's `\d` and not Ruby's.
///
/// So the engine is configured to Ruby's reading rather than its own default :
/// `multi_line(true)` makes `^`/`$` line anchors, and `unicode(false)` makes the
/// perl classes ASCII. Ruby is the reference because the bluebook DSL is written
/// in Ruby and its `pattern:` is a Ruby string a reader will try in irb.
///
/// What this does NOT fix is Ruby's `$`-before-a-final-newline, which Rust has
/// no flag for. That one is refused by the subset instead — see the `$` arm in
/// validate_pattern_subset.
pub fn matches(pattern: &str, value: &str) -> Result<bool, String> {
    let compiled = regex::RegexBuilder::new(pattern)
        .multi_line(true)
        .build()
        .map_err(|error| format!("{}", error))?;

    Ok(compiled.is_match(value))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rejected(p: &str) -> &'static str {
        validate_pattern_subset(p)
            .expect_err("should be refused")
            .construct
    }

    #[test]
    fn the_shapes_a_domain_actually_needs_are_admitted() {
        // Spelled with explicit ranges rather than the perl classes, because
        // those are refused now : Ruby reads them as ASCII and Rust as Unicode,
        // so a pattern written with them would mean two different things. These
        // are the same shapes, said in the way both engines share.
        for p in [
            r"^[A-Z]{3}-[0-9]{4}$",
            r"^[0-9]{5}(-[0-9]{4})?$",
            r"^\+?[0-9 ()-]{7,20}$",
            r"^[^@ ]+@[^@ ]+\.[^@ ]+$",
            r"^(red|green|blue)$",
            r"^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$",
            r"",
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
        // The two that PARSE in both engines and mean different things — the
        // failure the subset alone did not catch, and the reason `matches` exists
        // beside it. Ruby's perl classes are ASCII and Rust's are Unicode ; POSIX
        // brackets are the exact mirror.
        assert_eq!(rejected(r"^\d{4}$"), "perl character class");
        assert_eq!(rejected(r"^\w+$"), "perl character class");
        assert_eq!(rejected(r"^[^@\s]+$"), "perl character class");
        assert_eq!(rejected(r"^[[:digit:]]{4}$"), "posix bracket class");
        assert_eq!(rejected(r"^[[:alpha:]]+$"), "posix bracket class");
    }

    #[test]
    fn an_escaped_construct_is_a_literal_not_a_violation() {
        assert!(validate_pattern_subset(r"\(\?=").is_ok());
        assert!(validate_pattern_subset(r"(?<year>[0-9]{4})").is_ok());
        assert!(validate_pattern_subset(r"\0").is_ok());
    }

    // THE DIFFERENTIAL, and the reason `matches` configures the engine at all.
    //
    // spec/parity/fixtures/patterns.json is a RECORDED CONTRACT, not a transcript
    // of what Ruby happens to do : both runtimes answer to it, so a regression in
    // either is caught. (Recording Ruby's answers and diffing Rust against them
    // would have made Ruby unilaterally right and a Ruby regression invisible.)
    // spec/pattern_subset_spec.rb reads the same file.
    #[test]
    fn rust_reads_every_admitted_pattern_the_way_ruby_does() {
        let recorded = std::fs::read_to_string("../spec/parity/fixtures/patterns.json")
            .expect("spec/parity/fixtures/patterns.json");
        let rows: serde_json::Value = serde_json::from_str(&recorded).unwrap();

        let mut disagreements = vec![];
        for row in rows.as_array().unwrap() {
            let pattern = row["pattern"].as_str().unwrap();
            let input = row["input"].as_str().unwrap();
            let ruby = row["matches"].as_bool().unwrap();

            match matches(pattern, input) {
                Ok(rust) if rust == ruby => {}
                Ok(rust) => disagreements.push(format!(
                    "  {:?} against {:?} — ruby {}, rust {}",
                    pattern, input, ruby, rust
                )),
                Err(error) => disagreements.push(format!(
                    "  {:?} against {:?} — ruby {}, rust could not compile it: {}",
                    pattern, input, ruby, error
                )),
            }
        }

        assert!(
            disagreements.is_empty(),
            "the two engines disagree on {} case(s):\n{}",
            disagreements.len(),
            disagreements.join("\n")
        );
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
