//! Compiles a phrase's pattern text and matches a tokenized sentence against it.
//!
//! A pattern is literal words, `,` and `:`, `(a|an)` alternatives and `{slot:kind}` fill-ins. A
//! match must consume the whole sentence; a slot that can take several words tries the shortest
//! run first and lengthens it until the rest of the pattern fits.

use super::token::{Kind, Token};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SlotKind {
    /// One or more words: a noun phrase.
    Words,
    /// Exactly one word.
    Word,
    /// One quoted string.
    Text,
    /// One whole number.
    Int,
    /// Noun phrases joined by `and` or a comma.
    List,
    /// Everything left on the line, as written.
    Rest,
    /// A dotted field path such as `slug.value`.
    Path,
    /// A CamelCase event name.
    Event,
}

#[derive(Debug, Clone)]
pub enum Part {
    Lit(String),
    Alt(Vec<String>),
    Punct(char),
    Slot { name: String, kind: SlotKind },
}

#[derive(Debug, Clone)]
pub struct Pattern {
    pub parts: Vec<Part>,
    /// The pattern as the phrase row wrote it, for suggestions.
    pub source: String,
}

/// What one slot took from a sentence.
#[derive(Debug, Clone, Default)]
pub struct Capture {
    /// The text as written (a list's items joined with `, `).
    pub value: String,
    /// A list slot's items, each without its leading article.
    pub items: Vec<String>,
    /// The 1-based column of the first token the slot took, within the matched text.
    pub offset: usize,
}

impl Pattern {
    pub fn parse(text: &str) -> Result<Self, String> {
        let mut parts = Vec::new();
        let mut chars = text.chars().peekable();
        while let Some(&c) = chars.peek() {
            if c.is_whitespace() {
                chars.next();
            } else if c == ',' || c == ':' {
                chars.next();
                parts.push(Part::Punct(c));
            } else if c == '{' {
                chars.next();
                let body: String = chars.by_ref().take_while(|&inner| inner != '}').collect();
                parts.push(slot(&body)?);
            } else if c == '(' {
                chars.next();
                let body: String = chars.by_ref().take_while(|&inner| inner != ')').collect();
                parts.push(Part::Alt(body.split('|').map(str::to_lowercase).collect()));
            } else {
                let mut word = String::new();
                while let Some(&inner) = chars.peek() {
                    if inner.is_whitespace() || matches!(inner, ',' | ':' | '{' | '(') {
                        break;
                    }
                    word.push(inner);
                    chars.next();
                }
                parts.push(Part::Lit(word.to_lowercase()));
            }
        }
        if parts.is_empty() {
            return Err("an empty pattern".to_string());
        }
        Ok(Self {
            parts,
            source: text.to_string(),
        })
    }

    /// How many fixed words and marks the pattern holds: the more, the more specific.
    pub fn specificity(&self) -> usize {
        self.parts
            .iter()
            .filter(|part| !matches!(part, Part::Slot { .. }))
            .count()
    }

    /// The pattern as an author reads it in a suggestion: `Rule <description> holds when <condition>`.
    pub fn render(&self) -> String {
        let mut out = String::new();
        let mut chars = self.source.chars();
        while let Some(c) = chars.next() {
            if c == '{' {
                let body: String = chars.by_ref().take_while(|&inner| inner != '}').collect();
                let name = body.split(':').next().unwrap_or_default();
                out.push('<');
                out.push_str(name);
                out.push('>');
            } else {
                out.push(c);
            }
        }
        out
    }

    /// The fixed words of the pattern, lower case, in order.
    pub fn literals(&self) -> Vec<String> {
        self.parts
            .iter()
            .filter_map(|part| match part {
                Part::Lit(word) => Some(word.clone()),
                _ => None,
            })
            .collect()
    }
}

fn slot(body: &str) -> Result<Part, String> {
    let (name, kind) = body
        .split_once(':')
        .ok_or_else(|| format!("slot {{{body}}} names no kind"))?;
    let kind = match kind {
        "words" => SlotKind::Words,
        "word" => SlotKind::Word,
        "text" => SlotKind::Text,
        "int" => SlotKind::Int,
        "list" => SlotKind::List,
        "rest" => SlotKind::Rest,
        "path" => SlotKind::Path,
        "event" => SlotKind::Event,
        other => return Err(format!("slot {{{body}}} has the unknown kind '{other}'")),
    };
    Ok(Part::Slot {
        name: name.to_string(),
        kind,
    })
}

