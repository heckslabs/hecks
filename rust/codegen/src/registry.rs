//! Port of `rust/project/registry.rb` — the JSON command router. Read
//! that file's own header comments in full; this mirrors its algorithm
//! directly, function for function. The plain data shapes below
//! (`ReferenceCheck`/`CommandEntry`/`EntityCommandEntry`/`PortEntry`/
//! `AggregateEntry`) mirror the Hash shapes `domain_generator.rb` itself
//! accumulates while walking the IR (that file's own header spells out
//! the exact keys).

use crate::exemplar::Exemplar;
use crate::naming;
use crate::reference_specs::{self, ReferenceSpec};

#[derive(Clone)]
pub struct ReferenceCheck {
    pub field: String,
    pub optional: bool,
    /// `Some(element key expression)` for a list (`has_many`) check —
    /// `rust/project/domain_generator.rb#list_reference_check_item`.
    pub list_item: Option<String>,
    pub target_mod: String,
    pub target_name: String,
    pub heads: String,
}

/// One ANGLE-8 write-side tenant boundary check —
/// `rust/project/domain_generator.rb#tenant_boundary_checks`' Hash, typed.
pub struct TenantBoundaryCheck {
    pub reference_field: String,
    pub target_mod: String,
    pub target_name: String,
    pub aggregate_name: String,
    pub own_tenant_field: String,
    pub own_accessor: String,
    pub target_tenant_field: String,
    pub target_accessor: String,
}

pub struct CommandEntry {
    pub verb: String,
    pub name: String,
    pub fn_name: String,
    pub args_struct: String,
    pub creates: bool,
    pub identity_extra_params: Vec<String>,
    pub reference_checks: Vec<ReferenceCheck>,
    /// BUG#139 — the write-side tenant boundary checks this command runs
    /// before dispatch (`emit_tenant_boundary_check`, below).
    pub tenant_boundary_checks: Vec<TenantBoundaryCheck>,
    /// This command's OWN reference-typed attributes — `command_deref`'s
    /// own specs (`reference_specs.rb`'s own header).
    pub reference_specs: Vec<ReferenceSpec>,
    /// THIS COMMAND'S OWN DECLARED ATTRIBUTE NAMES (R1) —
    /// `reactions.rs`'s own `emit_command_attributes_table` reads this;
    /// see its header for the full argument.
    pub attributes: Vec<String>,
    /// R3 (docs/audits/2026-08-11-bug-triage.md) — VO invariant/admits/
    /// pattern checks, rendered as ready-to-splice lines
    /// (`commands::invariant_checks_for`'s own doc comment has the
    /// per-attribute logic). Precomputed at `CommandEntry` construction
    /// time, where `value_objects_by_name` is already in scope, rather
    /// than re-deriving it from a raw `Json` command here — the same
    /// division of labor `attributes`, just above, already uses.
    /// Spliced into the router match-arm's own body BEFORE `role`/
    /// `reference_checks`, matching Ruby's own DISPATCH_ORDER (this
    /// module's header, `emit_registry`) — found missing entirely here:
    /// `rust/project/registry.rb` got R3's fix; this file, its Rust-
    /// native mirror, never did. `spec/codegen_parity_spec.rb`, every
    /// domain with a command that takes a non-closed-set VO argument.
    /// `commands.rs::emit_command` already runs these a second time
    /// inside the generated dispatch fn itself; redundant on the
    /// success path, and the reason this router's own copy is safe to
    /// run first regardless.
    pub invariant_check_lines: Vec<String>,
    pub role: Option<String>,
}

pub struct EntityCommandEntry {
    pub verb: String,
    pub name: String,
    pub entity_record: String,
    pub fn_name: String,
    pub args_struct: String,
    pub reference_checks: Vec<ReferenceCheck>,
    pub reference_specs: Vec<ReferenceSpec>,
    /// THIS COMMAND'S OWN DECLARED ATTRIBUTE NAMES (R1) — see
    /// `CommandEntry`'s own identical field, above.
    pub attributes: Vec<String>,
    /// R3 — see `CommandEntry`'s own identical field, above.
    pub invariant_check_lines: Vec<String>,
    pub role: Option<String>,
    /// `entity_name:`/`entity_identity_reading:` — carried in
    /// `domain_generator.rb`'s own `entity_commands` hash (its own
    /// comment: for `entity_element_missing`'s `{entity}`/`{identity}`
    /// wording, codegen-time-static) but NOT actually read anywhere in
    /// `registry.rb`'s own `emit_registry` — `commands.rb#emit_entity_
    /// command` already computes the identical reading itself, inline,
    /// off the `entity` node it's handed directly. Kept here for shape
    /// parity with Ruby's own hash, not because anything in this crate's
    /// ported scope consumes them.
    pub entity_name: String,
    pub entity_identity_reading: String,
}

/// BUG#11 (loop-parity) — a command owned by an entity nested TWO levels
/// deep (`Aggregate.Entity.Entity.Command`). Mirrors `EntityCommandEntry`,
/// above, plus a second (`nested_*`) name/identity-reading pair for the
/// INNERMOST entity — the one `nested`'s own command actually belongs to
/// — alongside the FIRST hop's (`entity_name`/`entity_identity_reading`,
/// same fields `EntityCommandEntry` already carries, describing the
/// entity `nested` lives inside).
pub struct NestedEntityCommandEntry {
    pub verb: String,
    pub name: String,
    pub entity_record: String,
    pub nested_record: String,
    pub fn_name: String,
    pub args_struct: String,
    pub reference_checks: Vec<ReferenceCheck>,
    pub reference_specs: Vec<ReferenceSpec>,
    pub attributes: Vec<String>,
    pub invariant_check_lines: Vec<String>,
    pub role: Option<String>,
    pub entity_name: String,
    pub entity_identity_reading: String,
    pub nested_name: String,
    pub nested_identity_reading: String,
    /// BUG#19 (loop-parity) — whether `emit_registry`'s own
    /// `nested_entity_arms` gets a flat-args (`None => ...`) fallback
    /// branch for THIS command, mirroring `entity_arms`'s own depth-1
    /// shape one hop deeper, or stays the ROUTED-only shape BUG#11
    /// originally shipped. True only when BOTH hops' own identity is
    /// `extract_id`-supported (`domain_generator.rs`'s own header on
    /// why it needs both, not just the innermost).
    pub unrouted_supported: bool,
}

pub struct PortEntry {
    pub verb: String,
    pub name: String,
    pub fn_name: String,
    pub args_struct: String,
    pub reference_checks: Vec<ReferenceCheck>,
    /// Compatibility-only self-reference field from older port IR. New
    /// operations receive their owner solely through the routing envelope.
    pub legacy_receiver_field: Option<String>,
    /// `to:`-declared operations' own receiver field — a plain, real
    /// attribute (never stripped from the payload the way
    /// legacy_receiver_field is), named for the owning aggregate's own
    /// identified_by field. See domain_generator.rs's own comment on
    /// why this stays a separate field rather than folding into
    /// legacy_receiver_field.
    pub to_receiver_field: Option<String>,
}

