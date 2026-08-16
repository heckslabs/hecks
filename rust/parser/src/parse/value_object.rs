//! The `ValueObject`/`OneOf` constructs
//! (`lib/hecksagain/bluebook/ir/value_object.rb`) — shared here exactly as
//! `ValueObjectBuilder` answers both in Ruby (`one_of` `instance_eval`s
//! its block on the builder itself, so the two contexts are one Ruby
//! object; see `spec/syntax_conformance_spec.rb`'s own `BUILDER` table).
//! `invariant` admits BOTH `source` spellings (`{ ... }` and
//! `do ... end` — `parse::mod::source_body_text`'s own header explains
//! why) for a FRESH declaration, and — mirroring `command.rs`'s own
//! `given` one level over (S10, ADR 0025) — a BARE, block-less form that
//! REFERENCES an already-declared invariant of the same description on a
//! sibling value object of the same aggregate instead
//! (`try_reference_named_invariant`'s own header). `member` rows
//! (`build/closed_sets.rs`) are an open map of pairs, captured verbatim
//! per `PairsShape::verbatim`.

use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, LineShape, Opener, SourceLine};
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ValueObject.{word}"))
}

/// NO BLOCK IS A REFERENCE, NOT A FRESH DECLARATION (S10/S-next, ADR 0025,
/// one level over `command.rs`'s own `try_reference_named_given` — read
/// that function's header first, this mirrors it exactly one construct
/// down). `syntax.bluebook` declares exactly ONE keyword row for
/// `invariant`/ValueObject (`body: "source"`, `parse::mod::body_gate`'s
/// own comment names it directly among the words with "at most a sibling
/// `none` row, never" one — false as of THIS function; that comment is
/// now stale for this one word, kept anyway since fixing it belongs in
/// `syntax.bluebook`, out of scope here), so a bare `invariant("...")`
/// would otherwise be refused by the ordinary `next_line`/`body_gate`
/// path before ever reaching the `"invariant"` match arm below. Resolved
/// by `description` against `owner_value_objects` — the OWNING
/// aggregate's own sibling value objects, built SO FAR (source order;
/// `aggregate::parse_body`'s own `"value_object"` arm hands in
/// `@value_objects + closed_sets` up to this point, the same combination
/// `AggregateBuilder#value_object`'s own `owner_value_objects:` uses) —
/// duplicating the matched `Given` verbatim, the same canonical text,
/// into this value object's own invariants. Confirmed real:
/// banking.bluebook's own `Account`, `PositiveMoney`'s bare
/// `invariant("a currency is a three-letter code")` resolving against
/// `Money`'s own block-form declaration of the same description,
/// declared earlier in the same aggregate.
///
/// Peeks the next physical line WITHOUT consuming it unless it actually
/// matches (word `invariant`, `Opener::None`) — anything else (a
/// `invariant { ... }`/`invariant do ... end` fresh declaration, or any
/// other word entirely) falls through untouched to the ordinary
/// `next_line` gate below.
fn try_reference_named_invariant(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    vo_name: &str,
    owner_value_objects: &[ir::ValueObject],
) -> ParseResult<Option<ir::Given>> {
    let Some(&line) = lines.get(*pos) else { return Ok(None) };
    let LineShape::Call(call) = lex::classify(file, &line)? else { return Ok(None) };
    if call.word != "invariant" || !matches!(call.opener, Opener::None) {
        return Ok(None);
    }

    let args = super::argument_gate(file, "invariant", "ValueObject", &call.args, line.number)?;
    let description = super::positional_text(file, line.number, "invariant", &args, 1)?;
    let resolved = owner_value_objects
        .iter()
        .flat_map(|vo| vo.invariants.iter())
        .find(|given| given.description.as_deref() == Some(description.as_str()))
        .cloned()
        .ok_or_else(|| {
            Diagnostic::new(
                file,
                line.number,
                format!(
                    "'{vo_name}'s invariant {description:?} names no rule a sibling value object on \
                     this aggregate declares — declare it once with a block, on the value object that \
                     needs it first, before the ones that reference it back"
                ),
            )
        })?;

    *pos += 1;
    Ok(Some(resolved))
}

