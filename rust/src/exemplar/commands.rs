//! Exemplar shapes for rust/codegen/src/commands.rs (see mod.rs).
//!
//! `dispatch_fn` proves the outer `pub fn .. -> DispatchResult { .. dispatch(..) .. }` wrapper.
#![allow(dead_code, unused_variables)]

// Minimal element satisfying `dispatch_entity`'s bounds (`Fielded + Clone`).
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
    // Generated entities carry both `extract_id` and `extract_id_lenient`.
    fn extract_id_lenient(v: &crate::kernel::Json) -> Result<String, crate::kernel::Refusal> {
        let _ = v;
        Ok(String::new())
    }
    fn extract_wants(v: &crate::kernel::Json) -> String {
        let _ = v;
        String::new()
    }
}

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

// Stand-in for the aggregate record a generated `dispatch_*` fn targets.
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
impl crate::kernel::SetProjectedField for TmplRecord {
    fn set_projected_field(&mut self, name: &'static str, value: Option<crate::kernel::Value>) {
        let _ = (name, value);
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

fn tmpl_seed_projections_placeholder() -> Vec<(&'static str, Option<crate::kernel::Value>)> {
    Vec::new()
}

// TMPL:dispatch_fn BEGIN
pub fn dispatch_tmpl(
    repo: &mut impl crate::kernel::Repository<TmplRecord>, id: &str, args: TmplArgs, mutations: &mut Vec<crate::kernel::MutationRecord>, tenant_boundary_check: Result<(), crate::kernel::Refusal>,
) -> crate::kernel::DispatchResult<TmplRecord> {
tmpl_invariant_check_placeholder()?;
    let tmpl_eval_fielded = tmpl_with_references_placeholder();
    let tmpl_seed_projections = tmpl_seed_projections_placeholder();
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
        &tmpl_invariants_placeholder(),
        &[tmpl_emit_placeholder()],
        args.to_json(),
        mutations,
        tmpl_seed_projections,
        tenant_boundary_check,
    )
}
// TMPL:dispatch_fn END

fn tmpl_invariant_check_placeholder() -> Result<(), crate::kernel::Refusal> {
    Ok(())
}
// Empty for ordinary commands; a delegating command substitutes `delegate_prelude`.
fn tmpl_prelude_placeholder() {}
// Plain `TmplArgs` stands in for `kernel::WithReferences` so this exemplar compiles alone.
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
fn tmpl_invariants_placeholder() -> crate::kernel::InvariantSet {
    crate::kernel::InvariantSet { aggregate: vec![], entities: vec![] }
}
fn tmpl_emit_placeholder() -> &'static str {
    ""
}

// `delegates_to "Entity.Command"`: the entry point runs `apply_entity_command` inside its closure.
// `delegate_prelude` fills the prelude slot; `delegate_apply` fills the mutation slot.
// The inner `|record|` deliberately shadows the entry point's: entity `sets` only reach the element.
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
    let target_with_references = crate::kernel::WithReferences { command_deref: &command_deref, args: &target_args, owner_deref: &owner_deref };
    // TMPL:delegate_prelude END
    let _ = target_with_references;
    Ok(())
}

// `element_id` extraction must run after `dispatch`'s hydrate, so it is spliced into the
// mutation closure rather than the prelude. It uses `extract_id_lenient` because a blank mapped
// identity is a non-match, not a refusal.
fn tmpl_delegate_element_host(delegate_facts: crate::kernel::Json) -> Result<(), crate::kernel::Refusal> {
    // TMPL:delegate_element BEGIN
    let element_id = TmplElement::extract_id_lenient(&delegate_facts)?;
    let element_wants = TmplElement::extract_wants(&delegate_facts);
    // TMPL:delegate_element END
    let _ = (element_id, element_wants);
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
            "TmplQualifiedName",
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

// `entity_dispatch_fn`: `dispatch_fn`'s sibling wrapping `kernel::dispatch_entity`, which
// addresses one element by `identity()` and never creates.
fn tmpl_entity_mutation_lines_placeholder(record: &mut TmplElement) {}

// TMPL:entity_dispatch_fn BEGIN
pub fn dispatch_entity_tmpl(
    repo: &mut impl crate::kernel::Repository<TmplRecord>, parent_id: &str, element_id: &str, element_wants: &str, args: TmplArgs,
    mutations: &mut Vec<crate::kernel::MutationRecord>, tmpl_deref_params_placeholder: (),
) -> crate::kernel::DispatchResult<TmplRecord> {
tmpl_invariant_check_placeholder()?;
    let tmpl_eval_fielded = tmpl_with_references_placeholder();
    let tmpl_seed_projections = tmpl_seed_projections_placeholder();

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
        &tmpl_invariants_placeholder(),
        &[tmpl_emit_placeholder()],
        args.to_json(),
        mutations,
        tmpl_seed_projections,
    )
}
// TMPL:entity_dispatch_fn END
