//! Generic dispatch loops over the declared `AggregateStep`/`EntityStep` order.
//! Argument gates run in `decode_*_arguments`, before the router resolves identity.

use super::expr::{interpret, EvalContext, Expr, Field, Fielded, NoFields, StateFirst, Value, WithOld, WithParent};
use super::refusal_wording::{
    AlreadyExistsCreatingDuplicateArgs, LifecycleRefusedTransitionBlockedArgs, NotFoundCreatingNoIdentityArgs, NotFoundEntityElementMissingArgs,
    NotFoundRecordMissingArgs,
};
use super::vocab::{AggregateStep, EntityStep};
use super::{Event, Json, MutationRecord, Refusal, Repository, SetProjectedField, ToJson};

pub struct GivenSpec {
    pub description: &'static str,
    pub expr: Expr,
    // Carries the event name a `corrects` given checks, so the refusal can interpolate the
    // record's id (the static `description` cannot). `None` for every ordinary given.
    pub corrects_event: Option<&'static str>,
}

/// An `ensures` rule, checked after `apply_mutations`, with `old` bound to the prior state.
pub struct EnsuresSpec {
    pub description: &'static str,
    pub expr: Expr,
}

/// An invariant rule, checked after `ensures` and before save on the candidate record.
/// Entity invariants run per list element with `parent` bound to the owner.
pub struct InvariantSpec {
    pub description: &'static str,
    pub expr: Expr,
}

pub struct EntityInvariants {
    pub name: &'static str,
    pub list_field: &'static str,
    pub specs: Vec<InvariantSpec>,
    pub nested: Vec<EntityInvariants>,
}

pub struct InvariantSet {
    pub aggregate: Vec<InvariantSpec>,
    pub entities: Vec<EntityInvariants>,
}

pub fn enforce_invariants(record: &dyn Fielded, aggregate_name: &str, set: &InvariantSet) -> Result<(), Refusal> {
    for rule in &set.aggregate {
        let ctx = EvalContext { args: &NoFields, instance: record };
        if !interpret(&rule.expr, &ctx)?.truthy() {
            return Err(Refusal::InvariantViolation(format!("{aggregate_name} refused — {}", rule.description)));
        }
    }
    for entity in &set.entities {
        enforce_entity_invariants(record, entity)?;
    }
    Ok(())
}

fn enforce_entity_invariants(owner: &dyn Fielded, entity: &EntityInvariants) -> Result<(), Refusal> {
    let Some(elements) = owner.items(entity.list_field) else { return Ok(()) };
    for element in elements {
        let Field::Nested(element) = element else { continue };
        let with_parent = WithParent { args: &NoFields, parent: owner };
        for rule in &entity.specs {
            let ctx = EvalContext { args: &with_parent, instance: element };
            if !interpret(&rule.expr, &ctx)?.truthy() {
                return Err(Refusal::InvariantViolation(format!("{} refused — {}", entity.name, rule.description)));
            }
        }
        for nested in &entity.nested {
            enforce_entity_invariants(element, nested)?;
        }
    }
    Ok(())
}

/// The check half of a lifecycle transition: the current state must be in `from_states`.
///
/// The write half is folded into the generated `apply_mutations` closure as its last line.
pub struct TransitionCheck {
    pub field: &'static str,
    pub from_states: &'static [&'static str],
}

/// How a dispatch obtains its starting record: `Create` when the command declares no
/// `references`, `Act` when it addresses an existing record.
///
/// `'a` lets `build` borrow `args`, which is also borrowed as `&dyn Fielded` in the same call.
pub enum Hydrate<'a, T> {
    /// A creating command: mint the identity, build a fresh record if nothing answers to it.
    /// `build` assigns creation attributes (implicit, name-matched), not a `sets`.
    ///
    /// `state_independent` defers the `AlreadyExists` check to just before `repo.save`, for
    /// commands whose givens, ensures and mutations never read the aggregate's own state.
    Create { id: String, build: Box<dyn FnOnce() -> T + 'a>, state_independent: bool },
    /// An acting command: the identity already names a record.
    Act { id: String },
}

