//! The `Command` construct: a verb declared on an aggregate or entity.
//! Captures `given`/`ensures` bodies, `sets` mutations, `emits` and `provenance`.

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

/// Reads `from:` on a `command` call: one state string or an array of them, `None` when absent.
pub fn parse_from(
    file: &str,
    line: usize,
    args: &super::ArgumentGateResult,
) -> ParseResult<Option<ir::CommandFrom>> {
    let Some(raw) = super::named_raw(args, "from") else {
        return Ok(None);
    };
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

/// Outcome of a bare `given(...)` lookup. `Pending` marks a chapter-wide placeholder (empty
/// `canonical`) that `parse::chapter::parse_chapter` fills in once every file has loaded.
enum GivenLookup {
    Resolved(ir::Given),
    Pending { precondition_index: usize },
}

/// Resolves a bare `given("description")` against `preconditions`, then `entity_shared_givens`.
/// Consumes the line only when it is a block-less `given`. `syntax.bluebook` has no body-less
/// `given` row, so the shared body gate would refuse it.
fn try_reference_named_given(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    preconditions: &[ir::Given],
    entity_shared_givens: &[ir::Given],
) -> ParseResult<Option<GivenLookup>> {
    let Some(&line) = lines.get(*pos) else {
        return Ok(None);
    };
    let LineShape::Call(call) = lex::classify(file, &line)? else {
        return Ok(None);
    };
    if call.word != "given" || !matches!(call.opener, Opener::None) {
        return Ok(None);
    }

    super::verify_resolves_via(file, line.number, "given", "Command", "hash_chain")?;

    let args = super::argument_gate(file, "given", "Command", &call.args, line.number)?;
    let description = super::positional_text(file, line.number, "given", &args, 1)?;

    // A placeholder needs its index, not just the match, to defer correctly. Shared entity
    // givens never hold one.
    let resolved = if let Some(precondition_index) = preconditions
        .iter()
        .position(|given| given.description.as_deref() == Some(description.as_str()))
    {
        let given = &preconditions[precondition_index];
        if given.canonical.is_empty() {
            GivenLookup::Pending { precondition_index }
        } else {
            GivenLookup::Resolved(given.clone())
        }
    } else if let Some(given) = entity_shared_givens
        .iter()
        .find(|given| given.description.as_deref() == Some(description.as_str()))
    {
        GivenLookup::Resolved(given.clone())
    } else {
        return Err(Diagnostic::new(
            file,
            line.number,
            format!(
                "'{description}' names no precondition the owning aggregate or entity declares, \
                 and no sibling piece under the same aggregate declares it either — declare it \
                 once with a block, before the commands that reference it"
            ),
        ));
    };

    *pos += 1;
    Ok(Some(resolved))
}

/// A bare `given(...)` left pending: `givens[given_index]` is filled from
/// `preconditions[precondition_index]` once the latter resolves.
pub struct PendingCommandGiven {
    pub given_index: usize,
    pub precondition_index: usize,
}

/// Parses a `command "Name" do ... end` body.
/// `owner` tells a self `reference_to` from a cross-reference. `preconditions` and the `owner_*`
/// slices hold what the owner declared so far, so declaration order matters.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    owner: &str,
    from: Option<ir::CommandFrom>,
    preconditions: &[ir::Given],
    entity_shared_givens: &[ir::Given],
    owner_attributes: &[ir::Attribute],
    owner_value_objects: &[ir::ValueObject],
    owner_entities: &[ir::Entity],
) -> ParseResult<(ir::Command, Vec<PendingCommandGiven>)> {
    let mut command = ir::Command {
        name: name.to_string(),
        from,
        ..Default::default()
    };
    // Bare `given(...)` references left unresolved; `parse_chapter` fills them in.
    let mut pending: Vec<PendingCommandGiven> = Vec::new();

    loop {
        if let Some(outcome) =
            try_reference_named_given(file, lines, pos, preconditions, entity_shared_givens)?
        {
            match outcome {
                GivenLookup::Resolved(given) => command.givens.push(given),
                GivenLookup::Pending { precondition_index } => {
                    let given_index = command.givens.len();
                    // Empty canonical is the pending sentinel; `parse_chapter` overwrites it.
                    command.givens.push(ir::Given {
                        description: None,
                        canonical: String::new(),
                    });
                    pending.push(PendingCommandGiven {
                        given_index,
                        precondition_index,
                    });
                }
            }
            continue;
        }

        let Some(gated) = super::next_line(file, lines, pos, "Command")? else {
            resolve_implicit_attributes(
                &mut command,
                owner_attributes,
                owner_value_objects,
                owner_entities,
            );
            refuse_duplicate_targets(file, *pos, &command)?;
            refuse_undeclared_needs(file, *pos, &command)?;
            return Ok((command, pending));
        };
        let line = gated.line.number;

        match gated.row.word {
            "role" => {
                command.role = Some(super::positional_text(file, line, "role", &gated.args, 1)?)
            }
            "goal" => {
                command.goal = Some(super::positional_text(file, line, "goal", &gated.args, 1)?)
            }
            // A synthesized inline `one_of(...)` closed set is dropped; `CommandBuilder#build`
            // ignores it.
            "attribute" => command
                .attributes
                .push(super::build_attribute(file, line, "attribute", &gated.args)?.0),
            // `emits` takes a constant argument; see `parse/policy.rs` for the transform.
            "emits" => command.emits.push(super::positional_command_ref(
                file,
                line,
                "emits",
                &gated.args,
                1,
            )?),
            "reference_to" => apply_reference_to(file, line, &gated.args, owner, &mut command)?,
            "given" => {
                let description = super::positional_text(file, line, "given", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                command.givens.push(ir::Given {
                    description: Some(description),
                    canonical: canonical::apply(&raw),
                });
            }
            "ensures" => {
                let description = super::positional_text(file, line, "ensures", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                command.ensures.push(ir::Given {
                    description: Some(description),
                    canonical: canonical::apply(&raw),
                });
            }
            "needs" => {
                let fact = super::positional_symbol(file, line, "needs", &gated.args, 1)?;
                if !NEEDABLE_FACTS.contains(&fact.as_str()) {
                    return Err(Diagnostic::new(
                        file,
                        line,
                        format!(
                            "{} needs :{fact}, which the runtime cannot supply — it supplies :now",
                            command.name
                        ),
                    ));
                }
                if command.needs.contains(&fact) {
                    return Err(Diagnostic::new(
                        file,
                        line,
                        format!("{} declares needs :{fact} twice", command.name),
                    ));
                }
                command.needs.push(fact);
            }
            "provenance" => {
                let raw = super::named_raw(&gated.args, "from")
                    .ok_or_else(|| Diagnostic::new(file, line, "'provenance' requires a from:"))?;
                command.provenance = Some(ruby_value::read(raw.trim()));
            }
            "sets" => command
                .mutations
                .push(build_mutation(file, line, &gated.args)?),
            "delegates_to" => command
                .mutations
                .push(build_delegation(file, line, &gated.args)?),
            "corrects" => command
                .mutations
                .push(build_correction(file, line, &gated.args)?),
            _ => {
                return Err(super::not_built_yet(
                    "Command",
                    gated.row,
                    file,
                    line,
                    &gated.call.word,
                ))
            }
        }
    }
}

/// Imports owner attributes for bare `sets :field` and `append:` mutations.
/// Planned first, applied second, so `mutations` is only read while `attributes` is mutated.
fn resolve_implicit_attributes(
    command: &mut ir::Command,
    owner_attributes: &[ir::Attribute],
    owner_value_objects: &[ir::ValueObject],
    owner_entities: &[ir::Entity],
) {
    enum Job {
        BareSet(String),
        Append {
            target: String,
            fields: Vec<(String, String)>,
        },
    }

    let jobs: Vec<Job> = command
        .mutations
        .iter()
        .filter_map(|mutation| match mutation {
            ir::Mutation::Other {
                target,
                op,
                source: Some(ir::MutationSource::Argument(name)),
                ..
            } if op == "set" && name == target => Some(Job::BareSet(target.clone())),
            ir::Mutation::Append { target, fields } => Some(Job::Append {
                target: target.clone(),
                fields: fields.clone(),
            }),
            _ => None,
        })
        .collect();

    for job in jobs {
        match job {
            Job::BareSet(target) => {
                resolve_bare_set(&mut command.attributes, &target, owner_attributes)
            }
            Job::Append { target, fields } => resolve_append_fields(
                &mut command.attributes,
                &target,
                &fields,
                owner_attributes,
                owner_value_objects,
                owner_entities,
            ),
        }
    }
}

/// Reads `state(:name)`, the exact spelling `Literal.read` recognises.
fn state_ref(raw: &str) -> Option<String> {
    let inner = raw.strip_prefix("state(:")?.strip_suffix(')')?;
    let mut chars = inner.chars();
    let first = chars.next()?;
    if !(first.is_ascii_alphabetic() || first == '_') {
        return None;
    }
    if !chars.all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    Some(inner.to_string())
}

/// The outside facts a command may declare it needs; mirrors `CommandBuilder::NEEDABLE_FACTS`.
const NEEDABLE_FACTS: &[&str] = &["now"];

/// A need names the attribute the runtime fills, so the command must declare it.
fn refuse_undeclared_needs(file: &str, line: usize, command: &ir::Command) -> ParseResult<()> {
    match command
        .needs
        .iter()
        .find(|fact| !command.attributes.iter().any(|a| &a.name == *fact))
    {
        Some(fact) => Err(Diagnostic::new(
            file,
            line,
            format!(
                "{} needs :{fact} but declares no attribute :{fact} for the runtime to fill — add `attribute :{fact}, <type>`",
                command.name
            ),
        )),
        None => Ok(()),
    }
}

/// Refuses a field written twice: a command's effects are one update set (C4.2).
/// `delegates_to`/`corrects` name no field and are not counted.
fn refuse_duplicate_targets(file: &str, line: usize, command: &ir::Command) -> ParseResult<()> {
    let mut seen: Vec<(&str, &str)> = Vec::new();
    for mutation in &command.mutations {
        let (target, op) = match mutation {
            ir::Mutation::Append { target, .. } => (target.as_str(), "append"),
            ir::Mutation::Other { target, op, .. } => (target.as_str(), op.as_str()),
            _ => continue,
        };
        if let Some((_, earlier)) = seen.iter().find(|(t, _)| *t == target) {
            return Err(Diagnostic::new(
                file,
                line,
                format!(
                    "{} writes {target} twice ({earlier} and {op}) — a command's effects are one update set over \
                     the pre-dispatch state, so each field is written at most once",
                    command.name
                ),
            ));
        }
        seen.push((target, op));
    }
    Ok(())
}

/// Bare `sets :field` imports the owner's `Attribute` unless the command already declares it.
/// Only the self-referential set qualifies, and the owner must have declared the attribute
/// earlier in the source.
fn resolve_bare_set(
    attributes: &mut Vec<ir::Attribute>,
    target: &str,
    owner_attributes: &[ir::Attribute],
) {
    if attributes.iter().any(|attr| attr.name == target) {
        return;
    }
    if let Some(owner_attr) = owner_attributes.iter().find(|attr| attr.name == target) {
        attributes.push(owner_attr.clone());
    }
}

/// Finds the attributes of the owner's list element type, in value objects then entities.
fn element_type_attributes<'a>(
    list_field: &str,
    owner_attributes: &[ir::Attribute],
    owner_value_objects: &'a [ir::ValueObject],
    owner_entities: &'a [ir::Entity],
) -> Option<&'a [ir::Attribute]> {
    let list_attr = owner_attributes
        .iter()
        .find(|attr| attr.name == list_field && attr.list)?;

    if let Some(vo) = owner_value_objects
        .iter()
        .find(|vo| vo.name == list_attr.type_name)
    {
        return Some(&vo.attributes);
    }
    owner_entities
        .iter()
        .find(|entity| entity.name == list_attr.type_name)
        .map(|entity| entity.attributes.as_slice())
}