/// One successful match: each slot's capture, in the order the pattern names them.
#[derive(Debug, Clone, Default)]
pub struct Match {
    pub captures: Vec<(String, Capture)>,
}

impl Match {
    pub fn get(&self, name: &str) -> Option<&Capture> {
        self.captures
            .iter()
            .find(|(slot, _)| slot == name)
            .map(|(_, capture)| capture)
    }
}

/// Matches `tokens` (cut from `sentence`) against `pattern`. `furthest` is raised to the
/// highest token index any attempt reached, so a caller can say where a sentence stopped
/// fitting.
pub fn match_sentence(
    pattern: &Pattern,
    tokens: &[Token],
    sentence: &str,
    furthest: &mut usize,
) -> Option<Match> {
    let mut captures = Vec::new();
    if go(&pattern.parts, tokens, sentence, 0, &mut captures, furthest) {
        Some(Match { captures })
    } else {
        None
    }
}

fn go(
    parts: &[Part],
    tokens: &[Token],
    sentence: &str,
    at: usize,
    captures: &mut Vec<(String, Capture)>,
    furthest: &mut usize,
) -> bool {
    *furthest = (*furthest).max(at);
    let Some((part, rest)) = parts.split_first() else {
        return at == tokens.len();
    };
    match part {
        Part::Lit(word) => {
            let fits = tokens
                .get(at)
                .is_some_and(|t| t.is_word() && t.text.eq_ignore_ascii_case(word));
            fits && go(rest, tokens, sentence, at + 1, captures, furthest)
        }
        Part::Alt(words) => {
            let fits = tokens.get(at).is_some_and(|t| {
                t.is_word() && words.iter().any(|w| t.text.eq_ignore_ascii_case(w))
            });
            fits && go(rest, tokens, sentence, at + 1, captures, furthest)
        }
        Part::Punct(c) => {
            let fits = tokens.get(at).is_some_and(|t| t.kind == Kind::Punct(*c));
            fits && go(rest, tokens, sentence, at + 1, captures, furthest)
        }
        Part::Slot { name, kind } => {
            slot_go(name, *kind, rest, tokens, sentence, at, captures, furthest)
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn slot_go(
    name: &str,
    kind: SlotKind,
    rest: &[Part],
    tokens: &[Token],
    sentence: &str,
    at: usize,
    captures: &mut Vec<(String, Capture)>,
    furthest: &mut usize,
) -> bool {
    let mut try_take = |len: usize, capture: Capture, captures: &mut Vec<(String, Capture)>| {
        captures.push((name.to_string(), capture));
        if go(rest, tokens, sentence, at + len, captures, furthest) {
            return true;
        }
        captures.pop();
        false
    };
    let Some(first) = tokens.get(at) else {
        return false;
    };
    let offset = first.start;
    match kind {
        SlotKind::Text => {
            first.kind == Kind::Quoted
                && try_take(1, single(&first.text, offset), captures)
        }
        SlotKind::Word => first.is_word() && try_take(1, single(&first.text, offset), captures),
        SlotKind::Int => {
            first.is_word()
                && !first.text.is_empty()
                && first.text.chars().all(|c| c.is_ascii_digit())
                && try_take(1, single(&first.text, offset), captures)
        }
        SlotKind::Event => {
            first.is_word()
                && first.text.chars().next().is_some_and(|c| c.is_ascii_uppercase())
                && first.text.chars().all(|c| c.is_ascii_alphanumeric())
                && try_take(1, single(&first.text, offset), captures)
        }
        SlotKind::Path => {
            first.is_word() && is_path(&first.text) && try_take(1, single(&first.text, offset), captures)
        }
        SlotKind::Rest => {
            let Some(last) = tokens.last() else {
                return false;
            };
            let value = sentence[first.start..last.end].to_string();
            captures.push((name.to_string(), single(&value, offset)));
            if go(rest, tokens, sentence, tokens.len(), captures, furthest) {
                return true;
            }
            captures.pop();
            false
        }
        SlotKind::Words => {
            let mut len = 0;
            while tokens.get(at + len).is_some_and(Token::is_word) {
                len += 1;
                let value = tokens[at..at + len]
                    .iter()
                    .map(|t| t.text.as_str())
                    .collect::<Vec<_>>()
                    .join(" ");
                if try_take(len, single(&value, offset), captures) {
                    return true;
                }
            }
            false
        }
        SlotKind::List => {
            let mut len = 0;
            while tokens
                .get(at + len)
                .is_some_and(|t| t.is_word() || t.kind == Kind::Punct(','))
            {
                len += 1;
                let run = &tokens[at..at + len];
                let ends_on_word = run.last().is_some_and(Token::is_word);
                if !ends_on_word {
                    continue;
                }
                let items = list_items(run);
                if items.is_empty() {
                    continue;
                }
                let capture = Capture {
                    value: items.join(", "),
                    items,
                    offset,
                };
                if try_take(len, capture, captures) {
                    return true;
                }
            }
            false
        }
    }
}

fn single(value: &str, offset: usize) -> Capture {
    Capture {
        value: value.to_string(),
        items: Vec::new(),
        offset,
    }
}

fn is_path(text: &str) -> bool {
    text.split('.').all(|segment| {
        let mut chars = segment.chars();
        chars
            .next()
            .is_some_and(|c| c.is_ascii_lowercase() || c == '_')
            && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
    })
}

/// Splits a run of tokens at `and` and `,`, dropping each item's leading article.
fn list_items(run: &[Token]) -> Vec<String> {
    let mut items: Vec<Vec<&str>> = vec![Vec::new()];
    for token in run {
        let separator = token.kind == Kind::Punct(',') || token.text.eq_ignore_ascii_case("and");
        if separator {
            items.push(Vec::new());
        } else if let Some(current) = items.last_mut() {
            current.push(token.text.as_str());
        }
    }
    items
        .into_iter()
        .map(|mut words| {
            if words
                .first()
                .is_some_and(|w| matches!(w.to_lowercase().as_str(), "a" | "an" | "the"))
            {
                words.remove(0);
            }
            words.join(" ")
        })
        .filter(|item| !item.is_empty())
        .collect()
}

#[cfg(test)]
// reason: a `{slot:kind}` in a pattern string is the phrase syntax, not a format argument.
#[allow(clippy::literal_string_with_formatting_args)]
mod tests {
    use super::*;
    use crate::sentence::token::tokenize;

    fn run(pattern: &str, sentence: &str) -> Option<Match> {
        let pattern = Pattern::parse(pattern).ok()?;
        let tokens = tokenize(sentence).ok()?;
        match_sentence(&pattern, &tokens, sentence, &mut 0)
    }

    #[test]
    fn a_words_slot_stops_where_the_rest_of_the_pattern_fits() {
        let found = run("Domain: {name:words}", "Domain: Customer Orders");
        assert_eq!(found.and_then(|m| m.get("name").map(|c| c.value.clone())), Some("Customer Orders".to_string()));
    }

    #[test]
    fn a_list_drops_articles_and_splits_at_and() {
        let found = run("When {names:list} (is|are) given", "When a slug and a title are given");
        let items = found.and_then(|m| m.get("names").map(|c| c.items.clone()));
        assert_eq!(items, Some(vec!["slug".to_string(), "title".to_string()]));
    }

    #[test]
    fn a_sentence_with_words_left_over_does_not_match() {
        assert!(run("Goal: {goal:rest}", "Goal:").is_none());
        assert!(run("It has:", "It has: more").is_none());
    }

    #[test]
    fn a_rest_slot_keeps_the_text_as_written() {
        let found = run("Goal: {goal:rest}", "Goal: Change a page's title — its slug stays");
        assert_eq!(
            found.and_then(|m| m.get("goal").map(|c| c.value.clone())),
            Some("Change a page's title — its slug stays".to_string())
        );
    }

    #[test]
    fn a_pattern_renders_the_way_an_author_reads_it() {
        let pattern = Pattern::parse("Rule {description:text} holds when {condition:rest}");
        assert_eq!(
            pattern.map(|p| p.render()).ok(),
            Some("Rule <description> holds when <condition>".to_string())
        );
    }
}