#[allow(clippy::too_many_arguments)]
pub fn dispatch<'a, T, R>(
    repo: &mut R,
    hydrate: Hydrate<'a, T>,
    command_name: &'static str,
    aggregate_qualified_name: &'static str,
    // Bare `hecks_name` and the declared identity reading, as refusal wording quotes them;
    // `aggregate_qualified_name` (`{domain}::{aggregate}`) is what events and records use.
    aggregate_name: &'static str,
    identity_reading: &'static str,
    args: &'a dyn Fielded,
    givens: &[GivenSpec],
    transition: Option<TransitionCheck>,
    // Captures the typed args struct by reference (not `move`, like `Hydrate::Create.build`);
    // writing a typed field needs the real type, which `&dyn Fielded` erases.
    apply_mutations: impl FnOnce(&mut T) -> Result<(), Refusal> + 'a,
    ensures: &[EnsuresSpec],
    invariants: &InvariantSet,
    emits: &[&'static str],
    payload: Json,
    mutations: &mut Vec<MutationRecord>,
    // The synchronous half of `projects`, applied right before `repo.save`.
    seed_projections: Vec<(&'static str, Option<Value>)>,
    // The write-side tenant boundary. The router computes it (it needs every aggregate's repo)
    // but it is applied here, first in `Save`, before `seed_projections`.
    tenant_boundary_check: Result<(), Refusal>,
) -> Result<(T, Vec<Event>), Refusal>
where
    T: Fielded + Clone + ToJson + SetProjectedField,
    R: Repository<T>,
{
    // Set by a state-independent `Hydrate::Create`; checked in `Save`, just before `repo.save`.
    let mut defer_existence_check = false;

    // Each owned or `FnOnce` input is consumed by one arm via `take()`; the const assertions
    // below guarantee `hydrated` is set before any arm reads it.
    let mut hydrate = Some(hydrate);
    let mut apply_mutations = Some(apply_mutations);
    let mut tenant_boundary_check = Some(tenant_boundary_check);
    let mut seed_projections = Some(seed_projections);
    let mut hydrated: Option<(String, T)> = None;
    let mut old_snapshot: Option<T> = None;
    let mut events: Vec<Event> = Vec::new();

    for step in AggregateStep::ORDER {
        #[deny(clippy::wildcard_enum_match_arm)]
        match step {
            // Already run by `decode_aggregate_arguments`; see `aggregate_step_site`.
            // `aggregate_step_site`.
            AggregateStep::DecodeArguments
            | AggregateStep::RefuseUnknownArguments
            | AggregateStep::RefuseAbsentArguments
            | AggregateStep::NormalizeArgs
            | AggregateStep::RefuseRoleMismatch
            | AggregateStep::ResolveReferences => {}
            AggregateStep::Hydrate => {
                let hydrate = hydrate.take().expect(ONCE);
                hydrated = Some(hydrate_record(
                    repo,
                    hydrate,
                    command_name,
                    aggregate_name,
                    identity_reading,
                    &mut defer_existence_check,
                )?);
            }
            AggregateStep::EnforceGivens => {
                let (id, record) = hydrated.as_ref().expect(HYDRATED);
                enforce_givens(record, args, givens, command_name, aggregate_qualified_name, id)?;
            }
            AggregateStep::AdmissibleTransition => {
                let (_, record) = hydrated.as_ref().expect(HYDRATED);
                admissible_transition(record, transition.as_ref(), command_name)?;
            }
            // Folded into `Hydrate::Create.build`: givens already saw the built record.
            AggregateStep::AssignCreationAttributes => {}
            AggregateStep::ApplyMutations => {
                let (_, record) = hydrated.as_mut().expect(HYDRATED);
                // The state as the givens saw it — `old` inside an `ensures`,
                // `old` for `ensures`: the state before the mutation, cloned only if needed.
                old_snapshot = if ensures.is_empty() { None } else { Some(record.clone()) };
                (apply_mutations.take().expect(ONCE))(record)?;
            }
            // Written by the generated `apply_mutations` closure as its last line.
            AggregateStep::AdvanceLifecycle => {}
            // Performed inside the generated `apply_mutations` closure, which calls
            // `apply_entity_command` on the record in hand.
            AggregateStep::DelegateToEntity => {}
            AggregateStep::EnforceEnsures => {
                let (_, record) = hydrated.as_ref().expect(HYDRATED);
                if let Some(old) = &old_snapshot {
                    enforce_ensures(record, old, args, ensures, command_name)?;
                }
            }
            AggregateStep::EnforceInvariants => {
                let (_, record) = hydrated.as_ref().expect(HYDRATED);
                enforce_invariants(record, aggregate_name, invariants)?;
            }
            AggregateStep::Save => {
                let (id, record) = hydrated.as_mut().expect(HYDRATED);
                // Tenant boundary first: it precedes `seed_projections` and the write.
                tenant_boundary_check.take().expect(ONCE)?;

                for (field, value) in seed_projections.take().expect(ONCE) {
                    record.set_projected_field(field, value);
                }

                // Deferred `AlreadyExists` check for state-independent creates: runs after
                // every other step, immediately before the write.
                if defer_existence_check && repo.find(id.as_str()).is_some() {
                    return Err(Refusal::AlreadyExists(
                        AlreadyExistsCreatingDuplicateArgs {
                            command: command_name,
                            aggregate: aggregate_name,
                            identity: identity_reading,
                            offered: &format!("{id:?}"),
                        }
                        .render_args(),
                    ));
                }

                persist(repo, id, record, aggregate_qualified_name, mutations);
            }
            AggregateStep::Emit => {
                let (id, _) = hydrated.as_ref().expect(HYDRATED);
                events = emitted(emits, aggregate_qualified_name, id, &payload);
            }
        }
    }

    let (_, record) = hydrated.expect(HYDRATED);
    Ok((record, events))
}

/// `hydrate` — how this dispatch obtains its starting record (see
/// `Hydrate`'s own comment for the branch it takes).
fn hydrate_record<T, R>(
    repo: &R,
    hydrate: Hydrate<'_, T>,
    command_name: &'static str,
    aggregate_name: &'static str,
    identity_reading: &'static str,
    defer_existence_check: &mut bool,
) -> Result<(String, T), Refusal>
where
    T: Clone,
    R: Repository<T>,
{
    match hydrate {
        Hydrate::Create { id, build, state_independent } => {
            // A blank identity names nothing; refuse before any lookup rather than mint a
            // record keyed by "".
            if id.is_empty() {
                return Err(Refusal::NotFound(
                    NotFoundCreatingNoIdentityArgs { command: command_name, aggregate: aggregate_name, identity: identity_reading }
                        .render_args(),
                ));
            }
            // State-independent creates defer this check to `Save`.
            if state_independent {
                *defer_existence_check = true;
            } else if repo.find(&id).is_some() {
                return Err(Refusal::AlreadyExists(
                    AlreadyExistsCreatingDuplicateArgs {
                        command: command_name,
                        aggregate: aggregate_name,
                        identity: identity_reading,
                        offered: &format!("{id:?}"),
                    }
                    .render_args(),
                ));
            }
            Ok((id, build()))
        }
        Hydrate::Act { id } => {
            // Shared with `dispatch_entity`'s parent lookup: both raise `record_missing`.
            let record = repo.find(&id).ok_or_else(|| {
                Refusal::NotFound(
                    NotFoundRecordMissingArgs { aggregate: aggregate_name, identity: identity_reading, offered: &format!("{id:?}") }
                        .render_args(),
                )
            })?;
            Ok((id, record))
        }
    }
}

/// `enforce_givens` on an aggregate record.
fn enforce_givens(
    record: &dyn Fielded,
    args: &dyn Fielded,
    givens: &[GivenSpec],
    command_name: &str,
    aggregate_qualified_name: &str,
    id: &str,
) -> Result<(), Refusal> {
    for given in givens {
        let ctx = EvalContext { args, instance: record };
        if !interpret(&given.expr, &ctx)?.truthy() {
            // The `corrects` wording interpolates the record id, so it is built here.
            if let Some(event_name) = given.corrects_event {
                // `NothingToCorrect`, not `GivenNotMet`: the conformance corpus compares kinds.
                return Err(Refusal::NothingToCorrect(format!(
                    "{command_name} refused — corrects {event_name}, but {aggregate_qualified_name} #{id} has never emitted it"
                )));
            }
            return Err(Refusal::GivenNotMet(format!("{command_name} refused — {}", given.description)));
        }
    }
    Ok(())
}

/// `admissible_transition` — shared by the aggregate record and an entity
/// element, which check it identically.
fn admissible_transition(instance: &dyn Fielded, transition: Option<&TransitionCheck>, command_name: &str) -> Result<(), Refusal> {
    let Some(check) = transition else { return Ok(()) };
    match instance.field(check.field) {
        Some(Field::Value(Value::Str(current))) => {
            if !check.from_states.contains(&current.as_str()) {
                // `allowed` is `from_states`; `render_args` quotes each and joins with " or ".
                return Err(Refusal::LifecycleRefused(
                    LifecycleRefusedTransitionBlockedArgs {
                        command: command_name,
                        field: check.field,
                        current: &format!("{current:?}"),
                        allowed: check.from_states,
                    }
                    .render_args(),
                ));
            }
            Ok(())
        }
        // Unreachable for generated records (the lifecycle field is always a string): a
        // codegen bug, surfaced as TypeMismatch with no `RefusalSite` template.
        _ => Err(Refusal::TypeMismatch(format!(
            "{command_name}: lifecycle field {:?} missing or not a string — a codegen bug",
            check.field
        ))),
    }
}

/// `enforce_ensures` against the settled record (or element), `old` merged
/// into the args it reads.
fn enforce_ensures(
    settled: &dyn Fielded,
    old: &dyn Fielded,
    args: &dyn Fielded,
    ensures: &[EnsuresSpec],
    command_name: &str,
) -> Result<(), Refusal> {
    // C2.3 — the settled state first; see `StateFirst`.
    let state_first = StateFirst { args, settled };
    let with_old = WithOld { args: &state_first, old };
    for rule in ensures {
        let ctx = EvalContext { args: &with_old, instance: settled };
        if !interpret(&rule.expr, &ctx)?.truthy() {
            return Err(Refusal::EnsuresNotMet(format!("{command_name} refused — {}", rule.description)));
        }
    }
    Ok(())
}

/// The write half of `save`: the repository write and its mutation record.
fn persist<T, R>(repo: &mut R, id: &str, record: &T, aggregate_qualified_name: &str, mutations: &mut Vec<MutationRecord>)
where
    T: Clone + ToJson,
    R: Repository<T>,
{
    repo.save(id, record.clone());
    mutations.push(MutationRecord {
        aggregate: aggregate_qualified_name.to_string(),
        id: id.to_string(),
        operation: "save",
        state: record.to_json(),
    });
}

/// `emit` — the declared events, in declared order.
fn emitted(emits: &[&'static str], aggregate_qualified_name: &str, id: &str, payload: &Json) -> Vec<Event> {
    emits
        .iter()
        .map(|name| Event {
            name: name.to_string(),
            aggregate: aggregate_qualified_name.to_string(),
            id: id.to_string(),
            payload: payload.clone(),
            // Stamped later by `orchestrate`; this constructor has no clock.
            occurred_at: None,
            correlation: None,
        })
        .collect()
}

/// The element half of an entity command on a parent record already in hand, nothing saved:
/// locate, givens, transition, mutate, ensures.
///
/// Shared by `dispatch_entity` and delegating aggregate commands so a refusal reads the same
/// through either. `parent_in_args` binds `parent:` (the live owning record) into given and
/// ensures scope, so an ensures sees the parent after the mutation. Both callers pass `true`:
/// the routing layer's `parent_deref` snapshot is never refreshed after `apply_mutations`.
#[allow(clippy::too_many_arguments)]
pub fn apply_entity_command<'a, T, E>(
    record: &mut T,
    parent_id: &str,
    get_list: impl Fn(&T) -> &Vec<E>,
    get_list_mut: impl FnOnce(&mut T) -> &mut Vec<E>,
    matches: impl Fn(&E) -> bool,
    command_name: &'static str,
    // Renders `NothingToCorrect` wording, which qualifies the aggregate name.
    aggregate_qualified_name: &'static str,
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
    let mut element = ElementHalf {
        parent_id,
        get_list,
        get_list_mut: Some(get_list_mut),
        matches,
        command_name,
        aggregate_qualified_name,
        aggregate_name,
        entity_name,
        entity_identity_reading,
        wants,
        args,
        givens,
        transition,
        apply_mutations: Some(apply_mutations),
        ensures,
        parent_in_args,
        position: None,
        element: None,
        parent_before: None,
        old_snapshot: None,
    };
    for step in EntityStep::ORDER {
        element.run(step, record)?;
    }
    Ok(())
}

/// The element half's state, carried across `EntityStep::ORDER` — what
/// `apply_entity_command` and `dispatch_entity` both drive, one step at a
/// time, so a refusal reads identically through either caller.
struct ElementHalf<'a, 's, T, E, GetList, GetListMut, Matches, Apply> {
    parent_id: &'s str,
    get_list: GetList,
    get_list_mut: Option<GetListMut>,
    matches: Matches,
    command_name: &'static str,
    aggregate_qualified_name: &'static str,
    aggregate_name: &'static str,
    entity_name: &'static str,
    entity_identity_reading: &'static str,
    wants: &'s str,
    args: &'a dyn Fielded,
    givens: &'s [GivenSpec],
    transition: Option<TransitionCheck>,
    apply_mutations: Option<Apply>,
    ensures: &'s [EnsuresSpec],
    parent_in_args: bool,
    position: Option<usize>,
    element: Option<E>,
    parent_before: Option<T>,
    old_snapshot: Option<E>,
}

impl<'a, 's, T, E, GetList, GetListMut, Matches, Apply> ElementHalf<'a, 's, T, E, GetList, GetListMut, Matches, Apply>
where
    T: Fielded + Clone,
    E: Fielded + Clone,
    GetList: Fn(&T) -> &Vec<E>,
    GetListMut: FnOnce(&mut T) -> &mut Vec<E>,
    Matches: Fn(&E) -> bool,
    Apply: FnOnce(&mut E) -> Result<(), Refusal>,
{
    /// One declared entity step against the parent `record` already in hand.
    fn run(&mut self, step: EntityStep, record: &mut T) -> Result<(), Refusal> {
        #[deny(clippy::wildcard_enum_match_arm)]
        match step {
            // Already run by `decode_entity_arguments`; see `entity_step_site`.
            EntityStep::DecodeArguments
            | EntityStep::RefuseUnknownArguments
            | EntityStep::RefuseAbsentArguments
            | EntityStep::NormalizeArgs
            | EntityStep::RefuseRoleMismatch
            | EntityStep::ResolveReferences => Ok(()),
            // The parent half: `dispatch_entity`'s own arms, or the delegating aggregate's
            // `dispatch`.
            EntityStep::HydrateParent | EntityStep::EnforceInvariants | EntityStep::Save | EntityStep::Emit => Ok(()),
            EntityStep::LocateElement => self.locate_element(record),
            EntityStep::EnforceGivens => self.enforce_givens(),
            EntityStep::AdmissibleTransition => {
                admissible_transition(self.element.as_ref().expect(LOCATED), self.transition.as_ref(), self.command_name)
            }
            EntityStep::ApplyMutations => self.apply_mutations(record),
            // Written by the generated `apply_mutations` closure (the entity's own lifecycle).
            EntityStep::AdvanceLifecycle => Ok(()),
            EntityStep::EnforceEnsures => self.enforce_ensures(record),
        }
    }

    fn locate_element(&mut self, record: &T) -> Result<(), Refusal> {
        let position = (self.get_list)(record).iter().position(|el| (self.matches)(el)).ok_or_else(|| {
            Refusal::NotFound(
                NotFoundEntityElementMissingArgs {
                    entity: self.entity_name,
                    identity: self.entity_identity_reading,
                    wants: self.wants,
                    aggregate: self.aggregate_name,
                    parent_id: &format!("{:?}", self.parent_id),
                }
                .render_args(),
            )
        })?;
        self.element = Some((self.get_list)(record)[position].clone());
        self.position = Some(position);
        self.parent_before = Some(record.clone());
        Ok(())
    }

    fn enforce_givens(&self) -> Result<(), Refusal> {
        let parent_before = self.parent_before.as_ref().expect(LOCATED);
        let element = self.element.as_ref().expect(LOCATED);

        // Entity-level `corrects` is asked of the parent record and root aggregate, since an
        // entity has no event stream. It runs after the element lookup, before declared givens,
        // and proves the parent emitted the event, not that this element did.
        for given in self.givens {
            let Some(event_name) = given.corrects_event else { continue };
            let ctx = EvalContext { args: self.args, instance: parent_before };
            if !interpret(&given.expr, &ctx)?.truthy() {
                return Err(Refusal::NothingToCorrect(format!(
                    "{} refused — corrects {event_name}, but {} #{} has never emitted it",
                    self.command_name, self.aggregate_qualified_name, self.parent_id
                )));
            }
        }

        let with_parent = WithParent { args: self.args, parent: parent_before };
        let given_args: &dyn Fielded = if self.parent_in_args { &with_parent } else { self.args };
        for given in self.givens {
            // Handled above; the `corrects` flag field lives on the parent, not the element.
            if given.corrects_event.is_some() {
                continue;
            }
            let ctx = EvalContext { args: given_args, instance: element };
            if !interpret(&given.expr, &ctx)?.truthy() {
                return Err(Refusal::GivenNotMet(format!("{} refused — {}", self.command_name, given.description)));
            }
        }
        Ok(())
    }

    fn apply_mutations(&mut self, record: &mut T) -> Result<(), Refusal> {
        let position = self.position.expect(LOCATED);
        let mut element = self.element.take().expect(LOCATED);
        self.old_snapshot = if self.ensures.is_empty() { None } else { Some(element.clone()) };
        (self.apply_mutations.take().expect(ONCE))(&mut element)?;
        (self.get_list_mut.take().expect(ONCE))(record)[position] = element;
        Ok(())
    }

    fn enforce_ensures(&self, record: &T) -> Result<(), Refusal> {
        let Some(old) = &self.old_snapshot else { return Ok(()) };
        let position = self.position.expect(LOCATED);
        let parent_after = record.clone();
        let with_parent = WithParent { args: self.args, parent: &parent_after };
        let ensures_args: &dyn Fielded = if self.parent_in_args { &with_parent } else { self.args };
        let settled = &(self.get_list)(record)[position];
        enforce_ensures(settled, old, ensures_args, self.ensures, self.command_name)
    }
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
    invariants: &InvariantSet,
    emits: &[&'static str],
    payload: Json,
    mutations: &mut Vec<MutationRecord>,
    // As in `dispatch`: an entity command still ends in a parent aggregate save.
    seed_projections: Vec<(&'static str, Option<Value>)>,
) -> Result<(T, Vec<Event>), Refusal>
where
    T: Fielded + Clone + ToJson + SetProjectedField,
    E: Fielded + Clone,
    R: Repository<T>,
{
    let mut element = ElementHalf {
        parent_id,
        get_list,
        get_list_mut: Some(get_list_mut),
        matches,
        command_name,
        aggregate_qualified_name,
        aggregate_name,
        entity_name,
        entity_identity_reading,
        wants,
        args,
        givens,
        transition,
        apply_mutations: Some(apply_mutations),
        ensures,
        // See `apply_entity_command` on `parent_in_args`.
        parent_in_args: true,
        position: None,
        element: None,
        parent_before: None,
        old_snapshot: None,
    };
    let mut seed_projections = Some(seed_projections);
    let mut hydrated: Option<T> = None;
    let mut events: Vec<Event> = Vec::new();

    for step in EntityStep::ORDER {
        #[deny(clippy::wildcard_enum_match_arm)]
        match step {
            // Already run by `decode_entity_arguments`; see `entity_step_site`.
            EntityStep::DecodeArguments
            | EntityStep::RefuseUnknownArguments
            | EntityStep::RefuseAbsentArguments
            | EntityStep::NormalizeArgs
            | EntityStep::RefuseRoleMismatch
            | EntityStep::ResolveReferences => {}
            EntityStep::HydrateParent => {
                // Same `record_missing` site as `hydrate_record`.
                hydrated = Some(repo.find(parent_id).ok_or_else(|| {
                    Refusal::NotFound(
                        NotFoundRecordMissingArgs {
                            aggregate: aggregate_name,
                            identity: parent_identity_reading,
                            offered: &format!("{parent_id:?}"),
                        }
                        .render_args(),
                    )
                })?);
            }
            // The element half: the same per-step body `apply_entity_command` runs.
            EntityStep::LocateElement
            | EntityStep::EnforceGivens
            | EntityStep::AdmissibleTransition
            | EntityStep::ApplyMutations
            | EntityStep::AdvanceLifecycle
            | EntityStep::EnforceEnsures => {
                element.run(step, hydrated.as_mut().expect(HYDRATED))?;
            }
            EntityStep::EnforceInvariants => {
                enforce_invariants(hydrated.as_ref().expect(HYDRATED), aggregate_name, invariants)?;
            }
            EntityStep::Save => {
                let record = hydrated.as_mut().expect(HYDRATED);
                for (field, value) in seed_projections.take().expect(ONCE) {
                    record.set_projected_field(field, value);
                }
                persist(repo, parent_id, record, aggregate_qualified_name, mutations);
            }
            EntityStep::Emit => {
                events = emitted(emits, aggregate_qualified_name, parent_id, &payload);
            }
        }
    }

    Ok((hydrated.expect(HYDRATED), events))
}

const HYDRATED: &str = "the declared order hydrates before any step that reads the record (const-asserted in this file)";
const LOCATED: &str = "the declared order locates the element before any step that reads it (const-asserted in this file)";
const ONCE: &str = "each declared step appears exactly once in its ORDER";
const NORMALIZED: &str = "the declared order normalizes arguments before resolving references (const-asserted in this file)";

/// One generated hook per argument-gate step, called in declared order by
/// `decode_aggregate_arguments` and `decode_entity_arguments`.
///
/// `normalize_args` produces the typed `<Args>` that `resolve_references` reads.
pub struct ArgumentGates<'g, A> {
    pub decode_arguments: &'g dyn Fn(&Json) -> Result<(), Refusal>,
    pub refuse_unknown_arguments: &'g dyn Fn(&Json) -> Result<(), Refusal>,
    pub refuse_absent_arguments: &'g dyn Fn(&Json) -> Result<(), Refusal>,
    pub normalize_args: &'g dyn Fn(&Json) -> Result<A, Refusal>,
    pub refuse_role_mismatch: &'g dyn Fn() -> Result<(), Refusal>,
    pub resolve_references: &'g dyn Fn(&A) -> Result<(), Refusal>,
}

/// The argument-gate steps the aggregate and entity orders share, so one
/// body (`ArgumentGates::run`) serves both loops.
#[derive(Debug, Clone, Copy)]
enum ArgumentGate {
    DecodeArguments,
    RefuseUnknownArguments,
    RefuseAbsentArguments,
    NormalizeArgs,
    RefuseRoleMismatch,
    ResolveReferences,
}

impl<A> ArgumentGates<'_, A> {
    fn run(&self, gate: ArgumentGate, facts: &Json, args: &mut Option<A>) -> Result<(), Refusal> {
        match gate {
            ArgumentGate::DecodeArguments => (self.decode_arguments)(facts),
            ArgumentGate::RefuseUnknownArguments => (self.refuse_unknown_arguments)(facts),
            ArgumentGate::RefuseAbsentArguments => (self.refuse_absent_arguments)(facts),
            ArgumentGate::NormalizeArgs => {
                *args = Some((self.normalize_args)(facts)?);
                Ok(())
            }
            ArgumentGate::RefuseRoleMismatch => (self.refuse_role_mismatch)(),
            ArgumentGate::ResolveReferences => (self.resolve_references)(args.as_ref().expect(NORMALIZED)),
        }
    }
}

/// `AggregateStep::ORDER`'s argument gates over one aggregate command's facts:
/// the normalized `<Args>`, or the first refusal in declared order. Every
/// other step is `dispatch`'s, entered once the router has resolved identity.
pub fn decode_aggregate_arguments<A>(facts: &Json, gates: &ArgumentGates<'_, A>) -> Result<A, Refusal> {
    let mut args = None;
    for step in AggregateStep::ORDER {
        #[deny(clippy::wildcard_enum_match_arm)]
        let gate = match step {
            AggregateStep::DecodeArguments => ArgumentGate::DecodeArguments,
            AggregateStep::RefuseUnknownArguments => ArgumentGate::RefuseUnknownArguments,
            AggregateStep::RefuseAbsentArguments => ArgumentGate::RefuseAbsentArguments,
            AggregateStep::NormalizeArgs => ArgumentGate::NormalizeArgs,
            AggregateStep::RefuseRoleMismatch => ArgumentGate::RefuseRoleMismatch,
            AggregateStep::ResolveReferences => ArgumentGate::ResolveReferences,
            AggregateStep::Hydrate
            | AggregateStep::EnforceGivens
            | AggregateStep::AdmissibleTransition
            | AggregateStep::AssignCreationAttributes
            | AggregateStep::ApplyMutations
            | AggregateStep::AdvanceLifecycle
            | AggregateStep::DelegateToEntity
            | AggregateStep::EnforceEnsures
            | AggregateStep::EnforceInvariants
            | AggregateStep::Save
            | AggregateStep::Emit => continue,
        };
        gates.run(gate, facts, &mut args)?;
    }
    Ok(args.expect(NORMALIZED))
}

/// `EntityStep::ORDER`'s argument gates over one entity command's facts — see
/// `decode_aggregate_arguments`. Every other step is `dispatch_entity`'s.
pub fn decode_entity_arguments<A>(facts: &Json, gates: &ArgumentGates<'_, A>) -> Result<A, Refusal> {
    let mut args = None;
    for step in EntityStep::ORDER {
        #[deny(clippy::wildcard_enum_match_arm)]
        let gate = match step {
            EntityStep::DecodeArguments => ArgumentGate::DecodeArguments,
            EntityStep::RefuseUnknownArguments => ArgumentGate::RefuseUnknownArguments,
            EntityStep::RefuseAbsentArguments => ArgumentGate::RefuseAbsentArguments,
            EntityStep::NormalizeArgs => ArgumentGate::NormalizeArgs,
            EntityStep::RefuseRoleMismatch => ArgumentGate::RefuseRoleMismatch,
            EntityStep::ResolveReferences => ArgumentGate::ResolveReferences,
            EntityStep::HydrateParent
            | EntityStep::LocateElement
            | EntityStep::EnforceGivens
            | EntityStep::AdmissibleTransition
            | EntityStep::ApplyMutations
            | EntityStep::AdvanceLifecycle
            | EntityStep::EnforceEnsures
            | EntityStep::EnforceInvariants
            | EntityStep::Save
            | EntityStep::Emit => continue,
        };
        gates.run(gate, facts, &mut args)?;
    }
    Ok(args.expect(NORMALIZED))
}

/// A step's index in `AggregateStep::ORDER`, usable in a const context.
const fn aggregate_position(step: AggregateStep) -> usize {
    let mut index = 0;
    while index < AggregateStep::ORDER.len() {
        if AggregateStep::ORDER[index] as usize == step as usize {
            return index;
        }
        index += 1;
    }
    panic!("step missing from AggregateStep::ORDER")
}

/// A step's index in `EntityStep::ORDER`, usable in a const context.
const fn entity_position(step: EntityStep) -> usize {
    let mut index = 0;
    while index < EntityStep::ORDER.len() {
        if EntityStep::ORDER[index] as usize == step as usize {
            return index;
        }
        index += 1;
    }
    panic!("step missing from EntityStep::ORDER")
}

// Pairs where an arm consumes what an earlier arm produced; reordering them in
// vocabulary.bluebook fails the build instead of panicking at dispatch time.
const _: () = {
    use AggregateStep as A;
    let hydrate = aggregate_position(A::Hydrate);
    assert!(hydrate < aggregate_position(A::EnforceGivens));
    assert!(hydrate < aggregate_position(A::AdmissibleTransition));
    assert!(hydrate < aggregate_position(A::ApplyMutations));
    assert!(hydrate < aggregate_position(A::EnforceEnsures));
    assert!(hydrate < aggregate_position(A::EnforceInvariants));
    assert!(hydrate < aggregate_position(A::Save));
    assert!(hydrate < aggregate_position(A::Emit));
    // `old_snapshot` is taken in ApplyMutations; an EnforceEnsures before it
    // would see none and skip every ensures.
    assert!(aggregate_position(A::ApplyMutations) < aggregate_position(A::EnforceEnsures));
    // The router resolves identity only after `decode_aggregate_arguments`
    // returns, so every argument gate must be declared ahead of `hydrate`;
    // `resolve_references` reads the `<Args>` `normalize_args` produced.
    assert!(aggregate_position(A::DecodeArguments) < hydrate);
    assert!(aggregate_position(A::RefuseUnknownArguments) < hydrate);
    assert!(aggregate_position(A::RefuseAbsentArguments) < hydrate);
    assert!(aggregate_position(A::NormalizeArgs) < hydrate);
    assert!(aggregate_position(A::RefuseRoleMismatch) < hydrate);
    assert!(aggregate_position(A::ResolveReferences) < hydrate);
    assert!(aggregate_position(A::NormalizeArgs) < aggregate_position(A::ResolveReferences));

    use EntityStep as E;
    let hydrate_parent = entity_position(E::HydrateParent);
    assert!(hydrate_parent < entity_position(E::LocateElement));
    assert!(hydrate_parent < entity_position(E::EnforceInvariants));
    assert!(hydrate_parent < entity_position(E::Save));
    let locate = entity_position(E::LocateElement);
    assert!(locate < entity_position(E::EnforceGivens));
    assert!(locate < entity_position(E::AdmissibleTransition));
    assert!(locate < entity_position(E::ApplyMutations));
    // ApplyMutations moves the element back into the parent's list.
    assert!(entity_position(E::EnforceGivens) < entity_position(E::ApplyMutations));
    assert!(entity_position(E::AdmissibleTransition) < entity_position(E::ApplyMutations));
    assert!(entity_position(E::ApplyMutations) < entity_position(E::EnforceEnsures));
    // See the aggregate half: identity (parent, then element) is resolved
    // only after `decode_entity_arguments` returns.
    assert!(entity_position(E::DecodeArguments) < hydrate_parent);
    assert!(entity_position(E::RefuseUnknownArguments) < hydrate_parent);
    assert!(entity_position(E::RefuseAbsentArguments) < hydrate_parent);
    assert!(entity_position(E::NormalizeArgs) < hydrate_parent);
    assert!(entity_position(E::RefuseRoleMismatch) < hydrate_parent);
    assert!(entity_position(E::ResolveReferences) < hydrate_parent);
    assert!(entity_position(E::NormalizeArgs) < entity_position(E::ResolveReferences));
};

/// Where a declared dispatch step is actually performed in the Rust port.
/// The dispatch loops above follow this mapping.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepSite {
    /// An arm of the kernel's own dispatch loop does the work.
    Kernel,
    /// `decode_aggregate_arguments`/`decode_entity_arguments` call this
    /// step's generated hook (`ArgumentGates`) in its declared position,
    /// before the router resolves identity. `dispatch`'s own arm is a no-op.
    ArgumentGate,
    /// Folded into a generated closure the kernel already calls in another
    /// step's arm (named here). The loop's own arm is a no-op.
    FoldedInto(AggregateStepOrEntityStep),
}