/// Resolves self-referential fields of `sets :list, append: { field: :field }` against the
/// list element's construct. The exported IR is array-order-sensitive, so the group is
/// reinserted where its leftmost declared member sat, or at the end.
fn resolve_append_fields(
    attributes: &mut Vec<ir::Attribute>,
    target: &str,
    fields: &[(String, String)],
    owner_attributes: &[ir::Attribute],
    owner_value_objects: &[ir::ValueObject],
    owner_entities: &[ir::Entity],
) {
    let Some(element_attrs) = element_type_attributes(
        target,
        owner_attributes,
        owner_value_objects,
        owner_entities,
    ) else {
        return;
    };

    let self_ref_fields: Vec<&str> = fields
        .iter()
        .filter(|(field, value)| *value == format!(":{field}"))
        .map(|(field, _)| field.as_str())
        .collect();
    if self_ref_fields.is_empty() {
        return;
    }

    let present: Vec<ir::Attribute> = self_ref_fields
        .iter()
        .filter_map(|field| attributes.iter().find(|attr| attr.name == *field).cloned())
        .collect();
    if present.len() == self_ref_fields.len() {
        return; // already fully declared — nothing to resolve
    }

    let anchor = if present.is_empty() {
        attributes.len()
    } else {
        present
            .iter()
            .filter_map(|attr| attributes.iter().position(|a| a.name == attr.name))
            .min()
            .unwrap_or(attributes.len())
    };

    attributes.retain(|attr| !present.iter().any(|p| p.name == attr.name));

    let group: Vec<ir::Attribute> = self_ref_fields
        .iter()
        .filter_map(|field| {
            present
                .iter()
                .find(|attr| attr.name == *field)
                .cloned()
                .or_else(|| {
                    element_attrs
                        .iter()
                        .find(|attr| attr.name == *field)
                        .cloned()
                })
        })
        .collect();

    let insert_at = anchor.min(attributes.len());
    attributes.splice(insert_at..insert_at, group);
}

