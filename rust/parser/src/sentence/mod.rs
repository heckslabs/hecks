//! The sentence front end: reads a `.bluebook` written as plain business sentences and lowers
//! it to the same IR the Ruby-shaped grammar produces.
//!
//! What an author may say is the phrase table (`phrases.rs`, generated from the Sentence
//! bluebook); this module holds only what each phrase means. A sentence that matches no phrase is
//! refused with the column it stopped fitting at and the nearest phrases, never skipped.

mod changes;
/// The sentences legal at a cursor, for editors.
pub mod complete;
mod entity;
/// An examples file compiled to the `.behaviors` text that runs it.
pub mod examples;
/// A parsed bluebook written back out as canonical sentences.
pub mod format;
mod lower;
mod names;
mod options;
mod pattern;
mod process;
mod queries;
mod report;
mod token;

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::phrases::{PhraseRow, PHRASES};
use pattern::{match_sentence, Capture, Match, Pattern};
use token::{tokenize, Token};

/// Whether a source file is written as sentences: its first line that is not blank or a
/// comment opens with `Domain:`.
pub fn is_sentence_form(source: &str) -> bool {
    source
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with('#'))
        .is_some_and(|line| line.starts_with("Domain:"))
}

/// Parses every sentence-form file of one bluebook and merges their aggregates.
pub fn parse_bluebook(declaration_name: &str, files: &[(String, String)]) -> ParseResult<ir::Bluebook> {
    let grammar = Grammar::load()?;
    let mut merged: Option<ir::Bluebook> = None;
    for (path, source) in files {
        let parsed = Parser::new(path, &grammar, read_lines(path, source)?).file()?;
        if parsed.name != declaration_name {
            return Err(Diagnostic::new(
                path,
                1,
                format!(
                    "--bluebook {declaration_name} was requested, but this file declares '{}'",
                    parsed.name
                ),
            ));
        }
        match merged.as_mut() {
            None => merged = Some(parsed),
            Some(declaration) => {
                declaration.aggregates.extend(parsed.aggregates);
                declaration.policies.extend(parsed.policies);
                declaration.read_models.extend(parsed.read_models);
                declaration.process_managers.extend(parsed.process_managers);
                if declaration.vision.is_none() {
                    declaration.vision = parsed.vision;
                }
            }
        }
    }
    let mut declaration = merged.ok_or_else(|| {
        Diagnostic::new(
            "<none>",
            0,
            "hecks-parse bluebook requires at least one file",
        )
    })?;
    let first = files.first().map_or("<none>", |(path, _)| path.as_str());
    crate::build::query_inference::apply(first, &mut declaration)?;
    Ok(declaration)
}

/// One admitted phrase with its pattern compiled.
struct Phrase {
    row: &'static PhraseRow,
    pattern: Pattern,
}

struct Grammar {
    phrases: Vec<Phrase>,
}

impl Grammar {
    fn load() -> ParseResult<Self> {
        let mut phrases = Vec::new();
        for row in PHRASES.iter().filter(|row| row.live()) {
            let pattern = Pattern::parse(row.pattern).map_err(|reason| {
                Diagnostic::new(
                    "<phrases>",
                    0,
                    format!("phrase '{}' does not compile: {reason}", row.id),
                )
            })?;
            phrases.push(Phrase { row, pattern });
        }
        Ok(Self { phrases })
    }

    fn in_context(&self, context: &str) -> Vec<&Phrase> {
        self.phrases
            .iter()
            .filter(|phrase| phrase.row.context == context)
            .collect()
    }
}

/// One non-blank, non-comment line of the file.
#[derive(Clone)]
struct Line {
    number: usize,
    indent: usize,
    text: String,
}

fn read_lines(file: &str, source: &str) -> ParseResult<Vec<Line>> {
    let mut lines = Vec::new();
    for (index, raw) in source.lines().enumerate() {
        let text = raw.trim_end();
        let body = text.trim_start();
        if body.is_empty() || body.starts_with('#') {
            continue;
        }
        let leading = &text[..text.len() - body.len()];
        if leading.contains('\t') {
            return Err(Diagnostic::new(
                file,
                index + 1,
                "this line is indented with a tab; indent with spaces",
            )
            .with_column(1));
        }
        lines.push(Line {
            number: index + 1,
            indent: leading.len(),
            text: body.to_string(),
        });
    }
    Ok(lines)
}