/// The step a `StepSite::FoldedInto` step rides inside.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AggregateStepOrEntityStep {
    Aggregate(AggregateStep),
    Entity(EntityStep),
}

/// See `StepSite`. Exhaustive, no wildcard — a step the vocabulary gains
/// must be placed here before the crate compiles.
#[deny(clippy::wildcard_enum_match_arm)]
pub const fn aggregate_step_site(step: AggregateStep) -> StepSite {
    use AggregateStep as A;
    match step {
        // `<Args>::decode_arguments` (the facts are an object).
        A::DecodeArguments => StepSite::ArgumentGate,
        // `<Args>::refuse_unknown_arguments`/`<Args>::refuse_absent_arguments`.
        A::RefuseUnknownArguments | A::RefuseAbsentArguments => StepSite::ArgumentGate,
        // `<Args>::from_json`'s coercion + the router's invariant checks.
        A::NormalizeArgs => StepSite::ArgumentGate,
        // `kernel::check_role_via`.
        A::RefuseRoleMismatch => StepSite::ArgumentGate,
        // `kernel::check_reference`; the router computes the tenant boundary
        // after it, but the kernel's `Save` arm applies it.
        A::ResolveReferences => StepSite::ArgumentGate,
        A::Hydrate => StepSite::Kernel,
        A::EnforceGivens => StepSite::Kernel,
        A::AdmissibleTransition => StepSite::Kernel,
        // `Hydrate::Create.build`.
        A::AssignCreationAttributes => StepSite::FoldedInto(AggregateStepOrEntityStep::Aggregate(A::Hydrate)),
        A::ApplyMutations => StepSite::Kernel,
        // The generated `apply_mutations` closure's last line.
        A::AdvanceLifecycle => StepSite::FoldedInto(AggregateStepOrEntityStep::Aggregate(A::ApplyMutations)),
        // The generated `apply_mutations` closure → `apply_entity_command`.
        A::DelegateToEntity => StepSite::FoldedInto(AggregateStepOrEntityStep::Aggregate(A::ApplyMutations)),
        A::EnforceEnsures => StepSite::Kernel,
        A::EnforceInvariants => StepSite::Kernel,
        A::Save => StepSite::Kernel,
        A::Emit => StepSite::Kernel,
    }
}