/// THIS AGGREGATE'S OWN NESTED ENTITY — name + identity paths only,
/// mirroring `domain_generator.rb`'s own `entities:` hash field
/// (BUG#10). `reactions.rs`'s own `emit_entity_identity_head_table`
/// reads the single-component case (the only shape it resolves), the
/// same restraint `AggregateEntry::identified_by` already carries one
/// level up.
pub struct EntityIdentityEntry {
    pub name: String,
    pub identified_by: Vec<String>,
}

pub struct AggregateEntry {
    pub name: String,
    pub module_name: String,
    pub record: String,
    pub commands: Vec<CommandEntry>,
    pub entity_commands: Vec<EntityCommandEntry>,
    pub nested_entity_commands: Vec<NestedEntityCommandEntry>,
    pub ports: Vec<PortEntry>,
    pub chapter_mod: String,
    pub domain_name: String,
    /// This AGGREGATE's own reference-typed attributes — `owner_deref`'s
    /// own specs, and the domain-wide `REFERENCE_TABLE`'s own row for
    /// this aggregate (`reference_specs.rb`'s own header).
    pub reference_specs: Vec<ReferenceSpec>,
    /// THIS AGGREGATE'S OWN DECLARED IDENTITY PATHS, carried through
    /// verbatim — `reactions.rs`'s own `emit_identity_head_table` reads
    /// the single-component case (the only shape it resolves).
    pub identified_by: Vec<String>,
    /// THIS AGGREGATE'S OWN NESTED ENTITIES — `reactions.rs`'s own
    /// `emit_entity_identity_head_table` sibling table (BUG#10).
    pub entities: Vec<EntityIdentityEntry>,
}

pub fn emit_role_check(
    exemplar: &Exemplar,
    role: Option<&str>,
    command_name: &str,
) -> Option<String> {
    let role = role?;
    Some(exemplar.render(
        "role_check",
        &[
            ("\"TmplRole\"", naming::ruby_inspect_string(role)),
            (
                "\"TmplCommandName\"",
                naming::ruby_inspect_string(command_name),
            ),
        ],
    ))
}

/// Port of `rust/project/registry.rb#emit_tenant_boundary_check` — see that
/// method's own header. Hand-built rather than an exemplar shape: the
/// target side's accessor differs for a single-attribute value object
/// (`record.<head>.as_ref().map(|v| v.<inner>.clone())`) and a bare scalar
/// (`record.<field>.clone()`). Byte-identical to the Ruby output.
pub fn emit_tenant_boundary_check(check: &TenantBoundaryCheck) -> String {
    let ref_ident = naming::rust_ident_field(&check.reference_field);
    let own_expr = format!("args.{}.clone()", naming::rust_ident_field(&check.own_accessor));
    let target_expr = match check.target_accessor.split_once('.') {
        Some((head, inner)) => format!(
            "record.{}.as_ref().map(|v| v.{}.clone())",
            naming::rust_ident_field(head),
            naming::rust_ident_field(inner)
        ),
        None => format!("record.{}.clone()", naming::rust_ident_field(&check.target_accessor)),
    };

    let mut out = String::new();
    out.push_str(&format!("if let Some(record) = store.{}.find(&args.{ref_ident}) {{ ", check.target_mod));
    out.push_str(&format!("if let Some(target_tenant) = {target_expr} {{ "));
    out.push_str(&format!("let own_tenant = {own_expr}; "));
    out.push_str("if target_tenant != own_tenant { ");
    out.push_str(
        "return Err(crate::kernel::Refusal::Unauthorized(crate::kernel::refusal_wording::UnauthorizedCrossTenantReferenceArgs { ",
    );
    out.push_str(&format!("aggregate: {}, ", naming::ruby_inspect_string(&check.aggregate_name)));
    out.push_str(&format!("field: {}, ", naming::ruby_inspect_string(&check.own_tenant_field)));
    out.push_str("tenant: &format!(\"{:?}\", own_tenant), ");
    out.push_str(&format!("attribute: {}, ", naming::ruby_inspect_string(&check.reference_field)));
    out.push_str(&format!("target: {}, ", naming::ruby_inspect_string(&check.target_name)));
    out.push_str(&format!("target_field: {}, ", naming::ruby_inspect_string(&check.target_tenant_field)));
    out.push_str("other: &format!(\"{:?}\", target_tenant)");
    out.push_str(" }.render_args())); ");
    out.push_str("} } }");
    out
}

/// `kernel::ArgumentGates` FOR ONE COMMAND (roadmap D2) — port of
/// `rust/project/registry.rb#emit_argument_gates_literal`. The struct
/// literal `decode_aggregate_arguments`/`decode_entity_arguments` call
/// one field of per declared argument-gate step; NOTHING here names that
/// order. The last two fields are closures rather than plain function
/// references because both need `store`, which only exists at this
/// router level.
fn emit_argument_gates_literal(args_path: &str, invariant_check_lines: &[String], role_line: Option<String>, reference_lines: &[String]) -> String {
    let mut normalize = vec![format!("let args = {args_path}::from_json(v)?;")];
    normalize.extend(invariant_check_lines.iter().map(|l| squeeze(l)));
    normalize.push("Ok(args)".to_string());

    let role = match role_line.filter(|l| !l.is_empty()) {
        Some(line) => format!("&|| {{ {} Ok(()) }}", squeeze(&line)),
        None => "&|| Ok(())".to_string(),
    };
    let references: Vec<String> = reference_lines.iter().filter(|l| !l.is_empty()).map(|l| squeeze(l)).collect();
    let references = if references.is_empty() {
        format!("&|_args: &{args_path}| Ok(())")
    } else {
        format!("&|args: &{args_path}| {{ {} Ok(()) }}", references.join(" "))
    };

    format!(
        "crate::kernel::ArgumentGates {{ decode_arguments: &{args_path}::decode_arguments, \
         refuse_unknown_arguments: &{args_path}::refuse_unknown_arguments, \
         refuse_absent_arguments: &{args_path}::refuse_absent_arguments, \
         normalize_args: &|v: &crate::kernel::Json| {{ {} }}, refuse_role_mismatch: {role}, resolve_references: {references} }}",
        normalize.join(" ")
    )
}

/// An emitted check is a whole statement, sometimes several lines and
/// indented for the line-per-statement body it used to sit in; inside a
/// closure it is one expression among others.
fn squeeze(text: &str) -> String {
    text.lines().map(str::trim).filter(|l| !l.is_empty()).collect::<Vec<_>>().join(" ")
}

