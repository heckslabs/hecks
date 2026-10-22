//! The `Adapter` construct: a `.adapter` file's `Hecks.adapter "Name" do ... end` blocks, each
//! declaring a `port`, `field`s (optionally defaulted) and `secret`s. Printed by
//! `hecks-parse adapter`; adapters never enter `ir.json`.

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, SourceLine};
use crate::ruby_value::{self, Value};

/// Parses every top-level `adapter` block of one `.adapter` file, in file order.
///
/// A top-level line that is exactly `require "path"` is plain Ruby, not grammar, and is skipped;
/// any other top-level word goes through the normal gates and refuses there.
pub fn parse_file(path: &str, source: &str) -> ParseResult<Vec<ir::Adapter>> {
    let joined = lex::join_continuations(source);
    let lines = lex::lines(&joined);
    let mut pos = 0usize;
    let mut adapters = Vec::new();

    while pos < lines.len() {
        if is_require_line(lines[pos].text) {
            pos += 1;
            continue;
        }
        let (row, call, header_line) = super::file::parse_header(path, &lines, &mut pos)?;
        if row.inner != "Adapter" {
            return Err(Diagnostic::new(
                path,
                header_line,
                format!(
                    "a .adapter file's own top-level blocks must all be 'adapter'; got '{}'",
                    call.word
                ),
            ));
        }
        let name = super::file::header_name(&call)
            .ok_or_else(|| Diagnostic::new(path, header_line, "'adapter' needs a quoted name"))?;
        adapters.push(parse_body(path, &lines, &mut pos, name)?);
    }
    Ok(adapters)
}

/// `require` followed by exactly one double-quoted string, nothing else.
fn is_require_line(text: &str) -> bool {
    let Some(rest) = text.strip_prefix("require ") else {
        return false;
    };
    let rest = rest.trim();
    rest.len() >= 2
        && rest.starts_with('"')
        && rest.ends_with('"')
        && !rest[1..rest.len() - 1].contains(['"', '\\'])
}

fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: String,
) -> ParseResult<ir::Adapter> {
    let mut adapter = ir::Adapter {
        name,
        ..ir::Adapter::default()
    };
    while let Some(gated) = super::next_line(file, lines, pos, "Adapter")? {
        let number = gated.line.number;
        match gated.row.word {
            // A repeat replaces the earlier value, as the Ruby builder's setter does.
            "port" => {
                adapter.port = Some(super::positional_text(
                    file,
                    number,
                    "port",
                    &gated.args,
                    1,
                )?);
            }
            "field" => {
                let field = super::positional_symbol(file, number, "field", &gated.args, 1)?;
                if let Some(raw) = super::named_raw(&gated.args, "default") {
                    let value = default_value(file, number, raw)?;
                    // A repeated key keeps its first position with the last value.
                    match adapter.defaults.iter_mut().find(|(k, _)| *k == field) {
                        Some(slot) => slot.1 = value,
                        None => adapter.defaults.push((field.clone(), value)),
                    }
                }
                adapter.fields.push(field);
            }
            "secret" => {
                adapter.secrets.push(super::positional_symbol(
                    file,
                    number,
                    "secret",
                    &gated.args,
                    1,
                )?);
            }
            _ => {
                return Err(super::not_built_yet(
                    "Adapter",
                    gated.row,
                    file,
                    number,
                    &gated.call.word,
                ))
            }
        }
    }
    Ok(adapter)
}

/// A JSON-native default: string, integer, boolean or nil. Anything else is refused rather than
/// guessed at, and a string may use braces only for the `{name}` and `{storage_name}`
/// placeholders (Ruby's `^(?:[^{}]|\{(?:name|storage_name)\})*$`).
fn default_value(file: &str, line: usize, raw: &str) -> ParseResult<Value> {
    let value = ruby_value::read(raw);
    match &value {
        Value::Nil | Value::Bool(_) | Value::Int(_) => {}
        Value::Str(text) if braces_are_placeholders(text) => {}
        Value::Str(text) => {
            return Err(Diagnostic::new(
                file,
                line,
                format!(
                    "'field' default \"{text}\" uses braces; only {{name}} and {{storage_name}} are allowed"
                ),
            ))
        }
        _ => {
            return Err(Diagnostic::new(
                file,
                line,
                format!(
                    "'field' default ({}) must be a string, integer, true, false or nil",
                    raw.trim()
                ),
            ))
        }
    }
    Ok(value)
}

fn braces_are_placeholders(text: &str) -> bool {
    let mut rest = text;
    while let Some(at) = rest.find(['{', '}']) {
        let tail = &rest[at..];
        let Some(after) = ["{name}", "{storage_name}"]
            .iter()
            .find_map(|p| tail.strip_prefix(p))
        else {
            return false;
        };
        rest = after;
    }
    true
}
