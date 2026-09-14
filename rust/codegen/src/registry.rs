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
    pub target_mod: String,
    pub target_name: String,
    pub heads: String,
}

pub struct CommandEntry {
    pub verb: String,
    pub name: String,
    pub fn_name: String,
    pub args_struct: String,
    pub creates: bool,
    pub identity_extra_params: Vec<String>,
    pub reference_checks: Vec<ReferenceCheck>,
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
    /// BUG#23 (qa/bluebook/quality_control.bluebook) — the standalone
    /// structural argument gate (`json_codec::structural_precheck`, same
    /// text `Args::from_json` already builds internally), precomputed at
    /// `CommandEntry` construction time the same way `invariant_check_
    /// lines` above is. `None` for a CREATING command: `id_line` (this
    /// module's own `emit_registry`) is never emitted for one either, so
    /// there is no identity-resolution-before-structural-checks race for
    /// this fix to close there. See `emit_registry`'s own header on why
    /// this runs BEFORE `id_line`.
    pub structural_precheck: Option<String>,
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
    /// BUG#38 (qa/bluebook/quality_control.bluebook) — the SAME BUG#23
    /// standalone structural gate `CommandEntry::structural_precheck`
    /// already carries for the aggregate arm, one construct over: run
    /// BEFORE the route-less `None` arm's own `extract_id` calls, using
    /// the IDENTICAL allowlist this command's own `Args::from_json` call
    /// already builds (`extra_identity_heads:` included), so a malformed
    /// `id` can no longer short-circuit via `extract_id`'s own `?` before
    /// an unrelated undeclared argument on the same call is checked.
    ///
    /// BUG#136 — this used to be the FULL story: at the time, this stayed
    /// a narrow, ARGUMENT-NAME-only check specifically to avoid moving a
    /// declared argument's own value-object coercion ahead of `extract_id`
    /// on the happy path, which surfaced BUG#41 (a single-attribute value
    /// object's own `from_json` didn't check for an unknown key) as a new
    /// divergence. BUG#41 is now fixed (PR #623) — `emit_registry`'s own
    /// entity/nested-entity `None` arms now ALSO splice a full, discarded
    /// `{args_struct}::from_json(facts_json)?` precheck ahead of their own
    /// `extract_id` calls, matching Ruby's `normalize_args`-before-
    /// `hydrate_parent` order exactly — see that splice's own header.
    pub structural_precheck: Option<String>,
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
    /// BUG#38/#136 — see `EntityCommandEntry`'s own identical field,
    /// above. `None` when `unrouted_supported` is false: the ROUTED-only
    /// arm always requires an explicit route and never calls `extract_id`
    /// against raw `facts_json`, so there is no race for either fix to
    /// close.
    pub structural_precheck: Option<String>,
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

pub fn emit_reference_check(exemplar: &Exemplar, check: &ReferenceCheck) -> String {
    let ident = naming::rust_ident_field(&check.field);
    if check.optional {
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
            let dispatch_call = format!(
                "{mod_path}::dispatch_{}(&mut store.{}, {}args, mutations, owner_deref, command_deref)",
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
            // exact same wording `RefusalWording.render("NotFound",
            // "acting_no_identity", ...)` produces on the Ruby side.
            let not_found_expr = |acting_no_identity_message: &str| {
                format!(
                    "crate::kernel::Refusal::NotFound({}.to_string())",
                    naming::ruby_inspect_string(acting_no_identity_message)
                )
            };
            // `collision_key` — BUG#54 (qa/bluebook/quality_control.
            // bluebook) — see `rust/project/registry.rb`'s identical
            // comment for the full trace. A WIRE-KEY COLLISION
            // `structural_precheck` (BUG#23) can't reach:
            // `LedgerOrdering::Folder.AddSlip`'s bare `reference_to
            // Folder` addresses the aggregate through `id_line` below
            // using `a.identified_by`'s own head name (`reference` — no
            // `as:` mints a separate wire key) — the SAME wire key
            // `AddSlip` also separately declares as its own typed
            // argument (`attribute :reference, SlipReference`, a
            // DIFFERENT value-object type than the aggregate's own
            // identity type). A malformed `reference` (`null`, `{}`, or
            // `{value: ""}` — every shape `extract_id` itself refuses,
            // directly or through `to_id_component`'s own empty-string
            // guard, R4) makes `extract_id` fail to resolve ANY identity
            // (BUG#20's own case) and `id_line` below wraps that into
            // `NotFound` before `Args::from_json` — the one place
            // `SlipReference`'s own required/pattern check on this SAME
            // key would raise `TypeMismatch` — ever runs.
            //
            // `collision_key` finds this predicate's ONE colliding
            // attribute (`a.identified_by` is exactly one head AND that
            // head's plain name is among `c.attributes`) — `None` for
            // every command in the real corpus and every OTHER command
            // in this stress domain today (verified: no aggregate-level
            // acting command anywhere else bare-references its owner AND
            // redeclares that SAME name as its own attribute), so `id_
            // line` below takes its ORIGINAL, UNCHANGED shape, and
            // generated output is BYTE-IDENTICAL, for every command but
            // this one.
            //
            // When the predicate DOES hold, `id_line` no longer wraps
            // `extract_id`'s failure straight into `NotFound` — it tries
            // this command's OWN, already-generated argument pipeline
            // FIRST, inside `extract_id`'s own `Err` arm: the identical
            // `Args::from_json(facts_json)` call `body.push(format!("let
            // args = ..."))` already makes a few lines down, PLUS this
            // command's own `invariant_check_lines` (the identical
            // `args.<field>.check_invariants()?` calls this match arm's
            // body already runs after `Args::from_json` succeeds) —
            // spliced in VERBATIM, not re-derived, so there is zero risk
            // of drift between this early copy and the real one. Only if
            // THAT produces no refusal at all does the code fall through
            // to the ORIGINAL `NotFound`/`acting_no_identity` wording.
            // This closes every malformed shape `extract_id` itself can
            // ever refuse on (not just `null`/`{}`, a narrower version
            // of this fix tried first and found insufficient — BUG#54's
            // own adversarial mutation family also produces a THIRD
            // shape, a syntactically well-formed `{value: ""}` that
            // `to_id_component`'s own R4 empty-string guard refuses at
            // `extract_id` while `SlipReference`'s own pattern still
            // fails it identically) WITHOUT having to enumerate them:
            // `extract_id` failing at all is exactly the one condition
            // needed, since `extract_id`'s own composite-identity path
            // and this command's own value-object field read the EXACT
            // SAME underlying JSON — whenever one cannot find a usable
            // value neither can the other, so this can never turn a case
            // where Ruby's `normalize_args` silently succeeds (deferring
            // to a real `hydrate` `NotFound`, matching what `id_line`
            // already answered before this fix) into a wrongly-surfaced
            // argument refusal instead.
            //
            // That "only inside `extract_id`'s OWN failure arm" gate is
            // deliberate, not incidental: it is what keeps this from
            // being either of the two shapes already tried here and
            // reverted —
            //   1. NOT BUG#4's own first attempt (PR #529's commit
            //      message) — deferring EXISTENCE-CHECKING broadly past
            //      argument parsing for every command; the happy path
            //      (`extract_id` resolving an identity, the overwhelming
            //      majority of calls) is entirely untouched — this only
            //      ever runs inside the ALREADY-failing arm, and only
            //      ever for the one command matching the collision
            //      predicate above.
            //   2. NOT BUG#38's own first attempt (this file's `entity_
            //      commands` header, domain_generator.rs) — running a
            //      declared argument's OWN value-object coercion
            //      UNGATED, on the happy path, before `extract_id` runs
            //      at all, which surfaced a separate, still-open bug
            //      (BUG#41: a single-attribute value object's own
            //      `from_json` refuses `UnknownArgument` on an object
            //      with an extra key BEFORE its own missing-field
            //      check). This fix's own early argument pipeline runs
            //      STRICTLY AFTER `extract_id` has ALREADY failed — an
            //      input shaped so BUG#41's own gap could fire here (an
            //      extra key on an object that is ALSO missing the field
            //      `extract_id` itself needs) was ALREADY going to
            //      diverge from Ruby before this fix (as `NotFound`
            //      instead of whatever Ruby's `normalize_args` truly
            //      raises, the exact BUG#54 shape) — this fix can only
            //      ever trade one already-wrong answer for BUG#41's own,
            //      separately-catalogued one on that narrow slice, never
            //      break a case that agreed before it.
            let identity_heads: Vec<&str> =
                a.identified_by.iter().map(|p| p.split('.').next().unwrap_or(p.as_str())).collect();
            let collision_key = !c.creates && identity_heads.len() == 1 && c.attributes.iter().any(|attr| attr.as_str() == identity_heads[0]);
            // BUG#56 (qa/bluebook/quality_control.bluebook) — an ACTING
            // command's own `id_line`, below, already validates an
            // explicit `to:`'s route depth EAGERLY, ahead of `role_line`
            // — matching Ruby's own `Dispatcher#dispatch`, which resolves
            // `Routing.envelope(to)` unconditionally, for EVERY aggregate
            // command, creating or acting alike, strictly before
            // `@commands.call` (the door to `CommandInterpreter`'s own
            // `DISPATCH_ORDER`, `refuse_role_mismatch` included) ever
            // runs. A CREATING command's own generated `dispatch_*`
            // function already runs the SAME `route.require_depth(0)?`
            // check — but only INTERNALLY, deep inside its own
            // `Hydrate::Create`/`Hydrate::Act` decision, built as an
            // ARGUMENT to `crate::kernel::dispatch(...)` — and this
            // router only ever calls that generated function AFTER
            // `check_role` has already run. A caller offering an
            // explicit, wrong-depth `to:` (an entity route on an
            // aggregate-level creating command, say — undeclared,
            // route-shaped) alongside an unauthorized actor used to
            // refuse `Unauthorized` here, where Ruby had already refused
            // `TypeMismatch` on the route itself before ever reaching a
            // role check at all — confirmed live, `Governance::
            // RoleTransition.Grant`, `bin/qa_sweep banking --seeds 40
            // --adversarial 0.3 --role-draw 0.25`. This line closes that
            // gap the same way `id_line` already does for an acting
            // command: eagerly, ahead of everything else in this arm — a
            // plain validation, not an identity computation (a creating
            // command's own identity comes from its declared attributes,
            // never from `route`), so nothing is bound from it.
            let creating_route_precheck_line =
                "if let Some(route) = route { route.require_depth(0)?; }".to_string();
            let id_line = if c.creates {
                creating_route_precheck_line
            } else {
                let acting_no_identity_message = format!(
                    "{} acts on an existing {} — pass {}:",
                    c.name,
                    a.record,
                    a.identified_by.join(", ")
                );
                let not_found = not_found_expr(&acting_no_identity_message);
                if collision_key {
                    let collision_fallback = {
                        let mut lines = vec![format!(
                            "let args = {mod_path}::{}::from_json(facts_json)?;",
                            c.args_struct
                        )];
                        lines.extend(c.invariant_check_lines.iter().cloned());
                        lines.push(format!("return Err({not_found});"));
                        lines.join(" ")
                    };
                    format!(
                        "let id = match route {{ Some(route) => {{ route.require_depth(0)?; route.aggregate().to_string() }}, None => match {mod_path}::{}::extract_id(facts_json) {{ Ok(resolved) => resolved, Err(_) => {{ {collision_fallback} }} }}, }};",
                        a.record
                    )
                } else {
                    format!(
                        "let id = match route {{ Some(route) => {{ route.require_depth(0)?; route.aggregate().to_string() }}, None => {mod_path}::{}::extract_id(facts_json).map_err(|_| {not_found})?, }};",
                        a.record
                    )
                }
            };
            // BUG#23 (qa/bluebook/quality_control.bluebook) — Ruby's own
            // `DISPATCH_ORDER` runs `refuse_unknown_arguments`/`refuse_
            // absent_arguments` structurally BEFORE `hydrate`, but
            // `id_line` just above (an ACTING command's own identity
            // resolution) used to run BEFORE `Args::from_json` — the ONE
            // place those structural checks lived — every single time,
            // so a malformed `id`/`to:` (a route-shaped `{aggregate:,
            // entities:}` value offered where the command declares a
            // plain scalar identity, say) short-circuited the whole
            // dispatch via `extract_id`'s own `?`/`NotFound`-wrap before
            // a missing OTHER argument was ever checked — Ruby and Rust
            // then refused DIFFERENT KINDS for the identical malformed
            // command. `c.structural_precheck` (`json_codec::structural_
            // precheck`, `domain_generator.rs`) is the IDENTICAL unknown/
            // absent-argument check text `Args::from_json` already runs
            // internally — run a SECOND time, standalone, here, against
            // the raw `facts_json` `v` is bound to, BEFORE `id_line`.
            // `None` for a CREATING command (`domain_generator.rs`'s own
            // gate: `id_line` above is never emitted for one either, so
            // there is no race for this to close there). Deliberately
            // redundant with the copy still inside `Args::from_json`
            // itself (unchanged) rather than replacing it — the same
            // "can only ever refuse SOONER with the exact kind `from_
            // json` would have produced anyway, never diverge from it"
            // shape `invariant_check_lines` below already established for
            // R3 — NOT the reordering BUG#4 (PR #529) already tried and
            // reverted: `id_line` itself still runs in exactly the same
            // place, unchanged; this only adds an EARLIER, narrower gate
            // ahead of it, scoped to a command's own declared argument
            // shape, never to record existence.
            let structural_precheck_line = c
                .structural_precheck
                .as_ref()
                .map(|check| format!("{{ let v = facts_json; {check} }}"))
                .unwrap_or_default();
            let role_line = emit_role_check(exemplar, c.role.as_deref(), &c.name);
            let reference_lines: Vec<String> = c
                .reference_checks
                .iter()
                .map(|check| emit_reference_check(exemplar, check))
                .collect();

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
            if !structural_precheck_line.is_empty() {
                body.push(structural_precheck_line);
            }
            if !id_line.is_empty() {
                body.push(id_line);
            }
            body.extend(extra_lines);
            body.push(format!(
                "let args = {mod_path}::{}::from_json(facts_json)?;",
                c.args_struct
            ));
            // R3 (docs/audits/2026-08-11-bug-triage.md) — VO invariant/
            // admits/pattern checks BEFORE role_line/reference_lines,
            // matching Ruby's own DISPATCH_ORDER (this module's own
            // header) and `rust/project/registry.rb`'s identical splice.
            body.extend(c.invariant_check_lines.iter().cloned());
            if let Some(rl) = role_line {
                if !rl.is_empty() {
                    body.push(rl);
                }
            }
            body.extend(reference_lines.into_iter().filter(|l| !l.is_empty()));
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
            let role_line = emit_role_check(exemplar, c.role.as_deref(), &c.name);
            let reference_lines: Vec<String> = c
                .reference_checks
                .iter()
                .map(|check| emit_reference_check(exemplar, check))
                .collect();
            let dispatch_call = format!(
                "{mod_path}::dispatch_entity_{}(&mut store.{}, &parent_id, &element_id, &element_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))",
                c.fn_name, a.module_name
            );

            // BUG#38 (qa/bluebook/quality_control.bluebook) — the SAME
            // BUG#23 standalone structural gate the aggregate arm's own
            // `structural_precheck_line` already runs (this function's
            // header, above), one construct over: spliced INSIDE the
            // route-less `None` arm specifically, BEFORE its own
            // `extract_id` calls resolve. NOT spliced before the whole
            // `match route` the way the aggregate arm's `id_line` gets
            // it: an aggregate command's routed depth is always 0, which
            // a wrong-shaped explicit `to:` (the `routing_key` fuzz
            // mutation's `scalar` case parses into a zero-entity route)
            // always trivially satisfies, so that placement is never
            // actually observable for `CommandEntry`. An entity command's
            // `require_depth(1)` (or `require_depth(2)` one hop deeper)
            // is NOT trivially satisfied by that same zero-entity route —
            // confirmed live (`qa/stress_domains/nested_pieces`,
            // `Workspace.Board.AddCard` with a scalar `to:` mutation):
            // Ruby resolves an EXPLICITLY given `to:` independently of
            // `facts`/`ArgumentGate`, so a wrong-depth explicit route
            // refuses on its own terms, `TypeMismatch`, before Ruby's
            // absent-argument check on the unrelated `facts` payload is
            // ever reached — moving this ahead of the whole match (a
            // first attempt at this fix) refused `AbsentArgument`
            // instead, a genuine new divergence this narrower placement
            // avoids. See `EntityCommandEntry::structural_precheck`'s own
            // header for the rest of the reasoning (why this stays the
            // narrow structural-only check rather than moving the whole
            // `Args::from_json` earlier).
            let structural_precheck_line = c
                .structural_precheck
                .as_ref()
                .map(|check| format!("{{ let v = facts_json; {check} }}"))
                .unwrap_or_default();

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
            // BUG#136 (qa/bluebook/quality_control.bluebook) — see
            // `rust/project/registry.rb`'s own identical, longer comment
            // for the full reasoning: `structural_precheck_line`, above,
            // only ever catches an unknown/absent ARGUMENT NAME, never a
            // declared argument's own VALUE-OBJECT coercion (a declared
            // identity-echo attribute offered a route-shaped value where
            // its own VO type declares a plain scalar field). Ruby's
            // `normalize_args` runs that coercion BEFORE `hydrate_parent`/
            // `locate_element` unconditionally; this arm used to run BOTH
            // `extract_id` calls before `{}::from_json` ever touched the
            // same attribute, so a malformed identity-echo value always
            // short-circuited via `extract_id`'s own failure instead. The
            // narrower BUG#38 fix deliberately stopped short of this
            // because running a declared argument's own VO coercion ahead
            // of `extract_id` on the happy path surfaced BUG#41 (a single-
            // attribute value object's own `from_json` didn't check for an
            // unknown key) as a NEW divergence at the time — BUG#41 is now
            // fixed (PR #623), so re-running the full `from_json` early,
            // here, can no longer reintroduce that gap. The result is
            // discarded (`_args_precheck`) — purely for its `?` early-
            // error-propagation side effect, the same "deliberately
            // redundant, never diverging" shape the aggregate arm's own R3
            // splice and BUG#54's own `collision_fallback` already
            // established. The REAL `args` binding below, unchanged, still
            // runs unconditionally for both `Some(route)` and `None`.
            // BUG#140 — `element_id` resolves through `extract_id_
            // lenient`, not `extract_id` — see `rust/project/registry.rb`'s
            // own identical comment for the full reasoning
            // (`EntityElement#element_of`'s own absent-vs-blank
            // distinction, entity_element.rb). `parent_id` stays strict.
            let body_entity_match = format!(
                "let (parent_id, element_id, element_wants) = match route {{ Some(route) => {{ route.require_depth(1)?; let element_id = route.entities()[0].clone(); (route.aggregate().to_string(), element_id.clone(), element_id) }}, None => {{ {structural_precheck_line} let _args_precheck = {mod_path}::{}::from_json(facts_json)?; let parent_id = {mod_path}::{}::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let element_id = {mod_path}::{}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let element_wants = {mod_path}::{}::extract_wants(facts_json); (parent_id, element_id, element_wants) }}, }};",
                c.args_struct,
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
                body_entity_match,
            ];
            body.push(format!("let args = {mod_path}::{}::from_json(facts_json)?;", c.args_struct));
            // R3 — see the aggregate arm's own identical splice, above.
            body.extend(c.invariant_check_lines.iter().cloned());
            if let Some(rl) = role_line {
                body.push(rl);
            }
            body.extend(reference_lines);
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
            let role_line = emit_role_check(exemplar, c.role.as_deref(), &c.name);
            let reference_lines: Vec<String> = c
                .reference_checks
                .iter()
                .map(|check| emit_reference_check(exemplar, check))
                .collect();
            let dispatch_call = format!(
                "{mod_path}::dispatch_entity_{}(&mut store.{}, &parent_id, &hop1_id, &hop1_wants, &hop2_id, &hop2_wants, args, mutations, owner_deref, command_deref).map(|(_, events)| stamp_payload(events, &payload))",
                c.fn_name, a.module_name
            );

            // BUG#38 — see `entity_arms`' own identical splice, above,
            // including WHY this is scoped to INSIDE the route-less
            // `None` arm alone rather than before the whole `match
            // route`: an explicit but wrong-depth `to:` refuses on its
            // own terms in `Some(route)`, independently of `facts`,
            // before Ruby's absent-argument check on that unrelated
            // payload is ever reached. `None` (never spliced in) when
            // `unrouted_supported` is false: the ROUTED-only `else`
            // branch below always requires an explicit route and never
            // calls `extract_id` against raw `facts_json` at all, so
            // there is no route-less arm here for this to close.
            let structural_precheck_line = c
                .structural_precheck
                .as_ref()
                .map(|check| format!("{{ let v = facts_json; {check} }}"))
                .unwrap_or_default();

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
            // BUG#136 — see `entity_arms`'s own identical splice, above,
            // for the full reasoning: the SAME early, discarded
            // `{args_struct}::from_json` precheck, one nesting hop
            // deeper, spliced ahead of ALL THREE `extract_id` calls in
            // the route-less `None` arm only — `Some(route)`'s identity
            // never goes through `extract_id` and the ROUTED-only `else`
            // branch below never calls it against raw `facts_json` at
            // all, so neither needed this.
            // BUG#140 — `hop1_id`/`hop2_id` both resolve through
            // `extract_id_lenient` — see `rust/project/registry.rb`'s own
            // identical comment for the full reasoning. `parent_id` stays
            // strict.
            let route_binding = if c.unrouted_supported {
                format!(
                    "let (parent_id, hop1_id, hop1_wants, hop2_id, hop2_wants) = match route {{ Some(route) => {{ route.require_depth(2)?; let hop1_id = route.entities()[0].clone(); let hop2_id = route.entities()[1].clone(); (route.aggregate().to_string(), hop1_id.clone(), hop1_id, hop2_id.clone(), hop2_id) }}, None => {{ {structural_precheck_line} let _args_precheck = {mod_path}::{}::from_json(facts_json)?; let parent_id = {mod_path}::{}::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let hop1_id = {mod_path}::{}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let hop1_wants = {mod_path}::{}::extract_wants(facts_json); let hop2_id = {mod_path}::{}::extract_id_lenient(facts_json).map_err(|_| crate::kernel::Refusal::NotFound({}.to_string()))?; let hop2_wants = {mod_path}::{}::extract_wants(facts_json); (parent_id, hop1_id, hop1_wants, hop2_id, hop2_wants) }}, }};",
                    c.args_struct,
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
                    "let route = route.ok_or_else(|| crate::kernel::Refusal::TypeMismatch({}.to_string()))?; route.require_depth(2)?; let parent_id = route.aggregate().to_string(); let hop1_id = route.entities()[0].clone(); let hop2_id = route.entities()[1].clone(); let hop1_wants = hop1_id.clone(); let hop2_wants = hop2_id.clone();",
                    naming::ruby_inspect_string(&route_error)
                )
            };

            let mut body: Vec<String> = vec![
                "let invocation = crate::kernel::CommandInvocation::from_json(args_json)?;".to_string(),
                "let route = invocation.route();".to_string(),
                "let facts_json = invocation.facts();".to_string(),
            ];
            body.push(route_binding);
            body.push(format!("let args = {mod_path}::{}::from_json(facts_json)?;", c.args_struct));
            body.extend(c.invariant_check_lines.iter().cloned());
            if let Some(rl) = role_line {
                body.push(rl);
            }
            body.extend(reference_lines);
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
                    reference_specs: Vec::new(),
                    attributes: Vec::new(),
                    invariant_check_lines: Vec::new(),
                    role: None,
                    structural_precheck: None,
                },
                CommandEntry {
                    verb: "Banking::SafeDepositBox.Close".to_string(),
                    name: "Close".to_string(),
                    fn_name: "close".to_string(),
                    args_struct: "CloseArgs".to_string(),
                    creates: false,
                    identity_extra_params: Vec::new(),
                    reference_checks: Vec::new(),
                    reference_specs: Vec::new(),
                    attributes: Vec::new(),
                    invariant_check_lines: Vec::new(),
                    role: None,
                    structural_precheck: None,
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
                structural_precheck: None,
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
        assert!(generated.contains("RentArgs::from_json(facts_json)?"));
        assert!(generated.contains("route.require_depth(0)?; route.aggregate().to_string()"));
        assert!(generated.contains("route.require_depth(1)?"));
        assert!(generated.contains("let element_id = route.entities()[0].clone()"));
        assert!(generated.contains("VisitAnnotateArgs::from_json(facts_json)?"));
        assert!(generated.contains("Json::overlay(facts_json, &args.to_json())"));
        assert!(!generated.contains("VisitAnnotateArgs::from_json(args_json)?"));
        assert!(generated
            .contains("let (id, port_facts) = invocation.split_aggregate_receiver(None, None)?;"));
        assert!(generated.contains("store.safedepositbox.find(&id)"));
        assert!(generated.contains("PaymentGatewayReceiveArgs::from_json(facts_json)?"));
        assert!(generated.contains("dispatch_operation_paymentgateway_receive(&id, args)"));
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
                reference_specs: Vec::new(),
                attributes: Vec::new(),
                invariant_check_lines: Vec::new(),
                role: None,
                structural_precheck: None,
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
            "SafeDepositBox::extract_id(facts_json).map_err(|_| crate::kernel::Refusal::NotFound(\"Close acts on an existing SafeDepositBox — pass branch_code.value, box_number.value:\".to_string()))?,"
        ));
    }
}
