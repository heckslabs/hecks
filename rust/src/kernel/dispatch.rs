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
// repository.rs) are generated per command — the router is the one place
// with access to every OTHER aggregate's repo, not just this command's
// own — but they are no longer emitted as bare lines in whatever order
// the router happened to write them: the router hands them to
// `decode_aggregate_arguments`/`decode_entity_arguments` below as two
// fields of `ArgumentGates`, and the loop calls them in the position
// `refuse_role_mismatch`/`resolve_references` hold in the declared order.

//
// THE ORDER ITSELF IS NOT WRITTEN IN THIS FILE. `dispatch`,
// `apply_entity_command` and `dispatch_entity` each loop over the language's
// own declared step order — `AggregateStep::ORDER`/`EntityStep::ORDER`
// (kernel/vocab/, projected from vocabulary.bluebook's
// AggregateDispatchOrder/EntityDispatchOrder by bin/project_rust_vocabulary)
// — and `match` every step exhaustively, with no wildcard arm, so a step the
// language gains fails to compile here (E0004) until it is given an arm.
// The argument-gate steps (decode_arguments through resolve_references) are
// no-op arms in `dispatch`/`dispatch_entity`: they run in
// `decode_aggregate_arguments`/`decode_entity_arguments`, below — the SAME
// kind of loop over the SAME `ORDER`, calling one generated hook per step
// (`ArgumentGates`). They are a separate loop only because identity
// resolution needs the decoded facts and `resolve_references`/
// `refuse_role_mismatch` need the whole `Store` (every other aggregate's
// repo) — which the router can lend a closure but `dispatch` cannot hold
// while it also holds `&mut` this aggregate's own repo. Reordering the
// argument gates in vocabulary.bluebook reorders their refusals with no
// generator change; a gate moved past `hydrate` fails the const assertions
// at the bottom of this file. `aggregate_step_site`/`entity_step_site` name
// where every step runs.

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

