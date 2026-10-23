//! The `World` construct: a `.world` file's `Hecks.world "Name" do ... end` blocks, each holding
//! the scalar words `realm`, `latest`, `default_adapter`, `default_database` and any number of
//! open-vocabulary bindings (`persisted_by("Heki") do ... end`, `launcher "Launcher", k: v`).
//! Printed by `hecks-parse world`; worlds never enter `ir.json`.
//!
//! The settings bag is open, so a binding verb has no keyword row: it is shape-matched, and only
//! its verb, adapter and setting names are recorded. Setting values are never read into the IR
//! (they can be secrets) and nothing is ever evaluated.

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::keywords;
use crate::lex::{self, LineShape, Opener, SourceLine};
use crate::ruby_value::{self, Value};

/// Ruby methods that do something rather than name a binding. The settings bag is open, so these
/// are the words refused by name: a `.world` file only declares, it never runs anything.
const RUBY_KERNEL_WORDS: &[&str] = &[
    "puts",
    "print",
    "p",
    "pp",
    "require",
    "require_relative",
    "load",
    "eval",
    "instance_eval",
    "system",
    "exec",
    "spawn",
    "raise",
    "fail",
    "abort",
    "exit",
    "sleep",
    "send",
    "public_send",
    "binding",
    "at_exit",
    "warn",
    "gets",
    "open",
];

/// Parses every top-level `world` block of one `.world` file, in file order, unmerged.
pub fn parse_file(path: &str, source: &str) -> ParseResult<Vec<ir::World>> {
    let joined = lex::join_continuations(source);
    let lines = lex::lines(&joined);
    let mut pos = 0usize;
    let mut worlds = Vec::new();

    while pos < lines.len() {
        let (row, call, header_line) = super::file::parse_header(path, &lines, &mut pos)?;
        if row.inner != "World" {
            return Err(Diagnostic::new(
                path,
                header_line,
                format!(
                    "a .world file's own top-level blocks must all be 'world'; got '{}'",
                    call.word
                ),
            ));
        }
        let domain = super::file::header_name(&call)
            .filter(|name| !name.is_empty())
            .ok_or_else(|| {
                Diagnostic::new(path, header_line, "'world' needs a non-empty quoted name")
            })?;
        worlds.push(parse_body(path, &lines, &mut pos, domain)?);
    }
    Ok(worlds)
}

/// Folds blocks into one world per distinct domain, in order of first appearance, as the Ruby
/// registry does: a later scalar replaces an earlier one; a later binding replaces the earlier
/// binding with the same key wholesale, in the earlier slot; new keys append.
pub fn merge(blocks: Vec<ir::World>) -> Vec<ir::World> {
    let mut merged: Vec<ir::World> = Vec::new();
    for block in blocks {
        let Some(existing) = merged.iter_mut().find(|w| w.domain == block.domain) else {
            merged.push(block);
            continue;
        };
        if block.realm.is_some() {
            existing.realm = block.realm;
        }
        if block.latest.is_some() {
            existing.latest = block.latest;
        }
        if block.default_adapter.is_some() {
            existing.default_adapter = block.default_adapter;
        }
        existing.default_database |= block.default_database;
        for binding in block.bindings {
            upsert(&mut existing.bindings, binding);
        }
    }
    merged
}

/// A repeated (verb, adapter) key keeps its first position with the last contents.
fn upsert(bindings: &mut Vec<ir::Binding>, binding: ir::Binding) {
    let same = |b: &ir::Binding| {
        b.verb == binding.verb && b.adapter.to_lowercase() == binding.adapter.to_lowercase()
    };
    match bindings.iter_mut().find(|b| same(b)) {
        Some(slot) => *slot = binding,
        None => bindings.push(binding),
    }
}

fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    domain: String,
) -> ParseResult<ir::World> {
    let mut world = ir::World {
        domain,
        ..ir::World::default()
    };
    loop {
        let line = *lines.get(*pos).ok_or_else(|| {
            let last = lines.last().map_or(0, |l| l.number);
            Diagnostic::new(file, last, "unexpected end of file — still inside World")
        })?;
        let LineShape::Call(call) = lex::classify(file, &line)? else {
            *pos += 1;
            return Ok(world);
        };
        match call.word.as_str() {
            "default_database" => {
                *pos += 1;
                world.default_database = default_database_set(file, line.number, &call)?;
            }
            "realm" | "latest" | "default_adapter" => {
                let gated = super::next_line(file, lines, pos, "World")?.ok_or_else(|| {
                    Diagnostic::new(file, line.number, "unexpected 'end' inside World")
                })?;
                let value = scalar_text(file, line.number, &call.word, &gated.args)?;
                match call.word.as_str() {
                    "realm" => world.realm = Some(value),
                    "latest" => world.latest = Some(value),
                    _ => world.default_adapter = Some(value),
                }
            }
            _ => {
                *pos += 1;
                let binding = parse_binding(file, lines, pos, line.number, &call)?;
                upsert(&mut world.bindings, binding);
            }
        }
    }
}

