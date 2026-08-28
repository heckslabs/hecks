// EXEMPLAR shapes for rust/project/commands.rb — see mod.rs's own header.
//
// `dispatch_fn` is the outer skeleton `emit_command`/`emit_entity_command`
// wrap around `crate::kernel::dispatch`/`dispatch_entity` — the biggest
// remaining hand-interpolated shape in the generator, and the one with
// the most nested brackets or arrays to get wrong. Several of its own
// slots (`Hydrate::Create`/`Hydrate::Act` construction, the creation
// record-field list, `given`/`ensures` `Expr` data literals) stay plain
// Ruby string-building here, deliberately, matching the scoping already
// used throughout this tree: `Expr` literals are out of scope entirely
// (mod.rs's own header on `expr_emitter.rb`), and `Hydrate`/record-field
// construction is the SAME "helper builds one already-proven `field:
// value,` shape" pattern `field_assignment`/`to_json_field` already
// cover — retemplating it a fourth time here buys nothing new. What
// THIS shape is actually proving is the outer `pub fn .. -> DispatchResult
// { .. dispatch(..) .. }` wrapper: the one place a stray brace or comma
// among six different array/closure slots would previously have been
// caught only by `cargo build` on the whole generated tree.
#![allow(dead_code, unused_variables)]

// A real, minimal ENTITY element satisfying `dispatch_entity`'s own
// bounds (`E: Fielded + Clone`) plus the `.identity()` method
// `json.rs`'s own `self_identity` shape generates for every real entity
// — `entity_dispatch_fn` (below) needs a real element type to build a
// `matches: impl Fn(&E) -> bool` closure against.
#[derive(Debug, Clone, PartialEq)]
pub struct TmplElement {
    tmpl_field: i64,
}
impl crate::kernel::Fielded for TmplElement {
    fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {
        None
    }
}
impl TmplElement {
    fn identity(&self) -> String {
        String::new()
    }
    fn extract_id(v: &crate::kernel::Json) -> Result<String, crate::kernel::Refusal> {
        let _ = v;
        Ok(String::new())
    }
    fn extract_wants(v: &crate::kernel::Json) -> String {
        let _ = v;
        String::new()
    }
}

