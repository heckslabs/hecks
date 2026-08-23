// HAND-WRITTEN, ONCE, GENERIC — a regex matcher for exactly the dialect
// `Hecksagain::Bluebook::PatternSubset` (`lib/hecksagain/bluebook/
// pattern_subset.rb`) admits into a bluebook's `pattern:` declaration in
// the first place: literal characters, `.`, `^`/`$` (and `\A`/`\z`)
// anchors, `[...]`/`[^...]` character classes with explicit ranges,
// `*`/`+`/`?`/`{n}`/`{n,}`/`{n,m}` quantifiers, `(...)` groups, and `|`
// alternation. `PatternSubset` REFUSES backreferences, named
// backreferences, Perl classes (`\d`/`\w`/`\s`...), POSIX classes,
// lookaround, atomic groups, and possessive quantifiers at BLUEBOOK-LOAD
// time — read directly, not guessed — so by construction no pattern that
// ever reaches this matcher needs any of those: a plain recursive
// backtracking matcher is enough, no NFA/DFA compilation required, and
// zero Cargo dependencies (the same constraint `json.rs`/`expr.rs`
// already hold themselves to — see docs/implemented/decisions/0012).
//
// `Value::for_attribute`'s own `check_patterns` (coercion.rb) semantics:
// unanchored search — `Regexp.new(pattern).match?(text)` finds a match
// ANYWHERE in `text`, not just a whole-string match, unless the pattern
// itself anchors with `^`/`$`/`\A`/`\z`. `matches` (below) reproduces
// that: try every start position unless the pattern's own first atom is
// an anchor.

#[derive(Debug, Clone)]
enum Node {
    Literal(char),
    Any,
    Class { negate: bool, ranges: Vec<(char, char)> },
    // `^`/`$` — PER-LINE anchors (Ruby's own default, unlike most other
    // regex flavors): `^` matches at position 0 OR right after any `\n`;
    // `$` matches at the end of the text OR right before any `\n`. Item
    // #4, whole-project table-unification survey — found via a new
    // #[cfg(test)] walking spec/corpus/fixtures/patterns.json's own
    // recorded contract: this matcher used to treat `^`/`$` identically
    // to `\A`/`\z` (whole-string only), disagreeing with Ruby's real
    // `Regexp` on any multi-line input — e.g. `/^[A-Z]{3}-[0-9]{4}$/`
    // against `"xx\nABC-1234\nyy"` (Ruby: true, this matcher: false,
    // before this fix).
    LineStart,
    LineEnd,
    // `\A`/`\z`/`\Z` — WHOLE-STRING anchors, never satisfied mid-text no
    // matter where a `\n` falls. Distinct nodes, not a flag on Start/End,
    // because the two anchor KINDS mean genuinely different things, not
    // two spellings of the same fact — collapsing them is exactly the
    // bug this fix undoes.
    StringStart,
    StringEnd,
    Group(Vec<Node>),
    Alt(Vec<Vec<Node>>),
    Repeat { node: Box<Node>, min: usize, max: Option<usize> },
}

/// `true` if `text` contains a match for `pattern`, per the dialect above.
/// A pattern `PatternSubset` would have refused (or any other parse
/// failure) returns `false` rather than panicking — this matcher is only
/// ever invoked with a bluebook's OWN declared `pattern:` string, already
/// validated at load time by the Ruby side that generated this call, so a
/// parse failure here would mean a real bug elsewhere, not bad input to
/// tolerate gracefully.
pub fn matches(pattern: &str, text: &str) -> bool {
    let Ok(nodes) = parse(pattern) else { return false };
    let chars: Vec<char> = text.chars().collect();
    // ONLY `\A` (StringStart) justifies skipping straight to position 0 —
    // `^` (LineStart) can still legitimately match at a LATER position
    // (right after some `\n`), so the general "try every start position"
    // loop below has to run for it; `LineStart`'s own per-position check
    // (in `match_from`) is what actually enforces which positions qualify.
    let anchored_start = matches!(nodes.first(), Some(Node::StringStart));
    if anchored_start {
        return match_from(&nodes, 0, &chars, 0, &|_| true);
    }
    (0..=chars.len()).any(|start| match_from(&nodes, 0, &chars, start, &|_| true))
}