/// A phrase that matched a line, with what its slots took.
struct Matched {
    id: &'static str,
    found: Match,
    line: usize,
    indent: usize,
    /// The column the matched text starts at.
    base_col: usize,
    text: String,
}

impl Matched {
    fn capture(&self, name: &str) -> Capture {
        self.found.get(name).cloned().unwrap_or_default()
    }

    fn text_of(&self, name: &str) -> String {
        self.capture(name).value
    }

    /// The column of a capture's first character.
    fn col_of(&self, name: &str) -> usize {
        column(self.base_col, &self.text, self.capture(name).offset)
    }
}

enum Step {
    Phrase(Matched),
    Prose { text: String },
}

/// Which lines still belong to the block being read, and how far in they stand.
struct Scope {
    parent: Option<usize>,
    child: Option<usize>,
    first: bool,
}

impl Scope {
    const fn top() -> Self {
        Self {
            parent: None,
            child: Some(0),
            first: true,
        }
    }

    const fn inside(parent_indent: usize) -> Self {
        Self {
            parent: Some(parent_indent),
            child: None,
            first: true,
        }
    }
}

/// Why a sentence matched nothing: where it stopped fitting and what would have fitted.
struct Unmatched {
    column: usize,
    suggestions: Vec<String>,
}

/// A cursor over one sentence file's lines, lowering them block by block.
pub(super) struct Parser<'a> {
    file: &'a str,
    grammar: &'a Grammar,
    lines: Vec<Line>,
    pos: usize,
    /// Every value object the file declares, in any aggregate, for a type that names another's.
    types: Vec<String>,
    /// The value objects of the aggregates an entity being read stands inside.
    outer: Vec<ir::ValueObject>,
}

/// The 1-based column of byte `offset` in `text`, which itself starts at column `base`.
fn column(base: usize, text: &str, offset: usize) -> usize {
    base + text.get(..offset).map_or(0, |head| head.chars().count())
}

fn context_label(context: &str) -> &'static str {
    match context {
        "File" => "the top of a file",
        "Domain" => "a domain",
        "Vision" => "a domain's description",
        "Aggregate" => "an aggregate",
        "Has" => "an 'It has:' list",
        "ValueObject" => "a value object",
        "Lifecycle" => "a lifecycle",
        "Command" => "a command",
        "Policy" => "a policy",
        "Query" => "a query",
        "Report" => "a report",
        "Process" => "a process",
        "Handler" => "a step of a process",
        "Condition" => "a condition",
        "ExamplesFile" => "the top of an examples file",
        "Examples" => "an examples file",
        "Background" => "a background",
        "Example" => "an example",
        "Step" => "a step",
        "Outcome" => "an outcome",
        _ => "this place",
    }
}

impl<'a> Parser<'a> {
    const fn new(file: &'a str, grammar: &'a Grammar, lines: Vec<Line>) -> Self {
        Self {
            file,
            grammar,
            lines,
            pos: 0,
            types: Vec::new(),
            outer: Vec::new(),
        }
    }

    /// The names of the value objects and entities any aggregate of the file declares.
    fn declared_types(&self) -> Vec<String> {
        self.lines
            .iter()
            .filter_map(|line| self.match_text("Aggregate", &line.text, 1).ok())
            .filter(|(phrase, _)| {
                matches!(
                    phrase.row.id,
                    "value_object" | "value_object_with" | "closed_set" | "value_fields" | "entity"
                )
            })
            .map(|(_, found)| {
                names::camel(
                    found
                        .get("name")
                        .map_or("", |capture| capture.value.as_str()),
                )
            })
            .collect()
    }

    /// A refusal pointing at `col` of `line`.
    pub(super) fn error(&self, line: usize, col: usize, message: impl Into<String>) -> Diagnostic {
        Diagnostic::new(self.file, line, message).with_column(col)
    }

