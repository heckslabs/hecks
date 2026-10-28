//! The values an examples step gives a command, and how it names them.
//!
//! A step writes each value after the words that name it: `slug "about"`, `price 1200 cents`.
//! Every command argument is a tree of fields, and a step names its leaves:
//!
//! - A value object that wraps one field is transparent. `amount` names the cents of a price, and
//!   the wrapped field's own name may follow the number as a unit: `amount 1200 cents`.
//! - A value object that holds several fields is named by its parts. `price` and `size` name two
//!   parts of a pizza, and the whole name (`pizza price`) works too.
//! - A part's name drops a trailing unit it shares with the wrapped field, so `price_cents`, a
//!   price in cents, is `price`.
//!
//! A name that fits two parts is refused with the whole names that tell them apart, never
//! guessed.

use super::names::spoken;
use super::token::{tokenize, Kind, Token};
use super::{column, Parser};
use crate::diag::ParseResult;
use crate::ir;
use crate::render_ruby::string as ruby_string;

/// The deepest value object a step names through.
const DEPTH: usize = 4;

/// A value written in an example's arguments.
enum Literal {
    Text(String),
    Whole(String),
    Decimal(String),
}

/// One value a step can give: a leaf of one of the command's arguments.
struct Part {
    /// Field names from the argument down to the leaf.
    path: Vec<String>,
    /// The spoken names from the argument down, without a wrapped field.
    chain: Vec<String>,
    /// The spoken name of the field a one-field value wraps (`cents`), else empty.
    unit: String,
    /// The scalar type the leaf holds, when a step can write it.
    scalar: Option<String>,
    /// Whether the step must give it once its argument is given.
    required: bool,
    /// Whether its whole argument may be left out.
    group_optional: bool,
    /// The argument it belongs to, by position.
    top: usize,
}

impl Part {
    /// Every wording that names this part, shortest first.
    fn phrases(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for start in (0..self.chain.len()).rev() {
            let base = self.chain[start..].join(" ");
            out.extend(self.without_unit(&base));
            out.push(base.clone());
            if !self.unit.is_empty() && !has_tail(&base, &self.unit) {
                out.push(format!("{base} {}", self.unit));
            }
        }
        out.sort_by_key(|phrase| phrase.split(' ').count());
        let mut seen: Vec<String> = Vec::new();
        for phrase in out {
            if !seen.contains(&phrase) {
                seen.push(phrase);
            }
        }
        seen
    }

    /// `price cents` without the unit its wrapped field also names: `price`.
    fn without_unit(&self, base: &str) -> Option<String> {
        let tail = format!(" {}", self.unit);
        if self.unit.is_empty() {
            return None;
        }
        base.strip_suffix(&tail).map(str::to_string)
    }

    /// The whole name, from the argument down.
    fn whole(&self) -> String {
        self.chain.join(" ")
    }
}

/// Whether `base` is `unit` or ends in it as a word.
fn has_tail(base: &str, unit: &str) -> bool {
    base == unit || base.ends_with(&format!(" {unit}"))
}

/// Why a name picks no part.
enum Unresolved {
    /// No part is called that.
    Unknown,
    /// Several parts are; their whole names.
    Several(Vec<String>),
    /// It names a value that holds several parts; their wordings.
    Group(Vec<String>),
}

/// The values the command takes, as the leaves a step can name, in declaration order.
fn parts_of(aggregate: &ir::Aggregate, command: &ir::Command) -> Vec<Part> {
    let mut parts = Vec::new();
    for (top, attribute) in command.attributes.iter().enumerate() {
        let walk = Walk {
            aggregate,
            top,
            group_optional: omittable(attribute),
        };
        walk.descend(attribute, &Trail::default(), &mut parts);
    }
    parts
}

const fn omittable(attribute: &ir::Attribute) -> bool {
    attribute.optional || attribute.default.is_some()
}

/// What a walk down a value object has passed through.
#[derive(Default, Clone)]
struct Trail {
    path: Vec<String>,
    chain: Vec<String>,
    unit: String,
    required: bool,
    wrapped: bool,
}

