//! The `Lifecycle` construct: a fold onto the enclosing Aggregate or Entity, not its own category.
//! Parses `transition` lines and seals the owner's commands against the lifecycle field.

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Lifecycle.{word}"))
}

// `field` and `default` come from the header line, which the enclosing context has already read.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    field: &str,
    default: &str,
) -> ParseResult<ir::Lifecycle> {
    let mut lifecycle = ir::Lifecycle {
        field: field.to_string(),
        default: default.to_string(),
        transitions: Vec::new(),
    };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Lifecycle")? else {
            refuse_ambiguity(file, *pos, &lifecycle)?;
            return Ok(lifecycle);
        };

        match gated.row.word {
            "transition" => {
                let line = gated.line.number;
                let pair_text = super::named_raw(&gated.args, "=>").ok_or_else(|| {
                    Diagnostic::new(file, line, "'transition' names no 'command => state' pair")
                })?;
                let (command_raw, to_state_raw) = super::split_top_level_rocket(pair_text);
                let command = text_value(command_raw);
                let to_state = text_value(to_state_raw);
                let from_states = match super::named_raw(&gated.args, "from") {
                    None => vec![None],
                    Some(raw) => from_values(raw).into_iter().map(Some).collect(),
                };

                for from_state in from_states {
                    lifecycle.transitions.push(ir::StateTransitionRow {
                        command: command.clone(),
                        to_state: to_state.clone(),
                        from_state,
                    });
                }
            }
            _ => {
                return Err(super::not_built_yet(
                    "Lifecycle",
                    gated.row,
                    file,
                    gated.line.number,
                    &gated.call.word,
                ))
            }
        }
    }
}

// Refuses one command reaching two targets from overlapping `from:` states (`None` overlaps all).
// Rows are already expanded one per `from:` state. A `from:` naming an undeclared state is left
// to `hecks model_check`, since a bluebook may exhibit it on purpose. Wording matches Ruby's.
fn refuse_ambiguity(file: &str, line: usize, lifecycle: &ir::Lifecycle) -> ParseResult<()> {
    let mut seen: Vec<(&str, Option<&str>, &str)> = Vec::new();
    for row in &lifecycle.transitions {
        let from = row.from_state.as_deref();
        let earlier = seen.iter().find(|(c, f, t)| {
            *c == row.command && *t != row.to_state && (f.is_none() || from.is_none() || *f == from)
        });
        if let Some((_, _, earlier_target)) = earlier {
            return Err(Diagnostic::new(
                file,
                line,
                format!(
                    "lifecycle :{} declares two transitions for {:?} from the same state (=> {:?} and => {:?}) — \
                     which one fires would be declaration order; give them disjoint from: states",
                    lifecycle.field, row.command, earlier_target, row.to_state
                ),
            ));
        }
        seen.push((&row.command, from, &row.to_state));
    }
    Ok(())
}

// Refuses a `sets` on the lifecycle field and a `from:` on an owner with no lifecycle.
// `owner` is the aggregate or entity name; `line` is the owner's own.
pub fn seal_commands(
    file: &str,
    line: usize,
    owner: &str,
    lifecycle: Option<&ir::Lifecycle>,
    commands: &[ir::Command],
) -> ParseResult<()> {
    for command in commands {
        if let Some(lifecycle) = lifecycle {
            for mutation in &command.mutations {
                let target = match mutation {
                    ir::Mutation::Append { target, .. } => target,
                    ir::Mutation::Other { target, .. } => target,
                    _ => continue,
                };
                if *target == lifecycle.field {
                    return Err(Diagnostic::new(
                        file,
                        line,
                        format!(
                            "{owner}.{} sets {target}, {owner}'s lifecycle field — a lifecycle field moves only by \
                             transition; declare one instead of setting it",
                            command.name
                        ),
                    ));
                }
            }
        }
        let Some(from) = &command.from else { continue };
        let froms: Vec<&String> = match from {
            ir::CommandFrom::Single(s) => vec![s],
            ir::CommandFrom::Multiple(v) => v.iter().collect(),
        };
        if lifecycle.is_none() {
            return Err(Diagnostic::new(
                file,
                line,
                format!(
                    "{owner}.{} guards from: {:?}, but {owner} declares no lifecycle — from: checks a lifecycle \
                     field, and there is none here to check",
                    command.name,
                    froms.iter().map(|s| s.as_str()).collect::<Vec<_>>()
                ),
            ));
        }
    }
    Ok(())
}

fn text_value(raw: &str) -> String {
    match ruby_value::read(raw.trim()) {
        ruby_value::Value::Str(s) => s,
        other => ruby_value::to_s(&other),
    }
}

// Reads `from: "a"` as one state and `from: ["a", "b"]` as a list.
fn from_values(raw: &str) -> Vec<String> {
    let trimmed = raw.trim();
    if trimmed.starts_with('[') && trimmed.ends_with(']') {
        return ruby_value::split_items(&trimmed[1..trimmed.len() - 1])
            .into_iter()
            .map(|item| text_value(&item))
            .collect();
    }
    vec![text_value(trimmed)]
}
