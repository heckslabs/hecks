// HAND-WRITTEN, ONCE, GENERIC — a direct port of `CommandInterpreter#call`
// walking `DISPATCH_ORDER` (docs/guides/writing-a-port.md's "Dispatch, in
// the order it actually runs"), not one generated function per command
// shape. What still has to be generated per command is deliberately
// small: identity derivation, the mutation-application closure (writing
// into a specific Rust struct's typed fields has no generic equivalent
// without reflection — Ruby's own genericity there comes from
// `instance[mutation.target] = value` on a dynamically-typed Hash-backed
// object, which Rust has no analogue for), and value-object invariant
// checks on the raw args (still called before `dispatch` even starts,
// mirroring `normalize_args` running before `hydrate`).
//
// NOT YET GENERIC HERE, flagged rather than silently assumed away:
// `ensures` (needs the pre-mutation `old:` snapshot threaded through —
// real, undone), `enforce_role_mismatch`/`resolve_references` (no role
// checking or reference-existence checking generated yet), lifecycle
// transitions (`admissible_transition`/`advance_lifecycle` — a command
// naming a transition isn't wired into `dispatch` yet).

use super::expr::{interpret, EvalContext, Expr, Fielded};
use super::{Event, Refusal, Repository};
use std::collections::BTreeMap;

pub struct GivenSpec {
    pub description: &'static str,
    pub expr: Expr,
}

/// How this dispatch obtains its starting record — the one real branch
/// `DISPATCH_ORDER`'s `hydrate` step takes, decided by whether the
/// command declares `references` at all (`creates?` in Ruby,
/// `references.nil?` in the exported IR — see writing-a-port.md).
///
/// The `'a` lifetime ties `build` to however long the generated dispatch
/// function's own `args` local lives — `build` only ever reads `args`
/// (never moves out of it), and `args` is ALSO borrowed separately as
/// `&dyn Fielded` for given evaluation in the same call, so `build` must
/// borrow rather than own it. Without an explicit `'a` here, `Box<dyn
/// FnOnce() -> T>` defaults to `'static`, which a closure borrowing a
/// local can never satisfy.
pub enum Hydrate<'a, T> {
    /// A creating command: mint the identity, build a fresh record if
    /// nothing already answers to it. `build` is `assign_creation_attributes`
    /// — implicit, name-matched — not a `then_set`.
    Create { id: String, build: Box<dyn FnOnce() -> T + 'a> },
    /// An acting command: the identity already names a record.
    Act { id: String },
}

#[allow(clippy::too_many_arguments)]
pub fn dispatch<'a, T, R>(
    repo: &mut R,
    hydrate: Hydrate<'a, T>,
    command_name: &'static str,
    aggregate_qualified_name: &'static str,
    args: &'a dyn Fielded,
    givens: &[GivenSpec],
    // Takes no `args` parameter of its own — the generated closure passed
    // in captures the CONCRETE, typed args struct directly from its
    // enclosing scope (by reference — not `move`, for the same reason
    // `Hydrate::Create.build` isn't `move`: `args` is borrowed elsewhere
    // in the same call). `args: &dyn Fielded` above is for GIVEN
    // evaluation only, which only ever needs to read fields generically;
    // writing a typed field (`record.toppings.push(Topping { .. })`)
    // needs the real type, which a type-erased `&dyn Fielded` cannot
    // provide.
    apply_mutations: impl FnOnce(&mut T) -> Result<(), Refusal> + 'a,
    emits: &[&'static str],
    payload: BTreeMap<String, String>,
) -> Result<(T, Vec<Event>), Refusal>
where
    T: Fielded + Clone,
    R: Repository<T>,
{
    let (id, mut record) = match hydrate {
        Hydrate::Create { id, build } => {
            if repo.find(&id).is_some() {
                return Err(Refusal::AlreadyExists(format!(
                    "{command_name} creates a {aggregate_qualified_name} that already exists — {id:?}"
                )));
            }
            (id, build())
        }
        Hydrate::Act { id } => {
            let record = repo.find(&id).ok_or_else(|| {
                Refusal::NotFound(format!(
                    "{command_name} references a {aggregate_qualified_name} that was never created — {id:?}"
                ))
            })?;
            (id, record)
        }
    };

    for given in givens {
        let ctx = EvalContext { args, instance: &record };
        if !interpret(&given.expr, &ctx)?.truthy() {
            return Err(Refusal::GivenNotMet(given.description.to_string()));
        }
    }

    apply_mutations(&mut record)?;

    repo.save(&id, record.clone());

    let events = emits
        .iter()
        .map(|name| Event {
            name: name.to_string(),
            aggregate: aggregate_qualified_name.to_string(),
            id: id.clone(),
            payload: payload.clone(),
        })
        .collect();

    Ok((record, events))
}
