//! The regex subset a bluebook `pattern:` may use (mirrors `Hecks::Bluebook::PatternSubset`).
//! Engines disagree on backreferences, lookaround and `\d`/POSIX classes, so they are refused.

pub struct Rejection {
    pub construct: &'static str,
    pub reason: &'static str,
}

/// `None` when the pattern is in the portable subset, else a `Rejection` naming the construct.
pub fn validate(pattern: &str) -> Option<Rejection> {
    let chars: Vec<char> = pattern.chars().collect();
    let mut index = 0usize;

    while index < chars.len() {
        if chars[index] == '\\' {
            let next = chars.get(index + 1).copied();
            if matches!(next, Some(c) if c.is_ascii_digit() && c != '0') {
                return Some(refuse("backreference"));
            }
            if matches!(next, Some('k') | Some('g')) {
                return Some(refuse("named_backreference"));
            }
            if matches!(
                next,
                Some('d') | Some('D') | Some('w') | Some('W') | Some('s') | Some('S')
            ) {
                return Some(refuse("perl_class"));
            }
            index += if next.is_some() { 2 } else { 1 };
            continue;
        }

        if chars[index] == '(' && chars.get(index + 1) == Some(&'?') {
            let third = chars.get(index + 2).copied();
            if matches!(third, Some('=') | Some('!')) {
                return Some(refuse("lookahead"));
            }
            if third == Some('<') && matches!(chars.get(index + 3).copied(), Some('=') | Some('!'))
            {
                return Some(refuse("lookbehind"));
            }
            if third == Some('>') {
                return Some(refuse("atomic_group"));
            }
        }

        if posix_class_at(&chars, index) {
            return Some(refuse("posix_class"));
        }
        if matches!(chars[index], '*' | '+' | '?') && chars.get(index + 1) == Some(&'+') {
            return Some(refuse("possessive"));
        }

        index += 1;
    }

    None
}

fn refuse(key: &'static str) -> Rejection {
    let (construct, reason) = REASONS
        .iter()
        .find(|(k, _, _)| *k == key)
        .map(|(_, c, r)| (*c, *r))
        .expect("unknown PatternSubset rejection key");
    Rejection { construct, reason }
}

fn posix_class_at(chars: &[char], index: usize) -> bool {
    if chars.get(index) != Some(&'[') || chars.get(index + 1) != Some(&':') {
        return false;
    }
    let mut cursor = index + 2;
    while matches!(chars.get(cursor), Some(c) if c.is_ascii_alphabetic()) {
        cursor += 1;
    }
    chars.get(cursor) == Some(&':') && chars.get(cursor + 1) == Some(&']')
}

const REASONS: &[(&str, &str, &str)] = &[
    (
        "backreference",
        "backreference",
        "backreferences cannot be matched in linear time and portable engines refuse them ; a declared pattern may not depend on one",
    ),
    (
        "named_backreference",
        "named backreference",
        "a named backreference is still a backreference — it cannot be matched in linear time ; a declared pattern may not depend on one",
    ),
    (
        "perl_class",
        "perl character class",
        "engines read it in OPPOSITE directions : ASCII in some and Unicode in others, so an Arabic-Indic digit satisfies one and not the other. Spell the range you mean — [0-9], [A-Za-z0-9_], [ \\t] — which every engine reads the same way",
    ),
    (
        "posix_class",
        "posix bracket class",
        "[:digit:] and friends flip between ASCII and Unicode across engines — the mirror of the perl classes, and wrong in the same way. Spell the range you mean",
    ),
    (
        "lookahead",
        "lookahead",
        "lookahead cannot be matched in linear time and portable engines refuse it ; a declared pattern may not depend on it",
    ),
    (
        "lookbehind",
        "lookbehind",
        "lookbehind cannot be matched in linear time and portable engines refuse it ; a declared pattern may not depend on it",
    ),
    (
        "atomic_group",
        "atomic group",
        "an atomic group is a backtracking-engine control knob — linear-time engines reject `(?>` as a syntax error",
    ),
    (
        "possessive",
        "possessive quantifier",
        "a possessive quantifier is a backtracking-engine control knob — linear-time engines reject it as a syntax error",
    ),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn admits_the_explicit_ranges_email_address_pattern_uses() {
        assert!(validate(r"^[^@ ]+@[^@ ]+\.[^@ ]+$").is_none());
    }

    #[test]
    fn refuses_a_perl_digit_class() {
        let r = validate(r"\d+").unwrap();
        assert_eq!(r.construct, "perl character class");
    }

    #[test]
    fn refuses_a_backreference() {
        let r = validate(r"(a)\1").unwrap();
        assert_eq!(r.construct, "backreference");
    }

    #[test]
    fn refuses_lookahead() {
        let r = validate(r"a(?=b)").unwrap();
        assert_eq!(r.construct, "lookahead");
    }

    #[test]
    fn refuses_a_posix_class() {
        let r = validate(r"[[:digit:]]").unwrap();
        assert_eq!(r.construct, "posix bracket class");
    }

    #[test]
    fn treats_an_escaped_construct_as_a_literal() {
        // `\(\?=` is the literal text "(?=", not a lookahead.
        assert!(validate(r"\(\?=").is_none());
    }
}