/// Parses a `value_object "Name" do ... end` body. `owner_value_objects`
/// — see `try_reference_named_invariant`'s own header — is the OWNING
/// aggregate's own sibling value objects declared so far.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    owner_value_objects: &[ir::ValueObject],
) -> ParseResult<ir::ValueObject> {
    let mut vo = ir::ValueObject { name: name.to_string(), ..Default::default() };

    loop {
        if let Some(invariant) = try_reference_named_invariant(file, lines, pos, &vo.name, owner_value_objects)? {
            vo.invariants.push(invariant);
            continue;
        }

        let Some(gated) = super::next_line(file, lines, pos, "ValueObject")? else {
            // `ValueObjectBuilder#build`'s own `closed_set: @closed_set ||
            // !@members.empty?` — a non-empty `members` closes the set
            // even when nothing else set the flag explicitly (the bare
            // `member` spelling, S3, ADR 0025, never touches `closed_set`
            // itself the way `one_of:`/the legacy wrapper do).
            vo.closed_set = vo.closed_set || !vo.members.is_empty();
            return Ok(vo);
        };

        match gated.row.word {
            // A synthesized inline `one_of(...)` closed set (the TYPE-
            // POSITION form, `attribute :x, one_of("a", "b")`) is
            // discarded here on purpose — see `build/closed_sets.rs`'s
            // own header; `ValueObjectBuilder#build` never reads
            // `closed_sets` either (nor could it hold one: `IR::
            // ValueObject.declare` has no nested-value-objects field at
            // all). The FIELD'S OWN `one_of:` keyword (below) is the real
            // spelling for a closed set declared INSIDE a value_object.
            "attribute" => {
                let (attribute, one_of) = build_value_object_attribute(file, &gated.args)?;
                if let Some(values) = one_of {
                    let vo_name = vo.name.clone();
                    install_inline_closed_set(file, gated.line.number, &vo_name, &mut vo, &attribute.name, &values)?;
                }
                vo.attributes.push(attribute);
            }
            "invariant" => {
                let description = super::positional_text(file, gated.line.number, "invariant", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                vo.invariants.push(ir::Given { description: Some(description), canonical: canonical::apply(&raw) });
            }
            // BARE NOW (S3, ADR 0025 — "closed sets lose the wrapper
            // block") — a `member` row sits directly in the value_object
            // body, no `one_of do ... end` around it. A non-empty
            // `members` already means closed; see `build`'s own comment
            // below for why nothing else has to change for that.
            "member" => push_member(file, gated.line.number, &gated.args, &mut vo.members)?,
            _ => return Err(super::not_built_yet("ValueObject", gated.row, file, gated.line.number, &gated.call.word)),
        }
    }
}

/// `AttributeCollector#attribute`'s own `one_of:` keyword, read off the
/// argument gate directly rather than through the shared `build_attribute`
/// (which knows nothing about it — every OTHER context refuses it) — an
/// array literal of raw values, same shape `resolve_type_expression`'s own
/// positional `one_of(...)` already reads.
fn build_value_object_attribute(file: &str, args: &super::ArgumentGateResult) -> ParseResult<(ir::Attribute, Option<Vec<String>>)> {
    let (attribute, _) = super::build_attribute(file, 0, "attribute", args)?;
    let one_of = super::named_raw(args, "one_of").map(|raw| {
        let trimmed = raw.trim();
        let inner = trimmed.strip_prefix('[').and_then(|s| s.strip_suffix(']')).unwrap_or(trimmed);
        ruby_value::split_items(inner)
            .into_iter()
            .map(|segment| ruby_value::to_s(&ruby_value::read(segment.trim())))
            .collect()
    });
    Ok((attribute, one_of))
}

/// THE NEW SPELLING — `attribute :name, String, one_of: [...]`. Refuses a
/// SECOND attribute naming one_of: on the same value object (a single-
/// field set names exactly one field, by construction) and — the other
/// half of the same rule — refuses it once the value object turns out to
/// hold more than this one attribute, mirroring `ValueObjectBuilder#
/// install_inline_closed_set`/`#build` exactly.
fn install_inline_closed_set(
    file: &str,
    line: usize,
    vo_name: &str,
    vo: &mut ir::ValueObject,
    field: &str,
    values: &[String],
) -> ParseResult<()> {
    if !vo.attributes.is_empty() {
        return Err(Diagnostic::new(
            file,
            line,
            format!("'{vo_name}'s one_of: on '{field}' only works when it is the value object's only attribute"),
        ));
    }
    if vo.closed_set {
        return Err(Diagnostic::new(file, line, format!("'{vo_name}' declares one_of: on more than one attribute")));
    }

    vo.closed_set = true;
    vo.members = values.iter().map(|value| vec![(field.to_string(), value.clone())]).collect();
    Ok(())
}

/// `member field: value, ...` — one `pairs_shape: "verbatim"` open map,
/// bare now (no `one_of do ... end` wrapper — S3, ADR 0025). Shared by
/// both a value_object's own top-level `member` rows and (unchanged) the
/// same shape everywhere else `member` appears.
fn push_member(file: &str, line: usize, args: &super::ArgumentGateResult, members: &mut Vec<Vec<(String, String)>>) -> ParseResult<()> {
    if args.named.is_empty() {
        return Err(Diagnostic::new(file, line, "'member' declared an empty member"));
    }
    let fields = args.named.iter().map(|(field, raw)| (field.clone(), ruby_value::to_s(&ruby_value::read(raw)))).collect();
    members.push(fields);
    Ok(())
}