struct Walk<'a> {
    aggregate: &'a ir::Aggregate,
    top: usize,
    group_optional: bool,
}

impl Walk<'_> {
    fn descend(&self, attribute: &ir::Attribute, above: &Trail, out: &mut Vec<Part>) {
        let first = above.path.is_empty();
        let mut trail = above.clone();
        trail.path.push(attribute.name.clone());
        trail.required = if first {
            true
        } else {
            above.required && !omittable(attribute)
        };
        if above.wrapped {
            trail.unit = spoken(&attribute.name);
        } else {
            trail.chain.push(spoken(&attribute.name));
        }
        if matches!(attribute.type_name.as_str(), "String" | "Integer" | "Float") {
            out.push(self.part(trail, Some(attribute.type_name.clone())));
            return;
        }
        let object = self
            .aggregate
            .value_objects
            .iter()
            .find(|v| v.name == attribute.type_name);
        match object {
            Some(object) if !object.attributes.is_empty() && trail.path.len() < DEPTH => {
                trail.wrapped = object.attributes.len() == 1;
                for child in &object.attributes {
                    self.descend(child, &trail, out);
                }
            }
            _ => out.push(self.part(trail, None)),
        }
    }

    fn part(&self, trail: Trail, scalar: Option<String>) -> Part {
        Part {
            path: trail.path,
            chain: trail.chain,
            unit: trail.unit,
            scalar,
            required: trail.required,
            group_optional: self.group_optional,
            top: self.top,
        }
    }
}

/// The part a name picks.
fn resolve(parts: &[Part], name: &str) -> Result<usize, Unresolved> {
    let hits: Vec<usize> = (0..parts.len())
        .filter(|&i| parts[i].phrases().iter().any(|p| p == name))
        .collect();
    match hits.as_slice() {
        [only] => Ok(*only),
        [] => Err(group_of(parts, name)),
        _ => Err(Unresolved::Several(
            hits.iter().map(|&i| parts[i].whole()).collect(),
        )),
    }
}

/// A name that is no part but starts the whole name of several: the value they sit in.
fn group_of(parts: &[Part], name: &str) -> Unresolved {
    let inside: Vec<usize> = (0..parts.len())
        .filter(|&i| {
            let chain = &parts[i].chain;
            (1..chain.len()).any(|end| chain[..end].join(" ") == name)
        })
        .collect();
    if inside.is_empty() {
        Unresolved::Unknown
    } else {
        Unresolved::Group(inside.iter().map(|&i| display(parts, i)).collect())
    }
}

/// The shortest wording that names only part `index`.
fn display(parts: &[Part], index: usize) -> String {
    let mine = parts[index].phrases();
    mine.iter()
        .find(|phrase| {
            parts
                .iter()
                .filter(|other| other.phrases().contains(phrase))
                .count()
                == 1
        })
        .cloned()
        .unwrap_or_else(|| parts[index].whole())
}

/// Reads `slug "about" and title "About us"`, or `price 1200 cents and size "large"`, into the
/// argument values of `command`, each as the Ruby text the behaviors file passes.
pub(super) fn read(
    parser: &Parser<'_>,
    aggregate: &ir::Aggregate,
    command: &ir::Command,
    text: &str,
    line: usize,
    base_col: usize,
) -> ParseResult<Vec<(String, String)>> {
    let Ok(tokens) = tokenize(text) else {
        return Err(parser.error(line, base_col, "a quote is not closed"));
    };
    let reader = Reader {
        parser,
        command,
        parts: parts_of(aggregate, command),
        text,
        line,
        base_col,
    };
    let given = reader.given(&tokens)?;
    reader.complete(&given)?;
    Ok(render(&reader.parts, &given))
}

struct Reader<'a, 'p> {
    parser: &'a Parser<'p>,
    command: &'a ir::Command,
    parts: Vec<Part>,
    text: &'a str,
    line: usize,
    base_col: usize,
}

