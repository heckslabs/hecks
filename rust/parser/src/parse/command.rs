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
/// whatever the OWNING aggregate OR ENTITY has declared `preconditions`
/// SO FAR — the same textual-order dependency `AggregateBuilder#given`'s
/// own comment names ("DECLARE BEFORE THE COMMANDS THAT REFERENCE IT"),
/// automatically satisfied here since both `aggregate::parse_body` and
/// `entity::parse_body` hand in their OWN `preconditions` Vec mid-walk,
/// already containing every `given` parsed earlier in the same source
/// order (ADR 0028 gave entities their own `preconditions`, superseding
/// the entity-commands-always-refuse behavior this comment used to
/// describe). `entity_shared_givens` is the SECOND, cross-entity fallback
/// (`docs/resolution-rules/cross-entity-given.md`) — always empty for an
/// aggregate-owned command.
///
/// Peeks the next physical line WITHOUT consuming it unless it actually
/// matches (word `given`, `Opener::None`) — anything else (including a
/// `given { ... }`/`given do ... end` fresh declaration, or any other
/// word entirely) falls through untouched to the ordinary `next_line`
/// gate below, which already handles it.
/// `entity_shared_givens` — the cross-entity fallback pool
/// `docs/resolution-rules/cross-entity-given.md` names, and
/// `parse::entity`'s own header explains the threading of. Checked
/// SECOND, only after `preconditions` (this command's own direct owner)
/// comes up empty — via `.chain(...)`, the same priority Ruby's own
/// `@named_givens[description] || @entity_shared_givens[description]`
/// gives (own owner wins; the two never actually collide in practice,
/// since a piece's OWN `preconditions` and its aggregate's shared pool
/// are populated from disjoint declaration sites, but the order still
/// matches). Always `&[]` from `parse::aggregate`'s own call — an
/// aggregate-owned command has no sibling PIECE to reach across.
fn try_reference_named_given(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    preconditions: &[ir::Given],
    entity_shared_givens: &[ir::Given],
) -> ParseResult<Option<ir::Given>> {
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
    let resolved = preconditions
        .iter()
        .chain(entity_shared_givens.iter())
        .find(|given| given.description.as_deref() == Some(description.as_str()))
        .cloned()
        .ok_or_else(|| {
            Diagnostic::new(
                file,
                line.number,
                format!(
                    "'{description}' names no precondition the owning aggregate or entity declares, \
                     and no sibling piece under the same aggregate declares it either — declare it \
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
/// `owner_attributes` — `CommandBuilder#initialize`'s own
/// `owner_attributes:` — the OWNING aggregate's (or entity's) own
/// `attribute`s declared so far (textual order — the same ordering
/// caveat `preconditions` already carries), used by
/// `resolve_implicit_attributes` below once this command's own body is
/// fully parsed. `owner_value_objects`/`owner_entities` —
/// `CommandBuilder#initialize`'s own `owner_constructs:` (split into its
/// two real kinds here rather than kept as one mixed Vec the way Ruby's
/// duck-typed `hecks_name`/`attributes` lets it stay — `AggregateBuilder#
/// command`'s own `@value_objects + closed_sets + @entities`,
/// `EntityBuilder#command`'s own `@owner_value_objects + @entities`, both
/// SO-FAR slices the same way `owner_attributes` already is) — the owner's
/// own constructs (value objects, then entities), used by
/// `resolve_append_fields` to resolve an `append:` mutation's own list
/// field element type.
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
) -> ParseResult<ir::Command> {
    let mut command = ir::Command {
        name: name.to_string(),
        from,
        ..Default::default()
    };

    loop {
        if let Some(given) =
            try_reference_named_given(file, lines, pos, preconditions, entity_shared_givens)?
        {
            command.givens.push(given);
            continue;
        }

        let Some(gated) = super::next_line(file, lines, pos, "Command")? else {
            resolve_implicit_attributes(
                &mut command,
                owner_attributes,
                owner_value_objects,
                owner_entities,
            );
            return Ok(command);
        };
        let line = gated.line.number;

        match gated.row.word {
            "role" => {
                command.role = Some(super::positional_text(file, line, "role", &gated.args, 1)?)
            }
            "goal" => {
                command.goal = Some(super::positional_text(file, line, "goal", &gated.args, 1)?)
            }
            // A synthesized inline `one_of(...)` closed set is discarded
            // here on purpose — `CommandBuilder#build` never reads
            // `AttributeCollector#closed_sets`, confirmed by reading it
            // directly (`build/closed_sets.rs`'s own header names this
            // caller specifically). The attribute's own `type_name` is
            // already the right Pascal-cased name either way.
            "attribute" => command
                .attributes
                .push(super::build_attribute(file, line, "attribute", &gated.args)?.0),
            "emits" => {
                command
                    .emits
                    .push(super::positional_text(file, line, "emits", &gated.args, 1)?)
            }
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

/// `CommandBuilder#resolve_implicit_attributes!` — dispatches each
/// mutation, IN ITS OWN DECLARED ORDER, to the resolver matching its own
/// op (`:set` -> `resolve_bare_set`, `:append` -> `resolve_append_fields`
/// below), the same `case mutation.op when :set ... when :append ...`
/// Ruby runs. Built as a two-pass plan (collect what each mutation needs
/// FIRST, over an immutable borrow of `command.mutations`; mutate
/// `command.attributes` SECOND) rather than mutating mid-iteration —
/// `command.mutations` is read-only throughout this function, so nothing
/// about the two-pass split changes behavior; it exists only so the
/// borrow checker can see `mutations` and `attributes` (disjoint fields
/// of the same `Command`) mutated separately, matching Ruby's own
/// single-pass loop exactly in effect.
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

/// `CommandBuilder#resolve_bare_set!` — `sets :field` ALONE (the
/// omittable case `build_mutation` below already resolves into
/// `Mutation::Other { op: "set", source: Some(MutationSource::
/// Argument(target)) }`, target == source by construction) already says
/// the command accepts an argument named `:field`; requiring a SEPARATE
/// `attribute :field, ...` line that retypes what the owning
/// aggregate/entity already declared is the same redundancy S10's
/// `given` reference already killed for preconditions. When the command
/// hasn't declared its own `:field`, import the OWNER's already-parsed
/// `Attribute` verbatim (same `type_name`/`list`/`default`/`optional`/
/// `pattern`/`admits` — every field `ir::Attribute` carries) instead of
/// retyping it.
///
/// Only the exact self-referential shape qualifies — `sets :field, to:
/// :other` names a genuinely different source and stays exactly as
/// explicit as it always was; `sets :field, to: :field` is refused
/// outright by `build_mutation` before this ever runs (never reaches
/// `command.mutations` in the first place), and `sets :field, to: false`
/// (or any other literal) isn't naming an argument at all — `source` is
/// `MutationSource::Literal`, not `Argument`, so it never matches here.
///
/// Declaration order matters here the same way it already does for
/// `identified_by`/`given` — the owner's own attribute must already
/// exist in `owner_attributes` by the time THIS function runs, which
/// every real bluebook already satisfies (the aggregate/entity always
/// declares its attributes before the commands that act on them) and
/// which `aggregate::parse_body`/`entity::parse_body` both guarantee by
/// handing in their own `attributes` Vec mid-walk.
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

/// The owner's own LIST attribute names its element type as TEXT
/// (`Attribute.type_name`, already unwrapped from `list_of(...)` at
/// `parse::mod::resolve_type_expression`'s own `list_of` arm — the bare
/// inner constant, never re-wrapped the way a reference's own
/// `Reference<Target>` spelling is) — resolved against the owner's own
/// constructs (value objects THEN entities, matching `AggregateBuilder#
/// command`'s own `@value_objects + closed_sets + @entities` order) by
/// name. `CommandBuilder#element_type_for`'s own mirror.
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

/// `CommandBuilder#resolve_append_fields!` — ONE HOP DEEPER than
/// `resolve_bare_set` above: `sets :ledger, append: { narrative:
/// :narrative, ... }` builds a NEW element of a LIST field, so a bare
/// self-referential field inside it (hash key equals its own value,
/// `":field"` after rendering — see `ruby_value::render`'s own `Symbol`
/// arm — the same shorthand `resolve_bare_set` already reads) resolves
/// against the list field's own ELEMENT construct
/// (`element_type_attributes` above), not `owner_attributes` directly —
/// the owner itself never stores `:narrative`, only the list element's
/// own construct does.
///
/// POSITION-PRESERVING, not appended at the end — the exported IR is
/// array-order-sensitive, so this mutation's own fields are resolved as
/// ONE CONTIGUOUS GROUP, in the mutation's own hash order, reinserted at
/// whichever position the group's leftmost STILL-DECLARED member already
/// occupies (or the end, if every member of the group is resolved). The
/// `anchor` index is computed BEFORE any removal — nothing removed sits
/// before it (it is the MIN index among the removed set), so it is
/// already the correct insertion index into the POST-removal array with
/// no adjustment needed; the Ruby method's own comment gives the full
/// "why not append at the end" rationale (`Keyword#was`/`Argument#
/// variadic` only ever looked correct because they happened to already
/// be last).
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

/// `CommandBuilder#sets` — `to:`/`append:`/`increment:`/`decrement:`/
/// `multiply:`/`clamp:`/`remove:` names the operation (`Argument#selects`:
/// `op=set`/`op=append`/`op=increment`/`op=decrement`/`op=multiply`/
/// `op=clamp`/`op=remove` — `keywords.rs`'s own ArgumentRow table already
/// declares all seven ; this list is the piece that actually reads them,
/// so it has to stay in step by hand), and `to:` is now
/// OMITTABLE: `sets :status` alone means "set :status from the argument
/// of the same name" — `CommandBuilder#sets`'s own omittable case
/// (`named = { set: target } if named.empty?`). `to:` naming the SAME
/// symbol as the target is refused as redundant — `sets :x` alone
/// already says that.
///
/// `multiply:`/`clamp:`/`remove:` — vendored additions (command_builder.rb's
/// own header comment: "not (yet) upstream hecksagain"). `multiply:` reads
/// exactly like `increment:`/`decrement:` (an argument reference, resolved
/// through the SAME Symbol-vs-Literal branch below). `clamp:`'s own source
/// is always a literal `[min, max]` pair — `ruby_value::read` already parses
/// an Array literal (see ruby_value.rs's own `read("[1, 2]")` test), so no
/// special case is needed beyond naming the op. `remove:` matches an
/// element by VALUE, sourced the same single-argument-or-literal way
/// increment/decrement/multiply already are.
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

    // THE OMITTABLE CASE — no named op at all: `sets :target` alone
    // means "set :target from the argument of the same name".
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
    Ok(ir::Mutation::Other {
        target,
        op: op.to_string(),
        sign: mutation_sign(op).to_string(),
        source: Some(source),
    })
}

/// `CommandBuilder#delegates_to_impl` — `delegates_to "Entity.Command",
/// with: { key: :arg, ... }`, a pure-passthrough mutation whose `target`
/// is a DOTTED "Entity.Command" string (`kind: "text"`, positional 1 —
/// `keywords.rs`'s own ArgumentRow for this word, unlike `sets`'s bare
/// Symbol target) rather than an attribute name, and whose `with:` reads
/// the SAME hash-literal shape `sets ..., append: {...}` already does
/// (`parse_hash_literal_pairs`, reused verbatim — both are `kind:
/// "literal"` named arguments carrying a Ruby Hash of Symbol keys to
/// Symbol/literal values). `with:` is omittable (Ruby's own `with: {}`
/// default), so an absent one is simply no fields, not an error.
///
/// The "Entity.Command" shape check mirrors `delegates_to_impl`'s own
/// `entity_name, _dot, command_name = target.to_s.rpartition(".")` guard
/// — refused here the same way a malformed target is refused in Ruby,
/// even though the one real fixture (`delegates_to.bluebook`) never
/// exercises the error path.
fn build_delegation(file: &str, line: usize, args: &super::ArgumentGateResult) -> ParseResult<ir::Mutation> {
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
        Some(raw) => parse_hash_literal_pairs(raw).into_iter().map(|(k, v)| (k, ruby_value::render(&ruby_value::read(&v)))).collect(),
        None => Vec::new(),
    };
    Ok(ir::Mutation::Delegate { target, fields })
}

// `Vocabulary::MutationOp`'s own fixed values, read directly — see
// `ir::Mutation::Other`'s own header for why this parser computes the
// fact itself rather than reading a table.
fn mutation_sign(op: &str) -> &'static str {
    match op {
        "increment" => "1",
        "decrement" => "-1",
        _ => "",
    }
}

/// `{ name: :topping, amount: :amount }` -> `[("name", ":topping"),
/// ("amount", ":amount")]`, in WRITTEN order — Ruby Hash literal syntax,
/// braces included (this is an ARGUMENT VALUE, not a `source`-shaped
/// block: the lexer only treats a `{` as an opener at paren-depth zero,
/// and this one sits inside `sets`'s own parens).
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
