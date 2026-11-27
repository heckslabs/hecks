//! The closed form: every `.bluebook`, `.hecksagon` and `.world` file is checked here, line by
//! line, before the gem builds anything from it, and the gem loads only the text this returns.
//!
//! The walk is driven by the keyword table. Each line is one word call or `end`; the word must be
//! one the enclosing construct admits, its body must be the kind the table declares, and its
//! arguments must be literals ([`args`]). A `source` body is one rule expression
//! ([`predicate`]). Two places are open by design and checked by shape instead: a `.hecksagon`
//! bind verb (`persisted_by "Heki"`) and a `.world` binding verb with its settings block. An open
//! word may not be a method Ruby defines on every object ([`denied`]), since Ruby would run that
//! method before it ever reached the builder.
//!
//! The text returned keeps the file's line count: each checked statement stays on its own line,
//! with comments removed and continued lines joined onto their first, so a line number the gem
//! reports still points into the file the author wrote. Nothing reaches the output that the
//! check did not read and admit.

pub mod args;
pub mod denied;
pub mod predicate;
pub mod scan;

use crate::diag::{Diagnostic, ParseResult};
use crate::keywords::KeywordRow;
use crate::lex::{self, Call, LineShape, Opener, SourceLine};
use crate::parse;
use crate::render_ruby;

/// What the lines inside a block are read against.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Frame {
    /// A construct of the keyword table, such as `Aggregate` or `Hecksagon`.
    Closed(&'static str),
    /// A `.world` binding's settings block: open keys, literal values.
    Settings,
}

/// How a block ends.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Closer {
    End,
    Brace,
}

/// The only receiver a file's top line may name.
const FILE_RECEIVER: &str = "Hecks.";

/// Admits one file, in either form, and returns the text the gem may load in its place.
///
/// A bluebook written as sentences (its first line `Domain: <name>`) is read by the sentence
/// parser and rendered as declarations, and the rendering is checked like any other file, so the
/// gem never evaluates text this module did not admit.
pub fn admit(file: &str, source: &str) -> ParseResult<String> {
    let Some(name) = sentence_domain(source) else {
        return check(file, source);
    };
    let loaded = vec![(file.to_string(), source.to_string())];
    let bluebook = parse::declaration::parse_bluebook(&name, &loaded)?;
    let rendered =
        render_ruby::ruby_form(&bluebook).map_err(|why| Diagnostic::new(file, 1, why))?;
    check(file, &rendered)
}

/// The bluebook name a sentence-form file declares, each word of its `Domain:` line capitalised
/// and joined as `Hecks::SentenceForm.capitalised` reads it; `None` for the declaration form.
fn sentence_domain(source: &str) -> Option<String> {
    let first = source
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with('#'))?;
    let words = first.strip_prefix("Domain:")?;
    let name: String = words
        .split_whitespace()
        .map(|word| {
            let mut chars = word.chars();
            chars.next().map_or_else(String::new, |head| {
                head.to_uppercase().chain(chars).collect()
            })
        })
        .collect();
    Some(name)
}

/// Checks one declaration-form file and returns the text the gem may load in its place.
pub fn check(file: &str, source: &str) -> ParseResult<String> {
    let joined = lex::join_continuations(source);
    let rows: Vec<&str> = joined.split('\n').collect();
    let mut walker = Walker {
        file,
        rows: &rows,
        out: vec![String::new(); rows.len()],
        pos: 0,
    };
    walker.file_body()?;
    let mut text = walker.out.join("\n");
    if source.ends_with('\n') {
        text.push('\n');
    }
    Ok(text)
}

struct Walker<'a> {
    file: &'a str,
    rows: &'a [&'a str],
    out: Vec<String>,
    pos: usize,
}