impl Reader<'_, '_> {
    fn fault(&self, col: usize, message: impl Into<String>) -> crate::diag::Diagnostic {
        self.parser.error(self.line, col, message)
    }

    /// The values the step gives, as a part and the Ruby text of its value.
    fn given(&self, tokens: &[Token]) -> ParseResult<Vec<(usize, String)>> {
        let mut given: Vec<(usize, String)> = Vec::new();
        let mut words: Vec<&str> = Vec::new();
        let mut next = 0;
        while next < tokens.len() {
            let token = &tokens[next];
            next += 1;
            let col = column(self.base_col, self.text, token.start);
            let Some(literal) = self.literal(token, &mut words, col)? else {
                continue;
            };
            let name = self.name_of(&mut words, col)?;
            let index = self.pick(&name, col)?;
            next += unit_words(&self.parts[index].unit, &tokens[next..]);
            if given.iter().any(|(seen, _)| *seen == index) {
                let again = display(&self.parts, index);
                return Err(self.fault(col, format!("{again} is given twice")));
            }
            given.push((index, self.text_of(index, &literal, col)?));
        }
        words.first().map_or(Ok(given), |word| {
            Err(self.fault(self.base_col, format!("'{word}' has no value after it")))
        })
    }

    /// The value a token is, or `None` for a word of a name (kept in `words`) or a separator.
    fn literal<'t>(
        &self,
        token: &'t Token,
        words: &mut Vec<&'t str>,
        col: usize,
    ) -> ParseResult<Option<Literal>> {
        Ok(match token.kind {
            Kind::Quoted => Some(Literal::Text(token.text.clone())),
            Kind::Word if is_whole(&token.text) => Some(Literal::Whole(token.text.clone())),
            Kind::Word if is_decimal(&token.text) => Some(Literal::Decimal(token.text.clone())),
            Kind::Word => {
                if !(token.text.eq_ignore_ascii_case("and") && words.is_empty()) {
                    words.push(&token.text);
                }
                None
            }
            Kind::Punct(',') => None,
            Kind::Punct(_) => {
                return Err(self.fault(col, "unexpected punctuation in the values"));
            }
        })
    }

    /// The name the words before a value spell, without a leading article.
    fn name_of(&self, words: &mut Vec<&str>, col: usize) -> ParseResult<String> {
        let mut name = std::mem::take(words);
        if name
            .first()
            .is_some_and(|w| matches!(w.to_lowercase().as_str(), "a" | "an" | "the"))
        {
            name.remove(0);
        }
        if name.is_empty() {
            return Err(self.fault(col, "this value has no field name before it"));
        }
        Ok(name.join(" ").to_lowercase())
    }

    fn pick(&self, name: &str, col: usize) -> ParseResult<usize> {
        resolve(&self.parts, name).map_err(|miss| {
            let command = spoken(&self.command.name);
            match miss {
                Unresolved::Unknown => self.fault(
                    col,
                    format!("{command} takes no '{name}'. It takes: {}", self.takes()),
                ),
                Unresolved::Several(options) => self.fault(
                    col,
                    format!(
                        "'{name}' could be any of: {}. Say which",
                        options.join(", ")
                    ),
                ),
                Unresolved::Group(parts) => self.fault(
                    col,
                    format!(
                        "{name} holds several values; give each by name: {}",
                        parts.join(", ")
                    ),
                ),
            }
        })
    }

    fn takes(&self) -> String {
        if self.parts.is_empty() {
            return "nothing".to_string();
        }
        let names: Vec<String> = (0..self.parts.len())
            .map(|i| display(&self.parts, i))
            .collect();
        names.join(", ")
    }

    /// A literal as the Ruby text of the part it is given to.
    fn text_of(&self, index: usize, literal: &Literal, col: usize) -> ParseResult<String> {
        let part = &self.parts[index];
        let name = display(&self.parts, index);
        let Some(scalar) = &part.scalar else {
            return Err(self.fault(col, format!("I don't know how to write a value for {name}")));
        };
        match (scalar.as_str(), literal) {
            ("String", Literal::Text(text)) => Ok(ruby_string(text)),
            ("Integer", Literal::Whole(digits))
            | ("Float", Literal::Whole(digits) | Literal::Decimal(digits)) => Ok(digits.clone()),
            (expected, _) => {
                let wanted = match expected {
                    "String" => "text in quotes",
                    "Integer" => "a whole number",
                    _ => "a number",
                };
                Err(self.fault(col, format!("{name} is {wanted}")))
            }
        }
    }

    /// Refuses the step when a value it must give is missing.
    fn complete(&self, given: &[(usize, String)]) -> ParseResult<()> {
        let missing = (0..self.parts.len()).find(|&i| {
            let part = &self.parts[i];
            let engaged = given
                .iter()
                .any(|(seen, _)| self.parts[*seen].top == part.top);
            let supplied = given.iter().any(|(seen, _)| *seen == i);
            part.required && !supplied && (engaged || !part.group_optional)
        });
        missing.map_or(Ok(()), |i| {
            let needs = format!(
                "{} needs a {}",
                spoken(&self.command.name),
                display(&self.parts, i)
            );
            Err(self.fault(self.base_col, needs))
        })
    }
}

