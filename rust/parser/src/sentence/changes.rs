//! What a command does to the record, in sentences: `the status is set to "open"`, `the balance
//! goes up by the amount`, `the tags lose the label`. Read from a command's `Then`/`And` lines into
//! changes, resolved against the command's arguments, and written back from the IR's mutations.

use super::lower::FieldUse;
use super::names::{snake, spoken};
use super::{Matched, Parser};
use crate::diag::ParseResult;
use crate::ir;
use crate::ruby_value::{self, Value};

/// Where a change takes its value from.
pub(super) enum Source {
    Argument(FieldUse),
    Literal(Value),
    /// The record's own field, as it stood before the command.
    State(FieldUse),
    Expression(String),
}

/// One change a command makes, before its names are resolved.
pub(super) enum Change {
    /// The field takes the argument of the same name.
    SetSame(FieldUse),
    Op {
        target: FieldUse,
        op: &'static str,
        sign: &'static str,
        source: Source,
    },
}

fn field(m: &Matched, slot: &str) -> FieldUse {
    FieldUse {
        name: snake(&m.text_of(slot)),
        line: m.line,
        col: m.col_of(slot),
    }
}

impl Parser<'_> {
    /// The changes a `Then`/`And` line says, or none when it says something else.
    pub(super) fn changes_of(&self, m: &Matched) -> ParseResult<Option<Vec<Change>>> {
        let op = |op: &'static str, sign: &'static str, source: Source| Change::Op {
            target: field(m, "target"),
            op,
            sign,
            source,
        };
        let change = match m.id {
            "sets" => {
                return Ok(Some(super::lower::field_uses(m, "names").into_iter().map(Change::SetSame).collect()));
            }
            "set_to" => op("set", "", Source::Argument(field(m, "source"))),
            "set_to_literal" => op("set", "", Source::Literal(self.literal(m, "value")?)),
            "set_to_state" => op("set", "", Source::State(field(m, "source"))),
            "set_to_result" => op("set", "", Source::Expression(crate::canonical::apply(&m.text_of("code")))),
            "go_up" => op("increment", "1", Source::Argument(field(m, "source"))),
            "go_up_by" => op("increment", "1", Source::Literal(self.literal(m, "value")?)),
            "go_down" => op("decrement", "-1", Source::Argument(field(m, "source"))),
            "go_down_by" => op("decrement", "-1", Source::Literal(self.literal(m, "value")?)),
            "multiply" => op("multiply", "", Source::Argument(field(m, "source"))),
            "remove" => op("remove", "", Source::Argument(field(m, "source"))),
            "clamp" => {
                let bound = |slot: &str| Value::Int(m.text_of(slot).parse().unwrap_or_default());
                op("clamp", "", Source::Literal(Value::Array(vec![bound("low"), bound("high")])))
            }
            _ => return Ok(None),
        };
        Ok(Some(vec![change]))
    }

    /// The Ruby literal a `rest` slot holds: a number, quoted text, true, false, nothing or a hash.
    fn literal(&self, m: &Matched, slot: &str) -> ParseResult<Value> {
        let text = m.text_of(slot);
        match ruby_value::read(&text) {
            Value::Bare(_) => Err(self.error(
                m.line,
                m.col_of(slot),
                format!("'{text}' is not a value: write a number, quoted text, true, false or nothing"),
            )),
            value => Ok(value),
        }
    }

    /// The mutations `changes` make, once the arguments and fields they name are known.
    pub(super) fn mutations_of(
        &self,
        command: &str,
        changes: Vec<Change>,
        given: &[String],
        fields: &[String],
    ) -> ParseResult<Vec<ir::Mutation>> {
        let known = |name: &FieldUse, among: &[String], given_to_command: bool| -> ParseResult<()> {
            if among.contains(&name.name) {
                return Ok(());
            }
            let shown: Vec<String> = among.iter().map(|n| spoken(n)).collect();
            let message = if given_to_command {
                format!(
                    "'{}' is set from what the command is given, and {command} is not given. Add it to `When … given`",
                    spoken(&name.name)
                )
            } else {
                format!(
                    "'{}' is not a field here. The fields are: {}",
                    spoken(&name.name),
                    if shown.is_empty() { "none".to_string() } else { shown.join(", ") }
                )
            };
            Err(self.error(name.line, name.col, message))
        };
        let mut mutations = Vec::new();
        for change in changes {
            let (target, op, sign, source) = match change {
                Change::SetSame(target) => {
                    known(&target, given, true)?;
                    let source = ir::MutationSource::Argument(target.name.clone());
                    (target, "set", "", source)
                }
                Change::Op { target, op, sign, source } => {
                    let source = match source {
                        Source::Argument(arg) => {
                            known(&arg, given, true)?;
                            ir::MutationSource::Argument(arg.name)
                        }
                        Source::State(field) => {
                            known(&field, fields, false)?;
                            ir::MutationSource::State(field.name)
                        }
                        Source::Literal(value) => ir::MutationSource::Literal(value),
                        Source::Expression(text) => ir::MutationSource::Expression(text),
                    };
                    (target, op, sign, source)
                }
            };
            mutations.push(ir::Mutation::Other {
                target: target.name,
                op: op.to_string(),
                sign: sign.to_string(),
                source: Some(source),
            });
        }
        Ok(mutations)
    }
}