impl<'a> Walker<'a> {
    /// The next row that holds a statement, as a numbered line, moving past it.
    fn next_row(&mut self) -> Option<(usize, SourceLine<'a>)> {
        while self.pos < self.rows.len() {
            let idx = self.pos;
            self.pos += 1;
            let text = self.rows[idx].trim();
            if !text.is_empty() {
                return Some((
                    idx,
                    SourceLine {
                        number: idx + 1,
                        text,
                    },
                ));
            }
        }
        None
    }

    fn keep(&mut self, idx: usize, text: &str) {
        self.out[idx] = text.to_string();
    }

    fn refuse(&self, line: usize, message: impl Into<String>) -> Diagnostic {
        Diagnostic::new(self.file, line, message)
    }

    /// The top of a file: one or more `Hecks.<word> … do … end` declarations.
    fn file_body(&mut self) -> ParseResult<()> {
        let mut declared = false;
        while let Some((idx, line)) = self.next_row() {
            let Some(rest) = line.text.strip_prefix(FILE_RECEIVER) else {
                return Err(self.refuse(
                    line.number,
                    format!(
                        "'{}' sits outside any declaration — a file holds only `Hecks.<word> … \
                         do … end` declarations",
                        line.text
                    ),
                ));
            };
            let call = self.call(&SourceLine {
                number: line.number,
                text: rest,
            })?;
            let row = self.closed_row(&call, "File", line.number)?;
            self.check_args(&call, line, Frame::Closed("File"))?;
            self.keep(idx, line.text);
            self.body_of(row, &call, line)?;
            declared = true;
        }
        if declared {
            Ok(())
        } else {
            Err(self.refuse(1, "the file declares nothing"))
        }
    }

    /// Reads one line as a word call; `end` and nested `Hecks.` lines are refused here.
    fn call(&self, line: &SourceLine<'_>) -> ParseResult<Call> {
        if line.text.starts_with(FILE_RECEIVER) {
            return Err(self.refuse(
                line.number,
                "`Hecks.` names the file's own declaration and is only legal on its top line",
            ));
        }
        match lex::classify(self.file, line)? {
            LineShape::Call(call) => Ok(call),
            LineShape::End => Err(self.refuse(line.number, "`end` closes nothing here")),
        }
    }