/// See `StepSite`. Exhaustive, no wildcard.
#[deny(clippy::wildcard_enum_match_arm)]
pub const fn entity_step_site(step: EntityStep) -> StepSite {
    use EntityStep as E;
    match step {
        // The `<EntityArgs>` functions and checks named in
        // `aggregate_step_site`, through `decode_entity_arguments`.
        E::DecodeArguments => StepSite::ArgumentGate,
        E::RefuseUnknownArguments | E::RefuseAbsentArguments => StepSite::ArgumentGate,
        E::NormalizeArgs => StepSite::ArgumentGate,
        E::RefuseRoleMismatch => StepSite::ArgumentGate,
        E::ResolveReferences => StepSite::ArgumentGate,
        E::HydrateParent => StepSite::Kernel,
        E::LocateElement => StepSite::Kernel,
        E::EnforceGivens => StepSite::Kernel,
        E::AdmissibleTransition => StepSite::Kernel,
        E::ApplyMutations => StepSite::Kernel,
        E::AdvanceLifecycle => StepSite::FoldedInto(AggregateStepOrEntityStep::Entity(E::ApplyMutations)),
        E::EnforceEnsures => StepSite::Kernel,
        E::EnforceInvariants => StepSite::Kernel,
        E::Save => StepSite::Kernel,
        E::Emit => StepSite::Kernel,
    }
}