/// The sentences (without their `Then`/`And`) that say a command's mutations, a run of plain sets
/// sharing one.
pub(super) fn said(command: &str, mutations: &[ir::Mutation]) -> Result<Vec<String>, String> {
    let refused = || format!("the sentence form has no phrase for that kind of mutation on command {command}");
    let mut lines: Vec<String> = Vec::new();
    let mut plain: Vec<String> = Vec::new();
    let flush = |plain: &mut Vec<String>, lines: &mut Vec<String>| {
        if !plain.is_empty() {
            let verb = if plain.len() == 1 { "is" } else { "are" };
            lines.push(format!("{} {verb} set", super::format::join_and(plain)));
            plain.clear();
        }
    };
    for mutation in mutations {
        let ir::Mutation::Other { target, op, source: Some(source), .. } = mutation else {
            return Err(refused());
        };
        let name = spoken(target);
        if let (true, ir::MutationSource::Argument(argument)) = (op == "set", source) {
            if argument == target {
                plain.push(format!("the {name}"));
                continue;
            }
        }
        flush(&mut plain, &mut lines);
        lines.push(change_line(&name, op, source).ok_or_else(refused)?);
    }
    flush(&mut plain, &mut lines);
    Ok(lines)
}

/// One non-plain change as a sentence, or nothing when no phrase says that op over that source.
fn change_line(name: &str, op: &str, source: &ir::MutationSource) -> Option<String> {
    use ir::MutationSource::{Argument, Expression, Literal, State};
    Some(match (op, source) {
        ("set", Argument(arg)) => format!("the {name} is set to the {}", spoken(arg)),
        ("set", Literal(value)) => format!("the {name} is set to {}", ruby_value::render(value)),
        ("set", State(field)) => format!("the {name} is set to what the {} was", spoken(field)),
        ("set", Expression(text)) => format!("the {name} is set to the result of {text}"),
        ("increment", Argument(arg)) => format!("the {name} goes up by the {}", spoken(arg)),
        ("increment", Literal(value)) => format!("the {name} goes up by {}", ruby_value::render(value)),
        ("decrement", Argument(arg)) => format!("the {name} goes down by the {}", spoken(arg)),
        ("decrement", Literal(value)) => format!("the {name} goes down by {}", ruby_value::render(value)),
        ("multiply", Argument(arg)) => format!("the {name} is multiplied by the {}", spoken(arg)),
        ("remove", Argument(arg)) => format!("the {} is removed from the {name}", spoken(arg)),
        ("clamp", Literal(Value::Array(bounds))) => match bounds.as_slice() {
            [Value::Int(low), Value::Int(high)] => format!("the {name} is kept between {low} and {high}"),
            _ => return None,
        },
        _ => return None,
    })
}
