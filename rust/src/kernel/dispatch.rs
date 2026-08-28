// HAND-WRITTEN, ONCE, GENERIC — a direct port of `CommandInterpreter#call`
// walking `DISPATCH_ORDER` (docs/implemented/guides/running-a-runtime.md's "Dispatch, in
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
// NOT GENERIC HERE, BUT NOT MISSING EITHER: role checking (`check_role`,
// repository.rs, ADR 0019) and reference resolution (`check_reference`,
// repository.rs) both live in the GENERATED `registry.rs`/`merged.rs` call
// sites, not in this hand-written generic dispatch function — the one
// place with access to every OTHER aggregate's repo, not just this
// command's own, for reference checks, and the natural place to read a
// command's own declared `role:` for role checks. This function stays
// generic by construction: nothing here needs to change per command shape
// for either check to already be enforced.

use super::expr::{interpret, EvalContext, Expr, Field, Fielded, Value, WithOld, WithParent};
use super::refusal_wording::RefusalSite;
use super::{Event, Json, MutationRecord, Refusal, Repository, SetProjectedField, ToJson};

pub struct GivenSpec {
    pub description: &'static str,
    pub expr: Expr,
    // `corrects` — `CommandRules::Admissibility#enforce_correction_target`,
    // read directly: "structural, before the declared givens... `has this
    // exact record already emitted this exact event` is not a predicate
    // over the record's OWN fields [in the usual sense]... it is raised
    // structurally here, the same way NotFound/AlreadyExists are." Ported
    // as an ORDINARY given whose `expr` reads a synthetic per-record
    // boolean field (set whenever a command emitting the named event
    // succeeds — `rust/project/mutations.rb`'s own corrects-flag mutation
    // line), but with its OWN dynamic refusal wording instead of the
    // generic "{command} refused — {description}" every other given uses
    // — Ruby's own message interpolates the record's live id
    // (`RefusalWording` has no template for this shape; `description` is
    // `&'static str`, fixed at codegen time, so it cannot carry a runtime
    // id the way `NotFound`/`AlreadyExists` already do via `RefusalSite
    // ::render`). `None` for every ordinary given — zero behavior change
    // for anything that isn't a `corrects` mutation's own synthetic check.
    pub corrects_event: Option<&'static str>,
}

/// `enforce_ensures` — `CommandRules::Admissibility#enforce_ensures`, read
/// directly. Runs after `apply_mutations`, against `old:` merged into
/// `args` (`WithOld`, expr.rs) — "the state as the givens saw it," per
/// `CommandInterpreter#step_apply_mutations`'s own comment on where the
/// snapshot is taken: after `enforce_givens`/`admissible_transition`,
/// before the mutation that makes `old` and the post-mutation state
/// actually differ.
pub struct EnsuresSpec {
    pub description: &'static str,
    pub expr: Expr,
}

/// `admissible_transition` — the check half of a lifecycle transition.
/// The write half (`advance_lifecycle`, unconditional once a transition
/// applies at all) isn't a separate step here: nothing in the currently
/// generated dispatch pipeline observes the record between
/// `apply_mutations` and where `advance_lifecycle` would run (`ensures`
/// isn't generated yet), so the generated `apply_mutations` closure just
/// writes the target state as one more line — same observable order,
/// one fewer moving part in the kernel. Revisit this folding once
/// `ensures` is generated, in case an `ensures` ever needs to read the
/// lifecycle field's PRE-advance value specifically.
///
/// Reuses the record's own `Fielded` impl to read the current state —
/// unlike a WRITE, reading the lifecycle field generically needs no new
/// per-type glue, because it's already exposed the same way every other
/// field is.
pub struct TransitionCheck {
    pub field: &'static str,
    pub from_states: &'static [&'static str],
}