/// `enforce_invariants` — `CommandRules::Admissibility#enforce_invariants`
/// + `#check_entity_invariants`, read directly (docs/semantics/
/// bluebook-semantics.md C6.2). Runs after `ensures`, before save, on the
/// CANDIDATE record: the aggregate's own rules with no argument scope
/// (`NoFields` — Ruby's `attrs = {}`), then every element of every
/// entity list whose entity declares invariants, with `parent` bound to
/// the owner (`WithParent`), recursing into nested pieces exactly as Ruby
/// does — an entity with NO invariants of its own is not descended into,
/// matching `check_entity_invariants`' own `next if invariants.empty?`.
/// Generated once per aggregate (`<aggregate>_invariants()`, `rust/
/// project/commands.rb#emit_invariants_fn`) and passed to every dispatch
/// of that aggregate's commands, entity commands included — Ruby checks
/// the PARENT on an entity command too (`EntityInterpreter
/// #step_enforce_invariants`).
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
            // `"#{aggregate.hecks_name} refused — #{invariant.description}"`
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
                // `"#{entity.hecks_name} refused — #{invariant.description}"`
                return Err(Refusal::InvariantViolation(format!("{} refused — {}", entity.name, rule.description)));
            }
        }
        for nested in &entity.nested {
            enforce_entity_invariants(element, nested)?;
        }
    }
    Ok(())
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
    ///
    /// `state_independent` — BUG#28: Ruby has NO single fixed position for
    /// a creating command's `AlreadyExists` check relative to `enforce_
    /// givens`/`enforce_ensures`/`enforce_invariants`; it depends on
    /// `DependencyPlanning::Analyzer` classification. `hydrate_prior_or_
    /// initial` (state-dependent — a `from:`/state-reading `given`) and
    /// `hydrate_legacy_creation` both check eagerly, BEFORE any given —
    /// that's `state_independent: false`, unchanged from this field's own
    /// prior unconditional behavior. `hydrate_complete_state`, when the
    /// command is BOTH `complete_state?` AND `state_independent?` (every
    /// `given`/`ensures`/mutation reads a fresh command argument or a
    /// literal, never the aggregate's own not-yet-existing state) on an
    /// `atomic_put`-capable adapter, explicitly SKIPS its eager check and
    /// defers ALL THE WAY to `step_save` → `persist_instance` →
    /// `repository.atomic_put(insert_only: true)` — AFTER `enforce_
    /// givens`, `admissible_transition`, `apply_mutations`, `enforce_
    /// ensures` AND `enforce_invariants` have all already run. THAT is
    /// `state_independent: true` — see `dispatch`'s own body, below, for
    /// where the deferred check actually happens (immediately before
    /// `repo.save`, mirroring `persist_instance`'s own position exactly).
    ///
    /// Generated by `rust/project/dependency_planning.rb` (Ruby-hosted
    /// codegen) and `rust/codegen/src/dependency_planning.rs` (Rust-native
    /// codegen) — two INDEPENDENT ports of `Runtime::DependencyPlanning
    /// ::Analyzer`'s `complete_state? && state_independent?` predicate,
    /// each derived straight from ir.json's already-exported fields
    /// (attributes/mutations/givens/ensures ASTs/lifecycle), never a new
    /// wire-format field — see those two files' own headers for why: a
    /// precomputed sidecar fact would need `rust/parser`'s `hecks-parse`
    /// (a THIRD, separate IR producer) to also learn to compute it, which
    /// this fix does not attempt. `spec/codegen_parity_spec.rb`'s existing
    /// whole-file byte-identity check is what proves the two agree.
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
    invariants: &InvariantSet,
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
    // BUG#139 — `CommandRules::References#enforce_tenant_boundary`
    // (ANGLE-8's write-side tenant boundary, PR #595), DEFERRED to this
    // exact point rather than checked eagerly at the router. Ruby's own
    // `CommandInterpreter#step_save`, read directly: `resolve_state_
    // references` (which calls `enforce_tenant_boundary`) runs FIRST,
    // unconditionally, THEN — only for a real (non-dry-run) dispatch —
    // `seed_projected_fields`/`persist_instance`. So this is checked
    // HERE, right after `enforce_invariants`, strictly BEFORE
    // `seed_projections` below and BEFORE the deferred existence check
    // (BUG#28's own) that follows it — mirroring `step_save`'s real
    // order exactly: hydrate/givens/mutations/ensures/invariants have
    // ALL already had their say by this point, the same as Ruby's own
    // `enforce_tenant_boundary` running well after `step_hydrate`'s own
    // route-vs-derived-identity check (BUG#37/PR#606), never before it.
    //
    // The ROUTER (`registry.rb`/`registry.rs`'s generated code) computes
    // this value EAGERLY — it needs `store` (every OTHER aggregate's own
    // repo, to look up the referenced record's tenant field), which only
    // exists at that level, the same reason `resolve_references`/`check_
    // role` themselves are computed there rather than in this generic,
    // one-aggregate-repo-only function (this file's own top-of-file
    // comment). But computing the CHECK early and RAISING it early are
    // two different things — this parameter is the already-computed
    // `Result` (`Ok(())` for every command with no tenant boundary to
    // check — the overwhelming majority — or the FIRST violation found,
    // matching Ruby's own `.each { ... raise ... }` short-circuit), and
    // this function is the one place both codegen pipelines' generated
    // `dispatch_*` functions converge through, so this is where its
    // APPLICATION defers to, exactly like BUG#28's own existence-check
    // flag below.
    tenant_boundary_check: Result<(), Refusal>,
) -> Result<(T, Vec<Event>), Refusal>
where
    T: Fielded + Clone + ToJson + SetProjectedField,
    R: Repository<T>,
{
    // Set only by a state-independent `Hydrate::Create` (see that variant's
    // own comment) — checked in the `Save` arm, right before `repo.save`,
    // mirroring `persist_instance`'s own ATOMIC_PUT branch position exactly.
    let mut defer_existence_check = false;

    // Every owned or `FnOnce` input is consumed by exactly one arm; `take()`
    // is how the loop hands it over. The const assertions at the bottom of
    // this file prove every arm reading `hydrated` comes after `Hydrate` in
    // the declared order, so the `expect`s below cannot fire.
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
            // Already run, in this same declared order, by
            // `decode_aggregate_arguments` — the router calls it before it
            // resolves identity and enters this function. See
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
            // Folded into `Hydrate::Create.build` (generated): the record
            // `enforce_givens` already evaluated against IS the built one.
            AggregateStep::AssignCreationAttributes => {}
            AggregateStep::ApplyMutations => {
                let (_, record) = hydrated.as_mut().expect(HYDRATED);
                // THE STATE AS THE GIVENS SAW IT — `old` inside an `ensures`,
                // taken right before the mutation that makes it differ from
                // what follows. Only cloned when a real `ensures` needs it,
                // the same guard Ruby's own `step_apply_mutations` uses
                // (`unless ctx.command.ensures.empty?`).
                old_snapshot = if ensures.is_empty() { None } else { Some(record.clone()) };
                (apply_mutations.take().expect(ONCE))(record)?;
            }
            // Written by the generated `apply_mutations` closure itself, as
            // its last line — see `TransitionCheck`'s own comment.
            AggregateStep::AdvanceLifecycle => {}
            // Performed inside the generated `apply_mutations` closure
            // (`delegation_of`, rust/project/commands.rb), which calls
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
                // BUG#139'S OWN FIX — see this function's own header comment
                // on the `tenant_boundary_check` parameter for the full
                // reasoning. First thing in `Save`: the exact position
                // `step_save`'s own `resolve_state_references` call occupies
                // relative to `seed_projected_fields`/`persist_instance` in
                // Ruby — after every OTHER dispatch step has already had its
                // say, strictly before the write half of save begins.
                tenant_boundary_check.take().expect(ONCE)?;

                for (field, value) in seed_projections.take().expect(ONCE) {
                    record.set_projected_field(field, value);
                }

                // BUG#28's DEFERRED HALF — `persist_instance`'s own
                // ATOMIC_PUT branch, read directly: "a second creation is not
                // a fresh one," checked here, now, rather than eagerly at
                // hydration — AFTER givens/transition/mutations/ensures/
                // invariants, the identical position `repository.atomic_put
                // (insert_only: true)` occupies relative to Ruby's own
                // `step_save`. Only ever set by a state-independent
                // `Hydrate::Create` (see that variant's own comment); every
                // other dispatch reaches this a plain no-op.
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
            // `NotFound`/`creating_no_identity` — `Identity.of`
            // (identity.rb), read directly: "A BLANK PART NAMES NOTHING,
            // the same as an ABSENT one — AN ID IS A SCALAR, and '' is
            // not a fact about anything." `CommandInterpreter#hydrate_
            // complete_state`/`#hydrate_prior_or_initial` both raise this
            // exact site the moment `Identity.of` answers `nil` for a
            // creating command, BEFORE `repository.find` ever runs — so
            // a blank identity is refused, never looked up. Every
            // generated `id` expression here is `RefusalSite::
            // NotFoundCreatingNoIdentity` already had a template for (it
            // was declared, verbatim, in refusal_wording.rs from the
            // start) but nothing ever raised it: `Hydrate::Create` took
            // whatever `String` codegen handed it — including "" for a
            // single-component identity whose only part arrived
            // blank — straight to `repo.find`/`build()`, minting a real,
            // empty-string-keyed record Ruby would have refused before
            // ever reaching a store. Checked here, once, generically —
            // every `Hydrate::Create { id, .. }` call site already
            // builds `id` the same way Ruby's own `Naming.identity`
            // joins declared parts, so this is the one place both
            // codegen pipelines' output converges through.
            if id.is_empty() {
                return Err(Refusal::NotFound(
                    NotFoundCreatingNoIdentityArgs { command: command_name, aggregate: aggregate_name, identity: identity_reading }
                        .render_args(),
                ));
            }
            // BUG#28 — a state-independent creating command (see
            // `Hydrate::Create`'s own comment) skips this eager check
            // entirely; it runs again, deferred, in `dispatch`'s `Save` arm.
            if state_independent {
                *defer_existence_check = true;
            } else if repo.find(&id).is_some() {
                // `AlreadyExists`/`creating_duplicate` — `CommandInterpreter
                // #hydrate`'s own second guard, read directly: "a second
                // creation is not a fresh one."
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
            // `NotFound`/`record_missing` — `CommandInterpreter#hydrate`'s
            // own acting-command lookup failure, read directly. Shared
            // with `dispatch_entity`'s own parent lookup below: Ruby's
            // `EntityInterpreter#parent` raises this exact same site for
            // its own failed `repository.find`, not a distinct entity-
            // specific one.
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
            // `corrects` — `CommandRules::Admissibility
            // #enforce_correction_target`'s own dynamic message, read
            // directly: `"#{command.hecks_name} refused — corrects
            // #{event_name}, but #{event_key} ##{instance.id} has never
            // emitted it"` — `event_key` is `"#{domain}::#{aggregate}"`,
            // exactly what `aggregate_qualified_name` already is
            // (`dispatch`'s own header comment on that field).
            if let Some(event_name) = given.corrects_event {
                // ITS OWN CLASS (C8.2/C9.2, spec/corpus/semantics/
                // correction_needs_prior_emission.json): Ruby raises
                // `NothingToCorrect`, not `GivenNotMet` — the corpus
                // compares kinds, and this used to answer the wrong one.
                return Err(Refusal::NothingToCorrect(format!(
                    "{command_name} refused — corrects {event_name}, but {aggregate_qualified_name} #{id} has never emitted it"
                )));
            }
            // `CommandRules::Admissibility#enforce_givens`, read directly:
            // `"#{command.hecks_name} refused — #{given.description}"` —
            // the prefix this field-only message used to be missing.
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
                // `LifecycleRefused`/`transition_blocked` —
                // `admissible_transition` (command_rules/admissibility.rb),
                // read directly. `allowed` there is `candidates.flat_map
                // { |t| Array(t.from) }.uniq` restricted to THIS
                // command's own transitions — exactly what `from_states`
                // already is here (`lifecycle_transition_for`,
                // mutations.rb: `rows.map { |r| r[:from_state] }.uniq`
                // over rows already filtered to this command). Each
                // state's `.inspect` quoting and the " or " join are
                // `allowed`'s own RefusalSiteArgument row, applied by
                // `render_args` — handed over raw here.
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
        // Not a codegen-emitted mismatch a real dispatch should ever hit —
        // the lifecycle field is always a plain string on every generated
        // record. Surfaced as TypeMismatch, the same way an expression
        // evaluation bug is (see expr.rs's own `eval_error`), because
        // reaching this means the GENERATOR is wrong, not that the
        // command was refused for a real business reason. Deliberately
        // NOT one of `RefusalSite`'s templates — Ruby has no equivalent
        // message to match because Ruby's own dynamically-typed record
        // can never reach this branch at all.
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
            // Same prefix, same source: `CommandRules::Admissibility
            // #enforce_ensures` — `"#{command.hecks_name} refused —
            // #{rule.description}"`.
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
            // Stamped later, if at all — `orchestrate`'s own job (mod.rs's
            // `occurred_at`/`correlation` field docs), never this
            // command-shaped constructor's, which has no clock and no
            // notion of "was this dispatch a saga leg."
            occurred_at: None,
            correlation: None,
        })
        .collect()
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
/// given and ensures evaluates against, reading the parent off the LIVE
/// record: before the mutation for the givens, after it for the
/// ensures, which is what Ruby's own in-place element mutation gives it —
/// a chess king's "not left in check" ensures reads the board with the
/// piece already moved.
///
/// BUG#137 — this used to be `false` for a direct entity dispatch (only
/// a delegating door passed `true`), on the theory that the routing
/// layer's own `parent_deref` snapshot (`command_deref`'s `"parent"`
/// entry, fetched BEFORE the command ran) was enough either way. It is
/// enough for a `given` — which wants the pre-mutation parent, exactly
/// what `parent_deref` already is — but never for an `ensures`: nothing
/// ever refreshes that snapshot after `apply_mutations` runs, so an
/// entity-level `ensures` reading `parent.*` on a directly-dispatched
/// command NEVER saw its own element's own mutation (`Roster::Roster.
/// Member.Retire`'s `ensures("someone still serves") { parent.crew.
/// any? { |m| m.status == "active" } }` — examples/roster/bluebook/
/// roster.bluebook — retired the sole active member unconditionally:
/// the stale `parent.crew` snapshot still showed THAT SAME member as
/// `"active"`, so the `any?` trivially always held). Always `true` now,
/// for both callers — `apply_entity_command`'s own local
/// `parent_before`/`parent_after` (below) already replace the routing
/// layer's `parent_deref` for every SAME-aggregate `parent.*` read
/// (`given`/`ensures` alike) without changing what either sees; nothing
/// in the real corpus reads a cross-aggregate `parent.<reference>.*`
/// chain from inside an entity command (`parent_deref`'s one real edge
/// over a plain live-record read), so this is safe for every domain that
/// exists today.
#[allow(clippy::too_many_arguments)]
pub fn apply_entity_command<'a, T, E>(
    record: &mut T,
    parent_id: &str,
    get_list: impl Fn(&T) -> &Vec<E>,
    get_list_mut: impl FnOnce(&mut T) -> &mut Vec<E>,
    matches: impl Fn(&E) -> bool,
    command_name: &'static str,
    // BUG#31 — needed only to render `NothingToCorrect`'s own wording,
    // below, the exact same text `dispatch`'s aggregate-level twin
    // already renders (`"{command_name} refused — corrects {event_name},
    // but {aggregate_qualified_name} #{id} has never emitted it"`).
    // Every OTHER refusal this function renders already uses the bare
    // `aggregate_name` — unaffected, on purpose (see that param's own
    // call sites: Ruby's own `hecks_name`-based wording never qualifies).
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