#[cfg(test)]
#[path = "dispatch_guard_tests.rs"]
mod guard_tests;

// No `match step` above has a wildcard arm, so a step added to the vocabulary fails to
// compile (E0004) until placed. The tests pin the current kernel/argument-gate mapping.
#[cfg(test)]
mod step_order_tests {
    use super::*;

    #[test]
    fn decode_arguments_leads_both_orders() {
        assert_eq!(AggregateStep::ORDER[0], AggregateStep::DecodeArguments);
        assert_eq!(EntityStep::ORDER[0], EntityStep::DecodeArguments);
    }

    #[test]
    fn const_positions_agree_with_the_generated_ones() {
        for step in AggregateStep::ORDER {
            assert_eq!(aggregate_position(step), step.position());
        }
        for step in EntityStep::ORDER {
            assert_eq!(entity_position(step), step.position());
        }
    }

    #[test]
    fn the_kernel_performs_exactly_these_aggregate_steps() {
        let kernel: Vec<&str> =
            AggregateStep::ORDER.iter().filter(|s| aggregate_step_site(**s) == StepSite::Kernel).map(|s| s.step()).collect();
        assert_eq!(
            kernel,
            ["hydrate", "enforce_givens", "admissible_transition", "apply_mutations", "enforce_ensures", "enforce_invariants", "save", "emit"]
        );
    }