/// `reference_to`: a self-reference when there is no `as:` and the target is the owner,
/// otherwise a cross-reference attribute.
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
        command.attributes.push(references::reference_attribute(
            &target,
            as_name.as_deref(),
            optional,
        ));
        return Ok(());
    }

    if command.references.is_some() {
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "{}'s command references {owner} twice — a command acts on ONE root",
                command.name
            ),
        ));
    }
    command.references = Some(target);
    Ok(())
}

/// Builds a `sets` mutation. The named argument selects the op; the list must stay in step
/// with the ArgumentRow table in `keywords.rs`. Bare `sets :x` sets `:x` from the same-named
/// argument, and `to: :x` on `:x` is refused as redundant. `clamp:` takes a literal `[min, max]`.
fn build_mutation(
    file: &str,
    line: usize,
    args: &super::ArgumentGateResult,
) -> ParseResult<ir::Mutation> {
    let target = super::positional_symbol(file, line, "sets", args, 1)?;

    let named: Vec<(&str, &str)> = [
        ("to", "set"),
        ("append", "append"),
        ("increment", "increment"),
        ("decrement", "decrement"),
        ("multiply", "multiply"),
        ("clamp", "clamp"),
        ("remove", "remove"),
    ]
    .into_iter()
    .filter_map(|(key, op)| super::named_raw(args, key).map(|raw| (op, raw)))
    .collect();

    if named.len() > 1 {
        return Err(Diagnostic::new(file, line, format!("'sets :{target}' tries more than one operation at once — one mutation, one meaning")));
    }

    // No named op: `sets :target` alone sets it from the same-named argument.
    if named.is_empty() {
        return Ok(ir::Mutation::Other {
            target: target.clone(),
            op: "set".to_string(),
            sign: mutation_sign("set").to_string(),
            source: Some(ir::MutationSource::Argument(target)),
        });
    }

    let (op, raw) = named[0];
    if op == "append" {
        let fields = parse_hash_literal_pairs(raw)
            .into_iter()
            .map(|(k, v)| (k, ruby_value::render(&ruby_value::read(&v))))
            .collect();
        return Ok(ir::Mutation::Append { target, fields });
    }

    let value = ruby_value::read(raw.trim());
    // `to:` repeating the target is redundant only for a symbol; a literal such as
    // `to: false` is a value.
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
    // `state(:field)` is the record's own field, neither argument nor literal; classified
    // before the Symbol/literal split.
    let source = match state_ref(raw.trim()) {
        Some(name) => ir::MutationSource::State(name),
        None => match value {
            ruby_value::Value::Symbol(name) => ir::MutationSource::Argument(name),
            other => ir::MutationSource::Literal(other),
        },
    };
    Ok(ir::Mutation::Other {
        target,
        op: op.to_string(),
        sign: mutation_sign(op).to_string(),
        source: Some(source),
    })
}

