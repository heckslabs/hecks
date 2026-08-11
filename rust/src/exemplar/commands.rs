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

    crate::kernel::dispatch(
        repo,
        tmpl_hydrate_placeholder(),
        "TmplCmdName",
        "TmplQualifiedName",
        "TmplAggregateName",
        "TmplIdentityReading",
        &args,
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
fn tmpl_given_spec_placeholder() -> crate::kernel::GivenSpec {
    crate::kernel::GivenSpec { description: "", expr: crate::kernel::Expr::Bool(true) }
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
    mutations: &mut Vec<crate::kernel::MutationRecord>,
) -> crate::kernel::DispatchResult<TmplRecord> {
tmpl_invariant_check_placeholder()?;

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
        &args,
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