// The entity command's own args struct, as `delegate_prelude` builds it
// from the door's facts — see that shape's own comment below.
#[derive(Debug, Clone, PartialEq)]
pub struct TmplTargetArgs {
    tmpl_field: i64,
}
impl crate::kernel::Fielded for TmplTargetArgs {
    fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {
        None
    }
}
impl TmplTargetArgs {
    fn to_json(&self) -> crate::kernel::Json {
        crate::kernel::Json::Null
    }
    fn from_json(v: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {
        let _ = v;
        Ok(TmplTargetArgs { tmpl_field: 0 })
    }
}

// A real, minimal type satisfying `kernel::dispatch`'s own bounds
// (`T: Fielded + Clone + ToJson`) — standing in for whatever real
// aggregate record a generated `dispatch_*` fn actually targets.
#[derive(Debug, Clone, PartialEq)]
pub struct TmplRecord {
    tmpl_field: i64,
    tmpl_list_field: Vec<TmplElement>,
}
impl crate::kernel::Fielded for TmplRecord {
    fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {
        None
    }
}
impl crate::kernel::ToJson for TmplRecord {
    fn to_json(&self) -> crate::kernel::Json {
        crate::kernel::Json::Null
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct TmplArgs {
    tmpl_field: i64,
}
impl crate::kernel::Fielded for TmplArgs {
    fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {
        None
    }
}
impl TmplArgs {
    fn to_json(&self) -> crate::kernel::Json {
        crate::kernel::Json::Null
    }
}

fn tmpl_hydrate_placeholder() -> crate::kernel::Hydrate<'static, TmplRecord> {
    crate::kernel::Hydrate::Act { id: String::new() }
}

fn tmpl_mutation_lines_placeholder(record: &mut TmplRecord) {}

// TMPL:dispatch_fn BEGIN
pub fn dispatch_tmpl(
    repo: &mut impl crate::kernel::Repository<TmplRecord>, id: &str, args: TmplArgs, mutations: &mut Vec<crate::kernel::MutationRecord>,
) -> crate::kernel::DispatchResult<TmplRecord> {
tmpl_invariant_check_placeholder()?;
    let tmpl_eval_fielded = tmpl_with_references_placeholder();
tmpl_prelude_placeholder();
    crate::kernel::dispatch(
        repo,
        tmpl_hydrate_placeholder(),
        "TmplCmdName",
        "TmplQualifiedName",
        "TmplAggregateName",
        "TmplIdentityReading",
        &tmpl_eval_fielded,
        &[
tmpl_given_spec_placeholder(),
        ],
        tmpl_transition_placeholder(),
        |record| {
tmpl_mutation_lines_placeholder(record);
            Ok(())
        },
        &[
tmpl_ensures_spec_placeholder(),
        ],
        &[tmpl_emit_placeholder()],
        args.to_json(),
        mutations,
    )
}
// TMPL:dispatch_fn END

fn tmpl_invariant_check_placeholder() -> Result<(), crate::kernel::Refusal> {
    Ok(())
}
// `tmpl_prelude_placeholder` — the line between the references binding
// and the `dispatch` call. Every ordinary command substitutes it away
// to nothing (so the shape keeps its one blank line there, unchanged);
// a DELEGATING command (`delegates_to`, `commands.rb`'s own
// `emit_delegation`) substitutes the rendered `delegate_prelude`
// shape, below — bindings the closure and the payload both need
// before `dispatch` is entered.
fn tmpl_prelude_placeholder() {}
// `tmpl_with_references_placeholder` — the real substitution is a
// `crate::kernel::WithReferences` literal (`commands.rb`'s own
// `with_references_binding`), the SAME cross-aggregate-dereference
// Fielded surface `given`/`ensures` evaluation reads as `EvalContext.
// args` (`reference_lookup.rs`'s own header) — standing in here as
// plain `TmplArgs` only so this exemplar keeps compiling on its own;
// `WithReferences` isn't reachable from a bare `TmplArgs` value, but
// `&tmpl_eval_fielded` only needs SOME `impl Fielded` to typecheck this
// shape, and `TmplArgs` already is one.
fn tmpl_with_references_placeholder() -> TmplArgs {
    TmplArgs { tmpl_field: 0 }
}
fn tmpl_given_spec_placeholder() -> crate::kernel::GivenSpec {
    crate::kernel::GivenSpec { description: "", expr: crate::kernel::Expr::Bool(true), corrects_event: None }
}
fn tmpl_transition_placeholder() -> Option<crate::kernel::TransitionCheck> {
    None
}
fn tmpl_ensures_spec_placeholder() -> crate::kernel::EnsuresSpec {
    crate::kernel::EnsuresSpec { description: "", expr: crate::kernel::Expr::Bool(true) }
}
fn tmpl_emit_placeholder() -> &'static str {
    ""
}

// A DELEGATING COMMAND — `delegates_to "Entity.Command", with: { … }`
// (docs/implemented/guides/entities.md; `CommandInterpreter#step_
// delegate_to_entity`, read directly). The door is an ordinary
// aggregate command as far as `dispatch_fn` is concerned — its own
// givens, its own `from:` guard, save, emit — and its ENTIRE mutation
// is `kernel::apply_entity_command` run on the record inside the
// closure: the target entity command's locate → givens → transition →
// mutate → ensures, with `parent` read off the live record (see that
// function's own header). Two shapes, rendered into two of
// `dispatch_fn`'s own placeholders:
//
// `delegate_prelude` (into `tmpl_prelude_placeholder();`): the facts
// the target sees are the door's own args plus the `with:` mapping
// (`Json::with_aliases`); the target's args struct is read from them
// the same way the routing layer reads an entity command's own; the
// element is addressed by the entity's own `extract_id`/`extract_wants`
// over the same facts — the identical NotFound wording a direct
// dispatch renders.
//
// `delegate_apply` (into `tmpl_mutation_lines_placeholder(record);`):
// the call itself. The inner `|record|` closure is the TARGET's own
// mutation lines over the element and deliberately shadows the door's
// `record` — an entity command's `sets` only ever reach the element.
fn tmpl_aliases_placeholder() -> (&'static str, &'static str) {
    ("", "")
}

fn tmpl_delegate_prelude_host(
    args: TmplArgs,
    command_deref: Vec<(&'static str, crate::kernel::DerefNode)>,
    owner_deref: Vec<(&'static str, crate::kernel::DerefNode)>,
) -> Result<(), crate::kernel::Refusal> {
    // TMPL:delegate_prelude BEGIN
    let delegate_facts = args.to_json().with_aliases(&[tmpl_aliases_placeholder()]);
    let target_args = TmplTargetArgs::from_json(&delegate_facts)?;
    let element_id = TmplElement::extract_id(&delegate_facts)?;
    let element_wants = TmplElement::extract_wants(&delegate_facts);
    let target_with_references = crate::kernel::WithReferences { command_deref: &command_deref, args: &target_args, owner_deref: &owner_deref };
    // TMPL:delegate_prelude END
    let _ = (element_id, element_wants, target_with_references);
    Ok(())
}

fn tmpl_delegate_apply_host(
    record: &mut TmplRecord,
    id: &str,
    element_id: String,
    element_wants: String,
    target_with_references: TmplArgs,
) -> Result<(), crate::kernel::Refusal> {
        // TMPL:delegate_apply BEGIN
        crate::kernel::apply_entity_command(
            record,
            id,
            |r: &TmplRecord| &r.tmpl_list_field,
            |r: &mut TmplRecord| &mut r.tmpl_list_field,
            |el: &TmplElement| el.identity() == element_id,
            "TmplQualifiedCommandName",
            "TmplAggregateName",
            "TmplEntityName",
            "TmplEntityIdentityReading",
            &element_wants,
            &target_with_references,
            &[
tmpl_given_spec_placeholder(),
            ],
            tmpl_transition_placeholder(),
            |record| {
tmpl_entity_mutation_lines_placeholder(record);
                Ok(())
            },
            &[
tmpl_ensures_spec_placeholder(),
            ],
            true,
        )?;
        // TMPL:delegate_apply END
    Ok(())
}

// `entity_dispatch_fn` — `dispatch_fn`'s own sibling for an ENTITY
// command (`emit_entity_command`), wrapping `kernel::dispatch_entity`
// instead of `dispatch`: no `Hydrate` branch (an entity command never
// creates), a `matches` closure addressing ONE element by its own
// `identity()` instead of the parent's bare id, and two accessor
// closures (`get_list`/`get_list_mut`) reaching the parent's list field
// instead of one `Hydrate::Act { id }`. Never varies in SHAPE the way
// `dispatch_fn` does between creating/acting — an entity command is
// always "acting" on one already-addressed element — so this needs no
// `fn_signature`-style whole-span marker; the signature itself is fixed.
fn tmpl_entity_mutation_lines_placeholder(record: &mut TmplElement) {}

// TMPL:entity_dispatch_fn BEGIN
pub fn dispatch_entity_tmpl(
    repo: &mut impl crate::kernel::Repository<TmplRecord>, parent_id: &str, element_id: &str, element_wants: &str, args: TmplArgs,
    mutations: &mut Vec<crate::kernel::MutationRecord>, tmpl_deref_params_placeholder: (),
) -> crate::kernel::DispatchResult<TmplRecord> {
tmpl_invariant_check_placeholder()?;
    let tmpl_eval_fielded = tmpl_with_references_placeholder();

    crate::kernel::dispatch_entity(
        repo,
        parent_id,
        |r: &TmplRecord| &r.tmpl_list_field,
        |r: &mut TmplRecord| &mut r.tmpl_list_field,
        |el: &TmplElement| el.identity() == element_id,
        "TmplQualifiedCommandName",
        "TmplQualifiedName",
        "TmplAggregateName",
        "TmplParentIdentityReading",
        "TmplEntityName",
        "TmplEntityIdentityReading",
        element_wants,
        &tmpl_eval_fielded,
        &[
tmpl_given_spec_placeholder(),
        ],
        tmpl_transition_placeholder(),
        |record| {
tmpl_entity_mutation_lines_placeholder(record);
            Ok(())
        },
        &[
tmpl_ensures_spec_placeholder(),
        ],
        &[tmpl_emit_placeholder()],
        args.to_json(),
        mutations,
    )
}
// TMPL:entity_dispatch_fn END