/// `delegates_to "Entity.Command", with: { key: :arg }`: a passthrough mutation.
/// An absent `with:` means no fields; a target that is not dotted is refused.
fn build_delegation(
    file: &str,
    line: usize,
    args: &super::ArgumentGateResult,
) -> ParseResult<ir::Mutation> {
    let target = super::positional_text(file, line, "delegates_to", args, 1)?;
    let (entity_name, command_name) = target.rsplit_once('.').unwrap_or(("", ""));
    if entity_name.is_empty() || command_name.is_empty() {
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "'delegates_to {target:?}' does not name an entity and a command (\"Entity.Command\") — \
                 the same one-hop shape a bare given reference already uses"
            ),
        ));
    }

    let fields = match super::named_raw(args, "with") {
        Some(raw) => parse_hash_literal_pairs(raw)
            .into_iter()
            .map(|(k, v)| (k, ruby_value::render(&ruby_value::read(&v))))
            .collect(),
        None => Vec::new(),
    };
    Ok(ir::Mutation::Delegate { target, fields })
}

/// `corrects "Event", as: :binding, reason: "...", reverses: true`, gathered into one `fields`
/// list. `as:` renders as a quoted string (a bare Symbol would mean an attribute reference)
/// and an absent one renders `nil`.
fn build_correction(
    file: &str,
    line: usize,
    args: &super::ArgumentGateResult,
) -> ParseResult<ir::Mutation> {
    let target = super::positional_text(file, line, "corrects", args, 1)?;
    let reason = super::named_text(args, "reason").unwrap_or_default();
    if reason.trim().is_empty() {
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "'corrects {target:?}' names no reason — a correction is carried as \
                 data (an audit trail needs to say WHY), the same way a given's own \
                 description must say something"
            ),
        ));
    }

    let as_field = match super::named_symbol(args, "as") {
        Some(name) => ruby_value::render(&ruby_value::Value::Str(name)),
        None => "nil".to_string(),
    };
    let reverses = if super::named_flag(args, "reverses") { "true" } else { "false" };

    let fields = vec![
        ("as".to_string(), as_field),
        ("reason".to_string(), ruby_value::render(&ruby_value::Value::Str(reason))),
        ("reverses".to_string(), reverses.to_string()),
    ];
    Ok(ir::Mutation::Correction { target, fields })
}

// Fixed signs of `Vocabulary::MutationOp`; see `ir::Mutation::Other`.
fn mutation_sign(op: &str) -> &'static str {
    match op {
        "increment" => "1",
        "decrement" => "-1",
        _ => "",
    }
}

/// `{ name: :topping, amount: :amount }` -> `[("name", ":topping"), ("amount", ":amount")]`,
/// in written order. Braces are kept: the lexer opens a block only at paren-depth zero.
fn parse_hash_literal_pairs(text: &str) -> Vec<(String, String)> {
    let trimmed = text.trim();
    let inner = trimmed
        .strip_prefix('{')
        .and_then(|s| s.strip_suffix('}'))
        .unwrap_or(trimmed);
    ruby_value::split_items(inner)
        .into_iter()
        .filter_map(|segment| {
            super::as_named(&segment).map(|(k, v)| (k.to_string(), v.to_string()))
        })
        .collect()
}
