//! The `ValueObject`/`OneOf` constructs
//! (`lib/hecksagain/bluebook/ir/value_object.rb`) — shared here exactly as
//! `ValueObjectBuilder` answers both in Ruby (`one_of` `instance_eval`s
//! its block on the builder itself, so the two contexts are one Ruby
//! object; see `spec/syntax_conformance_spec.rb`'s own `BUILDER` table).
//! Stage 2+ work: `invariant` source-body capture, and `member` rows
//! (`build/closed_sets.rs`) — an open map of pairs, captured verbatim per
//! `PairsShape::verbatim`.

use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{Opener, SourceLine};
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ValueObject.{word}"))
}

/// Parses a `value_object "Name" do ... end` body.
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<ir::ValueObject> {
    let mut vo = ir::ValueObject { name: name.to_string(), ..Default::default() };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "ValueObject")? else {
            return Ok(vo);
        };

        match gated.row.word {
            "attribute" => vo.attributes.push(super::build_attribute(file, gated.line.number, "attribute", &gated.args)?),
            "invariant" => {
                let description = super::positional_text(file, gated.line.number, "invariant", &gated.args, 1)?;
                let Opener::BraceBlock { body } = &gated.call.opener else {
                    return Err(Diagnostic::new(file, gated.line.number, "'invariant' requires a { ... } predicate body"));
                };
                vo.invariants.push(ir::Given { description: Some(description), canonical: canonical::apply(body) });
            }
            "one_of" => {
                vo.closed_set = true;
                vo.members = parse_one_of_body(file, lines, pos)?;
            }
            _ => return Err(super::not_built_yet("ValueObject", gated.row, file, gated.line.number, &gated.call.word)),
        }
    }
}

/// `ValueObjectBuilder#one_of`/`#member` — the LONG closed-set form
/// (`one_of do member ... end`), the shape pizzas.bluebook's own `Size`
/// value object uses. Each `member` line is one `pairs_shape: "verbatim"`
/// open map (`member value: "small"`), and `IR::ValueObject#to_h` renders
/// each member as an array of `[field, value]` pairs via Ruby's own
/// `.to_s` (see `ruby_value::to_s`'s own header — NOT `Literal.render`).
fn parse_one_of_body(file: &str, lines: &[SourceLine], pos: &mut usize) -> ParseResult<Vec<Vec<(String, String)>>> {
    let mut members = Vec::new();

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "OneOf")? else {
            return Ok(members);
        };

        match gated.row.word {
            "member" => {
                if gated.args.named.is_empty() {
                    return Err(Diagnostic::new(file, gated.line.number, "'member' declared an empty member"));
                }
                let fields = gated
                    .args
                    .named
                    .iter()
                    .map(|(field, raw)| (field.clone(), ruby_value::to_s(&ruby_value::read(raw))))
                    .collect();
                members.push(fields);
            }
            _ => return Err(super::not_built_yet("OneOf", gated.row, file, gated.line.number, &gated.call.word)),
        }
    }
}