/// How many of `tokens` spell `unit` right after a number (`cents` after `1200`).
fn unit_words(unit: &str, tokens: &[Token]) -> usize {
    let words: Vec<&str> = unit.split(' ').filter(|w| !w.is_empty()).collect();
    let spelled = !words.is_empty()
        && tokens.len() >= words.len()
        && words.iter().zip(tokens).all(|(word, token)| {
            matches!(token.kind, Kind::Word) && token.text.eq_ignore_ascii_case(word)
        });
    if spelled {
        words.len()
    } else {
        0
    }
}

/// The given values as `(argument, Ruby text)`, an argument with several parts as one hash.
fn render(parts: &[Part], given: &[(usize, String)]) -> Vec<(String, String)> {
    let mut tops: Vec<usize> = Vec::new();
    for (index, _) in given {
        let top = parts[*index].top;
        if !tops.contains(&top) {
            tops.push(top);
        }
    }
    tops.into_iter()
        .map(|top| {
            let mut mine: Vec<&(usize, String)> = given
                .iter()
                .filter(|(index, _)| parts[*index].top == top)
                .collect();
            mine.sort_by_key(|(index, _)| *index);
            let entries: Vec<(&[String], &str)> = mine
                .iter()
                .map(|(index, text)| (parts[*index].path.as_slice(), text.as_str()))
                .collect();
            (entries[0].0[0].clone(), nested(&entries, 1))
        })
        .collect()
}

/// The Ruby text for the entries below `depth` fields of their paths.
fn nested(entries: &[(&[String], &str)], depth: usize) -> String {
    if let [(path, text)] = entries {
        if path.len() <= depth {
            return (*text).to_string();
        }
    }
    let mut keys: Vec<&String> = Vec::new();
    for (path, _) in entries {
        if !keys.contains(&&path[depth]) {
            keys.push(&path[depth]);
        }
    }
    let fields: Vec<String> = keys
        .into_iter()
        .map(|key| {
            let below: Vec<(&[String], &str)> = entries
                .iter()
                .filter(|(path, _)| &path[depth] == key)
                .copied()
                .collect();
            format!("{key}: {}", nested(&below, depth + 1))
        })
        .collect();
    format!("{{ {} }}", fields.join(", "))
}

fn is_whole(text: &str) -> bool {
    !text.is_empty() && text.chars().all(|c| c.is_ascii_digit())
}

fn is_decimal(text: &str) -> bool {
    text.split_once('.')
        .is_some_and(|(whole, fraction)| is_whole(whole) && is_whole(fraction))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_decimal_and_a_whole_number_are_told_apart() {
        assert!(is_whole("1700000000") && !is_whole("1.5") && !is_whole(""));
        assert!(is_decimal("1.5") && !is_decimal("15") && !is_decimal("1."));
    }
}
