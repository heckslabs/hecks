//! THE SCALAR AN IDENTITY PATH NAMES, and the JOIN of several — the twin of
//! `lib/hecksagain/runtime/identity.rb`.
//!
//! An identity is DECLARED as a path — `identified_by { number.value }` — and
//! this is the one place that reads one. It follows the path and nothing else.
//! Nothing is minted here, and nothing is guessed: a declaration that names no
//! field is refused when the bluebook loads, so by the time anything is
//! dispatched there is always a path to follow.
//!
//! SEVERAL PATHS ARE THE ORDINARY CASE ONE STEP OUT. Anything named beneath
//! another thing needs them — the language's own chapters are composite
//! throughout, an Aggregate being `bluebook_id` AND `name.value` — and Rust
//! read only the first, which is indistinguishable from reading them all as
//! long as every corpus member declares one. `Market::Stall` was the corpus
//! member that first told them apart (stall 1 in row A and stall 1 in row B
//! are not the same pitch); banking's own `SafeDepositBox` (branch_code +
//! box_number — box 12 downtown and box 12 uptown are not the same box)
//! carries the same proof now that market has folded into it.

use crate::bluebook::expression::resolver::State;
use serde_json::{Map, Value};

/// WHAT SEPARATES THE PARTS OF A DERIVED IDENTITY — `Naming::IDENTITY_JOIN`
/// (`lib/hecksagain/naming.rb`). It has to be spelled the same in both
/// runtimes or two readers name two different records off one declaration,
/// which is the failure this constant exists to make impossible to reintroduce
/// quietly.
pub const IDENTITY_JOIN: &str = ":";

/// EVERY DECLARED PATH, IN DECLARATION ORDER, because the identity is their
/// join and the order is a fact about the source.
///
/// Empty when nothing is declared. There is no `"id"` default: that default
/// was a MINT, and a caller who gets an empty list here has to say what that
/// means for them rather than be handed an invented answer.
pub fn paths(construct: &Map<String, Value>) -> Vec<&str> {
    construct
        .get("identified_by")
        .and_then(Value::as_array)
        .map(|paths| paths.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

/// THE ATTRIBUTES THOSE PATHS START AT — what a caller actually passes.
///
/// `identified_by { number.value }` means a caller passes `number:`, so the
/// head is what `refuse_unknown_arguments` admits and what a lookup reads out
/// of the payload. A composite has several, and admitting only the first
/// refuses a perfectly good dispatch as an undeclared argument.
pub fn heads(construct: &Map<String, Value>) -> Vec<&str> {
    paths(construct)
        .into_iter()
        .map(|path| path.split('.').next().unwrap_or(path))
        .collect()
}

/// HOW AN IDENTITY READS WHEN A RUNTIME HAS TO NAME IT IN A REFUSAL — the
/// paths as they were declared, so the message quotes the bluebook back
/// ("row.value, number.value", not "row"). Ruby's `Identity.reading`, and the
/// two must agree word for word or parity splits on the refusal rather than on
/// the behaviour.
pub fn reading(construct: &Map<String, Value>) -> String {
    paths(construct).join(", ")
}

/// THE SCALAR ONE PATH NAMES, dug out of the argument its head names.
///
/// The head is consumed by the lookup; what is left is the walk down into the
/// value object carrying the id. An id is ALWAYS a scalar, so a caller may
/// hand the field's value straight over — only a value object that actually
/// arrived whole has to be opened.
pub fn part(args: &State, path: &str) -> Option<String> {
    let (head, field) = split(path);
    let held = args.get(head)?;

    Some(match field {
        Some(name) => held
            .get(name)
            .map(crate::dispatcher::query_text)
            .unwrap_or_else(|| crate::dispatcher::query_text(held)),
        None => crate::dispatcher::query_text(held),
    })
}

/// THE SAME DERIVATION, FROM DECLARED PATHS RATHER THAN FROM THE WIRE.
///
/// `of` reads `identified_by` out of a JSON map, which is where this whole arc's
/// defect lived: the struct says `Vec<String>` and the reader asked for
/// `as_str`, got None on an array, fell through to a default, and COMPILED. No
/// test could have been written against a bug that has no failing input — only a
/// corpus member with two paths could show it, and there was none.
///
/// Handed the paths themselves, that question cannot be asked wrongly. The
/// typed domain hands `&aggregate.identified_by` straight over: a `Vec<String>`
/// is a list, taking `.first()` of it is a visible choice somebody has to write,
/// and there is no spelling of `as_str` that silently means "none".
///
/// `of` now calls this, so both routes share one derivation and cannot drift.
pub fn of_paths(paths: &[String], args: &State) -> Option<String> {
    if paths.is_empty() {
        return None;
    }

    let mut parts = Vec::with_capacity(paths.len());
    for path in paths {
        let held = part(args, path)?;
        if held.is_empty() {
            return None;
        }
        parts.push(held);
    }
    Some(parts.join(IDENTITY_JOIN))
}

/// THE IDENTITY IS THE JOIN OF ITS PARTS, in declaration order.
///
/// A part the payload does not carry makes the WHOLE identity unresolvable
/// rather than half of one. Half an identity names nothing, and joining what
/// did arrive would silently name a DIFFERENT record on every dispatch — the
/// precise failure that minting an id caused, arrived at by another road.
///
/// A BLANK PART NAMES NOTHING, the same as an absent one: `""` is not a fact
/// about anything, and Ruby's `Identity.of` filters it for the same reason.
pub fn of(construct: &Map<String, Value>, args: &State) -> Option<String> {
    let declared: Vec<String> = paths(construct).into_iter().map(str::to_string).collect();
    of_paths(&declared, args)
}

/// A path is a head and the walk into it. One split, so every reader takes the
/// same one.
pub fn split(path: &str) -> (&str, Option<&str>) {
    match path.split_once('.') {
        Some((head, rest)) => (head, Some(rest)),
        None => (path, None),
    }
}
