//! The `ValueObject` and `OneOf` constructs, which share one builder as in Ruby.
//! A bare `invariant("...")` references a sibling's invariant; `member` rows are verbatim pairs.

use crate::canonical;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::{self, LineShape, Opener, SourceLine};
use crate::ruby_value;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ValueObject.{word}"))
}

/// Resolves a bare `invariant("...")` against the sibling value objects' invariants by
/// description, copying the match; consumes the line only when it is that bare form (ADR 0025).
///
/// The grammar declares only a `source` body row for `invariant`, so the ordinary body gate
/// would refuse the bare form before the `"invariant"` arm in `parse_body` ran.
fn try_reference_named_invariant(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    vo_name: &str,
    owner_value_objects: &[ir::ValueObject],
) -> ParseResult<Option<ir::Given>> {
    let Some(&line) = lines.get(*pos) else {
        return Ok(None);
    };
    let LineShape::Call(call) = lex::classify(file, &line)? else {
        return Ok(None);
    };
    if call.word != "invariant" || !matches!(call.opener, Opener::None) {
        return Ok(None);
    }

    super::verify_resolves_via(
        file,
        line.number,
        "invariant",
        "ValueObject",
        "sibling_scan",
    )?;

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

pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
    owner_value_objects: &[ir::ValueObject],
) -> ParseResult<ir::ValueObject> {
    let mut vo = ir::ValueObject {
        name: name.to_string(),
        ..Default::default()
    };

    loop {
        if let Some(invariant) =
            try_reference_named_invariant(file, lines, pos, &vo.name, owner_value_objects)?
        {
            vo.invariants.push(invariant);
            continue;
        }

        let Some(gated) = super::next_line(file, lines, pos, "ValueObject")? else {
            // Mirrors `ValueObjectBuilder#build`: a non-empty `members` closes the set.
            vo.closed_set = vo.closed_set || !vo.members.is_empty();
            return Ok(vo);
        };

        match gated.row.word {
            // An inline type-position `one_of(...)` set is discarded (see build/closed_sets.rs);
            // `ValueObject` has no nested-value-objects field. Use the `one_of:` keyword instead.
            "attribute" => {
                let (attribute, one_of) = build_value_object_attribute(file, &gated.args)?;
                if let Some(values) = one_of {
                    let vo_name = vo.name.clone();
                    install_inline_closed_set(
                        file,
                        gated.line.number,
                        &vo_name,
                        &mut vo,
                        &attribute.name,
                        &values,
                    )?;
                }
                vo.attributes.push(attribute);
            }
            "invariant" => {
                let description =
                    super::positional_text(file, gated.line.number, "invariant", &gated.args, 1)?;
                let raw = super::source_body_text(file, lines, pos, &gated.call.opener)?;
                vo.invariants.push(ir::Given {
                    description: Some(description),
                    canonical: canonical::apply(&raw),
                });
            }
            "member" => push_member(file, gated.line.number, &gated.args, &mut vo.members)?,
            _ => {
                return Err(super::not_built_yet(
                    "ValueObject",
                    gated.row,
                    file,
                    gated.line.number,
                    &gated.call.word,
                ))
            }
        }
    }
}

/// Reads the `one_of:` keyword, which the shared `build_attribute` refuses in every context.
fn build_value_object_attribute(
    file: &str,
    args: &super::ArgumentGateResult,
) -> ParseResult<(ir::Attribute, Option<Vec<String>>)> {
    let (attribute, _) = super::build_attribute(file, 0, "attribute", args)?;
    let one_of = super::named_raw(args, "one_of").map(|raw| {
        let trimmed = raw.trim();
        let inner = trimmed
            .strip_prefix('[')
            .and_then(|s| s.strip_suffix(']'))
            .unwrap_or(trimmed);
        ruby_value::split_items(inner)
            .into_iter()
            .map(|segment| ruby_value::to_s(&ruby_value::read(segment.trim())))
            .collect()
    });
    Ok((attribute, one_of))
}

/// Installs `attribute :name, String, one_of: [...]`; refused unless it is the value object's
/// only attribute, mirroring `ValueObjectBuilder#install_inline_closed_set` and `#build`.
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
        return Err(Diagnostic::new(
            file,
            line,
            format!("'{vo_name}' declares one_of: on more than one attribute"),
        ));
    }

    vo.closed_set = true;
    // Unmarked like a bare `member` row (`push_member`): Ruby round-trips these through
    // `Marks#member`, so `true`/`false` export as JSON booleans, not strings.
    vo.members = values
        .iter()
        .map(|value| vec![(field.to_string(), unmark_scalar(value))])
        .collect();
    Ok(())
}

fn push_member(
    file: &str,
    line: usize,
    args: &super::ArgumentGateResult,
    members: &mut Vec<Vec<(String, ruby_value::Value)>>,
) -> ParseResult<()> {
    if args.named.is_empty() {
        return Err(Diagnostic::new(
            file,
            line,
            "'member' declared an empty member",
        ));
    }
    let fields = args
        .named
        .iter()
        .map(|(field, raw)| (field.clone(), unmark_scalar(&ruby_value::to_s(&ruby_value::read(raw)))))
        .collect();
    members.push(fields);
    Ok(())
}

/// Port of `Marks#unmark_scalar` (lib/hecks/bluebook/assembly/marks.rb).
/// Ruby stores every member field as text and infers Bool/Integer/Float from its shape, so a
/// quoted "true" or "1" unmarks to a real `true` or `1`.
fn unmark_scalar(text: &str) -> ruby_value::Value {
    if text == "true" {
        return ruby_value::Value::Bool(true);
    }
    if text == "false" {
        return ruby_value::Value::Bool(false);
    }
    if is_integer_shape(text) {
        if let Ok(n) = text.parse::<i64>() {
            return ruby_value::Value::Int(n);
        }
    }
    if is_float_shape(text) {
        if let Ok(f) = text.parse::<f64>() {
            return ruby_value::Value::Float(f);
        }
    }
    ruby_value::Value::Str(text.to_string())
}

/// Matches `/\A-?\d+\z/`: an optional leading `-`, then ASCII digits.
fn is_integer_shape(text: &str) -> bool {
    let digits = text.strip_prefix('-').unwrap_or(text);
    !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())
}

/// Matches `/\A-?\d+\.\d+\z/`: no exponent form, no bare leading or trailing dot.
fn is_float_shape(text: &str) -> bool {
    let rest = text.strip_prefix('-').unwrap_or(text);
    let Some((int_part, frac_part)) = rest.split_once('.') else {
        return false;
    };
    !int_part.is_empty()
        && !frac_part.is_empty()
        && int_part.bytes().all(|b| b.is_ascii_digit())
        && frac_part.bytes().all(|b| b.is_ascii_digit())
}