    /// Reads the next line of the block `scope` describes, or `None` where the block ends.
    fn step(
        &mut self,
        scope: &mut Scope,
        context: &str,
        allow_prose: bool,
    ) -> ParseResult<Option<Step>> {
        let Some(line) = self.lines.get(self.pos).cloned() else {
            return Ok(None);
        };
        if scope.parent.is_some_and(|parent| line.indent <= parent) {
            return Ok(None);
        }
        match scope.child {
            None => scope.child = Some(line.indent),
            Some(expected) if expected != line.indent => {
                let message = if line.indent > expected {
                    "this line is indented further than the lines above it"
                } else {
                    "this line is indented less than the lines above it"
                };
                return Err(self.error(line.number, 1, message));
            }
            Some(_) => {}
        }
        let first = std::mem::replace(&mut scope.first, false);
        let found = self.match_text(context, &line.text, line.indent + 1);
        match found {
            Ok((phrase, found)) => {
                self.pos += 1;
                Ok(Some(Step::Phrase(Matched {
                    id: phrase.row.id,
                    found,
                    line: line.number,
                    indent: line.indent,
                    base_col: line.indent + 1,
                    text: line.text,
                })))
            }
            Err(unmatched) => {
                let opens_a_block = self
                    .lines
                    .get(self.pos + 1)
                    .is_some_and(|next| next.indent > line.indent);
                if first && allow_prose && !opens_a_block && !line.text.ends_with(':') {
                    self.pos += 1;
                    return Ok(Some(Step::Prose { text: line.text }));
                }
                Err(self.unmatched_error(context, &line, &unmatched))
            }
        }
    }

    fn unmatched_error(&self, context: &str, line: &Line, unmatched: &Unmatched) -> Diagnostic {
        self.error(
            line.number,
            unmatched.column,
            format!(
                "this is not a sentence I know in {}: \"{}\"",
                context_label(context),
                line.text
            ),
        )
        .with_expected(unmatched.suggestions.clone())
    }

    /// Finds the one phrase of `context` that fits `text`: the most specific when several do.
    fn match_text(
        &self,
        context: &str,
        text: &str,
        base_col: usize,
    ) -> Result<(&'a Phrase, Match), Unmatched> {
        // A sentence may end in a full stop; it is punctuation, not part of the last word.
        let attempts: Vec<&str> = text
            .strip_suffix('.')
            .map_or_else(|| vec![text], |trimmed| vec![trimmed, text]);
        let grammar: &'a Grammar = self.grammar;
        let mut best: Option<(&'a Phrase, Match)> = None;
        let mut scored: Vec<(usize, String)> = Vec::new();
        let mut reach = 0;
        let mut reach_tokens: Vec<Token> = Vec::new();
        for attempt in attempts {
            let Ok(tokens) = tokenize(attempt) else {
                return Err(Unmatched {
                    column: base_col,
                    suggestions: vec!["a quote that is closed".to_string()],
                });
            };
            for phrase in grammar.in_context(context) {
                let mut furthest = 0;
                if let Some(found) =
                    match_sentence(&phrase.pattern, &tokens, attempt, &mut furthest)
                {
                    let better = best.as_ref().is_none_or(|(held, _)| {
                        phrase.pattern.specificity() > held.pattern.specificity()
                    });
                    if better {
                        best = Some((phrase, found));
                    }
                }
                scored.push((
                    furthest * 100 + shared_words(&phrase.pattern, &tokens),
                    phrase.pattern.render(),
                ));
                if furthest > reach || reach_tokens.is_empty() {
                    reach = furthest;
                    reach_tokens.clone_from(&tokens);
                }
            }
            if best.is_some() {
                break;
            }
        }
        if let Some(matched) = best {
            return Ok(matched);
        }
        scored.sort_by_key(|(score, _)| std::cmp::Reverse(*score));
        scored.dedup_by(|a, b| a.1 == b.1);
        let column = reach_tokens.get(reach).map_or_else(
            || column(base_col, text, text.len()),
            |t| column(base_col, text, t.start),
        );
        Err(Unmatched {
            column,
            suggestions: scored.into_iter().take(3).map(|(_, shown)| shown).collect(),
        })
    }
}

/// How many of a pattern's fixed words appear, in order, among the sentence's words.
fn shared_words(pattern: &Pattern, tokens: &[Token]) -> usize {
    let words: Vec<String> = tokens
        .iter()
        .filter(|t| t.is_word())
        .map(|t| t.text.to_lowercase())
        .collect();
    let mut at = 0;
    let mut shared = 0;
    for literal in pattern.literals() {
        if let Some(found) = words.iter().skip(at).position(|w| *w == literal) {
            at += found + 1;
            shared += 1;
        }
    }
    shared
}