    /// The table row for a word the construct admits, matched to its opener.
    fn closed_row(
        &self,
        call: &Call,
        context: &'static str,
        line: usize,
    ) -> ParseResult<&'static KeywordRow> {
        let candidates = parse::word_gate(self.file, &call.word, context, line)?;
        // A rule word written without a body names a rule declared elsewhere
        // (`given "positive"`), so it reads like any other bodiless word.
        if call.opener == Opener::None {
            if let Some(rule) = candidates.iter().find(|row| row.body == "source") {
                return Ok(rule);
            }
        }
        parse::body_gate(self.file, &candidates, &call.opener, line, &call.word)
    }

    fn check_args(&self, call: &Call, line: SourceLine<'_>, frame: Frame) -> ParseResult<()> {
        args::check(&call.args, args_mode(frame, &call.word)).map_err(|refusal| {
            let column = line.text.find(call.args.as_str()).unwrap_or(0) + refusal.at + 1;
            self.refuse(
                line.number,
                format!("'{}' takes literals only: {}", call.word, refusal.why),
            )
            .with_column(column)
        })
    }

    /// Walks whatever block a closed word opens, by the body kind its row declares.
    fn body_of(&mut self, row: &KeywordRow, call: &Call, line: SourceLine<'_>) -> ParseResult<()> {
        match row.body {
            "none" => Ok(()),
            "source" => self.source_body(call, line),
            _ => {
                let inner = Frame::Closed(row.inner);
                self.block(inner, call, line)
            }
        }
    }

    /// A `keywords`, `rows` or settings block: one line each, or a one-line `{ a; b }`.
    fn block(&mut self, frame: Frame, call: &Call, line: SourceLine<'_>) -> ParseResult<()> {
        match &call.opener {
            Opener::None => Ok(()),
            Opener::DoBlock {
                params: Some(params),
            } => Err(self.refuse(
                line.number,
                format!(
                    "'{}' opens a block with parameters |{params}|; a declaration block takes none",
                    call.word
                ),
            )),
            Opener::DoBlock { params: None } => self.lines_until(frame, Closer::End),
            Opener::BraceBlock { body } if body.starts_with('{') => {
                self.lines_until(frame, Closer::Brace)
            }
            Opener::BraceBlock { body } => {
                for statement in parse::brace_body_statements(body) {
                    if statement == "end" {
                        continue;
                    }
                    let inner = SourceLine {
                        number: line.number,
                        text: &statement,
                    };
                    self.statement_in_line(frame, inner)?;
                }
                Ok(())
            }
        }
    }

    fn lines_until(&mut self, frame: Frame, closer: Closer) -> ParseResult<()> {
        loop {
            let Some((idx, line)) = self.next_row() else {
                let last = self.rows.len();
                return Err(self.refuse(last, "unexpected end of file — a block is never closed"));
            };
            let closes = match closer {
                Closer::End => line.text == "end",
                Closer::Brace => line.text == "}",
            };
            if closes {
                self.keep(idx, line.text);
                return Ok(());
            }
            self.keep(idx, line.text);
            self.statement(frame, line)?;
        }
    }

    /// One statement on its own line; it may open a block that spans the lines after it.
    fn statement(&mut self, frame: Frame, line: SourceLine<'_>) -> ParseResult<()> {
        if let Some((receiver, rest)) = Self::qualified(frame, line) {
            return self.qualified_statement(frame, receiver, rest, line);
        }
        if line.text.starts_with(|c: char| c.is_ascii_uppercase()) {
            return Err(self.refuse(line.number, constant_first_why(line.text)));
        }
        let call = self.call(&line)?;
        self.check_args(&call, line, frame)?;
        match frame {
            Frame::Settings => {
                self.open_word(&call, line)?;
                self.block(Frame::Settings, &call, line)
            }
            Frame::Closed(context) => match self.closed_row(&call, context, line.number) {
                Ok(row) => self.body_of(row, &call, line),
                Err(refused) => self.open_statement(context, &call, line, refused),
            },
        }
    }

    /// A statement inside a one-line `{ … }` body: it may not open a multi-line block itself.
    fn statement_in_line(&mut self, frame: Frame, line: SourceLine<'_>) -> ParseResult<()> {
        let call = self.call(&line)?;
        if matches!(call.opener, Opener::DoBlock { .. }) {
            return Err(self.refuse(
                line.number,
                "a `do … end` block cannot open inside a one-line `{ … }` body",
            ));
        }
        self.statement(frame, line)
    }

    /// The two constructs whose own words are open: a hecksagon's bind verbs and a world's
    /// binding verbs. Anywhere else, the word the table refused stays refused.
    fn open_statement(
        &mut self,
        context: &'static str,
        call: &Call,
        line: SourceLine<'_>,
        refused: Diagnostic,
    ) -> ParseResult<()> {
        if refused.message.contains("was written with") {
            return Err(refused);
        }
        let inner = match context {
            "Hecksagon" => Frame::Closed("Hecksagon"),
            "World" => Frame::Settings,
            _ => return Err(refused),
        };
        self.open_word(call, line)?;
        self.block(inner, call, line)
    }

    fn open_word(&self, call: &Call, line: SourceLine<'_>) -> ParseResult<()> {
        if denied::is_ruby_method(&call.word) {
            return Err(self.refuse(
                line.number,
                format!(
                    "'{}' is a Ruby method, not a declaration word — Ruby would run it",
                    call.word
                ),
            ));
        }
        Ok(())
    }

    /// `Domain::Aggregate.word …`, legal only where a hecksagon or world binds an aggregate.
    fn qualified(frame: Frame, line: SourceLine<'_>) -> Option<(&str, &str)> {
        match frame {
            Frame::Closed("Hecksagon" | "World") => lex::strip_aggregate_receiver(line.text),
            _ => None,
        }
    }

    fn qualified_statement(
        &mut self,
        frame: Frame,
        receiver: &str,
        rest: &str,
        line: SourceLine<'_>,
    ) -> ParseResult<()> {
        let mut cursor = scan::Cursor::new(receiver);
        scan::constant_path(&mut cursor)
            .map_err(|refusal| self.refuse(line.number, refusal.why))?;
        let inner_line = SourceLine {
            number: line.number,
            text: rest,
        };
        let call = self.call(&inner_line)?;
        self.check_args(&call, inner_line, Frame::Settings)?;
        match (frame, call.word.as_str()) {
            (Frame::Closed("Hecksagon"), "port") => {
                let row = self.closed_row(&call, "Hecksagon", line.number)?;
                self.body_of(row, &call, inner_line)
            }
            (Frame::Closed("Hecksagon"), _) => {
                self.open_word(&call, inner_line)?;
                self.block(Frame::Closed("Hecksagon"), &call, inner_line)
            }
            _ => {
                self.open_word(&call, inner_line)?;
                self.block(Frame::Settings, &call, inner_line)
            }
        }
    }

    /// A rule body: `{ … }` on the line, or `do … end` across lines, read as one expression.
    fn source_body(&mut self, call: &Call, line: SourceLine<'_>) -> ParseResult<()> {
        let (text, number) = match &call.opener {
            Opener::BraceBlock { body } => (body.clone(), line.number),
            Opener::DoBlock {
                params: Some(params),
            } => {
                return Err(self.refuse(
                    line.number,
                    format!(
                        "'{}' takes no block parameters, but got |{params}|",
                        call.word
                    ),
                ));
            }
            Opener::DoBlock { params: None } => (self.rule_lines()?, line.number),
            Opener::None => return Ok(()),
        };
        predicate::check(&text).map_err(|refusal| {
            self.refuse(
                number,
                format!(
                    "'{}' holds a rule expression only: {}",
                    call.word, refusal.why
                ),
            )
        })
    }

    /// The lines of a `do … end` rule body, kept as written and joined for the check.
    fn rule_lines(&mut self) -> ParseResult<String> {
        let mut depth = 0usize;
        let mut parts: Vec<&str> = Vec::new();
        loop {
            let Some((idx, line)) = self.next_row() else {
                let last = self.rows.len();
                return Err(self.refuse(last, "unexpected end of file — a rule is never closed"));
            };
            self.keep(idx, line.text);
            if line.text == "end" {
                if depth == 0 {
                    return Ok(parts.join(" "));
                }
                depth -= 1;
            } else if opens_do(line.text) {
                depth += 1;
            }
            parts.push(line.text);
        }
    }
}

/// `sets` is the one word whose values are arithmetic over a command's operands.
fn args_mode(frame: Frame, word: &str) -> args::Mode {
    match (frame, word) {
        (Frame::Closed("Command"), "sets" | "then_set") => args::Mode::Operands,
        _ => args::Mode::Literals,
    }
}

fn opens_do(text: &str) -> bool {
    let trimmed = text.trim_end();
    trimmed.ends_with(" do") || (trimmed.ends_with('|') && trimmed.contains(" do |"))
}

/// Why a line that opens on a constant is refused: Ruby would call the constant, and a closed
/// line opens on a declaration word (only a hecksagon or world names an aggregate receiver).
fn constant_first_why(text: &str) -> String {
    let mut cursor = scan::Cursor::new(text);
    match scan::constant_path(&mut cursor) {
        Err(refusal) => refusal.why,
        Ok(name) => {
            format!(
                "`{name}` opens the line, so Ruby would run it; a line opens on a declaration word"
            )
        }
    }
}

#[cfg(test)]
mod tests;