pub fn emit_reference_check(exemplar: &Exemplar, check: &ReferenceCheck) -> String {
    let ident = naming::rust_ident_field(&check.field);
    if let Some(list_item) = &check.list_item {
        exemplar.render(
            "reference_check_list",
            &[
                (
                    "\"TmplTarget\"",
                    naming::ruby_inspect_string(&check.target_name),
                ),
                ("\"tmpl_heads\"", naming::ruby_inspect_string(&check.heads)),
                ("tmpl_target_mod", check.target_mod.clone()),
                ("tmpl_list_field", ident),
                ("&item.tmpl_element_field", list_item.clone()),
            ],
        )
    } else if check.optional {
        exemplar.render(
            "reference_check_optional",
            &[
                (
                    "\"TmplTarget\"",
                    naming::ruby_inspect_string(&check.target_name),
                ),
                ("\"tmpl_heads\"", naming::ruby_inspect_string(&check.heads)),
                ("tmpl_target_mod", check.target_mod.clone()),
                ("tmpl_optional_field", ident),
            ],
        )
    } else {
        exemplar.render(
            "reference_check_required",
            &[
                (
                    "\"TmplTarget\"",
                    naming::ruby_inspect_string(&check.target_name),
                ),
                ("\"tmpl_heads\"", naming::ruby_inspect_string(&check.heads)),
                ("tmpl_target_mod", check.target_mod.clone()),
                ("tmpl_field", ident),
            ],
        )
    }
}

fn chapter_path(a: &AggregateEntry) -> String {
    format!("crate::generated::{}::{}", a.chapter_mod, a.module_name)
}