/// THE ELEMENT HALF'S STATE, carried across `EntityStep::ORDER` — what
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
            // Already run, in declared order, by `decode_entity_arguments`
            // before the router resolves identity — see `entity_step_site`.
            EntityStep::DecodeArguments
            | EntityStep::RefuseUnknownArguments
            | EntityStep::RefuseAbsentArguments
            | EntityStep::NormalizeArgs
            | EntityStep::RefuseRoleMismatch
            | EntityStep::ResolveReferences => Ok(()),
            // THE PARENT HALF — `dispatch_entity`'s own arms, or, behind a
            // delegating door, the delegating aggregate command's own
            // `dispatch` (which hydrates, checks invariants on, saves, and
            // emits for the parent record this element lives in).
            EntityStep::HydrateParent | EntityStep::EnforceInvariants | EntityStep::Save | EntityStep::Emit => Ok(()),
            EntityStep::LocateElement => self.locate_element(record),
            EntityStep::EnforceGivens => self.enforce_givens(),
            EntityStep::AdmissibleTransition => {
                admissible_transition(self.element.as_ref().expect(LOCATED), self.transition.as_ref(), self.command_name)
            }
            EntityStep::ApplyMutations => self.apply_mutations(record),
            // Written by the generated `apply_mutations` closure itself —
            // THE ENTITY's own lifecycle (`lifecycle_transition_for(command,
            // entity)`, rust/project/commands.rb).
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

        // BUG#31 — entity-level `corrects` ADMISSIBILITY, checked against the
        // PARENT record/ROOT aggregate — never the entity's own element —
        // mirroring `EntityInterpreter#step_enforce_givens`'s own BUG#30 fix
        // (`lib/hecks/runtime/entity_interpreter.rb`) exactly: an entity has
        // no event stream of its own, so `enforce_correction_target` has to
        // be asked in the SAME terms `CommandRules::Emission#emit` always
        // stamps an entity command's emitted event with — the ROOT
        // aggregate's own qualified name and the PARENT record's own id,
        // never the entity's. Run AFTER the element lookup (a missing
        // element still answers `NotFound` first — the same order Ruby's own
        // `step_locate_element` -> `step_enforce_givens` already runs in) but
        // BEFORE the entity's own declared `given`s just below (same
        // structural-before-declared ordering `step_enforce_givens` uses).
        // One consequence, same as the aggregate-level check: this only
        // proves "the PARENT record has emitted the named event at some
        // point," never narrowed to this one entity element — a Ledger with
        // three Entries all satisfy the same check.
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
            // Handled above, against the PARENT record — evaluating it
            // again here, against `element`, would look up a flag field
            // that exists on the parent record's own struct, not on the
            // entity element's, the moment a real `corrects`-flagged
            // given ever reaches this path.
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
        // BUG#137 — see `apply_entity_command`'s own header on
        // `parent_in_args` for why a direct dispatch needs `true` here
        // too now, not just a delegating door.
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
            // Already run, in declared order, by `decode_entity_arguments`
            // before the router resolves identity and enters this function —
            // see `entity_step_site`.
            EntityStep::DecodeArguments
            | EntityStep::RefuseUnknownArguments
            | EntityStep::RefuseAbsentArguments
            | EntityStep::NormalizeArgs
            | EntityStep::RefuseRoleMismatch
            | EntityStep::ResolveReferences => {}
            EntityStep::HydrateParent => {
                // Same `record_missing` site `EntityInterpreter#parent` raises —
                // see `hydrate_record` above for the aggregate-level twin.
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
            // THE ELEMENT HALF — the same per-step body `apply_entity_command`
            // runs, so a direct dispatch and a delegating door agree.
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

/// THE ARGUMENT GATES, AS GENERATED HOOKS (roadmap D2) — one hook per
/// argument-gate step of the vocabulary's dispatch orders: Ruby's
/// `ArgumentGate#refuse_unknown_arguments`/`#refuse_absent_arguments`,
/// `Interpreting#normalize_args`, `CommandRules#refuse_role_mismatch`/
/// `#resolve_references`. The router (`rust/project/registry.rb`,
/// `rust/codegen/src/registry.rs`) builds one per command out of that
/// command's generated `<Args>` functions (`json_codec.rb#emit_argument_gates`)
/// and its role/reference checks, and hands it to `decode_aggregate_arguments`
/// or `decode_entity_arguments`, which call the hooks in DECLARED order.
/// Nothing generated names that order, so reordering these steps in
/// vocabulary.bluebook reorders which refusal wins with no generator change.
///
/// `decode_arguments` checks the facts are an object — Ruby's
/// `step_decode_arguments` has nothing left to do because `Invocation`
/// already decoded them (roadmap I2 moves that decode into this step).
/// `normalize_args` answers the typed `<Args>`; `resolve_references` reads it.
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

// THE ORDERINGS THIS FILE'S ARMS READ STATE ACROSS — checked when the crate
// compiles, not when a command runs. The vocabulary is free to reorder any
// other pair (that is a semantic change, and the conformance corpus judges
// it); these are the pairs where an arm consumes what an earlier arm produced,
// so reordering them in vocabulary.bluebook refuses to build rather than
// panicking (`expect`) or silently skipping `ensures` at dispatch time.
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
        // `kernel::check_role`.
        A::RefuseRoleMismatch => StepSite::ArgumentGate,
        // `kernel::check_reference`; the router computes the tenant boundary
        // after it, but the kernel's `Save` arm APPLIES it.
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

// HOW A MISSING ARM FAILS TO BUILD. `AggregateStep`/`EntityStep` are
// generated from vocabulary.bluebook; adding a step there and re-running
// bin/project_rust_vocabulary adds a variant, and every `match step` in this
// file — `dispatch`, `ElementHalf::run`, `dispatch_entity`,
// `decode_aggregate_arguments`, `decode_entity_arguments`,
// `aggregate_step_site`, `entity_step_site` — has no wildcard arm, so rustc
// refuses the crate with E0004 (non-exhaustive patterns) naming the new
// variant. The `#[deny(clippy::wildcard_enum_match_arm)]` on each keeps a
// later `_ =>` from quietly defeating that under clippy. The tests below pin
// the mapping's current shape so a step silently moving between the kernel
// loop and the argument-gate loop is a reviewed diff, not a drift.
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
