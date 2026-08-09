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
// already hold themselves to — see docs/decisions/0012).
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
    Start,
    End,
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
    let anchored_start = matches!(nodes.first(), Some(Node::Start));
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
        Node::Any => ti < text.len() && match_from(nodes, idx + 1, text, ti + 1, cont),
        Node::Class { negate, ranges } => {
            ti < text.len() && class_matches(*negate, ranges, text[ti]) && match_from(nodes, idx + 1, text, ti + 1, cont)
        }
        Node::Start => ti == 0 && match_from(nodes, idx + 1, text, ti, cont),
        Node::End => ti == text.len() && match_from(nodes, idx + 1, text, ti, cont),
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
            '^' => Ok(Node::Start),
            '$' => Ok(Node::End),
            '(' => {
                let inner = self.parse_alt()?;
                if self.bump() != Some(')') {
                    return Err(());
                }
                Ok(Node::Group(inner))
            }
            '[' => self.parse_class(),
            '\\' => match self.bump().ok_or(())? {
                'A' => Ok(Node::Start),
                'z' | 'Z' => Ok(Node::End),
                c => Ok(Node::Literal(c)), // an escaped metacharacter (`\.`, `\+`, `\\`, ...) — the literal itself
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
                    let lo = if c == '\\' { self.bump().ok_or(())? } else { c };
                    if self.peek() == Some('-') && self.chars.get(self.pos + 1).is_some_and(|c| *c != ']') {
                        self.bump();
                        let hi_raw = self.bump().ok_or(())?;
                        let hi = if hi_raw == '\\' { self.bump().ok_or(())? } else { hi_raw };
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