fn match_from(nodes: &[Node], idx: usize, text: &[char], ti: usize, cont: &dyn Fn(usize) -> bool) -> bool {
    if idx == nodes.len() {
        return cont(ti);
    }
    match &nodes[idx] {
        Node::Literal(c) => ti < text.len() && text[ti] == *c && match_from(nodes, idx + 1, text, ti + 1, cont),
        // `.` — matches any character EXCEPT `\n`, Ruby's own default
        // (no `/m` flag support in this dialect — PatternSubset admits
        // no way to spell one). Item #4, whole-project table-unification
        // survey — found via the same #[cfg(test)] contract test as the
        // LineStart/LineEnd and escape_char fixes just above.
        Node::Any => ti < text.len() && text[ti] != '\n' && match_from(nodes, idx + 1, text, ti + 1, cont),
        Node::Class { negate, ranges } => {
            ti < text.len() && class_matches(*negate, ranges, text[ti]) && match_from(nodes, idx + 1, text, ti + 1, cont)
        }
        Node::LineStart => (ti == 0 || text[ti - 1] == '\n') && match_from(nodes, idx + 1, text, ti, cont),
        Node::LineEnd => (ti == text.len() || text[ti] == '\n') && match_from(nodes, idx + 1, text, ti, cont),
        Node::StringStart => ti == 0 && match_from(nodes, idx + 1, text, ti, cont),
        Node::StringEnd => ti == text.len() && match_from(nodes, idx + 1, text, ti, cont),
        Node::Group(inner) => match_from(inner, 0, text, ti, &|ti2| match_from(nodes, idx + 1, text, ti2, cont)),
        Node::Alt(branches) => branches.iter().any(|b| match_from(b, 0, text, ti, &|ti2| match_from(nodes, idx + 1, text, ti2, cont))),
        Node::Repeat { node, min, max } => match_repeat(node, 0, *min, *max, nodes, idx + 1, text, ti, cont),
    }
}

/// Greedy quantifier matching WITH backtracking: try one more repetition
/// first (as many as `max` allows), and only once that whole branch fails
/// does it fall back to stopping at the current count — standard greedy-
/// then-backtrack semantics, the same a backtracking engine gives `+`/`*`
/// in any other implementation. `count == ti` guards against looping
/// forever on a zero-width repeated match (an empty group inside `*`,
/// which nothing in the admitted dialect's LIVE usage needs, but a
/// well-formed matcher shouldn't hang on either).
#[allow(clippy::too_many_arguments)]
fn match_repeat(
    node: &Node,
    count: usize,
    min: usize,
    max: Option<usize>,
    nodes: &[Node],
    next_idx: usize,
    text: &[char],
    ti: usize,
    cont: &dyn Fn(usize) -> bool,
) -> bool {
    let can_more = max.is_none_or(|m| count < m);
    if can_more {
        let one_more = std::slice::from_ref(node);
        let matched = match_from(one_more, 0, text, ti, &|ti2| {
            if ti2 == ti {
                return false; // zero-width — stop growing, fall through to the min/stop check below
            }
            match_repeat(node, count + 1, min, max, nodes, next_idx, text, ti2, cont)
        });
        if matched {
            return true;
        }
    }
    count >= min && match_from(nodes, next_idx, text, ti, cont)
}

fn class_matches(negate: bool, ranges: &[(char, char)], c: char) -> bool {
    let hit = ranges.iter().any(|(lo, hi)| *lo <= c && c <= *hi);
    hit != negate
}

// `\t`/`\n`/`\r` — the three CONTROL-CHARACTER escapes Ruby's own
// `Regexp` recognizes and this dialect's real corpus usage leans on
// hardest (`[^ \t\n\r]`, banking.bluebook's own most common `pattern:`
// — 26 usages in that one file alone). Item #4, whole-project table-
// unification survey — found via the new #[cfg(test)] contract test:
// both escape call sites used to take the RAW character following the
// backslash verbatim (`\t` → the letter `t`, not a real tab), which
// meant `[^ \t\n\r]` was silently checking against the LETTERS t/n/r
// instead of actual whitespace/control characters — every string
// containing a lowercase t, n, or r anywhere (extremely common in real
// text) was wrongly refused, and a string containing an ACTUAL tab/
// newline/CR was wrongly accepted. Every other escaped character
// (`\.`, `\+`, `\\`, `\-`, ...) passes through unchanged — this is a
// closed, small set, not a general C-style escape table, matching
// `PatternSubset`'s own admitted dialect (no `\0`, no `\xNN`, no
// Unicode escapes).
fn escape_char(c: char) -> char {
    match c {
        't' => '\t',
        'n' => '\n',
        'r' => '\r',
        other => other,
    }
}

