//! The `Command` construct (`lib/hecksagain/bluebook/ir/command.rb`) — a
//! verb declared on an aggregate or entity. `given` source-body capture
//! through canonical.rs (BOTH spellings — `{ ... }` and `do ... end`, see
//! `parse::mod::source_body_text`'s own header), `sets`' four named forms
//! (`to`/`append`/`increment`/`decrement`, the op-selection column
//! `Argument#selects` names), and `emits` list capture. STAGE 4 adds
//! `ensures` (the postcondition sibling of `given`, identical `source`-body
//! shape and canonicalization — confirmed real: `Account.Debit`'s own two
//! `ensures`, `ScheduledPayment.Retry`'s one) and `provenance` (identical
//! raw-Hash-capture shape to `AggregateBuilder#provenance`, one level down
//! — not exercised by any real corpus command yet, kept correct anyway).

use crate::build::naming;
use crate::build::references;
use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Command.{word}"))
}

/// Parses a `command "Name" do ... end` body. `owner` is the aggregate
/// (or, on an entity, the entity — not exercised by pizzas.bluebook,
/// which declares every command directly on `Order`) this command is
/// declared on — needed to tell `CommandBuilder#reference_to`'s SELF-
/// reference branch (`reference_to Order` on a command owned by `Order`)
/// from a genuine cross-reference (`as:` given, or the target isn't the
/// owner).
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str, owner: &str) -> ParseResult<ir::Command> {
    let mut command = ir::Command { name: name.to_string(), ..Default::default() };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Command")? else {
            return Ok(command);
        };
        let line = gated.line.number;

        match gated.row.word {
            "role" => command.role = Some(super::positional_text(file, line, "role", &gated.args, 1)?),
            "goal" => command.goal = Some(super::positional_text(file, line, "goal", &gated.args, 1)?),
            // A synthesized inline `one_of(...)` closed set is discarded
            // here on purpose — `CommandBuilder#build` never reads
            // `AttributeCollector#closed_sets`, confirmed by reading it
            // directly (`build/closed_sets.rs`'s own header names this
            // caller specifically). The attribute's own `type_name` is
            // already the right Pascal-cased name either way.
            "attribute" => command.attributes.push(super::build_attribute(file, line, "attribute", &gated.args)?.0),
            "emits" => command.emits.push(super::positional_text(file, line, "emits", &gated.args, 1)?),
            "reference_to" => apply_reference_to(file, line, &gated.args, owner, &mut command)?,
            "given" => {
                let description = super::positional_text(file, line, "given", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                command.givens.push(ir::Given { description: Some(description), canonical: canonical::apply(&raw) });
            }
            "ensures" => {
                let description = super::positional_text(file, line, "ensures", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                command.ensures.push(ir::Given { description: Some(description), canonical: canonical::apply(&raw) });
            }
            "provenance" => {
                let raw = super::named_raw(&gated.args, "from")
                    .ok_or_else(|| Diagnostic::new(file, line, "'provenance' requires a from:"))?;
                command.provenance = Some(ruby_value::read(raw.trim()));
            }
            "sets" => command.mutations.push(build_mutation(file, line, &gated.args)?),
            _ => return Err(super::not_built_yet("Command", gated.row, file, line, &gated.call.word)),
        }
    }
}

/// `CommandBuilder#reference_to` — SELF (`@references =`) when no `as:`
/// was given AND the target's bare name equals the owner; otherwise a
/// genuine CROSS-reference attribute (`build/references.rs`, the same
/// mint every other `reference_to` caller shares).
fn apply_reference_to(
    file: &str,
    line: usize,
    args: &super::ArgumentGateResult,
    owner: &str,
    command: &mut ir::Command,
) -> ParseResult<()> {
    let target_raw = super::positional_constant(file, line, "reference_to", args, 1)?;
    let target = naming::demodulise(target_raw);
    let as_name = super::named_symbol(args, "as");
    let optional = super::named_flag(args, "optional");

    if as_name.is_some() || target != owner {
        command.attributes.push(references::reference_attribute(&target, as_name.as_deref(), optional));
        return Ok(());
    }

    if command.references.is_some() {
        return Err(Diagnostic::new(
            file,
            line,
            format!("{}'s command references {owner} twice — a command acts on ONE root", command.name),
        ));
    }
    command.references = Some(target);
    Ok(())
}

/// `CommandBuilder#then_set`/`sets` — exactly one of `to:`/`append:`/
/// `increment:`/`decrement:` names the operation (`Argument#selects`:
/// `op=set`/`op=append`/`op=increment`/`op=decrement`).
fn build_mutation(file: &str, line: usize, args: &super::ArgumentGateResult) -> ParseResult<ir::Mutation> {
    let target = super::positional_symbol(file, line, "sets", args, 1)?;

    let named: Vec<(&str, &str)> = [("to", "set"), ("append", "append"), ("increment", "increment"), ("decrement", "decrement")]
        .into_iter()
        .filter_map(|(key, op)| super::named_raw(args, key).map(|raw| (op, raw)))
        .collect();

    if named.is_empty() {
        return Err(Diagnostic::new(file, line, format!("'sets :{target}' names no operation — give it to:, append:, increment:, or decrement:")));
    }
    if named.len() > 1 {
        return Err(Diagnostic::new(file, line, format!("'sets :{target}' tries more than one operation at once — one mutation, one meaning")));
    }

    let (op, raw) = named[0];
    if op == "append" {
        let fields = parse_hash_literal_pairs(raw).into_iter().map(|(k, v)| (k, ruby_value::render(&ruby_value::read(&v)))).collect();
        return Ok(ir::Mutation::Append { target, fields });
    }

    let value = ruby_value::read(raw.trim());
    let source = match value {
        ruby_value::Value::Symbol(name) => ir::MutationSource::Argument(name),
        other => ir::MutationSource::Literal(other),
    };
    Ok(ir::Mutation::Other { target, op: op.to_string(), source: Some(source) })
}

/// `{ name: :topping, amount: :amount }` -> `[("name", ":topping"),
/// ("amount", ":amount")]`, in WRITTEN order — Ruby Hash literal syntax,
/// braces included (this is an ARGUMENT VALUE, not a `source`-shaped
/// block: the lexer only treats a `{` as an opener at paren-depth zero,
/// and this one sits inside `sets`'s own parens).
fn parse_hash_literal_pairs(text: &str) -> Vec<(String, String)> {
    let trimmed = text.trim();
    let inner = trimmed.strip_prefix('{').and_then(|s| s.strip_suffix('}')).unwrap_or(trimmed);
    ruby_value::split_items(inner)
        .into_iter()
        .filter_map(|segment| super::as_named(&segment).map(|(k, v)| (k.to_string(), v.to_string())))
        .collect()
}
