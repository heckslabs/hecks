//! The OUTERMOST gate — `File` context, the three words that begin any
//! file this parser reads: `bluebook`, `hecksagon`, `world`. Real for
//! Stage 1, same as every nested line: shape (lex.rs), word, body, and
//! argument gates (parse/mod.rs) all run here exactly as they do one level
//! down — nothing about being the top of the file is special-cased.

use crate::diag::{Diagnostic, ParseResult};
use crate::keywords::KeywordRow;
use crate::lex::{self, Call, LineShape, SourceLine};
use crate::ruby_value;

pub fn parse_header<'a>(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
) -> ParseResult<(&'a KeywordRow, Call, usize)> {
    let line = *lines.get(*pos).ok_or_else(|| {
        Diagnostic::new(file, 0, "empty file — expected bluebook/hecksagon/world")
    })?;
    let shape = lex::classify(file, &line)?;
    *pos += 1;

    match shape {
        LineShape::End => Err(Diagnostic::new(
            file,
            line.number,
            "unexpected 'end' at the top of the file",
        )),
        LineShape::Call(call) => {
            let candidates = super::word_gate(file, &call.word, "File", line.number)?;
            let row = super::body_gate(file, &candidates, &call.opener, line.number, &call.word)?;
            super::argument_gate(file, &call.word, "File", &call.args, line.number)?;
            Ok((row, call, line.number))
        }
    }
}

/// The header's own declared name — `bluebook "Pizzas"`'s first
/// positional argument (the `text`-kind row, `at: "1"`). Read back through
/// ruby_value the same way any other captured text argument is.
pub fn header_name(call: &Call) -> Option<String> {
    let first = ruby_value::split_items(&call.args).into_iter().next()?;
    match ruby_value::read(&first) {
        ruby_value::Value::Str(name) => Some(name),
        _ => None,
    }
}

/// The header's own OPTIONAL `version:` named argument — `Hecks.bluebook
/// "Banking", version: "v1" do`, `bluebook`'s own `named: "version"` row
/// (`context: "File"`). Not exercised by pizzas.bluebook/the framework
/// trio/the grammar chapters (none pins a version) — confirmed real by
/// banking.bluebook, the first real corpus member to.
pub fn header_version(call: &Call) -> Option<String> {
    ruby_value::split_items(&call.args)
        .into_iter()
        .find_map(|segment| {
            let (name, value) = super::as_named(&segment)?;
            if name != "version" {
                return None;
            }
            Some(match ruby_value::read(value.trim()) {
                ruby_value::Value::Str(s) => s,
                other => ruby_value::to_s(&other),
            })
        })
}