/// How this dispatch obtains its starting record — the one real branch
/// `DISPATCH_ORDER`'s `hydrate` step takes, decided by whether the
/// command declares `references` at all (`creates?` in Ruby,
/// `references.nil?` in the exported IR — see running-a-runtime.md).
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
    /// — implicit, name-matched — not a `sets`.
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
    // `aggregate_name`/`identity_reading` — codegen-time-static text a
    // refusal message quotes, kept SEPARATE from `aggregate_qualified_name`
    // above on purpose: that field is `{domain}::{aggregate}` (what an
    // `Event`/`MutationRecord` names itself), but `CommandInterpreter#
    // hydrate`'s own refusal wording (`command_interpreter.rb`, read
    // directly) quotes the aggregate's bare `hecks_name` — "Account", never
    // "Banking::Account" — and its declared `identified_by` reading
    // (`Identity.reading`, `identity.rb`), the SAME `target[:identified_by]
    // .map { |p| p.split(".").first }.join(", ")`-shaped computation
    // `reference_checks` (domain_generator.rb) already does for
    // `reference_target_missing`'s own `heads`. Verified against the real
    // interpreter, not assumed: `Banking::Account.Credit` against a number
    // that was never opened reads "no Account with number.value
    // \"acct-x\"" — bare aggregate name, dotted identity path, nothing
    // domain-qualified.
    aggregate_name: &'static str,
    identity_reading: &'static str,
    args: &'a dyn Fielded,
    givens: &[GivenSpec],
    transition: Option<TransitionCheck>,
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
    ensures: &[EnsuresSpec],
    emits: &[&'static str],
    payload: Json,
    mutations: &mut Vec<MutationRecord>,
    // THE SYNCHRONOUS HALF OF `projects` (S12, ADR 0025) —
    // `CommandInterpreter#step_save`'s own `seed_projected_fields(ctx)`
    // call, read directly: computed by the ROUTER (`reference_lookup.rs`'s
    // `seeded_projections`, off the SAME `WithReferences` already built
    // for given/ensures evaluation) and applied here, right before
    // `repo.save`, the identical position Ruby's own step occupies
    // relative to `enforce_ensures`/persistence. Empty for every
    // aggregate that declares no `projects` field — no-op, not a
    // conditional branch, so this parameter costs nothing when unused.
    seed_projections: Vec<(&'static str, Option<String>)>,
) -> Result<(T, Vec<Event>), Refusal>
where
    T: Fielded + Clone + ToJson + SetProjectedField,
    R: Repository<T>,
{
    let (id, mut record) = match hydrate {
        Hydrate::Create { id, build } => {
            if repo.find(&id).is_some() {
                // `AlreadyExists`/`creating_duplicate` — `CommandInterpreter
                // #hydrate`'s own second guard, read directly: "a second
                // creation is not a fresh one."
                return Err(Refusal::AlreadyExists(RefusalSite::AlreadyExistsCreatingDuplicate.render(&[
                    ("command", command_name),
                    ("aggregate", aggregate_name),
                    ("identity", identity_reading),
                    ("offered", &format!("{id:?}")),
                ])));
            }
            (id, build())
        }
        Hydrate::Act { id } => {
            // `NotFound`/`record_missing` — `CommandInterpreter#hydrate`'s
            // own acting-command lookup failure, read directly. Shared
            // with `dispatch_entity`'s own parent lookup below: Ruby's
            // `EntityInterpreter#parent` raises this exact same site for
            // its own failed `repository.find`, not a distinct entity-
            // specific one.
            let record = repo.find(&id).ok_or_else(|| {
                Refusal::NotFound(RefusalSite::NotFoundRecordMissing.render(&[
                    ("aggregate", aggregate_name),
                    ("identity", identity_reading),
                    ("offered", &format!("{id:?}")),
                ]))
            })?;
            (id, record)
        }
    };

    for given in givens {
        let ctx = EvalContext { args, instance: &record };
        if !interpret(&given.expr, &ctx)?.truthy() {
            // `corrects` — `CommandRules::Admissibility
            // #enforce_correction_target`'s own dynamic message, read
            // directly: `"#{command.hecks_name} refused — corrects
            // #{event_name}, but #{event_key} ##{instance.id} has never
            // emitted it"` — `event_key` is `"#{domain}::#{aggregate}"`,
            // exactly what `aggregate_qualified_name` already is
            // (this function's own header comment on that field).
            if let Some(event_name) = given.corrects_event {
                return Err(Refusal::GivenNotMet(format!(
                    "{command_name} refused — corrects {event_name}, but {aggregate_qualified_name} #{id} has never emitted it"
                )));
            }
            // `CommandRules::Admissibility#enforce_givens`, read directly:
            // `"#{command.hecks_name} refused — #{given.description}"` —
            // the prefix this field-only message used to be missing.
            return Err(Refusal::GivenNotMet(format!("{command_name} refused — {}", given.description)));
        }
    }

    if let Some(check) = &transition {
        match record.field(check.field) {
            Some(Field::Value(Value::Str(current))) => {
                if !check.from_states.contains(&current.as_str()) {
                    // `LifecycleRefused`/`transition_blocked` —
                    // `admissible_transition` (command_rules/admissibility.rb),
                    // read directly. `allowed` there is `candidates.flat_map
                    // { |t| Array(t.from) }.uniq` restricted to THIS
                    // command's own transitions — exactly what `from_states`
                    // already is here (`lifecycle_transition_for`,
                    // mutations.rb: `rows.map { |r| r[:from_state] }.uniq`
                    // over rows already filtered to this command). Each
                    // state is `.inspect`-quoted and joined with " or ",
                    // never Rust's own `{:?}` slice-debug rendering.
                    let allowed = check.from_states.iter().map(|s| format!("{s:?}")).collect::<Vec<_>>().join(" or ");
                    return Err(Refusal::LifecycleRefused(RefusalSite::LifecycleRefusedTransitionBlocked.render(&[
                        ("command", command_name),
                        ("field", check.field),
                        ("current", &format!("{current:?}")),
                        ("allowed", &allowed),
                    ])));
                }
            }
            // Not a codegen-emitted mismatch a real dispatch should ever hit —
            // the lifecycle field is always a plain string on every generated
            // record. Surfaced as TypeMismatch, the same way an expression
            // evaluation bug is (see expr.rs's own `eval_error`), because
            // reaching this means the GENERATOR is wrong, not that the
            // command was refused for a real business reason. Deliberately
            // NOT one of `RefusalSite`'s templates — Ruby has no equivalent
            // message to match because Ruby's own dynamically-typed record
            // can never reach this branch at all.
            _ => {
                return Err(Refusal::TypeMismatch(format!(
                    "{command_name}: lifecycle field {:?} missing or not a string — a codegen bug",
                    check.field
                )))
            }
        }
    }

    // THE STATE AS THE GIVENS SAW IT — `old` inside an `ensures`, taken
    // right before the mutation that makes it differ from what follows.
    // Only cloned when a real `ensures` needs it, the same guard Ruby's
    // own `step_apply_mutations` uses (`unless ctx.command.ensures.empty?`).
    let old_snapshot = if ensures.is_empty() { None } else { Some(record.clone()) };

    apply_mutations(&mut record)?;

    if let Some(old) = &old_snapshot {
        let with_old = WithOld { args, old };
        for rule in ensures {
            let ctx = EvalContext { args: &with_old, instance: &record };
            if !interpret(&rule.expr, &ctx)?.truthy() {
                // Same prefix, same source: `CommandRules::Admissibility
                // #enforce_ensures` — `"#{command.hecks_name} refused —
                // #{rule.description}"`.
                return Err(Refusal::EnsuresNotMet(format!("{command_name} refused — {}", rule.description)));
            }
        }
    }

    for (field, value) in seed_projections {
        record.set_projected_field(field, value);
    }

    repo.save(&id, record.clone());
    mutations.push(MutationRecord {
        aggregate: aggregate_qualified_name.to_string(),
        id: id.clone(),
        operation: "save",
        state: record.to_json(),
    });

    let events = emits
        .iter()
        .map(|name| Event {
            name: name.to_string(),
            aggregate: aggregate_qualified_name.to_string(),
            id: id.clone(),
            payload: payload.clone(),
            // Stamped later, if at all — `orchestrate`'s own job (mod.rs's
            // `occurred_at`/`correlation` field docs), never this
            // command-shaped constructor's, which has no clock and no
            // notion of "was this dispatch a saga leg."
            occurred_at: None,
            correlation: None,
        })
        .collect();

    Ok((record, events))
}

/// A direct port of `EntityInterpreter#call` walking its own, SHORTER
/// `DISPATCH_ORDER` (docs/implemented/guides/entities.md): `normalize_args`/
/// `refuse_role_mismatch`/`resolve_references` are the same not-yet-generic
/// gaps `dispatch` above already carries; there is no `hydrate` branch (an
/// entity command never creates — it always addresses a parent AND one of
/// the parent's own list elements, both of which must already exist) and
/// no `assign_creation_attributes` for the same reason.
///
/// `get_list`/`get_list_mut` are the generated per-command closures reading
/// the ONE list attribute on `T` whose declared element type names this
/// entity (`element_of`'s own `aggregate.attributes.find { |a| a.list? &&
/// a.type == entity_name }`, mirrored at codegen time instead of a runtime
/// search, since the generator already knows which attribute that is).
/// `matches` compares each element's own generated `identity()` against
/// the caller-supplied element id — the Rust-typed counterpart of Ruby's
/// `wants.all? { |head, _, want| el[head] == want }` (`element_of`),
/// collapsed to one string comparison because both sides already agree on
/// the SAME dotted-path-join-by-":" convention `extract_id`/`identity()`
/// (json_codec.rb) use everywhere else.
/// THE ELEMENT HALF OF AN ENTITY COMMAND, on a parent record already in
/// hand and nothing saved — `EntityInterpreter`'s locate → givens →
/// transition → mutate → ensures, exactly the steps
/// `CommandInterpreter#step_delegate_to_entity` runs INSIDE a
/// delegating aggregate command (docs/implemented/guides/entities.md,
/// `delegates_to`) and `dispatch_entity`, below, runs before its own
/// save. One body, two callers, so a refusal reads identically whether
/// the entity command was dispatched directly or through its door.
///
/// `parent_in_args`: `Admissibility#enforce_givens`/`#enforce_ensures`
/// merge `parent:` — the OWNING record — into the args every entity
/// given and ensures evaluates against. A direct entity dispatch gets
/// that from the routing layer (`parent_deref`, a snapshot fetched
/// before the command ran, pushed into `command_deref` as `"parent"`);
/// a delegating door has no such layer, so with `parent_in_args` this
/// reads the parent off the LIVE record instead — before the mutation
/// for the givens, after it for the ensures, which is what Ruby's own
/// in-place element mutation gives it: a chess king's "not left in
/// check" ensures reads the board with the piece already moved.
#[allow(clippy::too_many_arguments)]
pub fn apply_entity_command<'a, T, E>(
    record: &mut T,
    parent_id: &str,
    get_list: impl Fn(&T) -> &Vec<E>,
    get_list_mut: impl FnOnce(&mut T) -> &mut Vec<E>,
    matches: impl Fn(&E) -> bool,
    command_name: &'static str,
    aggregate_name: &'static str,
    entity_name: &'static str,
    entity_identity_reading: &'static str,
    wants: &str,
    args: &'a dyn Fielded,
    givens: &[GivenSpec],
    transition: Option<TransitionCheck>,
    apply_mutations: impl FnOnce(&mut E) -> Result<(), Refusal> + 'a,
    ensures: &[EnsuresSpec],
    parent_in_args: bool,
) -> Result<(), Refusal>
where
    T: Fielded + Clone,
    E: Fielded + Clone,
{
    let position = get_list(record).iter().position(|el| matches(el)).ok_or_else(|| {
        Refusal::NotFound(RefusalSite::NotFoundEntityElementMissing.render(&[
            ("entity", entity_name),
            ("identity", entity_identity_reading),
            ("wants", wants),
            ("aggregate", aggregate_name),
            ("parent_id", &format!("{parent_id:?}")),
        ]))
    })?;
    let mut element = get_list(record)[position].clone();

    {
        let parent_before = record.clone();
        let with_parent = WithParent { args, parent: &parent_before };
        let given_args: &dyn Fielded = if parent_in_args { &with_parent } else { args };
        for given in givens {
            let ctx = EvalContext { args: given_args, instance: &element };
            if !interpret(&given.expr, &ctx)?.truthy() {
                return Err(Refusal::GivenNotMet(format!("{command_name} refused — {}", given.description)));
            }
        }
    }

    if let Some(check) = &transition {
        match element.field(check.field) {
            Some(Field::Value(Value::Str(current))) => {
                if !check.from_states.contains(&current.as_str()) {
                    let allowed = check.from_states.iter().map(|s| format!("{s:?}")).collect::<Vec<_>>().join(" or ");
                    return Err(Refusal::LifecycleRefused(RefusalSite::LifecycleRefusedTransitionBlocked.render(&[
                        ("command", command_name),
                        ("field", check.field),
                        ("current", &format!("{current:?}")),
                        ("allowed", &allowed),
                    ])));
                }
            }
            _ => {
                return Err(Refusal::TypeMismatch(format!(
                    "{command_name}: lifecycle field {:?} missing or not a string — a codegen bug",
                    check.field
                )))
            }
        }
    }

    let old_snapshot = if ensures.is_empty() { None } else { Some(element.clone()) };
    apply_mutations(&mut element)?;
    get_list_mut(record)[position] = element;

    if let Some(old) = &old_snapshot {
        let parent_after = record.clone();
        let with_parent = WithParent { args, parent: &parent_after };
        let ensures_args: &dyn Fielded = if parent_in_args { &with_parent } else { args };
        let with_old = WithOld { args: ensures_args, old };
        let settled = &get_list(record)[position];
        for rule in ensures {
            let ctx = EvalContext { args: &with_old, instance: settled };
            if !interpret(&rule.expr, &ctx)?.truthy() {
                return Err(Refusal::EnsuresNotMet(format!("{command_name} refused — {}", rule.description)));
            }
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub fn dispatch_entity<'a, T, E, R>(
    repo: &mut R,
    parent_id: &str,
    get_list: impl Fn(&T) -> &Vec<E>,
    get_list_mut: impl FnOnce(&mut T) -> &mut Vec<E>,
    matches: impl Fn(&E) -> bool,
    command_name: &'static str,
    aggregate_qualified_name: &'static str,
    aggregate_name: &'static str,
    parent_identity_reading: &'static str,
    entity_name: &'static str,
    entity_identity_reading: &'static str,
    wants: &str,
    args: &'a dyn Fielded,
    givens: &[GivenSpec],
    transition: Option<TransitionCheck>,
    apply_mutations: impl FnOnce(&mut E) -> Result<(), Refusal> + 'a,
    ensures: &[EnsuresSpec],
    emits: &[&'static str],
    payload: Json,
    mutations: &mut Vec<MutationRecord>,
    // Same as `dispatch`'s own `seed_projections` — an entity command
    // still ends in a PARENT AGGREGATE save (`repo.save(parent_id, ..)`,
    // below), the identical `step_save` Ruby's own `step_delegate_to_
    // entity` falls through to, so a parent with `projects` fields needs
    // the same synchronous seed here too.
    seed_projections: Vec<(&'static str, Option<String>)>,
) -> Result<(T, Vec<Event>), Refusal>
where
    T: Fielded + Clone + ToJson + SetProjectedField,
    E: Fielded + Clone,
    R: Repository<T>,
{
    // Same `record_missing` site `EntityInterpreter#parent` raises —
    // see `dispatch` above for the aggregate-level twin.
    let mut record = repo.find(parent_id).ok_or_else(|| {
        Refusal::NotFound(RefusalSite::NotFoundRecordMissing.render(&[
            ("aggregate", aggregate_name),
            ("identity", parent_identity_reading),
            ("offered", &format!("{parent_id:?}")),
        ]))
    })?;

    apply_entity_command(
        &mut record,
        parent_id,
        get_list,
        get_list_mut,
        matches,
        command_name,
        aggregate_name,
        entity_name,
        entity_identity_reading,
        wants,
        args,
        givens,
        transition,
        apply_mutations,
        ensures,
        false,
    )?;

    for (field, value) in seed_projections {
        record.set_projected_field(field, value);
    }

    repo.save(parent_id, record.clone());
    mutations.push(MutationRecord {
        aggregate: aggregate_qualified_name.to_string(),
        id: parent_id.to_string(),
        operation: "save",
        state: record.to_json(),
    });
    let events = emits
        .iter()
        .map(|name| Event {
            name: name.to_string(),
            aggregate: aggregate_qualified_name.to_string(),
            id: parent_id.to_string(),
            payload: payload.clone(),
            occurred_at: None,
            correlation: None,
        })
        .collect();
    Ok((record, events))
}
