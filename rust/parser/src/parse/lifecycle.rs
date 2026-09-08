//! The `Lifecycle` construct (`lib/hecks/bluebook/ir/lifecycle.rb`).
//! NOT a category of its own in `syntax.bluebook`'s `Keyword.opens` column
//! — it's a DECLARED FOLD onto whichever of `Aggregate`/`Entity` opened it
//! (`lifecycle`'s own row: `opens: ""`, `fills: "state_field"`); Stage 2+
//! folding logic has to land the built `Lifecycle` on the ENCLOSING
//! record rather than treat it as independent. `parse::walk_body` still
//! recurses into `Lifecycle` context the same way any other `do`-body
//! does — real gating for every `transition` line inside — and reports
//! this module's own stub once that's done, since Stage 1 builds nothing
//! regardless of which record a construct eventually folds onto.
//! Stage 2+ work: `transition ... from: [...]` list expansion (see the
//! Ruby source's own `expand`).

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Lifecycle.{word}"))
}

/// Parses a `lifecycle :field, default: "..." do ... end` body — `field`/
/// `default` are already read at the ENCLOSING (Aggregate/Entity)
/// context, since `lifecycle`'s own header line is gated there (`opens:
/// ""` — this is a fold, not its own category, per this module's own
/// header).
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

/// `LifecycleBuilder#refuse_ambiguity!` — C5.3 (docs/semantics/
/// bluebook-semantics.md): two transitions for one command whose `from:`
/// sets overlap (or where either has no `from:`) were silently
/// first-wins; refused once the state machine can be read whole. Rows
/// are already EXPANDED one per `from:` state, so an overlap is one
/// command reaching two different targets from one `from_state` (`None`
/// overlaps everything). A `from:` naming a state nothing declares is
/// NOT refused — that is a `bin/model_check` reachability finding a
/// bluebook may exhibit on purpose. Same wording as Ruby's.
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

/// `AggregateBuilder::Sealing#seal_lifecycle_guards` + the lifecycle half
/// of `#seal_mutation_targets` (and `EntityBuilder`'s twins) — C5.3: a
/// `sets` on the lifecycle field is refused, and a `from:` on an owner
/// with no lifecycle at all. `owner` is the aggregate or entity name;
/// `line` the owner's own.
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

/// `from: "available"` (one state) or `from: ["available", "pending"]`
/// (several, list-expanded — `transition ... from: [...]`, the plan's own
/// named Stage 2+ derivation, mirroring `Lifecycle#expand`'s `Array(
/// transition.from)`). Not exercised by pizzas.bluebook (its one
/// transition names a single `from:`), implemented anyway since both
/// forms are one small function.
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
