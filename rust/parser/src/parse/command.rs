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
use crate::lex::{self, LineShape, Opener, SourceLine};
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Command.{word}"))
}

/// LIFECYCLE STATE AS A COMMAND GUARD (S10, ADR 0025) — `command "Debit",
/// from: "open"`, read off the CALLER's own argument gate (`aggregate::
/// parse_body`'s / `entity::parse_body`'s own `command` arm — the
/// `from:` keyword sits on the `command` CALL itself, one level above
/// this function's own body-parsing loop, the same reason `owner` is a
/// parameter here rather than something this function reads off its own
/// body). `kind: "literal"` in syntax.bluebook (one state or several,
/// `AggregateBuilder#command`'s own comment) — a bare quoted string or an
/// array literal of them, `ruby_value::read` already distinguishes the
/// two. `None` when the call gave no `from:` at all, matching
/// `CommandBuilder#initialize`'s own `case from when Array ... when nil
/// then nil else from.to_s end` default.
pub fn parse_from(file: &str, line: usize, args: &super::ArgumentGateResult) -> ParseResult<Option<ir::CommandFrom>> {
    let Some(raw) = super::named_raw(args, "from") else { return Ok(None) };
    match ruby_value::read(raw.trim()) {
        ruby_value::Value::Str(s) => Ok(Some(ir::CommandFrom::Single(s))),
        ruby_value::Value::Array(items) => {
            let states: Vec<String> = items
                .into_iter()
                .map(|item| match item {
                    ruby_value::Value::Str(s) => Ok(s),
                    other => Err(Diagnostic::new(file, line, format!("'command's from: names a non-string state ({other:?})"))),
                })
                .collect::<ParseResult<_>>()?;
            Ok(Some(ir::CommandFrom::Multiple(states)))
        }
        other => Err(Diagnostic::new(file, line, format!("'command's from: ({raw}) reads as {other:?}, neither a string nor an array of strings"))),
    }
}

/// NO BLOCK IS A REFERENCE, NOT A FRESH DECLARATION (S10, ADR 0025 —
/// `CommandBuilder#given`'s own comment: "the SAME word, the SAME shape
/// ... minus the block"). `syntax.bluebook` declares exactly ONE keyword
/// row for `given`/Command (`body: "source"`) — unlike `identified_by`,
/// which gets a SECOND `body: "none"` row for its own no-block form —
/// so this is a REAL, CONFIRMED grammar-table gap: the shared
/// `word_gate`/`body_gate` in `parse::mod` would refuse a bare
/// `given("customer is active")` outright ("was written with no body,
/// expected: source"), confirmed live against banking.bluebook's own
/// `Account.OpenAccount` before this function existed. Worked around
/// HERE, locally, rather than by hand-patching the generated
/// `keywords.rs` (which `bin/project_parser_table` would silently
/// overwrite the next time anyone regenerates it from syntax.bluebook —
/// the real fix belongs in that table, one row, mirroring
/// `identified_by`'s own two-row precedent, and is out of this slice's
/// scope: `syntax.bluebook` lives under `lib/`).
///
/// BYTE-EXACT PARITY NEEDS REAL RESOLUTION, not just "parses without
/// erroring" — confirmed by reading `spec/golden/ir/Banking.json`
/// directly: `Account.Credit`'s own bare `given("customer is active")`
/// emits the SAME `canonical: "customer.status == \"active\""` text
/// Account's own aggregate-level precondition declares, not an empty or
/// placeholder canonical. `CommandBuilder#reference_named_given` (Ruby)
/// duplicates the resolved `Given` verbatim into the command's own
/// `givens`; this mirrors that, resolving by `description` against
/// whatever the OWNING aggregate has declared `preconditions` SO FAR —
/// the same textual-order dependency `AggregateBuilder#given`'s own
/// comment names ("DECLARE BEFORE THE COMMANDS THAT REFERENCE IT"),
/// automatically satisfied here since `aggregate::parse_body` hands in
/// its own `preconditions` Vec mid-walk, already containing every
/// `given` parsed earlier in the same source order. An ENTITY's own
/// commands get `&[]` (`EntityBuilder#command` never forwards
/// `named_givens:` at all — Ruby's own `reference_named_given` always
/// raises there), so a bare `given` inside an entity's command fails
/// resolution here too, matching Ruby's refusal.
///
/// Peeks the next physical line WITHOUT consuming it unless it actually
/// matches (word `given`, `Opener::None`) — anything else (including a
/// `given { ... }`/`given do ... end` fresh declaration, or any other
/// word entirely) falls through untouched to the ordinary `next_line`
/// gate below, which already handles it.
fn try_reference_named_given(file: &str, lines: &[SourceLine], pos: &mut usize, preconditions: &[ir::Given]) -> ParseResult<Option<ir::Given>> {
    let Some(&line) = lines.get(*pos) else { return Ok(None) };
    let LineShape::Call(call) = lex::classify(file, &line)? else { return Ok(None) };
    if call.word != "given" || !matches!(call.opener, Opener::None) {
        return Ok(None);
    }

    let args = super::argument_gate(file, "given", "Command", &call.args, line.number)?;
    let description = super::positional_text(file, line.number, "given", &args, 1)?;
    let resolved = preconditions.iter().find(|given| given.description.as_deref() == Some(description.as_str())).cloned().ok_or_else(|| {
        Diagnostic::new(
            file,
            line.number,
            format!(
                "'{description}' names no precondition the owning aggregate declares — declare it \
                 once with a block, before the commands that reference it"
            ),
        )
    })?;

    *pos += 1;
    Ok(Some(resolved))
}

