//! What a command does to the record, in sentences: `the status is set to "open"`, `the balance
//! goes up by the amount`, `the tags lose the label`. Read from a command's `Then`/`And` lines into
//! changes, resolved against the command's arguments, and written back from the IR's mutations.

use super::lower::FieldUse;
use super::names::{camel, snake, spoken};
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

/// Where one field of a row gets its value: an argument, or a literal as the IR spells it.
pub(super) enum Origin {
    Argument(FieldUse),
    Literal(String),
}

/// One change a command makes, before its names are resolved.
pub(super) enum Change {
    /// A row added to a list field, each of its fields given by name.
    Append {
        target: FieldUse,
        fields: Vec<(String, Origin)>,
    },
    /// The work handed to a command of an entity (`Entity.Command`).
    Delegate {
        target: String,
        fields: Vec<(String, Origin)>,
    },
    /// An earlier event corrected.
    Correction {
        target: String,
        fields: Vec<(String, Origin)>,
    },
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
                return Ok(Some(
                    super::lower::field_uses(m, "names")
                        .into_iter()
                        .map(Change::SetSame)
                        .collect(),
                ));
            }
            "add_row" => {
                return Ok(Some(vec![Change::Append {
                    target: field(m, "target"),
                    fields: self.row_fields(m)?,
                }]));
            }
            "delegates" => {
                let target = format!(
                    "{}.{}",
                    camel(&m.text_of("entity")),
                    camel(&m.text_of("command"))
                );
                return Ok(Some(vec![Change::Delegate {
                    target,
                    fields: self.row_fields(m)?,
                }]));
            }
            "corrects" => {
                return Ok(Some(vec![Change::Correction {
                    target: m.text_of("event"),
                    fields: self.row_fields(m)?,
                }]));
            }
            "set_to" => op("set", "", Source::Argument(field(m, "source"))),
            "set_to_literal" => op("set", "", Source::Literal(self.literal(m, "value")?)),
            "set_to_state" => op("set", "", Source::State(field(m, "source"))),
            "set_to_result" => op(
                "set",
                "",
                Source::Expression(crate::canonical::apply(&m.text_of("code"))),
            ),
            "go_up" => op("increment", "1", Source::Argument(field(m, "source"))),
            "go_up_by" => op("increment", "1", Source::Literal(self.literal(m, "value")?)),
            "go_down" => op("decrement", "-1", Source::Argument(field(m, "source"))),
            "go_down_by" => op(
                "decrement",
                "-1",
                Source::Literal(self.literal(m, "value")?),
            ),
            "multiply" => op("multiply", "", Source::Argument(field(m, "source"))),
            "remove" => op("remove", "", Source::Argument(field(m, "source"))),
            "clamp" => {
                let bound = |slot: &str| Value::Int(m.text_of(slot).parse().unwrap_or_default());
                op(
                    "clamp",
                    "",
                    Source::Literal(Value::Array(vec![bound("low"), bound("high")])),
                )
            }
            _ => return Ok(None),
        };
        Ok(Some(vec![change]))
    }

    /// The `key from the x` and `key as literal` items of a `with` slot, as the IR spells them.
    pub(super) fn with_pairs(&self, m: &Matched) -> ParseResult<Vec<(String, String)>> {
        Ok(self
            .row_fields(m)?
            .into_iter()
            .map(|(key, origin)| match origin {
                Origin::Argument(from) => (key, format!(":{}", from.name)),
                Origin::Literal(text) => (key, text),
            })
            .collect())
    }

    /// The `key from the argument` and `key as literal` items of a `with` slot.
    fn row_fields(&self, m: &Matched) -> ParseResult<Vec<(String, Origin)>> {
        let text = m.text_of("fields");
        let col = m.col_of("fields");
        let mut fields = Vec::new();
        for item in ruby_value::split_items(&text) {
            let item = item.trim();
            let from = item.find(" from the ");
            let as_literal = item.find(" as ");
            let (key, origin) = match (from, as_literal) {
                (Some(at), other) if other.is_none_or(|later| at < later) => {
                    let name = FieldUse {
                        name: snake(&item[at + " from the ".len()..]),
                        line: m.line,
                        col,
                    };
                    (&item[..at], Origin::Argument(name))
                }
                (_, Some(at)) => {
                    let literal = &item[at + " as ".len()..];
                    if matches!(ruby_value::read(literal), Value::Bare(_)) {
                        return Err(self.error(m.line, col, format!("'{literal}' is not a value: write a number, quoted text, true, false, nothing or a {{value: …}}")));
                    }
                    (
                        &item[..at],
                        Origin::Literal(ruby_value::render(&ruby_value::read(literal))),
                    )
                }
                _ => {
                    return Err(self.error(
                        m.line,
                        col,
                        format!("'{item}' needs a source: write `{item} from the <argument>` or `{item} as <value>`"),
                    ));
                }
            };
            fields.push((snake(key), origin));
        }
        Ok(fields)
    }

    /// The Ruby literal a `rest` slot holds: a number, quoted text, true, false, nothing or a hash.
    pub(super) fn literal(&self, m: &Matched, slot: &str) -> ParseResult<Value> {
        let text = m.text_of(slot);
        match ruby_value::read(&text) {
            Value::Bare(_) => Err(self.error(
                m.line,
                m.col_of(slot),
                format!(
                    "'{text}' is not a value: write a number, quoted text, true, false or nothing"
                ),
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
        let known = |name: &FieldUse,
                     among: &[String],
                     given_to_command: bool|
         -> ParseResult<()> {
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
                    if shown.is_empty() {
                        "none".to_string()
                    } else {
                        shown.join(", ")
                    }
                )
            };
            Err(self.error(name.line, name.col, message))
        };
        let rows = |fields: Vec<(String, Origin)>| -> ParseResult<Vec<(String, String)>> {
            fields
                .into_iter()
                .map(|(key, origin)| match origin {
                    Origin::Argument(arg) => {
                        known(&arg, given, true).map(|()| (key, format!(":{}", arg.name)))
                    }
                    Origin::Literal(text) => Ok((key, text)),
                })
                .collect()
        };
        let mut mutations = Vec::new();
        for change in changes {
            let (target, op, sign, source) = match change {
                Change::Append { target, fields } => {
                    mutations.push(ir::Mutation::Append {
                        target: target.name,
                        fields: rows(fields)?,
                    });
                    continue;
                }
                Change::Delegate { target, fields } => {
                    mutations.push(ir::Mutation::Delegate {
                        target,
                        fields: rows(fields)?,
                    });
                    continue;
                }
                Change::Correction { target, fields } => {
                    mutations.push(ir::Mutation::Correction {
                        target,
                        fields: rows(fields)?,
                    });
                    continue;
                }
                Change::SetSame(target) => {
                    known(&target, given, true)?;
                    let source = ir::MutationSource::Argument(target.name.clone());
                    (target, "set", "", source)
                }
                Change::Op {
                    target,
                    op,
                    sign,
                    source,
                } => {
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
    let refused_for = |mutation: &ir::Mutation| match mutation {
        ir::Mutation::Append { target, .. } => format!(
            "the sentence form has no phrase for adding a row to {target} on command {command}"
        ),
        ir::Mutation::Delegate { target, .. } => format!(
            "the sentence form has no phrase for handing the work to {target} on command {command}"
        ),
        ir::Mutation::Correction { target, .. } => {
            format!("the sentence form has no phrase for correcting {target} on command {command}")
        }
        ir::Mutation::Other { target, op, .. } => {
            format!("the sentence form has no phrase for {op} of {target} like this on command {command}")
        }
    };
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
        let (target, op, source) = match mutation {
            ir::Mutation::Other {
                target,
                op,
                source: Some(source),
                ..
            } => (target, op, source),
            ir::Mutation::Append { target, fields } => {
                flush(&mut plain, &mut lines);
                let items = row_items(fields).ok_or_else(|| refused_for(mutation))?;
                lines.push(format!(
                    "a row is added to the {} with {items}",
                    spoken(target)
                ));
                continue;
            }
            ir::Mutation::Delegate { target, fields } => {
                flush(&mut plain, &mut lines);
                let (entity, command) = target
                    .split_once('.')
                    .ok_or_else(|| refused_for(mutation))?;
                let items = row_items(fields).ok_or_else(|| refused_for(mutation))?;
                lines.push(format!(
                    "the {} is told to {} with {items}",
                    spoken(entity),
                    spoken(command)
                ));
                continue;
            }
            ir::Mutation::Correction { target, fields } => {
                flush(&mut plain, &mut lines);
                let items = row_items(fields).ok_or_else(|| refused_for(mutation))?;
                lines.push(format!("{target} is corrected with {items}"));
                continue;
            }
            ir::Mutation::Other { .. } => return Err(refused_for(mutation)),
        };
        let name = spoken(target);
        if let (true, ir::MutationSource::Argument(argument)) = (op == "set", source) {
            if argument == target {
                plain.push(format!("the {name}"));
                continue;
            }
        }
        flush(&mut plain, &mut lines);
        lines.push(change_line(&name, op, source).ok_or_else(|| refused_for(mutation))?);
    }
    flush(&mut plain, &mut lines);
    Ok(lines)
}

/// `key from the argument, key as literal` for the fields of a row, or nothing when one has no
/// phrase.
pub(super) fn row_items(fields: &[(String, String)]) -> Option<String> {
    if fields.is_empty() {
        return None;
    }
    let items: Option<Vec<String>> = fields
        .iter()
        .map(|(key, value)| {
            let key = spoken(key);
            match value.strip_prefix(':').filter(|name| {
                !name.is_empty()
                    && name
                        .chars()
                        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
            }) {
                Some(name) => Some(format!("{key} from the {}", spoken(name))),
                None if matches!(ruby_value::read(value), Value::Bare(_)) => None,
                None => Some(format!("{key} as {value}")),
            }
        })
        .collect();
    Some(items?.join(", "))
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
        ("increment", Literal(value)) => {
            format!("the {name} goes up by {}", ruby_value::render(value))
        }
        ("decrement", Argument(arg)) => format!("the {name} goes down by the {}", spoken(arg)),
        ("decrement", Literal(value)) => {
            format!("the {name} goes down by {}", ruby_value::render(value))
        }
        ("multiply", Argument(arg)) => format!("the {name} is multiplied by the {}", spoken(arg)),
        ("remove", Argument(arg)) => format!("the {} is removed from the {name}", spoken(arg)),
        ("clamp", Literal(Value::Array(bounds))) => match bounds.as_slice() {
            [Value::Int(low), Value::Int(high)] => {
                format!("the {name} is kept between {low} and {high}")
            }
            _ => return None,
        },
        _ => return None,
    })
}