// ── PARSER — recursive descent, `alternation > concat > repeat > atom`,
// the standard regex grammar shape. Returns a flat `Vec<Node>` (a `Seq`)
// at the top level; `|` at any level becomes one `Node::Alt` holding each
// branch's own `Vec<Node>`.
fn parse(pattern: &str) -> Result<Vec<Node>, ()> {
    let chars: Vec<char> = pattern.chars().collect();
    let mut p = Parser { chars: &chars, pos: 0 };
    let node = p.parse_alt()?;
    if p.pos != p.chars.len() {
        return Err(());
    }
    Ok(node)
}

struct Parser<'a> {
    chars: &'a [char],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek();
        if c.is_some() {
            self.pos += 1;
        }
        c
    }

    /// `alternation := concat ('|' concat)*` — a single branch collapses
    /// straight back to its own `Vec<Node>` rather than a one-armed `Alt`,
    /// so a pattern with no `|` anywhere never pays for the indirection.
    fn parse_alt(&mut self) -> Result<Vec<Node>, ()> {
        let first = self.parse_concat()?;
        if self.peek() != Some('|') {
            return Ok(first);
        }
        let mut branches = vec![first];
        while self.peek() == Some('|') {
            self.bump();
            branches.push(self.parse_concat()?);
        }
        Ok(vec![Node::Alt(branches)])
    }

    /// `concat := repeat*` — stops at `|` or `)`, the two constructs that
    /// end a concatenation without consuming it themselves.
    fn parse_concat(&mut self) -> Result<Vec<Node>, ()> {
        let mut nodes = Vec::new();
        while let Some(c) = self.peek() {
            if c == '|' || c == ')' {
                break;
            }
            nodes.push(self.parse_repeat()?);
        }
        Ok(nodes)
    }

    /// `repeat := atom ('*' | '+' | '?' | '{' n (',' m?)? '}')?`
    fn parse_repeat(&mut self) -> Result<Node, ()> {
        let atom = self.parse_atom()?;
        match self.peek() {
            Some('*') => {
                self.bump();
                Ok(Node::Repeat { node: Box::new(atom), min: 0, max: None })
            }
            Some('+') => {
                self.bump();
                Ok(Node::Repeat { node: Box::new(atom), min: 1, max: None })
            }
            Some('?') => {
                self.bump();
                Ok(Node::Repeat { node: Box::new(atom), min: 0, max: Some(1) })
            }
            Some('{') => {
                let save = self.pos;
                self.bump();
                match self.parse_bounded_repeat() {
                    Some((min, max)) => Ok(Node::Repeat { node: Box::new(atom), min, max }),
                    None => {
                        // Not a well-formed `{n,m}` — PatternSubset would
                        // never let a bare/malformed `{` through as
                        // anything but a literal brace either, so treat it
                        // as one, same as any other non-special character.
                        self.pos = save;
                        Ok(atom)
                    }
                }
            }
            _ => Ok(atom),
        }
    }

    /// Already past the `{`. `n`, `n,`, or `n,m`, each digit run non-empty
    /// for `n`/`m` — returns `None` (not a quantifier after all) rather
    /// than `Err` so the caller can fall back to a literal `{`.
    fn parse_bounded_repeat(&mut self) -> Option<(usize, Option<usize>)> {
        let min = self.parse_digits()?;
        match self.peek() {
            Some('}') => {
                self.bump();
                Some((min, Some(min)))
            }
            Some(',') => {
                self.bump();
                if self.peek() == Some('}') {
                    self.bump();
                    Some((min, None))
                } else {
                    let max = self.parse_digits()?;
                    if self.peek() == Some('}') {
                        self.bump();
                        Some((min, Some(max)))
                    } else {
                        None
                    }
                }
            }
            _ => None,
        }
    }

    fn parse_digits(&mut self) -> Option<usize> {
        let start = self.pos;
        while matches!(self.peek(), Some(c) if c.is_ascii_digit()) {
            self.bump();
        }
        if self.pos == start {
            return None;
        }
        self.chars[start..self.pos].iter().collect::<String>().parse().ok()
    }

    fn parse_atom(&mut self) -> Result<Node, ()> {
        match self.bump().ok_or(())? {
            '.' => Ok(Node::Any),
            '^' => Ok(Node::LineStart),
            '$' => Ok(Node::LineEnd),
            '(' => {
                let inner = self.parse_alt()?;
                if self.bump() != Some(')') {
                    return Err(());
                }
                Ok(Node::Group(inner))
            }
            '[' => self.parse_class(),
            '\\' => match self.bump().ok_or(())? {
                'A' => Ok(Node::StringStart),
                'z' | 'Z' => Ok(Node::StringEnd),
                c => Ok(Node::Literal(escape_char(c))), // an escaped metacharacter (`\.`, `\+`, `\\`, ...) or control char (`\t`, `\n`, `\r`) — the literal itself
            },
            c => Ok(Node::Literal(c)),
        }
    }

    /// `[...]`/`[^...]` — explicit ranges (`a-z`) and bare characters,
    /// `PatternSubset`'s own admitted dialect (no POSIX `[:digit:]`,
    /// already refused before this ever runs). A `]` as the very FIRST
    /// class member (`[]abc]`) is a literal `]`, the conventional regex
    /// reading — checked before the loop treats `]` as the closing
    /// bracket.
    fn parse_class(&mut self) -> Result<Node, ()> {
        let negate = if self.peek() == Some('^') {
            self.bump();
            true
        } else {
            false
        };
        let mut ranges = Vec::new();
        let mut first = true;
        loop {
            match self.peek() {
                Some(']') if !first => {
                    self.bump();
                    break;
                }
                Some(c) => {
                    self.bump();
                    let lo = if c == '\\' { escape_char(self.bump().ok_or(())?) } else { c };
                    if self.peek() == Some('-') && self.chars.get(self.pos + 1).is_some_and(|c| *c != ']') {
                        self.bump();
                        let hi_raw = self.bump().ok_or(())?;
                        let hi = if hi_raw == '\\' { escape_char(self.bump().ok_or(())?) } else { hi_raw };
                        ranges.push((lo, hi));
                    } else {
                        ranges.push((lo, lo));
                    }
                }
                None => return Err(()),
            }
            first = false;
        }
        Ok(Node::Class { negate, ranges })
    }
}