/// A non-empty string literal, as Ruby's world language requires of these words.
fn scalar_text(
    file: &str,
    line: usize,
    word: &str,
    args: &super::ArgumentGateResult,
) -> ParseResult<String> {
    let raw = args.positional.first().map_or("", |(_, v)| v.trim());
    if !raw.starts_with('"') {
        return Err(Diagnostic::new(
            file,
            line,
            format!("'{word}' takes a quoted string"),
        ));
    }
    let text = super::positional_text(file, line, word, args, 1)?;
    if text.is_empty() {
        return Err(Diagnostic::new(
            file,
            line,
            format!("'{word}' must not be empty"),
        ));
    }
    Ok(text)
}

/// `default_database` takes a string or any Ruby expression (an environment lookup). The expression
/// is neither evaluated nor kept: only that it was set. A literal empty string or `nil` refuses.
fn default_database_set(file: &str, line: usize, call: &lex::Call) -> ParseResult<bool> {
    let items = ruby_value::split_items(&call.args);
    let single = items.len() == 1 && call.opener == Opener::None;
    if !single || super::as_named(&items[0]).is_some() {
        return Err(Diagnostic::new(
            file,
            line,
            "'default_database' takes exactly one value and no block",
        ));
    }
    if matches!(ruby_value::read(&items[0]), Value::Str(ref s) if s.is_empty()) || items[0] == "nil"
    {
        return Err(Diagnostic::new(
            file,
            line,
            "'default_database' must not be empty",
        ));
    }
    Ok(true)
}

/// One binding call: `verb("Adapter") do ... end`, or `verb "Adapter", k: v, ...` with no block.
/// Records the verb, the first positional string, the keyword names, then the body's top-level
/// keys. A verb that is a grammar word elsewhere is refused, as Ruby's word gate refuses it.
fn parse_binding(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    number: usize,
    call: &lex::Call,
) -> ParseResult<ir::Binding> {
    if RUBY_KERNEL_WORDS.contains(&call.word.as_str()) {
        return Err(Diagnostic::new(
            file,
            number,
            format!(
                "'{}' is a Ruby method, not a binding verb; a .world file only declares",
                call.word
            ),
        ));
    }
    if keywords::KEYWORDS
        .iter()
        .any(|k| k.live() && k.word == call.word)
    {
        return Err(Diagnostic::new(
            file,
            number,
            format!(
                "'{}' is a grammar word, not a binding verb, and World does not admit it",
                call.word
            ),
        ));
    }
    let mut adapter = None;
    let mut settings: Vec<String> = Vec::new();
    for item in ruby_value::split_items(&call.args) {
        if let Some((name, _value)) = super::as_named(&item) {
            push_unique(&mut settings, name.to_string());
        } else if adapter.is_none() && item.starts_with('"') {
            adapter = Some(match ruby_value::read(&item) {
                Value::Str(s) => s,
                other => ruby_value::to_s(&other),
            });
        } else {
            return Err(Diagnostic::new(
                file,
                number,
                format!(
                    "'{}' takes one quoted adapter name, then keyword arguments",
                    call.word
                ),
            ));
        }
    }
    let adapter = adapter.ok_or_else(|| {
        Diagnostic::new(
            file,
            number,
            format!("'{}' needs a quoted adapter name", call.word),
        )
    })?;
    match call.opener {
        Opener::None => {}
        Opener::DoBlock { .. } => body_keys(file, lines, pos, &mut settings)?,
        Opener::BraceBlock { .. } => {
            return Err(Diagnostic::new(
                file,
                number,
                format!("'{}' takes a `do ... end` block, not braces", call.word),
            ))
        }
    }
    Ok(ir::Binding {
        verb: call.word.clone(),
        adapter,
        settings,
    })
}

/// Collects a binding block's top-level setting names, tracking nested blocks through the shape
/// gate so a malformed line inside still refuses. Values are not read.
fn body_keys(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    settings: &mut Vec<String>,
) -> ParseResult<()> {
    let mut depth = 1;
    while depth > 0 {
        let line = *lines.get(*pos).ok_or_else(|| {
            let last = lines.last().map_or(0, |l| l.number);
            Diagnostic::new(
                file,
                last,
                "unexpected end of file — still inside a binding block",
            )
        })?;
        *pos += 1;
        match lex::classify(file, &line)? {
            LineShape::End => depth -= 1,
            LineShape::Call(call) => {
                if depth == 1 {
                    push_unique(settings, call.word.clone());
                }
                if matches!(call.opener, Opener::DoBlock { .. }) {
                    depth += 1;
                }
            }
        }
    }
    Ok(())
}

fn push_unique(names: &mut Vec<String>, name: String) {
    if !names.contains(&name) {
        names.push(name);
    }
}
