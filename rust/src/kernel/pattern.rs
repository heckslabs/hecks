// Regex matcher for the dialect `Hecks::Bluebook::PatternSubset` admits (no backreferences,
// lookaround or Perl classes). Unanchored search, like Ruby's `Regexp#match?`.

#[derive(Debug, Clone)]
enum Node {
    Literal(char),
    Any,
    Class { negate: bool, ranges: Vec<(char, char)> },
    // `^`/`$` match at line boundaries, as in Ruby.
    LineStart,
    LineEnd,
    // `\A`/`\z`/`\Z` match only at the whole-string boundaries.
    StringStart,
    StringEnd,
    Group(Vec<Node>),
    Alt(Vec<Vec<Node>>),
    Repeat { node: Box<Node>, min: usize, max: Option<usize> },
}

/// `true` if `text` contains a match for `pattern`; a pattern that fails to parse is `false`.
pub fn matches(pattern: &str, text: &str) -> bool {
    let Ok(nodes) = parse(pattern) else { return false };
    let chars: Vec<char> = text.chars().collect();
    // Only `\A` may skip to position 0; `^` can still match after a later `\n`.
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
        // Like Ruby without `/m`, `.` does not match `\n`.
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

// Greedy: try one more repetition first, then fall back to stopping at the current count.
// The `ti2 == ti` check stops a zero-width repetition from looping forever.
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

// `\t`, `\n` and `\r` become control characters; any other escape is the literal itself.
fn escape_char(c: char) -> char {
    match c {
        't' => '\t',
        'n' => '\n',
        'r' => '\r',
        other => other,
    }
}

// Recursive descent: `alternation > concat > repeat > atom`.
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

    /// `alternation := concat ('|' concat)*`
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

    /// `concat := repeat*`, ending at `|` or `)`.
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
                        // Not a well-formed `{n,m}`: read the brace as a literal.
                        self.pos = save;
                        Ok(atom)
                    }
                }
            }
            _ => Ok(atom),
        }
    }

    /// Past the `{`. Returns `None` (not a quantifier) so the caller can read a literal `{`.
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
                // an escaped metacharacter or control char: the literal itself
                c => Ok(Node::Literal(escape_char(c))),
            },
            c => Ok(Node::Literal(c)),
        }
    }

    /// `[...]`/`[^...]` with ranges. A leading `]` is a literal member (`[]abc]`).
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

// Walks every row of the recorded pattern contract so dialect changes cannot drop a case.
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