// Item #4, whole-project table-unification survey — `matches` above had
// zero unit-test coverage of its own before this, only the exact-wording
// contract of a handful of real corpus refusals via
// spec/rust_conformance_spec.rb (refusal_wording_pattern_mismatch.json,
// added alongside this test). This mirrors what
// spec/pattern_subset_spec.rb already does for Ruby's own `Regexp`
// against the SAME recorded contract (`spec/corpus/fixtures/
// patterns.json`) — one `#[test]` walking every row, not a hand-picked
// subset, so a change to `matches`'s own dialect can't silently drop
// coverage of a case nobody thought to re-add. `#[cfg(test)]` only —
// compiled out of every real build, touches none of the matcher's own
// hot-path lines above.
#[cfg(test)]
mod tests {
    use super::matches;
    use crate::kernel::Json;

    #[test]
    fn matches_every_row_of_the_recorded_pattern_contract() {
        let raw = include_str!("../../../spec/corpus/fixtures/patterns.json");
        let parsed = Json::parse(raw).expect("patterns.json must parse");
        let rows = parsed.as_array().expect("patterns.json must be a JSON array");
        assert!(!rows.is_empty(), "the recorded contract must not be empty");

        for row in rows {
            let pattern = row.get("pattern").and_then(Json::as_str).expect("row must carry a pattern");
            let input = row.get("input").and_then(Json::as_str).expect("row must carry an input");
            let expected = matches!(row.get("matches"), Some(Json::Bool(true)));

            assert_eq!(
                matches(pattern, input),
                expected,
                "pattern {pattern:?} against {input:?} should match={expected}"
            );
        }
    }
}