/// Parses a `command "Name" do ... end` body. `owner` is the aggregate
/// (or, on an entity, the entity — not exercised by pizzas.bluebook,
/// which declares every command directly on `Order`) this command is
/// declared on — needed to tell `CommandBuilder#reference_to`'s SELF-
/// reference branch (`reference_to Order` on a command owned by `Order`)
/// from a genuine cross-reference (`as:` given, or the target isn't the
/// owner). `from` — see `parse_from`'s own header — is resolved by the
/// CALLER (off the `command` call's own argument gate) and handed in
/// already-built, the same way `owner` already is. `preconditions` — see
/// `try_reference_named_given`'s own header — is the OWNING aggregate's
/// own `given`s declared so far; always `&[]` for an entity's command.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    owner: &str,
    from: Option<ir::CommandFrom>,
    preconditions: &[ir::Given],
) -> ParseResult<ir::Command> {
    let mut command = ir::Command { name: name.to_string(), from, ..Default::default() };

    loop {
        if let Some(given) = try_reference_named_given(file, lines, pos, preconditions)? {
            command.givens.push(given);
            continue;
        }

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

/// `CommandBuilder#sets` — `to:`/`append:`/`increment:`/`decrement:`
/// names the operation (`Argument#selects`:
/// `op=set`/`op=append`/`op=increment`/`op=decrement`), and `to:` is now
/// OMITTABLE: `sets :status` alone means "set :status from the argument
/// of the same name" — `CommandBuilder#sets`'s own omittable case
/// (`named = { set: target } if named.empty?`). `to:` naming the SAME
/// symbol as the target is refused as redundant — `sets :x` alone
/// already says that.
fn build_mutation(file: &str, line: usize, args: &super::ArgumentGateResult) -> ParseResult<ir::Mutation> {
    let target = super::positional_symbol(file, line, "sets", args, 1)?;

    let named: Vec<(&str, &str)> = [("to", "set"), ("append", "append"), ("increment", "increment"), ("decrement", "decrement")]
        .into_iter()
        .filter_map(|(key, op)| super::named_raw(args, key).map(|raw| (op, raw)))
        .collect();

    if named.len() > 1 {
        return Err(Diagnostic::new(file, line, format!("'sets :{target}' tries more than one operation at once — one mutation, one meaning")));
    }

    // THE OMITTABLE CASE — no named op at all: `sets :target` alone
    // means "set :target from the argument of the same name".
    if named.is_empty() {
        return Ok(ir::Mutation::Other { target: target.clone(), op: "set".to_string(), source: Some(ir::MutationSource::Argument(target)) });
    }

    let (op, raw) = named[0];
    if op == "append" {
        let fields = parse_hash_literal_pairs(raw).into_iter().map(|(k, v)| (k, ruby_value::render(&ruby_value::read(&v)))).collect();
        return Ok(ir::Mutation::Append { target, fields });
    }

    let value = ruby_value::read(raw.trim());
    // `to:` REPEATING THE TARGET, ONLY WHEN IT'S A SYMBOL NAMING A
    // FIELD — a literal (`to: false`, ...) is a VALUE, never a
    // redundant name (`CommandBuilder#sets`'s own `to.is_a?(Symbol)`
    // guard — a bare `false`/`0`/... must never be mistaken for the
    // target's own name).
    if op == "set" {
        if let ruby_value::Value::Symbol(ref name) = value {
            if *name == target {
                return Err(Diagnostic::new(
                    file,
                    line,
                    format!("'sets :{target}, to: :{target}' repeats the target — sets :{target} alone already means the same"),
                ));
            }
        }
    }
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