pub fn emit_registry(exemplar: &Exemplar, aggregates: &[AggregateEntry]) -> String {
    let store_fields: Vec<String> = aggregates
        .iter()
        .map(|a| {
            format!(
                "    pub {}: crate::kernel::InMemoryRepository<{}::{}>,",
                a.module_name,
                chapter_path(a),
                a.record
            )
        })
        .collect();
    let store_inits: Vec<String> = aggregates
        .iter()
        .map(|a| {
            format!(
                "            {}: crate::kernel::InMemoryRepository::new(),",
                a.module_name
            )
        })
        .collect();

    let dump_arms: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let prefix = format!("{}::{}#", a.domain_name, a.name);
            format!(
                "for (id, record) in self.{}.entries() {{\n    instances.push((format!(\"{{}}{{}}\", {}, id), record.to_json()));\n}}",
                a.module_name,
                naming::ruby_inspect_string(&prefix)
            )
        })
        .collect();

    let seed_arms: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let mod_path = chapter_path(a);
            let prefix = format!("{}::{}#", a.domain_name, a.name);
            format!(
                "if let Some(id) = key.strip_prefix({}) {{\n    store.{}.save(id, {mod_path}::{}::from_json(value)?);\n    continue;\n}}",
                naming::ruby_inspect_string(&prefix),
                a.module_name,
                a.record
            )
        })
        .collect();

    let query_arms: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let prefix = format!("{}::{}", a.domain_name, a.name);
            format!(
                "if aggregate == {} {{\n    return Some(self.{}.entries().map(|(id, record)| (id.clone(), record.to_json())).collect());\n}}",
                naming::ruby_inspect_string(&prefix),
                a.module_name
            )
        })
        .collect();

    let mut aggregate_arms: Vec<String> = Vec::new();
    for a in aggregates {
        let mod_path = chapter_path(a);
        for c in &a.commands {
            let extra_names = &c.identity_extra_params;
            let extra_idents: Vec<String> = extra_names
                .iter()
                .map(|n| naming::rust_ident_field(n))
                .collect();
            let extra_lines: Vec<String> = extra_names
                .iter()
                .zip(extra_idents.iter())
                .map(|(name, ident)| {
                    let msg = format!("{} creates a {} — pass {name}", c.verb, a.record);
                    format!(
                        "let {ident} = facts_json.dig({}).ok_or_else(|| crate::kernel::Refusal::NotFound({}.to_string()))?.to_id_component()?;",
                        naming::ruby_inspect_string(name),
                        naming::ruby_inspect_string(&msg)
                    )
                })
                .collect();
            let extra_pass: String = extra_idents
                .iter()
                .map(|ident| format!("&{ident}, "))
                .collect();

            // BUG#22 (QualityControl ledger) — see `rust/project/
            // registry.rb`'s identical comment: a CREATING command's own
            // generated `dispatch_*` fn now takes `route` too (right
            // after `repo`), so it can decide create-vs-find from
            // whether one was actually given, instead of purely from its
            // own static `creates:` flag.
            // BUG#139 — `tenant_boundary_check` trails `command_deref`
            // here, the same "computed eagerly at router level, applied
            // deferred inside `dispatch()`" split `owner_deref`/`command_
            // deref` themselves already use. This pipeline has no `tenant_
            // boundary_checks`-equivalent source data (see the bound
            // local's own comment, below), so it is always `Ok(())` —
            // zero behavior change, the parameter exists purely so this
            // pipeline's own generated code keeps compiling against
            // `dispatch()`'s now-wider signature.
            let dispatch_call = format!(
                "{mod_path}::dispatch_{}(&mut store.{}, {}args, mutations, owner_deref, command_deref, tenant_boundary_check)",
                c.fn_name,
                a.module_name,
                if c.creates { format!("route, {extra_pass}") } else { "&id, ".to_string() }
            );
            // BUG#20 (qa/bluebook/quality_control.bluebook) — `extract_id`'s
            // own `no identity found at all` case (every one of its
            // tried sources — the composite identity, `id`, and the
            // command's own reference key — came back empty, including a
            // caller-supplied `id: null`, which `to_id_component` refuses
            // and this call site used to let propagate raw) always
            // raised `TypeMismatch`. `CommandInterpreter#hydrate_
            // existing`'s own identical fallback chain (`identity_of ||
            // identity_from(:id) || identity_from(reference_key) ||
            // raise(...)`, command_interpreter.rb, read directly) raises
            // `NotFound`/`acting_no_identity` instead — this IS `dispatch`
            // (kernel/dispatch.rs)'s own `Hydrate::Act` NOT-FOUND site's
            // upstream twin: an ACTING command's id is resolved HERE, at
            // the router, before `dispatch` (and its already-correct
            // `Hydrate::Act` repo.find-miss `NotFoundRecordMissing`
            // check) is ever called at all, so `dispatch` itself never
            // saw this case to refuse correctly. `extract_id` has no
            // per-command context (command name, declared identity
            // reading) of its own to render `RefusalSite::
            // NotFoundActingNoIdentity` — its ONE possible `Err` is
            // wrapped here, where both are already in scope, into the
            // exact same wording `RefusalWording.render_site("NotFound",
            // "acting_no_identity", ...)` produces on the Ruby side — off
            // the same declared template and the same argument rows,
            // never re-typed here.
            let not_found_expr = |command: &str, aggregate: &str, identity: &str| {
                format!(
                    "crate::kernel::Refusal::NotFound(crate::kernel::refusal_wording::NotFoundActingNoIdentityArgs {{ command: {}, aggregate: {}, identity: {} }}.render_args())",
                    naming::ruby_inspect_string(command),
                    naming::ruby_inspect_string(aggregate),
                    naming::ruby_inspect_string(identity)
                )
            };
            // ROUTE DEPTH FOR EVERY AGGREGATE COMMAND, CONDITIONALLY
            // EAGER (BUG#141/BUG#123, qa/bluebook/quality_control.
            // bluebook), AND IDENTITY AFTER THE GATES (roadmap D2) — see
            // `rust/project/registry.rb`'s identical comments in full,
            // including the exact D2-documented gap this closes:
            // Ruby's `Invocation.route` validates `to:` before
            // `DISPATCH_ORDER` opens at all, but ONLY for the legacy/
            // flat-facts shape — the explicit `with:` shape's own
            // `Invocation.facts_for` validates facts BEFORE `route(to)`
            // runs, so a wrong-depth route alongside bad `with:`-shaped
            // facts must refuse the SAME kind Ruby does (UnknownArgument/
            // AbsentArgument, not TypeMismatch). `CommandInvocation::
            // explicit_with()` (rust/src/kernel/routing.rs) is what makes
            // that call-shape distinction available here at all.
            // `extract_id` is part of `hydrate`, so it still runs after
            // every argument gate, unchanged from D2 — which is what
            // BUG#23's standalone `structural_precheck` splice, BUG#38/
            // #136's discarded `_args_precheck` and BUG#54's `collision_
            // fallback` were each patching around one command shape at a
            // time. All three stay gone.
            let route_precheck_line =
                "if let Some(route) = route { route.require_depth(0)?; }".to_string();
            let id_line = if c.creates {
                String::new()
            } else {
                let not_found = not_found_expr(&c.name, &a.record, &a.identified_by.join(", "));
                format!(
                    "let id = match route {{ Some(route) => route.aggregate().to_string(), None => {mod_path}::{}::extract_id(facts_json).map_err(|_| {not_found})?, }};",
                    a.record
                )
            };
            // THE ARGUMENT GATES, HANDED TO THE KERNEL (roadmap D2) —
            // one generated function per declared argument-gate step,
            // called by `kernel::decode_aggregate_arguments` in
            // `AggregateStep::ORDER`. This arm no longer decides which of
            // them wins: reordering them in vocabulary.bluebook reorders
            // the refusals with no change here. See
            // `rust/project/registry.rb`'s `gates_expr` for the full
            // argument.
            let gates_expr = format!(
                "crate::kernel::decode_aggregate_arguments(facts_json, &{})?",
                emit_argument_gates_literal(
                    &format!("{mod_path}::{}", c.args_struct),
                    &c.invariant_check_lines,
                    emit_role_check(exemplar, c.role.as_deref(), &c.name),
                    &c
                        .reference_checks
                        .iter()
                        .map(|check| emit_reference_check(exemplar, check))
                        .collect::<Vec<_>>()
                )
            );
            // BUG#141/BUG#123 — see `route_precheck_line`'s own header,
            // above, for the full reasoning. A single `if invocation.
            // explicit_with() { ... } else { ... }` EXPRESSION (its
            // value bound to `args`) rather than two separately-ordered
            // statements, so exactly one of the two orders ever actually
            // runs per call.
            let args_line = format!(
                "let args = if invocation.explicit_with() {{ let args = {gates_expr}; {route_precheck_line} args }} \
                 else {{ {route_precheck_line} {gates_expr} }};"
            );

            // BUG#139 — the ANGLE-8 write-side tenant boundary (PR #595),
            // ported from `rust/project/registry.rb`'s own
            // `tenant_boundary_check_line`. The checks are derived from
            // `ir.json` at codegen time (`domain_generator.rs#tenant_
            // boundary_checks`); none means the unconditional `Ok(())`,
            // otherwise every check runs inside one closure, in order.
            let tenant_boundary_check_bodies: Vec<String> = c
                .tenant_boundary_checks
                .iter()
                .map(emit_tenant_boundary_check)
                .collect();
            let tenant_boundary_check_line = if tenant_boundary_check_bodies.is_empty() {
                "let tenant_boundary_check: Result<(), crate::kernel::Refusal> = Ok(());".to_string()
            } else {
                format!(
                    "let tenant_boundary_check: Result<(), crate::kernel::Refusal> = \
                     (|| -> Result<(), crate::kernel::Refusal> {{ {} Ok(()) }})();",
                    tenant_boundary_check_bodies.join(" ")
                )
            };

            // `owner_deref`/`command_deref` — see `reference_lookup.rs`'s
            // own header and `rust/project/registry.rb`'s identical
            // comment: resolved HERE, before the `&mut store.<mod>`
            // borrow below, since it needs `store` as a whole.
            let owner_deref_expr = if c.creates {
                "Vec::new()".to_string()
            } else {
                format!(
                    "crate::kernel::owner_deref(&*store, REFERENCE_TABLE, {}, &id)",
                    naming::ruby_inspect_string(&format!("{}::{}", a.domain_name, a.name))
                )
            };
            let deref_lines = vec![
                format!("let owner_deref = {owner_deref_expr};"),
                format!(
                    "let command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, {}, &args);",
                    reference_specs::emit_reference_specs_literal(&c.reference_specs)
                ),
            ];

            let mut body: Vec<String> = vec![
                "let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;"
                    .to_string(),
                "let route = invocation.route();".to_string(),
                "let facts_json = invocation.facts();".to_string(),
            ];
            body.push(args_line);
            // IDENTITY AFTER THE GATES — `id_line`'s own comment, above;
            // `extra_lines` reads a creating command's bare identity-extra
            // heads, identity too, so it moves with it.
            if !id_line.is_empty() {
                body.push(id_line);
            }
            body.extend(extra_lines);
            body.push(tenant_boundary_check_line);
            body.extend(deref_lines);
            body.push(
                "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());"
                    .to_string(),
            );
            body.push(format!(
                "{dispatch_call}.map(|(_, events)| stamp_payload(events, &payload))"
            ));

            aggregate_arms.push(format!(
                "          {} => {{\n{}\n          }}",
                naming::ruby_inspect_string(&c.verb),
                body.iter()
                    .map(|l| format!("              {l}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
    }

    let mut entity_arms: Vec<String> = Vec::new();
    for a in aggregates {
        let mod_path = chapter_path(a);
        for c in &a.entity_commands {
            // THE ARGUMENT GATES (roadmap D2) — see the aggregate arm's
            // own `gates_line`, above; `kernel::decode_entity_arguments`
            // walks `EntityStep::ORDER`.
            let gates_line = format!(
                "let args = crate::kernel::decode_entity_arguments(facts_json, &{})?;",
                emit_argument_gates_literal(
                    &format!("{mod_path}::{}", c.args_struct),
                    &c.invariant_check_lines,
                    emit_role_check(exemplar, c.role.as_deref(), &c.name),
                    &c
                        .reference_checks
                        .iter()
                        .map(|check| emit_reference_check(exemplar, check))
                        .collect::<Vec<_>>()
                )
            );
            let dispatch_call = format!(
                "{mod_path}::dispatch_entity_{}(&mut store.{}, &parent_id, &element_id, &element_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))",
                c.fn_name, a.module_name
            );

            // ARGUMENT GATES BEFORE IDENTITY (roadmap D2) — see
            // `rust/project/registry.rb`'s own longer note: no standalone
            // structural precheck and no discarded `_args_precheck`
            // spliced into the route-less `None` arm any more (BUG#38,
            // BUG#136); `gates_line` above runs every declared argument
            // gate for a routed and an unrouted call alike, and identity
            // resolves afterwards, which is Ruby's own order. The eager
            // `route.require_depth(1)?` that leads the body keeps the ONE
            // ordering that fix had to respect: Ruby resolves an
            // EXPLICITLY given `to:` independently of `facts`, so a
            // wrong-depth route refuses on its own terms first.
            // BUG#132 (qa/bluebook/quality_control.bluebook) — the SAME
            // BUG#20 fix the aggregate arm's own `id_line` already
            // applies (this file's header, above) had never been
            // extended to this, the ENTITY arm's route-less `None`
            // branch — see `rust/project/registry.rb`'s own identical,
            // longer comment for the full trace (Ruby's own
            // `EntityInterpreter#parent`/`EntityElement#element_of`,
            // entity_interpreter.rb/entity_element.rb).
            let entity_parent_no_identity_message = format!(
                "{} acts on a {}'s {} — pass {}:",
                c.name, a.record, c.entity_name, a.identified_by.join(", ")
            );
            let entity_element_no_identity_message = format!(
                "{} acts on one {} — pass {}:",
                c.name, c.entity_name, c.entity_identity_reading
            );
            // BUG#140 — `element_id` resolves through `extract_id_
            // lenient`, not `extract_id` — see `rust/project/registry.rb`'s
            // own identical comment for the full reasoning
            // (`EntityElement#element_of`'s own absent-vs-blank
            // distinction, entity_element.rb). `parent_id` stays strict.
            let body_entity_match = format!(
                "let (parent_id, element_id, element_wants) = match route {{ Some(route) => {{ let element_id = route.entities()[0].clone(); (route.aggregate().to_string(), element_id.clone(), element_id) }}, None => {{ let parent_id = {mod_path}::{}::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let element_id = {mod_path}::{}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let element_wants = {mod_path}::{}::extract_wants(facts_json); (parent_id, element_id, element_wants) }}, }};",
                a.record,
                naming::ruby_inspect_string(&entity_parent_no_identity_message),
                c.entity_record,
                naming::ruby_inspect_string(&entity_element_no_identity_message),
                c.entity_record
            );

            let mut body: Vec<String> = vec![
                "let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;".to_string(),
                "let route = invocation.route();".to_string(),
                "let facts_json = invocation.facts();".to_string(),
                "if let Some(route) = route { route.require_depth(1)?; }".to_string(),
                gates_line,
                body_entity_match,
            ];
            // `owner_deref` — BUG#40 fix — see `rust/project/registry.rb`'s
            // own identical, longer comment: carries the PARENT
            // aggregate's own `reference_to`/`belongs_to` fields,
            // dereferenced off the already-known `parent_id`, exactly the
            // same call an aggregate-level `Act` command already makes for
            // its own `id` (this file's own `owner_deref_expr`, above) —
            // what `seeded_projections` needs to re-seed the PARENT's own
            // `projects` fields on every entity-command save, since
            // `dispatch_entity` unconditionally re-applies every
            // `seed_projections` entry the same way the aggregate-level
            // `dispatch` does. Previously unconditionally `Vec::new()`, so
            // `seeded_projections` could never resolve a reference name
            // like `"customer"` here and every entity command wiped the
            // field to `null`. An entity's OWN `reference_to` attributes
            // (dereferenced off the addressed ELEMENT itself, a different
            // thing again) remain a real, still-open, separate gap — no
            // entity in this corpus declares one. `command_deref` covers
            // the entity command's own reference-typed arguments, PLUS —
            // merged in exactly like Ruby's own `parent:` tier — the
            // PARENT aggregate's own dereferenced state under one
            // `"parent"` key.
            body.push(format!(
                "let owner_deref = crate::kernel::owner_deref(&*store, REFERENCE_TABLE, {}, &parent_id);",
                naming::ruby_inspect_string(&format!("{}::{}", a.domain_name, a.name))
            ));
            body.push(format!(
                "let mut command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, {}, &args);",
                reference_specs::emit_reference_specs_literal(&c.reference_specs)
            ));
            body.push(format!(
                "if let Some(parent_node) = crate::kernel::parent_deref(&*store, REFERENCE_TABLE, {}, &parent_id) {{ command_deref.push((\"parent\", parent_node)); }}",
                naming::ruby_inspect_string(&format!("{}::{}", a.domain_name, a.name))
            ));
            body.push(
                "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());"
                    .to_string(),
            );
            body.push(dispatch_call);

            entity_arms.push(format!(
                "          {} => {{\n{}\n          }}",
                naming::ruby_inspect_string(&c.verb),
                body.iter()
                    .map(|l| format!("              {l}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
    }

    // BUG#11 (loop-parity) — a command owned by an entity nested TWO
    // levels deep. Mirrors `rust/project/registry.rb`'s own `nested_
    // entity_arms`.
    //
    // BUG#19 (loop-parity) — `c.unrouted_supported` (`domain_
    // generator.rs`'s own header on when it's true) now picks between
    // the SAME `Some(route) => ... | None => ...` shape `entity_arms`
    // above already has, extended one hop deeper (`hop1_id`/`hop1_wants`
    // off `entity`'s own `extract_id`/`extract_wants`, `hop2_id`/`hop2_
    // wants` off `nested`'s own — both newly emitted for this), and the
    // ROUTED-only shape BUG#11 originally shipped (kept, unchanged, for
    // a domain whose identity shape at either hop isn't `extract_id`-
    // supported yet).
    let mut nested_entity_arms: Vec<String> = Vec::new();
    for a in aggregates {
        let mod_path = chapter_path(a);
        for c in &a.nested_entity_commands {
            // THE ARGUMENT GATES (roadmap D2) — see the aggregate arm's
            // own `gates_line`, above; `kernel::decode_entity_arguments`
            // walks `EntityStep::ORDER`.
            let gates_line = format!(
                "let args = crate::kernel::decode_entity_arguments(facts_json, &{})?;",
                emit_argument_gates_literal(
                    &format!("{mod_path}::{}", c.args_struct),
                    &c.invariant_check_lines,
                    emit_role_check(exemplar, c.role.as_deref(), &c.name),
                    &c
                        .reference_checks
                        .iter()
                        .map(|check| emit_reference_check(exemplar, check))
                        .collect::<Vec<_>>()
                )
            );
            let dispatch_call = format!(
                "{mod_path}::dispatch_entity_{}(&mut store.{}, &parent_id, &hop1_id, &hop1_wants, &hop2_id, &hop2_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))",
                c.fn_name, a.module_name
            );

            // ARGUMENT GATES BEFORE IDENTITY (roadmap D2) — see
            // `entity_arms`' own note, above: no standalone precheck and
            // no discarded `_args_precheck` any more, and the eager
            // `route.require_depth(2)?` keeps an explicit wrong-depth
            // route refusing ahead of them all.
            // BUG#132 — see `entity_arms`'s own identical fix, above: the
            // SAME unwrapped `extract_id(facts_json)?` gap, one nesting
            // hop deeper. `parent_id` wraps into `entity_parent_no_
            // identity` (Ruby's joined entity path — `ctx.entity_name`
            // there is `entity_names.join(".")`, matching
            // `"{entity_name}.{nested_name}"` here); `hop1_id`/`hop2_id`
            // each wrap into their OWN hop's `entity_element_no_identity`
            // (Ruby's `EntityElement#element_of` runs once per chain
            // entry, so each hop's failure names THAT hop's own entity/
            // identity, never the other's).
            let entity_parent_no_identity_message = format!(
                "{} acts on a {}'s {}.{} — pass {}:",
                c.name, a.record, c.entity_name, c.nested_name, a.identified_by.join(", ")
            );
            let hop1_no_identity_message = format!(
                "{} acts on one {} — pass {}:",
                c.name, c.entity_name, c.entity_identity_reading
            );
            let hop2_no_identity_message = format!(
                "{} acts on one {} — pass {}:",
                c.name, c.nested_name, c.nested_identity_reading
            );
            // BUG#140 — `hop1_id`/`hop2_id` both resolve through
            // `extract_id_lenient` — see `rust/project/registry.rb`'s own
            // identical comment for the full reasoning. `parent_id` stays
            // strict.
            let route_binding = if c.unrouted_supported {
                format!(
                    "let (parent_id, hop1_id, hop1_wants, hop2_id, hop2_wants) = match route {{ Some(route) => {{ let hop1_id = route.entities()[0].clone(); let hop2_id = route.entities()[1].clone(); (route.aggregate().to_string(), hop1_id.clone(), hop1_id, hop2_id.clone(), hop2_id) }}, None => {{ let parent_id = {mod_path}::{}::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let hop1_id = {mod_path}::{}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let hop1_wants = {mod_path}::{}::extract_wants(facts_json); let hop2_id = {mod_path}::{}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let hop2_wants = {mod_path}::{}::extract_wants(facts_json); (parent_id, hop1_id, hop1_wants, hop2_id, hop2_wants) }}, }};",
                    a.record,
                    naming::ruby_inspect_string(&entity_parent_no_identity_message),
                    c.entity_record,
                    naming::ruby_inspect_string(&hop1_no_identity_message),
                    c.entity_record,
                    c.nested_record,
                    naming::ruby_inspect_string(&hop2_no_identity_message),
                    c.nested_record
                )
            } else {
                let route_error = format!(
                    "{} addresses an entity nested two levels deep — requires an explicit to: {{ aggregate:, entities: [...] }} route",
                    c.verb
                );
                format!(
                    "let route = route.ok_or_else(|| crate::kernel::Refusal::TypeMismatch({}.to_string()))?; let parent_id = route.aggregate().to_string(); let hop1_id = route.entities()[0].clone(); let hop2_id = route.entities()[1].clone(); let hop1_wants = hop1_id.clone(); let hop2_wants = hop2_id.clone();",
                    naming::ruby_inspect_string(&route_error)
                )
            };

            let mut body: Vec<String> = vec![
                "let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;".to_string(),
                "let route = invocation.route();".to_string(),
                "let facts_json = invocation.facts();".to_string(),
            ];
            body.push("if let Some(route) = route { route.require_depth(2)?; }".to_string());
            body.push(gates_line);
            body.push(route_binding);
            // BUG#40 fix — see `entity_arms`'s own identical comment,
            // above: the top-level PARENT aggregate's own
            // `#{AGGREGATE}_PROJECTED_FIELDS` is what `seed_projections_
            // binding` scopes a nested entity command's re-seeding to too
            // (`commands.rb`'s `seed_projections_binding(aggregate)` takes
            // the OUTER `aggregate`, never the nested entity), so
            // `owner_deref` here needs that SAME top-level `a`'s own
            // reference fields, dereferenced off `parent_id`.
            body.push(format!(
                "let owner_deref = crate::kernel::owner_deref(&*store, REFERENCE_TABLE, {}, &parent_id);",
                naming::ruby_inspect_string(&format!("{}::{}", a.domain_name, a.name))
            ));
            body.push(format!(
                "let command_deref = crate::kernel::command_deref(&*store, REFERENCE_TABLE, {}, &args);",
                reference_specs::emit_reference_specs_literal(&c.reference_specs)
            ));
            body.push(
                "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());"
                    .to_string(),
            );
            body.push(dispatch_call);

            nested_entity_arms.push(format!(
                "          {} => {{\n{}\n          }}",
                naming::ruby_inspect_string(&c.verb),
                body.iter()
                    .map(|l| format!("              {l}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
    }

    let mut port_arms: Vec<String> = Vec::new();
    for a in aggregates {
        let mod_path = chapter_path(a);
        for p in &a.ports {
            let reference_lines: Vec<String> = p
                .reference_checks
                .iter()
                .map(|check| emit_reference_check(exemplar, check))
                .collect();
            let dispatch_call = format!("{mod_path}::dispatch_operation_{}(&id, args).map(|events| stamp_payload(events, &payload))", p.fn_name);
            let legacy_receiver = p
                .legacy_receiver_field
                .as_deref()
                .map(naming::ruby_inspect_string)
                .map(|field| format!("Some({field})"))
                .unwrap_or_else(|| "None".to_string());
            let to_receiver = p
                .to_receiver_field
                .as_deref()
                .map(naming::ruby_inspect_string)
                .map(|field| format!("Some({field})"))
                .unwrap_or_else(|| "None".to_string());

            let mut body: Vec<String> = vec![
                "let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;".to_string(),
                format!("let (id, port_facts) = invocation.split_aggregate_receiver({legacy_receiver}, {to_receiver})?;"),
                "let facts_json = &port_facts;".to_string(),
                format!(
                    "let _instance = store.{}.find(&id).ok_or_else(|| crate::kernel::Refusal::NotFound(format!(\"{} {{:?}} does not exist\", id)))?;",
                    a.module_name, a.name
                ),
                format!("let args = {mod_path}::{}::from_json(facts_json)?;", p.args_struct),
            ];
            body.extend(reference_lines);
            body.push(
                "let payload = crate::kernel::Json::overlay(facts_json, &args.to_json());"
                    .to_string(),
            );
            body.push(dispatch_call);

            port_arms.push(format!(
                "          {} => {{\n{}\n          }}",
                naming::ruby_inspect_string(&p.verb),
                body.iter()
                    .map(|l| format!("              {l}"))
                    .collect::<Vec<_>>()
                    .join("\n")
            ));
        }
    }

    let mut dispatch_arms = aggregate_arms;
    dispatch_arms.extend(entity_arms);
    dispatch_arms.extend(nested_entity_arms);
    dispatch_arms.extend(port_arms);

    let header = "// GENERATED by bin/project_rust — the JSON command router\n// `kernel::cli` dispatches every step through. Do not hand-edit —\n// re-run bin/project_rust instead.\n#![allow(dead_code, unused_variables)]\n\n// `Repository::save` (from_seed, below) is a TRAIT method —\n// `InMemoryRepository`'s own inherent methods (entries(), used\n// by instances()) need no import, but save() does.\nuse crate::kernel::Repository;\n\n";

    let body = exemplar.render(
        "registry_file",
        &[
            ("TmplStore2", "Store".to_string()),
            (
                "    pub tmpl_field: crate::kernel::InMemoryRepository<i64>,",
                store_fields.join("\n"),
            ),
            (
                "            tmpl_field: tmpl_store_fields_placeholder(),",
                store_inits.join("\n"),
            ),
            ("tmpl_dump_arm_placeholder();", dump_arms.join("\n")),
            ("tmpl_seed_arm_placeholder();", seed_arms.join("\n")),
            ("tmpl_query_arm_placeholder();", query_arms.join("\n")),
            (
                "\"tmpl_verb\" => { tmpl_dispatch_arm_placeholder() }",
                dispatch_arms.join("\n"),
            ),
        ],
    );

    format!("{header}{body}")
}

/// Port of `rust/project/registry.rb#emit_reference_table`.
pub fn emit_reference_table(aggregates: &[AggregateEntry]) -> String {
    let rows: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let qualified = format!("{}::{}", a.domain_name, a.name);
            format!(
                "    ({}, {}),",
                naming::ruby_inspect_string(&qualified),
                reference_specs::emit_reference_specs_literal(&a.reference_specs)
            )
        })
        .collect();

    format!(
        "pub static REFERENCE_TABLE: crate::kernel::ReferenceTable = &[\n{}\n];\n",
        rows.join("\n")
    )
}

/// Port of `rust/project/registry.rb#emit_reference_lookup`.
pub fn emit_reference_lookup(aggregates: &[AggregateEntry]) -> String {
    let arms: Vec<String> = aggregates
        .iter()
        .map(|a| {
            let prefix = format!("{}::{}", a.domain_name, a.name);
            format!(
                "if target == {} {{\n    return self.{}.find(id).map(|r| Box::new(r) as Box<dyn crate::kernel::Fielded>);\n}}",
                naming::ruby_inspect_string(&prefix),
                a.module_name
            )
        })
        .collect();

    format!(
        "{}\nimpl crate::kernel::ReferenceLookup for Store {{\n    fn find_fielded(&self, target: &str, id: &str) -> Option<Box<dyn crate::kernel::Fielded>> {{\n{}\n        None\n    }}\n}}\n",
        emit_reference_table(aggregates),
        arms.join("\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_router_separates_routes_and_supports_compound_create_facts() {
        let aggregate = AggregateEntry {
            name: "SafeDepositBox".to_string(),
            module_name: "safedepositbox".to_string(),
            record: "SafeDepositBox".to_string(),
            commands: vec![
                CommandEntry {
                    verb: "Banking::SafeDepositBox.Rent".to_string(),
                    name: "Rent".to_string(),
                    fn_name: "rent".to_string(),
                    args_struct: "RentArgs".to_string(),
                    creates: true,
                    identity_extra_params: vec![
                        "branch_code".to_string(),
                        "box_number".to_string(),
                    ],
                    reference_checks: Vec::new(),
                    tenant_boundary_checks: Vec::new(),
                    reference_specs: Vec::new(),
                    attributes: Vec::new(),
                    invariant_check_lines: Vec::new(),
                    role: None,
                },
                CommandEntry {
                    verb: "Banking::SafeDepositBox.Close".to_string(),
                    name: "Close".to_string(),
                    fn_name: "close".to_string(),
                    args_struct: "CloseArgs".to_string(),
                    creates: false,
                    identity_extra_params: Vec::new(),
                    reference_checks: Vec::new(),
                    tenant_boundary_checks: Vec::new(),
                    reference_specs: Vec::new(),
                    attributes: Vec::new(),
                    invariant_check_lines: Vec::new(),
                    role: None,
                },
            ],
            entity_commands: vec![EntityCommandEntry {
                verb: "Banking::SafeDepositBox.Visit.Annotate".to_string(),
                name: "Annotate".to_string(),
                entity_record: "Visit".to_string(),
                fn_name: "visit_annotate".to_string(),
                args_struct: "VisitAnnotateArgs".to_string(),
                reference_checks: Vec::new(),
                reference_specs: Vec::new(),
                attributes: Vec::new(),
                invariant_check_lines: Vec::new(),
                role: None,
                entity_name: "Visit".to_string(),
                entity_identity_reading: "date, sequence".to_string(),
            }],
            nested_entity_commands: Vec::new(),
            ports: vec![PortEntry {
                verb: "Banking::SafeDepositBox.PaymentGateway.Receive".to_string(),
                name: "Receive".to_string(),
                fn_name: "paymentgateway_receive".to_string(),
                args_struct: "PaymentGatewayReceiveArgs".to_string(),
                reference_checks: Vec::new(),
                legacy_receiver_field: None,
                to_receiver_field: None,
            }],
            chapter_mod: "banking".to_string(),
            domain_name: "Banking".to_string(),
            reference_specs: Vec::new(),
            identified_by: vec!["branch_code".to_string(), "box_number".to_string()],
            entities: Vec::new(),
        };

        let generated = emit_registry(&Exemplar::load(), &[aggregate]);

        assert!(generated.contains("CommandInvocation::from_json(args_json)?"));
        assert!(generated.contains("let branch_code = facts_json.dig(\"branch_code\")"));
        assert!(generated.contains("let box_number = facts_json.dig(\"box_number\")"));
        // THE ARGUMENT GATES (roadmap D2) — `from_json` is reached through
        // the `normalize_args` hook now (`v`, the gate loop's own binding),
        // never as a bare line in the arm; route depth leads the body for
        // every command, and identity resolves after every gate.
        assert!(generated.contains("crate::kernel::decode_aggregate_arguments(facts_json, &crate::kernel::ArgumentGates {"));
        assert!(generated.contains("decode_arguments: &crate::generated::banking::safedepositbox::RentArgs::decode_arguments"));
        assert!(generated.contains("refuse_unknown_arguments: &crate::generated::banking::safedepositbox::RentArgs::refuse_unknown_arguments"));
        assert!(generated.contains("refuse_absent_arguments: &crate::generated::banking::safedepositbox::RentArgs::refuse_absent_arguments"));
        assert!(generated.contains("RentArgs::from_json(v)?"));
        assert!(generated.contains("if let Some(route) = route { route.require_depth(0)?; }"));
        assert!(generated.contains("Some(route) => route.aggregate().to_string()"));
        assert!(generated.contains("if let Some(route) = route { route.require_depth(1)?; }"));
        assert!(generated.contains("crate::kernel::decode_entity_arguments(facts_json, &crate::kernel::ArgumentGates {"));
        assert!(generated.contains("let element_id = route.entities()[0].clone()"));
        assert!(generated.contains("VisitAnnotateArgs::from_json(v)?"));
        assert!(!generated.contains("RentArgs::from_json(facts_json)?"));
        assert!(generated.contains("Json::overlay(facts_json, &args.to_json())"));
        assert!(!generated.contains("VisitAnnotateArgs::from_json(args_json)?"));
        assert!(generated
            .contains("let (id, port_facts) = invocation.split_aggregate_receiver(None, None)?;"));
        assert!(generated.contains("store.safedepositbox.find(&id)"));
        assert!(generated.contains("PaymentGatewayReceiveArgs::from_json(facts_json)?"));
        assert!(generated.contains("dispatch_operation_paymentgateway_receive(&id, args)"));
    }

    // BUG#141/BUG#123 (qa/bluebook/quality_control.bluebook) — D2 (#751)
    // made the route-depth check run eagerly, unconditionally, ahead of
    // `decode_aggregate_arguments`, for every aggregate command — correct
    // for a legacy-shaped call, but D2's own comment (superseded now)
    // named the gap left open: an explicit `with:` call validates facts
    // BEFORE `route(to)` on the Ruby side. This pins that the generated
    // code now branches on `invocation.explicit_with()` at runtime
    // instead of picking one fixed order — both orders present in the
    // generated text (only one branch runs per call), neither hard-coded
    // first.
    #[test]
    fn explicit_with_gates_precheck_ordering_for_an_acting_command() {
        let aggregate = AggregateEntry {
            name: "Hangar".to_string(),
            module_name: "hangar".to_string(),
            record: "Hangar".to_string(),
            commands: vec![CommandEntry {
                verb: "Fixture::Hangar.Prioritize".to_string(),
                name: "Prioritize".to_string(),
                fn_name: "prioritize".to_string(),
                args_struct: "PrioritizeArgs".to_string(),
                creates: false,
                identity_extra_params: Vec::new(),
                reference_checks: Vec::new(),
                tenant_boundary_checks: Vec::new(),
                reference_specs: Vec::new(),
                attributes: vec!["priority".to_string()],
                invariant_check_lines: Vec::new(),
                role: None,
            }],
            entity_commands: Vec::new(),
            nested_entity_commands: Vec::new(),
            ports: Vec::new(),
            chapter_mod: "fixture".to_string(),
            domain_name: "Fixture".to_string(),
            reference_specs: Vec::new(),
            identified_by: vec!["code".to_string()],
            entities: Vec::new(),
        };

        let generated = emit_registry(&Exemplar::load(), &[aggregate]);

        assert!(generated.contains("let args = if invocation.explicit_with() { let args = crate::kernel::decode_aggregate_arguments(facts_json, &crate::kernel::ArgumentGates {"));
        assert!(generated.contains("if let Some(route) = route { route.require_depth(0)?; } args } else { if let Some(route) = route { route.require_depth(0)?; } crate::kernel::decode_aggregate_arguments(facts_json, &crate::kernel::ArgumentGates {"));
        assert!(generated.contains("Some(route) => route.aggregate().to_string()"));
    }

    // BUG#20 (qa/bluebook/quality_control.bluebook) — an ACTING command's
    // `extract_id(facts_json)?` used to let ANY internal failure (its
    // one real case: every identity source it tries — the composite
    // identity, `id`, and the reference key — came back empty,
    // including a caller-supplied `id: null`) propagate as `extract_id`'s
    // own generic `TypeMismatch("... no identity found ...")`. Ruby's
    // `CommandInterpreter#hydrate_existing` (command_interpreter.rb, read
    // directly) raises `NotFound`/`acting_no_identity` for the identical
    // case instead — `RefusalWording.render("NotFound",
    // "acting_no_identity", command:, aggregate:, identity:)`, rendered
    // here at CODEGEN time (this router's own call site, not `extract_id`
    // itself, is the one place with the command's short name, the
    // aggregate's bare record name, AND its declared identity reading
    // all already in scope) with the EXACT same wording
    // `RefusalSite::NotFoundActingNoIdentity`'s template gives.
    #[test]
    fn acting_command_id_resolution_failure_refuses_not_found_not_type_mismatch() {
        let aggregate = AggregateEntry {
            name: "SafeDepositBox".to_string(),
            module_name: "safedepositbox".to_string(),
            record: "SafeDepositBox".to_string(),
            commands: vec![CommandEntry {
                verb: "Banking::SafeDepositBox.Close".to_string(),
                name: "Close".to_string(),
                fn_name: "close".to_string(),
                args_struct: "CloseArgs".to_string(),
                creates: false,
                identity_extra_params: Vec::new(),
                reference_checks: Vec::new(),
                tenant_boundary_checks: Vec::new(),
                reference_specs: Vec::new(),
                attributes: Vec::new(),
                invariant_check_lines: Vec::new(),
                role: None,
            }],
            entity_commands: Vec::new(),
            nested_entity_commands: Vec::new(),
            ports: Vec::new(),
            chapter_mod: "banking".to_string(),
            domain_name: "Banking".to_string(),
            reference_specs: Vec::new(),
            identified_by: vec!["branch_code.value".to_string(), "box_number.value".to_string()],
            entities: Vec::new(),
        };

        let generated = emit_registry(&Exemplar::load(), &[aggregate]);

        // The raw `extract_id(facts_json)?` (no `.map_err`, still
        // TypeMismatch on ANY failure) must be gone from an acting
        // command's own id_line ...
        assert!(!generated.contains("SafeDepositBox::extract_id(facts_json)?,"));
        // ... replaced by a wrapper that converts extract_id's failure
        // into the exact NotFound/acting_no_identity wording Ruby's own
        // CommandInterpreter#hydrate_existing raises for this case.
        assert!(generated.contains(
            "SafeDepositBox::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound(crate::kernel::refusal_wording::NotFoundActingNoIdentityArgs { command: \"Close\", aggregate: \"SafeDepositBox\", identity: \"branch_code.value, box_number.value\" }.render_args()))?,"
        ));
    }
}