    #[test]
    fn the_kernel_performs_exactly_these_entity_steps() {
        let kernel: Vec<&str> =
            EntityStep::ORDER.iter().filter(|s| entity_step_site(**s) == StepSite::Kernel).map(|s| s.step()).collect();
        assert_eq!(
            kernel,
            [
                "hydrate_parent",
                "locate_element",
                "enforce_givens",
                "admissible_transition",
                "apply_mutations",
                "enforce_ensures",
                "enforce_invariants",
                "save",
                "emit"
            ]
        );
    }

    #[test]
    fn argument_gates_all_precede_the_first_kernel_step() {
        // The router resolves identity between the two loops, so every
        // argument gate sits ahead of the first kernel step.
        let first_kernel = AggregateStep::ORDER.iter().position(|s| aggregate_step_site(*s) == StepSite::Kernel).unwrap();
        for step in AggregateStep::ORDER {
            if aggregate_step_site(step) == StepSite::ArgumentGate {
                assert!(step.position() < first_kernel, "{} is an argument gate but is declared after hydrate", step.step());
            }
        }
        let first_kernel = EntityStep::ORDER.iter().position(|s| entity_step_site(*s) == StepSite::Kernel).unwrap();
        for step in EntityStep::ORDER {
            if entity_step_site(step) == StepSite::ArgumentGate {
                assert!(step.position() < first_kernel, "{} is an argument gate but is declared after hydrate_parent", step.step());
            }
        }
    }

