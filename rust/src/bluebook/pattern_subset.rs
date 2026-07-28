
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
        for p in [
            r"^[A-Z]{3}-\d{4}$",                    
            r"^\d{5}(-\d{4})?$",                    
            r"^\+?[0-9 ()-]{7,20}$",                
            r"^[^@\s]+@[^@\s]+\.[^@\s]+$",          
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
    }

    #[test]
    fn an_escaped_construct_is_a_literal_not_a_violation() {
        assert!(validate_pattern_subset(r"\(\?=").is_ok());
        assert!(validate_pattern_subset(r"(?<year>\d{4})").is_ok());
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