    use std::cell::RefCell;

    /// Hooks that record which step ran, refusing at the steps named in `refuse`.
    fn recorded<R>(refuse: &[&'static str], body: impl FnOnce(&ArgumentGates<'_, i64>) -> R) -> (R, Vec<&'static str>) {
        let ran = RefCell::new(Vec::new());
        let hit = |step: &'static str| -> Result<(), Refusal> {
            ran.borrow_mut().push(step);
            if refuse.contains(&step) {
                Err(Refusal::TypeMismatch(step.to_string()))
            } else {
                Ok(())
            }
        };
        let decode = |_: &Json| hit("decode_arguments");
        let unknown = |_: &Json| hit("refuse_unknown_arguments");
        let absent = |_: &Json| hit("refuse_absent_arguments");
        let normalize = |_: &Json| hit("normalize_args").map(|()| 7);
        let role = || hit("refuse_role_mismatch");
        let references = |args: &i64| {
            assert_eq!(*args, 7, "resolve_references reads what normalize_args produced");
            hit("resolve_references")
        };
        let gates = ArgumentGates {
            decode_arguments: &decode,
            refuse_unknown_arguments: &unknown,
            refuse_absent_arguments: &absent,
            normalize_args: &normalize,
            refuse_role_mismatch: &role,
            resolve_references: &references,
        };
        let result = body(&gates);
        (result, ran.into_inner())
    }

    #[test]
    fn the_argument_gate_loops_call_every_hook_in_declared_order() {
        let facts = Json::Object(Vec::new());
        let (result, ran) = recorded(&[], |gates| decode_aggregate_arguments(&facts, gates));
        assert_eq!(result.unwrap(), 7);
        let declared: Vec<&str> =
            AggregateStep::ORDER.iter().filter(|s| aggregate_step_site(**s) == StepSite::ArgumentGate).map(|s| s.step()).collect();
        assert_eq!(ran, declared);

        let (result, ran) = recorded(&[], |gates| decode_entity_arguments(&facts, gates));
        assert_eq!(result.unwrap(), 7);
        let declared: Vec<&str> =
            EntityStep::ORDER.iter().filter(|s| entity_step_site(**s) == StepSite::ArgumentGate).map(|s| s.step()).collect();
        assert_eq!(ran, declared);
    }

    #[test]
    fn the_earliest_declared_violated_gate_wins_and_later_hooks_never_run() {
        let facts = Json::Object(Vec::new());
        let gates: Vec<&'static str> =
            AggregateStep::ORDER.iter().filter(|s| aggregate_step_site(**s) == StepSite::ArgumentGate).map(|s| s.step()).collect();
        for (i, earlier) in gates.iter().enumerate() {
            for later in &gates[i + 1..] {
                let (result, ran) = recorded(&[earlier, later], |g| decode_aggregate_arguments(&facts, g));
                assert_eq!(result.unwrap_err().to_string(), Refusal::TypeMismatch(earlier.to_string()).to_string());
                assert_eq!(ran.last(), Some(earlier));
                let (result, _) = recorded(&[earlier, later], |g| decode_entity_arguments(&facts, g));
                assert_eq!(result.unwrap_err().to_string(), Refusal::TypeMismatch(earlier.to_string()).to_string());
            }
        }
    }
}
