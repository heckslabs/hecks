//! Command dispatch — the core execution loop
//!
//! Resolves a command name to its aggregate + definition,
//! enforces givens, checks lifecycle, applies mutations,
//! transitions state, persists, and emits.
//!
//! Usage:
//!   let result = dispatch(&mut runtime, "CreatePizza", attrs)?;
//!
//! [antibody-exempt: rust/src/runtime/command_dispatch.rs — kernel-floor
//!  dispatch path. i156 added strict bare-name resolution gated by the
//!  HECKS_STRICT_DISPATCH env var ; the rest of the file is pre-i156.]

use super::{AggregateState, Event, Runtime, RuntimeError, Value};
use super::interpreter;
use crate::ir::{Command, Lifecycle};
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct CommandResult {
    pub aggregate_id: String,
    pub aggregate_type: String,
    pub event: Option<Event>,
    /// Event-sourcing deltas (i-event-sourcing) — the fields this command
    /// actually changed, computed as a before/after diff of aggregate state
    /// (so a lifecycle transition is just another changed field, no special-
    /// casing). `record_event_append` appends one immutable Event to the Log
    /// per delta. Empty for synthetic events and bulk-form dispatch (v1).
    pub deltas: Vec<(String, Value)>,
}

/// Resolution of a dispatch address — i111-J.
///
/// `Aggregate(agg_idx, cmd_idx)` — command lives directly on the
/// aggregate's commands list.
///
/// `Entity(agg_idx, ent_idx, cmd_idx)` — command lives inside an
/// entity declared inside the aggregate's `entity "Foo" do … end`
/// block. Dispatch still operates on the parent aggregate's record
/// (entities are reached only through the root in DDD), but uses the
/// entity's command — its mutations, givens, lifecycle.
#[derive(Debug, Clone, Copy)]
enum Resolution {
    Aggregate(usize, usize),
    Entity(usize, usize, usize),
}

impl Resolution {
    fn agg_idx(&self) -> usize {
        match self {
            Resolution::Aggregate(a, _) => *a,
            Resolution::Entity(a, _, _) => *a,
        }
    }
}

/// Borrow the resolved command from the runtime's IR.
fn cmd_for<'a>(rt: &'a Runtime, res: Resolution) -> &'a Command {
    match res {
        Resolution::Aggregate(a, c) => &rt.domain.aggregates[a].commands[c],
        Resolution::Entity(a, e, c) => &rt.domain.aggregates[a].entities[e].commands[c],
    }
}

/// Borrow the lifecycle that gates the resolved command : the entity's
/// own lifecycle when present, otherwise the parent aggregate's.
fn lifecycle_for<'a>(rt: &'a Runtime, res: Resolution) -> Option<&'a Lifecycle> {
    match res {
        Resolution::Aggregate(a, _) => rt.domain.aggregates[a].lifecycle.as_ref(),
        Resolution::Entity(a, e, _) => rt.domain.aggregates[a].entities[e]
            .lifecycle
            .as_ref()
            .or(rt.domain.aggregates[a].lifecycle.as_ref()),
    }
}
pub fn dispatch(
    rt: &mut Runtime,
    command_name: &str,
    attrs: HashMap<String, Value>,
) -> Result<CommandResult, RuntimeError> {
    dispatch_inner(rt, command_name, attrs, None)
}

/// Cascade-aware dispatch (i111-K) — used by `Runtime::drain_policies`
/// when the triggered command's aggregate has the SAME type as the
/// upstream event. Passing the upstream id as a hint lets the second
/// dispatch reuse the existing record instead of counter-minting a
/// fresh id.
///
/// This closes the i111-C surprise : multi-step pipelines like
/// CorpusPruning (Measure → Split with `given { measured == true }`)
/// previously needed `identified_by` declared just to keep the cascade
/// landing on the same row. With this hint, the cascade preserves the
/// id automatically — `identified_by` becomes a query / addressability
/// concern, not a cascade-correctness requirement.
///
/// The hint is honored only when :
///   - The triggered command's aggregate type matches `upstream_type`
///   - A record already exists at `upstream_id` in that repo
/// Otherwise the dispatch falls through to standard id resolution
/// (identified_by lookup → counter-mint), keeping cross-type cascades
/// and missing-record cases unchanged.
pub fn dispatch_cascade(
    rt: &mut Runtime,
    command_name: &str,
    attrs: HashMap<String, Value>,
    upstream_type: &str,
    upstream_id: &str,
) -> Result<CommandResult, RuntimeError> {
    dispatch_inner(rt, command_name, attrs, Some((upstream_type.to_string(), upstream_id.to_string())))
}

fn dispatch_inner(
    rt: &mut Runtime,
    command_name: &str,
    attrs: HashMap<String, Value>,
    cascade_hint: Option<(String, String)>,
) -> Result<CommandResult, RuntimeError> {
    // Caller-scoped resolution (i-fqn local-short) : the CALLER's bluebook is
    // the upstream aggregate's realm_path (cascade_hint = the aggregate whose
    // event triggered this dispatch). A SHORT ref then resolves LOCAL-first —
    // a same-name aggregate in the caller's own bluebook wins over a foreign
    // homonym. None for a top-level dispatch (no cascade), so those fall back
    // to global match and should carry a full FQN. ADDITIVE : the fallback
    // preserves today's global first-match whenever no local candidate exists.
    let caller_scope: Option<String> = cascade_hint.as_ref().and_then(|(up_type, _)| {
        rt.domain.aggregates.iter()
            .find(|a| &a.name == up_type)
            .and_then(|a| a.realm_path.clone())
    });
    let res = resolve(rt, command_name, caller_scope.as_deref())?;
    let agg_idx = res.agg_idx();

    // Many-form dispatch (i113 / i116) — only applies to aggregate-level
    // commands. Entity commands route through the parent's record and
    // don't currently support the list_of(VO) bulk pattern.
    if let Resolution::Aggregate(_, cmd_idx) = res {
        if let Some(spec_attr) = bulk_spec_attr(rt, agg_idx, cmd_idx) {
            return dispatch_bulk(rt, agg_idx, cmd_idx, command_name, &spec_attr, attrs);
        }
    }

    // create-vs-update is now a persistence upsert keyed on identity (see
    // the resolution block below) — the #729 name-heuristic and the
    // first-class-factory `is_create` bit both retired. `self_ref` survives
    // only to resolve the id a legacy `reference_to` kwarg carries.
    let self_ref = find_self_ref_res(rt, res);
    let aggregate_name = rt.domain.aggregates[agg_idx].name.clone();
    let aggregate_context = rt.domain.aggregates[agg_idx].context.clone();
    let repo_hash_key = super::repo_key(aggregate_context.as_deref(), &aggregate_name);

    // ROOT-3 — singleton identity from the declared default. A singleton declares
    // `identified_by :name` + `attribute :name, default: "X"`. id_for_command keys
    // off `attrs`, but the attribute default was only applied to STATE (AFTER id
    // resolution), so a policy/PM dispatch that omitted the key counter-minted a
    // new row instead of keying the singleton (statusline 3881 rows, awareness "1",
    // the Seed gather). Inject the identity attribute's declared default into attrs
    // BEFORE id resolution, so a singleton keys by its name whether or not the
    // caller passed it. Command default wins ; else the aggregate's. No-op when the
    // key is already supplied or carries no default (non-singleton aggregates).
    let mut attrs = attrs;
    if let Some(key) = rt.domain.aggregates[agg_idx].identified_by.clone() {
        if !attrs.contains_key(&key) {
            let cmd = cmd_for(rt, res);
            let from_cmd = cmd.attributes.iter().find(|a| a.name == key);
            let from_agg = rt.domain.aggregates[agg_idx].attributes.iter().find(|a| a.name == key);
            if let Some(d) = from_cmd.and_then(|a| a.default.clone())
                .or_else(|| from_agg.and_then(|a| a.default.clone()))
            {
                let attr_type = from_cmd.map(|a| a.attr_type.clone())
                    .or_else(|| from_agg.map(|a| a.attr_type.clone()))
                    .unwrap_or_default();
                attrs.insert(key.clone(), parse_default(&d, &attr_type));
            }
        }
    }
    let attrs = attrs;

    // i111-K — same-type cascade id preservation. When the cascade
    // hopped Aggregate → Aggregate (same type) and a record exists at
    // the upstream id, reuse it. This runs BEFORE id_for_command so it
    // overrides counter-mint behavior for aggregates without
    // identified_by — closing the i111-C identified_by-required gap.
    let cascade_id = cascade_hint.as_ref().and_then(|(up_type, up_id)| {
        if up_type == &aggregate_name {
            // A same-type cascade must NOT hijack the identity of a command that
            // supplies its OWN id via the aggregate's identified_by field in attrs
            // (e.g. Claim.Acquire(story=s2) cascaded from ClaimReleased(s1) must
            // CREATE s2, not update s1). Only reuse the upstream id when the
            // command brings no explicit identity.
            let supplies_own_id = rt.domain.aggregates[agg_idx].identified_by
                .as_ref()
                .map_or(false, |idf| attrs.get(idf).map_or(false, |v| !v.to_string().is_empty()));
            if supplies_own_id {
                return None;
            }
            rt.repositories.get(&repo_hash_key)
                .and_then(|repo| repo.find(up_id))
                .map(|_| up_id.clone())
        } else {
            None
        }
    });

    // Build the diagnostic up front — borrowing `rt` inside
    // `ok_or_else` collides with the `get_mut` mutable borrow.
    let unknown_agg_msg = if rt.repositories.contains_key(&repo_hash_key) {
        String::new()
    } else {
        unknown_aggregate_message(rt, &aggregate_name)
    };
    // i-cascade-fk : a cross-aggregate cascade (cascade_hint upstream type
    // differs from this aggregate) driving a self-ref command carries the
    // upstream event's leaked `id`, which names the UPSTREAM record, not one
    // of this type. Resolve the owning record from the upstream record's FK
    // (its attribute whose declared type IS this aggregate) so e.g.
    // TaskCompleted -> Story.DropPendingTaskCount finds the Story via Task.story.
    let cascade_fk_id: Option<String> = cascade_hint.as_ref().and_then(|(up_type, up_id)| {
        if up_type == &aggregate_name { return None; }
        // same-context upstream first : in combined-domain mode several
        // domains may share an aggregate name (e.g. Task), so prefer the one
        // in the target's context before falling back to any match.
        let up_agg = rt.domain.aggregates.iter()
            .find(|a| &a.name == up_type && a.context == aggregate_context)
            .or_else(|| rt.domain.aggregates.iter().find(|a| &a.name == up_type))?;
        let fname = up_agg.attributes.iter()
            .find(|at| at.attr_type == aggregate_name)
            .map(|at| at.name.clone())?;
        rt.repositories.get(&super::repo_key(up_agg.context.as_deref(), up_type))
            .and_then(|up| up.find(up_id))
            .and_then(|rec| rec.fields.get(&fname))
            .and_then(|v| v.as_str().map(str::to_string))
    });
    // i735 defect 2 — an aggregate whose `:sqlite` adapter was refused at
    // boot has NO repository (dropped, never silently swapped to heki).
    // Surface the loud reason instead of a misleading "unknown aggregate".
    if let Some(reason) = rt.refused_persistence.get(&repo_hash_key) {
        return Err(RuntimeError::PersistenceRefused(reason.clone()));
    }
    let repo = rt.repositories.get_mut(&repo_hash_key)
        .ok_or(RuntimeError::UnknownAggregate(unknown_agg_msg))?;

    // Pure upsert on identity (Relationship grammar, 2026-06-18) — create
    // vs update is a PERSISTENCE contract, not a declaration. Resolve the
    // identity from every source, then find-or-create : present -> update,
    // absent -> insert. No name heuristic, no reference_to(Self) error-on-
    // absent — the row's existence IS the create/update bit, so AddStory
    // can no longer mint a phantom Sprint. `find_self_ref_res` survives
    // only to keep resolving the id a legacy `reference_to` kwarg carries
    // (e.g. `sprint=`) until the corpus drops the self-ref form ; new
    // commands resolve via the universal `id` key or id_for_command.
    let resolved_id = if let Some(ref_name) = &self_ref {
        attrs.get(ref_name).map(|v| v.to_string())
            .or_else(|| cascade_fk_id.clone())
            .or_else(|| attrs.get("id").map(|v| v.to_string()))
            .or_else(|| cascade_id.clone())
            .unwrap_or_else(|| repo.id_for_command(&attrs))
    } else if let Some(id) = cascade_id.clone() {
        id
    } else {
        repo.id_for_command(&attrs)
    };
    let (mut state, is_new) = match repo.find(&resolved_id).cloned() {
        Some(s) => (s, false),
        None => (AggregateState::new(&resolved_id), true),
    };

    // Event-sourcing delta capture (i-event-sourcing) — snapshot state
    // BEFORE the command's effects (defaults, mutations, transition). For a
    // new aggregate this is empty, so every resolved field (including the
    // applied defaults and the lifecycle transition) surfaces as a delta in
    // the before/after diff computed just before save.
    let before_fields = state.fields.clone();

    if is_new {
        apply_defaults(rt, agg_idx, &mut state);
        apply_lifecycle_default(rt, agg_idx, &mut state);
    }

    // Create commands copy matching attrs to aggregate. For entity
    // commands the parent aggregate's attribute set is the target
    // schema (entities live within the parent's record). This phase runs
    // BEFORE pipeline_core (givens -> mutations -> invariants), so a
    // pure-data create like EventSourcing::Event.Append populates its VO
    // attrs here and check_invariants enforces on the REAL values, not
    // the apply_defaults empty-list placeholders. then_set mutations run
    // after and override on overlap (no corpus then_set targets a raw
    // create-attr name, so this is inert for existing aggregates).
    if is_new {
        let agg_attr_names: Vec<&str> = rt.domain.aggregates[agg_idx]
            .attributes.iter().map(|a| a.name.as_str()).collect();
        let cmd = cmd_for(rt, res);
        for cmd_attr in &cmd.attributes {
            if agg_attr_names.contains(&cmd_attr.name.as_str()) {
                if let Some(val) = attrs.get(&cmd_attr.name) {
                    state.set(&cmd_attr.name, val.clone());
                }
            }
        }
    }

    // Pipeline: givens → lifecycle check → mutations → lifecycle transition
    let cmd = cmd_for(rt, res);
    interpreter::check_givens(cmd, &state, &attrs)?;
    check_lifecycle(rt, res, &state)?;
    interpreter::apply_mutations(cmd, &mut state, &attrs);
    apply_lifecycle_transition(rt, res, &mut state);

    // f4 — aggregate-level invariants are checked on the RESULTING state
    // (post-mutation, post-transition) before save. A violated invariant
    // rejects the command exactly like a failed `given` : 0 events, no save.
    // An invariant is a `given` enforced on every command.
    if let Some(violated) = crate::invariants::check_invariants(
        &rt.domain.aggregates[agg_idx].invariants,
        &state,
        &attrs,
    ) {
        return Err(RuntimeError::InvariantViolation {
            name: violated.name.clone(),
            expression: violated.expression.clone(),
        });
    }

    // belongs_to-on-event — the aggregate's stored belongs_to FKs ride its
    // emitted event so downstream adapters can bind them (the freed worker on
    // ClaimReleased -> SEAM 1 retrigger ; the story on LeaseReclaimed -> worktree
    // unlock). Command inputs win on collision ; empty FKs are skipped.
    let mut event_data = attrs.clone();
    for r in &rt.domain.aggregates[agg_idx].references {
        if matches!(r.kind, crate::ir::ReferenceKind::BelongsTo)
            && !event_data.contains_key(&r.name)
        {
            let v = state.get(&r.name);
            if !v.to_string().is_empty() {
                event_data.insert(r.name.clone(), v.clone());
            }
        }
    }
    // Event-sourcing deltas — the fields whose value changed vs. the
    // pre-command snapshot. A lifecycle transition is just another changed
    // field here (status: pending -> authorized), so it needs no special-
    // casing. Computed BEFORE save (which moves state). record_event_append
    // appends one immutable Log Event per delta.
    let deltas: Vec<(String, Value)> = state.fields.iter()
        .filter(|(k, v)| before_fields.get(*k) != Some(*v))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    // deciderate Layer 0b — the CHANGED state fields (deltas) ride the emitted
    // event so a policy can GUARD on the RESULTING state, not just the command
    // inputs (e.g. `where games_remaining: 0` after a decrement — the Bracket
    // saga's round-complete condition). The delta WINS over a same-named
    // command input : the event must carry what the command RESULTED IN, not
    // what was requested. This is essential when a for_each SWEEP passes the
    // swept record's PRE-mutation field (e.g. Bubble.Decay receives the floating
    // bubble's old `size`) and then mutates it — the guard (`where size: 0`)
    // must see the post-decrement value, not the stale swept input. Untouched
    // input fields (never in deltas) are left as-is.
    for (k, v) in &deltas {
        event_data.insert(k.clone(), v.clone());
    }
    let aggregate_id = state.id.clone();
    let was_deleted = state.deleted;
    let ctx = crate::heki::WriteContext::Dispatch {
        aggregate: &aggregate_name, command: command_name,
    };
    let repo = rt.repositories.get_mut(&repo_hash_key).unwrap();
    if was_deleted {
        repo.delete(&aggregate_id, ctx);
    } else {
        repo.save(state, ctx);
    }

    let event = build_event_res(rt, res, &aggregate_id, &event_data);
    if let Some(ref evt) = event {
        // Sprint 14 (retire-sync-cascade-pipeline) — the legacy Sync vs.
        // Actor fork retired. Every aggregate publishes inline through the
        // event bus ; the `delivery :actor` mailbox-stub path is gone. The
        // actor-per-aggregate-instance + async-event-delivery-bus stories
        // will rewire publishing into per-mailbox enqueueing later without
        // a bluebook-visible fork — the runtime is the swappable substrate.
        rt.event_bus.publish(evt.clone());
    }

    let result = CommandResult {
        aggregate_id,
        aggregate_type: aggregate_name,
        event,
        deltas,
    };
    // Event-sourcing : append to the durable Log at the UNIVERSAL door, so
    // every command that passes through storehouse — top-level dispatch AND
    // cascade reaction (which reaches dispatch_inner via dispatch_cascade,
    // bypassing the Runtime::dispatch wrapper) — is recorded. record_event_append
    // guards against recursion (its own Append) and infra (CascadeRun/OutboundEvent).
    // Phase-4 causation : a cascaded dispatch carries its upstream (type, id) ;
    // the cause is the last Log event recorded for that aggregate. Root
    // dispatches (no hint) resolve to empty — where CausationTrace stops.
    let causation_id = rt.cause_for_cascade(&cascade_hint);
    rt.record_event_append(&result, command_name, &causation_id);
    // Event Log consolidation : the Consolidate maintenance command folds this
    // realm's per-process shards into the global ordered event.heki. Hooked
    // HERE (not the Runtime::dispatch wrapper) so it fires on BOTH the manual
    // dispatch path AND the driver's dispatch_cascade fire (storehouse drive).
    // No-op for every other command. Replaces the hand-written run_merge daemon.
    rt.run_consolidate_if(command_name);
    Ok(result)
}

/// The canonical FQN form of a dispatch address, for the LOG surfaces.
/// Resolves `command_name` to its aggregate and rebuilds the full
/// `Realm::…::Domain::Aggregate.verb` from the aggregate's stamped
/// `realm_path`, so a `storehouse follow` line shows WHERE the dispatch
/// actually landed — not the terse 2-seg the caller typed. A future
/// mis-resolution becomes visible in the log instead of hiding behind the
/// short form. Falls back to the raw name for legacy dotted forms,
/// unstamped aggregates (string-parsed / outside ~/Projects), or anything
/// that doesn't resolve — the log never invents an address it can't build.
pub fn canonical_for_log(rt: &Runtime, command_name: &str) -> String {
    let Some((_head, tail)) = command_name.rsplit_once('.') else {
        return command_name.to_string();
    };
    let (domain, target, _cmd) = match parse_fqn(command_name) {
        Ok(parts) => parts,
        Err(_) => return command_name.to_string(),
    };
    let domain_lc = domain.to_lowercase();
    let (realm, context) = crate::heki::fqn_realm_context(command_name);
    for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
        if agg.name != target { continue; }
        if !domain_matches(rt, ai, &domain, &domain_lc) { continue; }
        if !crate::heki::realm_context_matches(agg.realm_path.as_deref(), realm.as_deref(), context.as_deref()) { continue; }
        if let Some(prefix) = crate::fqns_resolve::canonical_prefix(agg) {
            return format!("{}.{}", prefix, tail);
        }
    }
    command_name.to_string()
}

/// The canonical strings an authorization gate matches a policy against —
/// derived from the RESOLVED target, NEVER the caller's raw input, so a BARE
/// dispatch (`PlaceOrder`) and a fully-qualified one (`Pizzas::Order.PlaceOrder`)
/// of the SAME command yield IDENTICAL forms and therefore the IDENTICAL gate
/// verdict. This is the forbid-bypass fix (SECURITY-gate-matches-raw-not-fqn,
/// 2026-07-03) : before it, `evaluate_policy` matched the policy `action`
/// pattern against whatever the caller typed, so a namespace-scoped
/// `forbid Pizzas::Order.*` was escaped by dispatching the bare verb (which
/// never prefix-matched the pattern) and a namespace `permit Pizzas::*` wrongly
/// failed a bare-verb caller.
/// [antibody-exempt: rust/src/runtime/command_dispatch.rs (canonical_action) —
///  kernel-floor authz gate, security fix, authorized by Chris 2026-07-03]
///
/// `action_forms` is matched against the policy `action` ; `resource_forms`
/// against `resource`. A form SET (not a single string) keeps BOTH legacy
/// authoring conventions matching after canonicalisation — a bare-verb policy
/// (`Open`, `List`) AND a qualified one (`AuthzDemo::Vault.list`) — while every
/// form is resolution-derived, so parity across dispatch shapes holds. An
/// unresolvable phrase (the synthetic `<Aggregate>.state` reads, or genuine
/// junk) falls back to the raw string : nothing that fails to resolve can
/// dispatch anyway, so the raw fallback can never reopen the bypass, and
/// deny-by-default still bites an unknown verb.
pub(crate) struct CanonicalAction {
    pub action_forms: Vec<String>,
    pub resource_forms: Vec<String>,
}

pub(crate) fn canonical_action(rt: &Runtime, name: &str) -> CanonicalAction {
    // Command first — the dispatch path's OWN resolver, so the gate keys on
    // exactly what would execute.
    if let Ok(res) = resolve(rt, name, None) {
        let agg = &rt.domain.aggregates[res.agg_idx()];
        let verb = cmd_for(rt, res).name.clone();
        return canon_forms(agg, &verb);
    }
    // Then a query — by exact or snake_case verb, refusing on a homonym (an
    // ambiguous verb keeps the raw fallback rather than guess an aggregate).
    if let Some((agg, verb)) = resolve_query_agg(rt, name) {
        return canon_forms(agg, &verb);
    }
    // Unresolvable — keep the raw phrase and its tail so synthetic reads
    // (`Vault.state`) and any bare form still match a policy authored on them.
    // Resource mirrors the pre-fix derivation exactly : the head before the
    // last `.`, or the whole name when bare — never empty, so a `resource: *`
    // policy still matches (the `explain` dry path resolves no domain).
    let verb = name.rsplit('.').next().unwrap_or(name).to_string();
    let resource = name.rsplit_once('.').map(|(h, _)| h).unwrap_or(name);
    CanonicalAction {
        action_forms: dedup_nonempty(vec![name.to_string(), verb]),
        resource_forms: dedup_nonempty(vec![resource.to_string()]),
    }
}

/// Build the action/resource form set for a RESOLVED (aggregate, verb). The
/// `Domain` segment is the aggregate's bluebook context (falling back to its
/// category), mirroring `Domain::Aggregate.verb` — the shape a policy is
/// authored against and the one `parse_fqn` reads back.
fn canon_forms(agg: &crate::ir::Aggregate, verb: &str) -> CanonicalAction {
    let verb_snake = crate::util::snake_case(verb);
    let domain = agg
        .context
        .clone()
        .or_else(|| agg.category.clone())
        .unwrap_or_default();
    let mut action_forms = Vec::new();
    let mut resource_forms = vec![agg.name.clone()];
    if domain.is_empty() {
        // No context to anchor a 2-seg FQN — expose the verb forms alone.
        action_forms.push(verb.to_string());
        action_forms.push(verb_snake);
    } else {
        let resource_fqn = format!("{}::{}", domain, agg.name);
        action_forms.push(format!("{}.{}", resource_fqn, verb));
        action_forms.push(format!("{}.{}", resource_fqn, verb_snake));
        action_forms.push(verb.to_string());
        action_forms.push(verb_snake);
        resource_forms.push(resource_fqn);
    }
    CanonicalAction {
        action_forms: dedup_nonempty(action_forms),
        resource_forms: dedup_nonempty(resource_forms),
    }
}

/// Find the single aggregate declaring `name`'s verb as a query — exact or
/// snake_case. `name` may be bare (`List`) or qualified (`AuthzDemo::Vault.list`) ;
/// when qualified the intended aggregate name disambiguates a homonym. Returns
/// None on no match OR ambiguity (the caller keeps the raw fallback).
fn resolve_query_agg<'a>(
    rt: &'a Runtime,
    name: &str,
) -> Option<(&'a crate::ir::Aggregate, String)> {
    let verb = name.rsplit('.').next().unwrap_or(name);
    let want_agg = if name.contains('.') {
        parse_fqn(name).ok().map(|(_d, target, _c)| target)
    } else {
        None
    };
    let mut hit: Option<(&crate::ir::Aggregate, String)> = None;
    for agg in rt.domain.aggregates.iter() {
        if let Some(ref want) = want_agg {
            if &agg.name != want {
                continue;
            }
        }
        for q in agg.queries.iter() {
            if q.name == verb || crate::util::snake_case(&q.name) == verb {
                if hit.is_some() {
                    return None; // homonym — refuse, keep raw fallback
                }
                hit = Some((agg, q.name.clone()));
            }
        }
    }
    hit
}

fn dedup_nonempty(v: Vec<String>) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    v.into_iter()
        .filter(|s| !s.is_empty())
        .filter(|s| seen.insert(s.clone()))
        .collect()
}

/// Decide whether a multi-hit resolution is AMBIGUOUS — the pure core of the
/// FQN flip, extracted so it is unit-testable without a Runtime. A dispatch
/// that OMITTED its realm (`realm_omitted`) and resolves to >1 DISTINCT
/// non-empty realm_path is ambiguous : returns the sorted candidate FQNs the
/// caller must disambiguate between. Returns None when the dispatch carried a
/// realm, when fewer than two distinct realms remain, or when the matching
/// aggregates carry no stamped realm_path (legacy / string-parsed) — those
/// keep first-match-wins, exactly as before the flip.
fn ambiguity_candidates(hit_realms: &[String], realm_omitted: bool, command_name: &str) -> Option<Vec<String>> {
    if !realm_omitted {
        return None;
    }
    let mut candidates: Vec<String> = hit_realms.iter()
        .filter(|rp| !rp.is_empty())
        .map(|rp| format!("{}::{}", rp.replace('/', "::"), command_name))
        .collect();
    candidates.sort();
    candidates.dedup();
    if candidates.len() > 1 {
        Some(candidates)
    } else {
        None
    }
}

/// Resolve a command address to a Resolution (aggregate or entity-owned).
///
/// ## Canonical form — i560 v2 FQN migration (2026-05-12)
///
///   - `Domain::Aggregate.Command` (commands, PascalCase)
///   - `Domain::Aggregate.query_name` (queries, snake_case)
///
///     Two `::`-separated segments followed by `.<Command-or-query>`.
///
///     - `Domain` matches against an aggregate's `context` (bluebook
///       namespace, set by `Hecks.bluebook "X"`) OR against the
///       bluebook's `category` (the directory under `aggregates/`,
///       e.g. `discipline`, `framework`, `world`). Case-insensitive.
///     - `Aggregate` matches the aggregate's `name`.
///     - The post-`.` token is PascalCase for commands and snake_case
///       for queries.
///
///   This is the form the CLI accepts (`storehouse <root>
///   Domain::Aggregate.Command`). The CLI gate in `main.rs` rejects
///   the legacy short forms with a helpful error naming the canonical
///   shape. The resolver below still accepts the legacy dotted forms
///   so internal cascade machinery (`drain_policies`,
///   `dispatch_cascade`) keeps working — bluebook `trigger_command`
///   strings are typically declared as `Aggregate.Command` in source
///   today, and rewriting every bluebook is out of scope for this
///   sidequest.
///
/// ## Legacy forms (accepted for internal cascade use)
///
///   - `Context.Aggregate.Command` — three dotted parts (i142 form).
///   - `Aggregate.Entity.Command` — three dotted parts that don't
///     match a known context (i111-J).
///   - `Aggregate.Command` — two dotted parts.
///   - `Command` — bare command name.
/// Reduce a realm-OVER-qualified FQN to its canonical `Domain::Aggregate.Command`
/// tail — the last TWO `::`-delimited namespace segments before the `.command`.
/// `Hecks::Framework::Cascade::Cascade.RecordResult` -> `Cascade::Cascade.RecordResult`.
/// Returns None when the address is already two segments or fewer (nothing to
/// strip) or carries no `.command`, so the caller only retries a genuinely
/// over-qualified target. The realm-tolerant fallback for hecksagon `result_into`
/// dispatch targets (2026-06-30).
fn realm_over_qualified_tail(command_name: &str) -> Option<String> {
    let dot = command_name.rfind('.')?;
    let addr = &command_name[..dot];
    let cmd = &command_name[dot..]; // includes the leading '.'
    let segs: Vec<&str> = addr.split("::").collect();
    if segs.len() <= 2 {
        return None;
    }
    Some(format!("{}::{}{}", segs[segs.len() - 2], segs[segs.len() - 1], cmd))
}

fn resolve(rt: &Runtime, command_name: &str, caller_scope: Option<&str>) -> Result<Resolution, RuntimeError> {
        // i560 v2 — canonical FQN form first. Presence of `::` is the
        // discriminator ; the rest falls through to the legacy dotted
        // forms that internal cascade dispatch relies on.
        if command_name.contains("::") {
            match resolve_fully_qualified(rt, command_name, caller_scope) {
                Ok(r) => return Ok(r),
                Err(e) => {
                    // Realm-tolerant fallback (FQN over-qualification, 2026-06-30).
                    // A dispatch target carrying MORE namespace segments than the
                    // canonical `Domain::Aggregate.Command` tail — e.g. the
                    // hecksagon `result_into`
                    // `Hecks::Framework::Cascade::Cascade.RecordResult` — derives a
                    // realm/context from the extra segments that no aggregate's
                    // real realm_path matches, so the strict resolve filters every
                    // candidate out. Retry with the bare two-segment tail
                    // (`Cascade::Cascade.RecordResult`) before surfacing the error.
                    // The tail path keeps its own ambiguity guard (a homonym across
                    // realms still errors), so this never silently mis-resolves ;
                    // it only fires AFTER the strict form already failed, so a
                    // correct full FQN is never overridden.
                    //
                    // The retry passes caller_scope = None : an over-qualified
                    // target EXPLICITLY named its bluebook, so it is a global cross-
                    // bluebook reference, not a scope-relative short ref. Passing the
                    // caller's scope would trip the foreign-bluebook guard (a realm-
                    // omitted ref resolving outside the caller's scope is rejected),
                    // which is exactly the cascade case (Tools -> Cascade). Global
                    // resolution still errors on a genuine cross-realm homonym.
                    if let Some(tail) = realm_over_qualified_tail(command_name) {
                        if let Ok(r) = resolve_fully_qualified(rt, &tail, None) {
                            return Ok(r);
                        }
                    }
                    return Err(e);
                }
            }
        }
    let parts: Vec<&str> = command_name.split('.').collect();
    match parts.as_slice() {
        [a, b, c] => {
            // Try Context.Aggregate.Command first (i142). If no
            // aggregate is in that context, fall through to the
            // Aggregate.Entity.Command form (i111-J).
            for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                if agg.name != *b { continue; }
                if agg.context.as_deref() != Some(*a) { continue; }
                for (ci, cmd) in agg.commands.iter().enumerate() {
                    if cmd.name == *c { return Ok(Resolution::Aggregate(ai, ci)); }
                }
            }
            for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                if agg.name != *a { continue; }
                for (ei, ent) in agg.entities.iter().enumerate() {
                    if ent.name != *b { continue; }
                    for (ci, cmd) in ent.commands.iter().enumerate() {
                        if cmd.name == *c { return Ok(Resolution::Entity(ai, ei, ci)); }
                    }
                }
            }
            Err(RuntimeError::UnknownCommand(
                unknown_command_message_3part(rt, command_name, a, b, c)
            ))
        }
        [agg_name, cmd_name] => {
            // First pass — direct aggregate command match. LOCAL-first
            // (i-fqn local-short) : a same-name aggregate in the caller's own
            // bluebook wins outright. Else decide by UNIQUENESS — a unique target
            // resolves even when foreign (mirrors the lenient bare-name path every
            // cross-bluebook PM `dispatch` / policy `then trigger` short ref relies
            // on). Only a genuine HOMONYM — the same Aggregate.Command in 2+
            // DISTINCT stamped bluebooks, none local — must use the full FQN.
            // (pulse-pm fix : the prior guard errored on the FIRST foreign match
            // without counting, silently killing cross-bluebook PM dotted refs.)
            let mut matches: Vec<(Resolution, Option<String>)> = Vec::new();
            for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                if agg.name != *agg_name { continue; }
                for (ci, cmd) in agg.commands.iter().enumerate() {
                    if cmd.name == *cmd_name {
                        if caller_scope.is_some() && agg.realm_path.as_deref() == caller_scope {
                            return Ok(Resolution::Aggregate(ai, ci));
                        }
                        matches.push((Resolution::Aggregate(ai, ci), agg.realm_path.clone()));
                    }
                }
            }
            if !matches.is_empty() {
                let distinct_scopes: std::collections::HashSet<&str> =
                    matches.iter().filter_map(|(_, rp)| rp.as_deref()).collect();
                if caller_scope.is_some() && distinct_scopes.len() > 1 {
                    return Err(RuntimeError::UnknownCommand(format!(
                        "{} — short ref is ambiguous across {} bluebooks (caller scope {:?}); a cross-bluebook cascade must use the full Realm::Context::Bluebook::Aggregate FQN",
                        command_name, distinct_scopes.len(), caller_scope)));
                }
                return Ok(matches.into_iter().next().unwrap().0);
            }
            // Second pass (i111-J) — entity-owned command, accepted
            // only when unambiguous (single owning entity within the
            // aggregate). Multiple owners on the same aggregate is a
            // corpus error ; surface it loudly.
            let mut hits: Vec<(usize, usize, usize, String)> = Vec::new();
            for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                if agg.name != *agg_name { continue; }
                for (ei, ent) in agg.entities.iter().enumerate() {
                    for (ci, cmd) in ent.commands.iter().enumerate() {
                        if cmd.name == *cmd_name {
                            hits.push((ai, ei, ci, ent.name.clone()));
                        }
                    }
                }
            }
            if hits.len() == 1 {
                Ok(Resolution::Entity(hits[0].0, hits[0].1, hits[0].2))
            } else if hits.is_empty() {
                Err(RuntimeError::UnknownCommand(
                    unknown_command_message_2part(rt, command_name, agg_name, cmd_name)
                ))
            } else {
                // Multiple entities of the same aggregate own a command
                // by this name. Without entity disambiguation in the
                // address, the runtime can't pick. Same shape as i156
                // bare-name ambiguity ; reuse UnknownCommand with the
                // candidate list embedded in the message.
                let mut candidates: Vec<String> = hits.iter()
                    .map(|h| format!("{}.{}", agg_name, h.3))
                    .collect();
                candidates.sort();
                candidates.dedup();
                Err(RuntimeError::UnknownCommand(format!(
                    "{} — ambiguous, candidates: {}",
                    command_name,
                    candidates.join(", ")
                )))
            }
        }
        [cmd_name] => {
            // Bare-name dispatch — i156 strict mode (opt-in via the
            // HECKS_STRICT_DISPATCH env var). When strict mode is on AND
            // the bare name appears on more than one aggregate across
            // the loaded corpus, fail loudly with the candidate list
            // instead of silently first-match-wins.
            //
            // Strict mode stays opt-in until the corpus migration is
            // complete (the validator_corpus::bare_name_collisions rule
            // surfaces what's left ; ~107 .behaviors setups already
            // migrated to qualified form by i156 part 2). The i156 PR
            // body documents the gating decision.
            //
            // Default (non-strict) behavior preserves first-match-wins
            // for backward compat — same as before. Per-aggregate
            // uniqueness (i155) still holds within a single bluebook.
            //
            // i111-J — the walk also visits entity-owned commands so
            // collapsed-entity behaviors can still dispatch by short
            // name. Aggregate commands take precedence ; entities are
            // the fallback. Strict-mode collision counts include
            // entity owners alongside aggregate owners.
            let strict = std::env::var("HECKS_STRICT_DISPATCH")
                .map(|v| v == "1" || v == "true")
                .unwrap_or(false);
            if strict {
                let mut hits: Vec<(Resolution, String)> = Vec::new();
                for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                    for (ci, cmd) in agg.commands.iter().enumerate() {
                        if cmd.name == *cmd_name {
                            hits.push((Resolution::Aggregate(ai, ci), agg.name.clone()));
                        }
                    }
                    for (ei, ent) in agg.entities.iter().enumerate() {
                        for (ci, cmd) in ent.commands.iter().enumerate() {
                            if cmd.name == *cmd_name {
                                hits.push((
                                    Resolution::Entity(ai, ei, ci),
                                    format!("{}.{}", agg.name, ent.name),
                                ));
                            }
                        }
                    }
                }
                match hits.len() {
                    0 => Err(RuntimeError::UnknownCommand(
                        unknown_command_message_bare(rt, command_name)
                    )),
                    1 => Ok(hits[0].0),
                    _ => {
                        let mut candidates: Vec<String> = hits.iter().map(|h| h.1.clone()).collect();
                        candidates.sort();
                        candidates.dedup();
                        Err(RuntimeError::AmbiguousCommand {
                            name: cmd_name.to_string(),
                            candidates,
                        })
                    }
                }
            } else {
                for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                    for (ci, cmd) in agg.commands.iter().enumerate() {
                        if cmd.name == *cmd_name { return Ok(Resolution::Aggregate(ai, ci)); }
                    }
                }
                for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
                    for (ei, ent) in agg.entities.iter().enumerate() {
                        for (ci, cmd) in ent.commands.iter().enumerate() {
                            if cmd.name == *cmd_name {
                                return Ok(Resolution::Entity(ai, ei, ci));
                            }
                        }
                    }
                }
                Err(RuntimeError::UnknownCommand(
                    unknown_command_message_bare(rt, command_name)
                ))
            }
        }
        _ => Err(RuntimeError::UnknownCommand(format!(
            "{} — malformed dispatch address (canonical form is 'Domain::Aggregate.Command' or 'Domain::Aggregate.query_name'; legacy forms still accepted for cascade: 'Command', 'Aggregate.Command', 'Context.Aggregate.Command', 'Aggregate.Entity.Command')",
            command_name
        ))),
    }
}

/// Parse a realm-qualified, VARIABLE-DEPTH address into component parts.
///
/// The folder tree IS the namespace : `Realm[::Subrealm…]::Domain::Aggregate.command`
/// (or `.query_name`). Parsed by ENDS, not count — the last `::` segment is the
/// Aggregate, the second-to-last is the Domain, and everything before them
/// (Realm + 0+ subrealms) is the namespace path. Minimum 2 segments.
///
/// Returned tuple: (domain, aggregate, command_or_query) — the two address ENDS
/// that resolution keys on. The Realm/subrealm prefix is ACCEPTED here ; during
/// the migration bridge it is not yet enforced in resolution (that arrives with
/// the realm-path stamped on each Aggregate). So both the new
/// `Realm::Domain::Aggregate` form and the legacy prefix-free `Domain::Aggregate`
/// (i560 v2) resolve identically — the latter is just the zero-prefix case.
pub fn parse_fqn(command_name: &str) -> Result<(String, String, String), String> {
    let err = || format!(
        "calling format is Realm::Domain::Aggregate.command (queries: .query_name lowercase) — got '{}' (need at least Domain::Aggregate before the '.')",
        command_name
    );
    let (head, tail) = match command_name.rsplit_once('.') {
        Some(pair) => pair,
        None => return Err(err()),
    };
    if tail.is_empty() || head.is_empty() {
        return Err(err());
    }
    let segments: Vec<&str> = head.split("::").collect();
    if segments.len() < 2 || segments.iter().any(|s| s.is_empty()) {
        return Err(err());
    }
    let n = segments.len();
    Ok((
        segments[n - 2].to_string(), // Domain  — second-to-last segment
        segments[n - 1].to_string(), // Aggregate — the leaf (last segment)
        tail.to_string(),
    ))
}

/// Resolve the fully-qualified canonical form
/// `Domain::Aggregate.Command`. The trailing token is the command
/// name (PascalCase) ; queries are resolved by the query layer using
/// `parse_fqn` directly, so this function only returns a Resolution
/// for command-shaped addresses.
fn resolve_fully_qualified(rt: &Runtime, command_name: &str, caller_scope: Option<&str>) -> Result<Resolution, RuntimeError> {
    let (domain, target, cmd) = match parse_fqn(command_name) {
        Ok(parts) => parts,
        Err(msg) => return Err(RuntimeError::UnknownCommand(msg)),
    };

    let domain_lc = domain.to_lowercase();
    let (realm, context) = crate::heki::fqn_realm_context(command_name);

    // First pass — aggregate-rooted command (target == aggregate name).
    // The FLIP (i-fqn): collect EVERY realm-matching candidate rather than
    // taking the first. A realm-OMITTED (2-seg) dispatch that resolves to >1
    // aggregate across distinct realms is reported AmbiguousCommand instead of
    // silently picking the first — the Tools::Cascade wrong-realm failure mode.
    // This is a no-op while the merged corpus has zero cross-realm collisions ;
    // it only bites when a genuine homonym appears. A realm-QUALIFIED dispatch
    // (realm.is_some()) keeps the first-match behaviour — its realm already
    // disambiguated via realm_context_matches.
    let mut hits: Vec<Resolution> = Vec::new();
    let mut hit_realms: Vec<String> = Vec::new();
    for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
        if agg.name != target { continue; }
        if !domain_matches(rt, ai, &domain, &domain_lc) { continue; }
        if !crate::heki::realm_context_matches(agg.realm_path.as_deref(), realm.as_deref(), context.as_deref()) { continue; }
        for (ci, c) in agg.commands.iter().enumerate() {
            if c.name == cmd {
                hits.push(Resolution::Aggregate(ai, ci));
                hit_realms.push(agg.realm_path.clone().unwrap_or_default());
            }
        }
    }
    if hits.len() == 1 {
        // TIGHTEN (i-fqn) : a scoped (cascade) realm-OMITTED short ref whose single
        // hit is a FOREIGN stamped bluebook must use the full FQN. Top-level (no
        // scope), full-FQN (realm given), and unstamped hits keep first-match.
        if caller_scope.is_some() && realm.is_none() {
            let rp = hit_realms[0].as_str();
            if !rp.is_empty() && Some(rp) != caller_scope {
                return Err(RuntimeError::UnknownCommand(format!(
                    "{} — short ref resolves only to a FOREIGN bluebook (caller scope {:?}); a cross-bluebook cascade must use the full Realm::Context::Bluebook::Aggregate FQN",
                    command_name, caller_scope)));
            }
        }
        return Ok(hits.remove(0));
    }
    if hits.len() > 1 {
        // LOCAL-first (i-fqn local-short) : when the caller's bluebook is known
        // and exactly one hit lives in it, the local aggregate wins over foreign
        // homonyms — no ambiguity error, no first-match guess.
        if let Some(scope) = caller_scope {
            let local: Vec<usize> = hit_realms.iter().enumerate()
                .filter(|(_, rp)| rp.as_str() == scope)
                .map(|(i, _)| i)
                .collect();
            if local.len() == 1 {
                return Ok(hits.remove(local[0]));
            }
            // TIGHTEN : a scoped realm-omitted cascade ref with NO unique local
            // hit spans only foreign bluebooks — error rather than first-match.
            if realm.is_none() {
                return Err(RuntimeError::UnknownCommand(format!(
                    "{} — short ref has no unique local match in caller scope {:?} and spans multiple bluebooks; use the full FQN",
                    command_name, caller_scope)));
            }
        }
        if let Some(candidates) = ambiguity_candidates(&hit_realms, realm.is_none(), command_name) {
            return Err(RuntimeError::AmbiguousCommand {
                name: command_name.to_string(),
                candidates,
            });
        }
        return Ok(hits.remove(0));
    }

    // Second pass — entity-owned command. The canonical form uses the
    // entity name in the command (e.g. `Discipline::Macrophage.CheckRegister`
    // for a Register command on the Check entity). But for parity with
    // the legacy `Aggregate.Entity.Command` form, we also accept lookups
    // where `target` is an aggregate name and the command lives on one
    // of its entities — useful for one-shot dispatches without renaming
    // the entity command.
    for (ai, agg) in rt.domain.aggregates.iter().enumerate() {
        if agg.name != target { continue; }
        if !domain_matches(rt, ai, &domain, &domain_lc) { continue; }
        if !crate::heki::realm_context_matches(agg.realm_path.as_deref(), realm.as_deref(), context.as_deref()) { continue; }
        for (ei, ent) in agg.entities.iter().enumerate() {
            for (ci, c) in ent.commands.iter().enumerate() {
                if c.name == cmd {
                    return Ok(Resolution::Entity(ai, ei, ci));
                }
            }
        }
    }

    Err(RuntimeError::UnknownCommand(format!(
        "{} — no command at this address. Checked domain '{}' for aggregate '{}' and command '{}'.",
        command_name, domain, target, cmd
    )))
}

/// Does the FQN's first segment match the aggregate's bluebook
/// context or category? Case-insensitive match — `Discipline` and
/// `discipline` both resolve to `category "discipline"`.
fn domain_matches(rt: &Runtime, agg_idx: usize, domain: &str, domain_lc: &str) -> bool {
    let agg = &rt.domain.aggregates[agg_idx];
    if agg.context.as_deref() == Some(domain) { return true; }
    if let Some(ref ctx) = agg.context {
        if ctx.to_lowercase() == *domain_lc { return true; }
    }
    // i560 v2 — match against the aggregate's stamped category so
    // `Discipline::Macrophage.Run` resolves through the merged corpus.
    if let Some(ref cat) = agg.category {
        if cat == domain || cat.to_lowercase() == *domain_lc { return true; }
    }
    // Single-domain fallback : when the runtime was booted from a
    // single .bluebook the per-Domain category is still set.
    if let Some(ref cat) = rt.domain.category {
        if cat.to_lowercase() == *domain_lc { return true; }
    }
    false
}
/// Resolution-aware self-ref finder (i111-J). For an entity command,
/// the self-ref still points at the parent aggregate's record because
/// the entity is reached through the root. The reference's actual
/// name (which may be aliased via `role: :incident_id`) is what the
/// runner / DSL passes the kwarg under ; the runtime must look up
/// under the same key.
fn find_self_ref_res(rt: &Runtime, res: Resolution) -> Option<String> {
    let agg_idx = res.agg_idx();
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = cmd_for(rt, res);
    let agg_snake = to_snake_case(&agg.name);
    for r in &cmd.references {
        let ref_snake = to_snake_case(&r.target);
        if ref_snake == agg_snake || agg_snake.ends_with(&ref_snake) {
            return Some(r.name.clone());
        }
    }
    None
}

/// Verify the command is allowed given the current lifecycle state.
/// Routes through Resolution so entity commands consult the entity's
/// lifecycle when present (falls back to the parent aggregate's
/// lifecycle otherwise).
fn check_lifecycle(
    rt: &Runtime, res: Resolution, state: &AggregateState,
) -> Result<(), RuntimeError> {
    let lifecycle = match lifecycle_for(rt, res) {
        Some(lc) => lc,
        None => return Ok(()),
    };
    let cmd = cmd_for(rt, res);
    let matching: Vec<_> = lifecycle.transitions.iter()
        .filter(|t| t.command == cmd.name).collect();
    if matching.is_empty() { return Ok(()); }

    let current = format!("{}", state.get(&lifecycle.field));
    let allowed = matching.iter().any(|t| match &t.from_state {
        Some(from) => current == *from,
        None => true,
    });
    if allowed { Ok(()) } else {
        Err(RuntimeError::LifecycleViolation {
            command: cmd.name.clone(),
            field: lifecycle.field.clone(),
            current,
            allowed: matching.iter().filter_map(|t| t.from_state.clone()).collect(),
        })
    }
}

/// Apply the lifecycle transition if one matches the resolved command.
/// Resolution-aware (i111-J) — entity commands consult the entity's
/// lifecycle when present, otherwise the parent aggregate's.
fn apply_lifecycle_transition(rt: &Runtime, res: Resolution, state: &mut AggregateState) {
    let lifecycle = match lifecycle_for(rt, res) {
        Some(lc) => lc,
        None => return,
    };
    let cmd = cmd_for(rt, res);
    let current = format!("{}", state.get(&lifecycle.field));
    for t in &lifecycle.transitions {
        if t.command != cmd.name { continue; }
        let from_ok = match &t.from_state {
            Some(from) => current == *from,
            None => true,
        };
        if from_ok {
            state.set(&lifecycle.field, Value::Str(t.to_state.clone()));
            return;
        }
    }
}

pub(crate) fn apply_lifecycle_default(rt: &Runtime, agg_idx: usize, state: &mut AggregateState) {
    let agg = &rt.domain.aggregates[agg_idx];
    if let Some(ref lc) = agg.lifecycle {
        if matches!(state.get(&lc.field), Value::Null) {
            state.set(&lc.field, Value::Str(lc.default.clone()));
        }
    }
}

fn apply_defaults(rt: &Runtime, agg_idx: usize, state: &mut AggregateState) {
    let agg = &rt.domain.aggregates[agg_idx];
    let vo_names: Vec<&str> = agg.value_objects.iter().map(|vo| vo.name.as_str()).collect();
    for attr in &agg.attributes {
        if let Some(ref default) = attr.default {
            state.set(&attr.name, parse_default(default, &attr.attr_type));
        } else if attr.list || vo_names.contains(&attr.attr_type.as_str()) {
            state.set(&attr.name, Value::List(vec![]));
        }
    }
}

/// Resolution-aware event builder (i111-J). Entity commands emit
/// events tagged with the parent aggregate's name — that's the
/// addressable record from outside the bounded context — but use
/// the entity command's `emits:` declaration when present.
fn build_event_res(
    rt: &Runtime, res: Resolution,
    aggregate_id: &str, attrs: &HashMap<String, Value>,
) -> Option<Event> {
    let agg_idx = res.agg_idx();
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = cmd_for(rt, res);
    let event_name = cmd.emits.clone().unwrap_or_else(|| default_event_name(&cmd.name));
    Some(Event {
        name: event_name,
        aggregate_type: agg.name.clone(),
        aggregate_id: aggregate_id.to_string(),
        data: attrs.clone(),
        realm_path: agg.realm_path.clone(),
    })
}

fn default_event_name(cmd_name: &str) -> String {
    if let Some(rest) = cmd_name.strip_prefix("Create") {
        format!("{}Created", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Add") {
        format!("{}Added", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Place") {
        format!("{}Placed", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Cancel") {
        format!("{}Cancelled", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Update") {
        format!("{}Updated", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Remove") {
        format!("{}Removed", rest)
    } else if let Some(rest) = cmd_name.strip_prefix("Delete") {
        format!("{}Deleted", rest)
    } else {
        format!("{}Completed", cmd_name)
    }
}

fn parse_default(default: &str, attr_type: &str) -> Value {
    match attr_type {
        "Integer" => Value::Int(default.parse().unwrap_or(0)),
        "Boolean" => Value::Bool(default == "true"),
        _ => Value::Str(default.trim_matches('"').to_string()),
    }
}

fn to_snake_case(s: &str) -> String {
    crate::parser_helpers::to_snake_case(s)
}

// ============================================================
// Error-message helpers — turn bare error variants into
// caller-actionable diagnostics. Wraps useful corpus context
// (available commands, aggregate names, expected self-ref attr
// names) into the String payload so the existing variant shape
// stays untouched but the caller sees what to fix.
// ============================================================

/// List every aggregate visible in the loaded domains, in
/// `Context.Aggregate` form when a context is set so the caller
/// can disambiguate same-name aggregates across bluebooks.
fn available_aggregate_names(rt: &Runtime) -> Vec<String> {
    let mut names: Vec<String> = rt.domain.aggregates.iter()
        .map(|a| match &a.context {
            Some(ctx) => format!("{}.{}", ctx, a.name),
            None => a.name.clone(),
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

/// List every command declared on a specific aggregate (by name),
/// across every bluebook the aggregate appears in. Returned in
/// `Aggregate.Command` form. Includes entity-owned commands as
/// `Aggregate.Entity.Command` so the caller can see the i111-J
/// addressable surface too.
fn commands_on_aggregate(rt: &Runtime, agg_name: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for agg in rt.domain.aggregates.iter().filter(|a| a.name == agg_name) {
        for cmd in &agg.commands {
            out.push(format!("{}.{}", agg.name, cmd.name));
        }
        for ent in &agg.entities {
            for cmd in &ent.commands {
                out.push(format!("{}.{}.{}", agg.name, ent.name, cmd.name));
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

/// List every command in every aggregate/entity in the corpus, in
/// fully-qualified form. Used as the fallback hint for bare-name
/// dispatch misses where we have no aggregate context to narrow
/// the listing by.
fn all_commands_qualified(rt: &Runtime) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for agg in &rt.domain.aggregates {
        let agg_prefix = match &agg.context {
            Some(ctx) => format!("{}.{}", ctx, agg.name),
            None => agg.name.clone(),
        };
        for cmd in &agg.commands {
            out.push(format!("{}.{}", agg_prefix, cmd.name));
        }
        for ent in &agg.entities {
            for cmd in &ent.commands {
                out.push(format!("{}.{}.{}", agg_prefix, ent.name, cmd.name));
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

/// Truncate a candidates list for the error string. Long
/// listings (1000+ commands across the corpus) would drown the
/// error ; the cap keeps the message useful without hiding
/// information silently — the truncated count is included.
fn join_truncated(items: &[String], cap: usize) -> String {
    if items.len() <= cap {
        items.join(", ")
    } else {
        format!("{}, … ({} more)", items[..cap].join(", "), items.len() - cap)
    }
}

fn unknown_aggregate_message(rt: &Runtime, agg_name: &str) -> String {
    let avail = available_aggregate_names(rt);
    if avail.is_empty() {
        format!("{} — no aggregates loaded in this runtime", agg_name)
    } else {
        format!(
            "{} — no aggregate by that name in the loaded domains. Available: {}",
            agg_name,
            join_truncated(&avail, 40),
        )
    }
}

fn unknown_command_message_3part(
    rt: &Runtime, full: &str, a: &str, b: &str, c: &str,
) -> String {
    // 3-part form means either Context.Aggregate.Command or
    // Aggregate.Entity.Command. The caller almost certainly
    // intended one of those — list commands on each candidate
    // aggregate so they can self-correct.
    let mut hints: Vec<String> = Vec::new();
    // Context.Aggregate.Command : aggregates named `b` in context `a`.
    for agg in rt.domain.aggregates.iter()
        .filter(|agg| agg.name == b && agg.context.as_deref() == Some(a))
    {
        for cmd in &agg.commands {
            hints.push(format!("{}.{}.{}", a, b, cmd.name));
        }
    }
    // Aggregate.Entity.Command : aggregates named `a` with entity `b`.
    for agg in rt.domain.aggregates.iter().filter(|agg| agg.name == a) {
        for ent in agg.entities.iter().filter(|e| e.name == b) {
            for cmd in &ent.commands {
                hints.push(format!("{}.{}.{}", a, b, cmd.name));
            }
        }
    }
    hints.sort();
    hints.dedup();
    if hints.is_empty() {
        // No aggregate context matched at all — fall back to a
        // corpus-wide listing so they see what IS available.
        let all = all_commands_qualified(rt);
        format!(
            "{} — no command at that address. Looked for Context.Aggregate.Command ('{}.{}') and Aggregate.Entity.Command ('{}.{}'); neither matched. Available commands: {}",
            full, a, b, a, b,
            join_truncated(&all, 30),
        )
    } else {
        format!(
            "{} — '{}' not declared at that address. Did you mean: {}",
            full, c, join_truncated(&hints, 20),
        )
    }
}

fn unknown_command_message_2part(
    rt: &Runtime, full: &str, agg_name: &str, cmd_name: &str,
) -> String {
    let on_agg = commands_on_aggregate(rt, agg_name);
    if on_agg.is_empty() {
        // The aggregate part itself doesn't exist.
        let aggs = available_aggregate_names(rt);
        format!(
            "{} — no aggregate '{}' in the loaded domains. Available aggregates: {}",
            full, agg_name, join_truncated(&aggs, 40),
        )
    } else {
        format!(
            "{} — command '{}' not declared on '{}'. Available on this aggregate: {}",
            full, cmd_name, agg_name, join_truncated(&on_agg, 30),
        )
    }
}

fn unknown_command_message_bare(rt: &Runtime, cmd_name: &str) -> String {
    let all = all_commands_qualified(rt);
    if all.is_empty() {
        format!("{} — no commands declared in the loaded domains", cmd_name)
    } else {
        format!(
            "{} — no command by that name in the loaded domains. Available: {}",
            cmd_name, join_truncated(&all, 30),
        )
    }
}


// ============================================================
// Many-form bulk dispatch — i113 / i116
// ============================================================
//
// A command qualifies as bulk when it takes exactly one attribute,
// that attribute is a `list_of(VO)` whose VO is declared on the same
// aggregate, the aggregate has `identified_by :field`, and the VO
// carries that identity field. The dispatcher then iterates the list,
// builds per-row attrs from the VO's fields, and runs each row through
// the standard save path so upsert + audit semantics carry through.

/// Return the bulk-spec attribute name when the command meets the bulk
/// shape contract ; otherwise None. Pure shape inspection — no naming
/// convention, no command-prefix rules.
fn bulk_spec_attr(rt: &Runtime, agg_idx: usize, cmd_idx: usize) -> Option<String> {
    let agg = &rt.domain.aggregates[agg_idx];
    let cmd = &agg.commands[cmd_idx];
    let id_field = agg.identified_by.as_deref()?;

    if cmd.attributes.len() != 1 {
        return None;
    }
    let attr = &cmd.attributes[0];
    if !attr.list {
        return None;
    }
    let vo = agg.value_objects.iter().find(|v| v.name == attr.attr_type)?;
    let vo_has_id = vo.attributes.iter().any(|a| a.name == id_field);
    if !vo_has_id {
        return None;
    }
    Some(attr.name.clone())
}

/// Iterate the spec list, dispatch one save per row through the
/// standard pipeline, emit one event per row. The event is published
/// so policies and projections see each row exactly as if it had been
/// dispatched single-form. The returned CommandResult points at the
/// LAST row's aggregate id — callers that need every id should listen
/// on the event bus instead.
fn dispatch_bulk(
    rt: &mut Runtime,
    agg_idx: usize,
    cmd_idx: usize,
    command_name: &str,
    spec_attr: &str,
    attrs: HashMap<String, Value>,
) -> Result<CommandResult, RuntimeError> {
    let specs = match attrs.get(spec_attr) {
        Some(Value::List(items)) => items.clone(),
        Some(Value::Str(s)) => parse_specs_from_str(s)?,
        Some(other) => {
            return Err(RuntimeError::MissingAttribute(format!(
                "{}: expected list_of(VO), got {:?}",
                spec_attr, other
            )));
        }
        None => {
            return Err(RuntimeError::MissingAttribute(spec_attr.to_string()));
        }
    };

    let aggregate_name = rt.domain.aggregates[agg_idx].name.clone();
    let event_name = rt.domain.aggregates[agg_idx].commands[cmd_idx]
        .emits
        .clone()
        .unwrap_or_else(|| format!("{}Completed", command_name));

    let vo_field_names: Vec<String> = {
        let cmd_attr = &rt.domain.aggregates[agg_idx].commands[cmd_idx].attributes[0];
        let vo = rt.domain.aggregates[agg_idx]
            .value_objects
            .iter()
            .find(|v| v.name == cmd_attr.attr_type)
            .expect("bulk_spec_attr already verified VO exists");
        vo.attributes.iter().map(|a| a.name.clone()).collect()
    };

    let mut last_id = String::new();
    let mut last_event: Option<Event> = None;
    for spec in &specs {
        let row_attrs = spec_to_attrs(spec, &vo_field_names);
        let row_id = save_one_row(rt, agg_idx, &aggregate_name, command_name, &row_attrs)?;
        let event = Event {
            name: event_name.clone(),
            aggregate_type: aggregate_name.clone(),
            aggregate_id: row_id.clone(),
            data: row_attrs,
            realm_path: rt.domain.aggregates[agg_idx].realm_path.clone(),
        };
        // Sprint 14 (retire-sync-cascade-pipeline) — many-form
        // (`list_of(VO)`) inputs publish one event per row through the
        // bus, just like the single-event site in phase_11_emit. The
        // legacy delivery-mode fork retired with the sync-cascade
        // pipeline ; every event flows through `event_bus.publish`.
        rt.event_bus.publish(event.clone());
        last_id = row_id;
        last_event = Some(event);
    }

    Ok(CommandResult {
        aggregate_id: last_id,
        aggregate_type: aggregate_name,
        event: last_event,
        // Bulk many-form (`list_of(VO)`) event-sourcing is deferred (v1) —
        // per-row deltas would need a diff per saved row inside the loop.
        deltas: Vec::new(),
    })
}

/// Coerce a Value (Map or Str-encoded JSON object) into a per-row
/// attrs hash. Map fields are picked up directly ; a Str body is
/// parsed as JSON when the VO field set is known.
fn spec_to_attrs(spec: &Value, vo_fields: &[String]) -> HashMap<String, Value> {
    match spec {
        Value::Map(m) => m.clone(),
        Value::Str(s) => {
            // Best-effort JSON object parse for CLI-passed specs.
            if let Ok(serde_json::Value::Object(map)) = serde_json::from_str::<serde_json::Value>(s) {
                let mut out = HashMap::new();
                for f in vo_fields {
                    if let Some(v) = map.get(f) {
                        out.insert(f.clone(), json_to_value(v));
                    }
                }
                out
            } else {
                HashMap::new()
            }
        }
        _ => HashMap::new(),
    }
}

fn json_to_value(v: &serde_json::Value) -> Value {
    match v {
        serde_json::Value::String(s) => Value::Str(s.clone()),
        serde_json::Value::Bool(b) => Value::Bool(*b),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Value::Int(i)
            } else {
                Value::Str(n.to_string())
            }
        }
        serde_json::Value::Null => Value::Null,
        _ => Value::Str(v.to_string()),
    }
}

/// Parse a string-encoded specs list — the CLI path. Accepts a JSON
/// array of objects ; each object becomes a Value::Map. Anything else
/// surfaces as an error so the caller sees the shape mismatch instead
/// of silently saving zero rows.
fn parse_specs_from_str(s: &str) -> Result<Vec<Value>, RuntimeError> {
    let parsed: serde_json::Value = serde_json::from_str(s)
        .map_err(|e| RuntimeError::MissingAttribute(format!("specs: invalid JSON ({})", e)))?;
    let arr = parsed.as_array().ok_or_else(|| {
        RuntimeError::MissingAttribute("specs: expected JSON array".into())
    })?;
    let mut out = Vec::with_capacity(arr.len());
    for raw in arr {
        if let serde_json::Value::Object(obj) = raw {
            let mut m = HashMap::new();
            for (k, v) in obj {
                m.insert(k.clone(), json_to_value(v));
            }
            out.push(Value::Map(m));
        } else {
            out.push(json_to_value(raw));
        }
    }
    Ok(out)
}

/// Save one row through the standard pipeline — apply defaults, copy
/// matching command attrs onto the aggregate, persist, return the
/// row's id. Mirrors the create path of `dispatch` but skipped the
/// givens / lifecycle plumbing : bulk register has no per-row gates,
/// the command itself is the gate.
fn save_one_row(
    rt: &mut Runtime,
    agg_idx: usize,
    aggregate_name: &str,
    command_name: &str,
    row_attrs: &HashMap<String, Value>,
) -> Result<String, RuntimeError> {
    let repo_hash_key = super::repo_key(
        rt.domain.aggregates[agg_idx].context.as_deref(),
        aggregate_name,
    );
    // Build the diagnostic up front — borrowing `rt` inside
    // `ok_or_else` collides with the `get_mut` mutable borrow.
    let unknown_agg_msg = if rt.repositories.contains_key(&repo_hash_key) {
        String::new()
    } else {
        unknown_aggregate_message(rt, aggregate_name)
    };
    // i735 defect 2 — see the sibling guard above ; a refused-persistence
    // aggregate errors loudly here too rather than reading as unknown.
    if let Some(reason) = rt.refused_persistence.get(&repo_hash_key) {
        return Err(RuntimeError::PersistenceRefused(reason.clone()));
    }
    let repo = rt
        .repositories
        .get_mut(&repo_hash_key)
        .ok_or(RuntimeError::UnknownAggregate(unknown_agg_msg))?;
    let id = repo.id_for_command(row_attrs);
    let (mut state, is_new) = match repo.find(&id).cloned() {
        Some(s) => (s, false),
        None => (AggregateState::new(&id), true),
    };
    if is_new {
        apply_defaults(rt, agg_idx, &mut state);
        apply_lifecycle_default(rt, agg_idx, &mut state);
    }

    // Copy every VO field onto the aggregate (path, reason, …) — same
    // semantics as the single-row create path's matching-attrs copy.
    let agg_attr_names: Vec<String> = rt.domain.aggregates[agg_idx]
        .attributes
        .iter()
        .map(|a| a.name.clone())
        .collect();
    for name in &agg_attr_names {
        if let Some(val) = row_attrs.get(name) {
            state.set(name, val.clone());
        }
    }

    let ctx = crate::heki::WriteContext::Dispatch {
        aggregate: aggregate_name,
        command: command_name,
    };
    let repo = rt.repositories.get_mut(&repo_hash_key).unwrap();
    let row_id = state.id.clone();
    repo.save(state, ctx);
    Ok(row_id)
}

#[cfg(test)]
mod fqn_tests {
    use super::parse_fqn;

// parse_fqn reads a realm-qualified, VARIABLE-DEPTH address by its ENDS :
// last :: segment = Aggregate, second-to-last = Domain, everything before
// (Realm + 0+ subrealms) is the accepted-but-unenforced namespace prefix.
// Returns (domain, aggregate, verb).

#[test]
fn legacy_two_segment_is_the_zero_prefix_case() {
    assert_eq!(
        parse_fqn("AgentInbox::AgentMessage.AllUnread").unwrap(),
        ("AgentInbox".to_string(), "AgentMessage".to_string(), "AllUnread".to_string())
    );
}

#[test]
fn realm_qualified_three_segment_resolves_by_ends() {
    assert_eq!(
        parse_fqn("Hecks::AgentInbox::AgentMessage.all_unread").unwrap(),
        ("AgentInbox".to_string(), "AgentMessage".to_string(), "all_unread".to_string())
    );
}

#[test]
fn subrealm_four_segment_still_takes_the_two_ends() {
    assert_eq!(
        parse_fqn("Hecks::Framework::AgentInbox::AgentMessage.all_unread").unwrap(),
        ("AgentInbox".to_string(), "AgentMessage".to_string(), "all_unread".to_string())
    );
}

#[test]
fn deep_n_segment_uncapped() {
    assert_eq!(
        parse_fqn("A::B::C::D::E::Agg.Cmd").unwrap(),
        ("E".to_string(), "Agg".to_string(), "Cmd".to_string())
    );
}

#[test]
fn malformed_addresses_are_rejected() {
    assert!(parse_fqn("NoColons.Cmd").is_err());   // < 2 :: segments
    assert!(parse_fqn("Just::Two").is_err());       // no '.' verb
    assert!(parse_fqn("Dangling::.Cmd").is_err());  // empty trailing segment
    assert!(parse_fqn("::Agg.Cmd").is_err());       // empty leading segment
}

// ---- the FLIP : ambiguity_candidates (the realm-strict guard) ----

#[test]
fn ambiguity_two_distinct_realms_realm_omitted_is_ambiguous() {
    // The flip's core : a realm-OMITTED 2-seg dispatch hitting the same
    // Domain::Aggregate.command across two realms reports BOTH candidates
    // instead of silently first-match-winning.
    let realms = vec!["hecks/framework".to_string(), "miette/body".to_string()];
    let got = super::ambiguity_candidates(&realms, true, "Tools::Widget.Make");
    assert_eq!(got, Some(vec![
        "hecks::framework::Tools::Widget.Make".to_string(),
        "miette::body::Tools::Widget.Make".to_string(),
    ]));
}

#[test]
fn ambiguity_realm_qualified_dispatch_is_never_ambiguous() {
    // When the caller named the realm, realm_context_matches already
    // narrowed — keep first-match-wins.
    let realms = vec!["hecks/framework".to_string(), "miette/body".to_string()];
    assert_eq!(super::ambiguity_candidates(&realms, false, "X::Y.Z"), None);
}

#[test]
fn ambiguity_same_realm_twice_is_not_ambiguous() {
    // Two hits in the SAME realm dedup to one candidate — not ambiguous.
    let realms = vec!["hecks/framework".to_string(), "hecks/framework".to_string()];
    assert_eq!(super::ambiguity_candidates(&realms, true, "X::Y.Z"), None);
}

#[test]
fn ambiguity_unstamped_realms_keep_first_match() {
    // Legacy / string-parsed aggregates carry an empty realm_path —
    // filtered out, so they fall through to first-match-wins.
    let realms = vec![String::new(), String::new()];
    assert_eq!(super::ambiguity_candidates(&realms, true, "X::Y.Z"), None);
}

// ---- caller-scoped local-first (i-fqn local-short) ----

// A "Widget.Make" homonym across two bluebooks (hecks + miette), both with
// context "Framework" so the 2-seg `Framework::Widget.Make` form hits BOTH.
fn two_widget_domain() -> crate::ir::Domain {
    let src = r#"
Hecks.bluebook "Framework" do
aggregate "Widget" do
attribute :id, Id
command "Make" do
  attribute :id, Id
end
end
end
"#;
    let mut d = crate::parser::parse(src);
    for a in d.aggregates.iter_mut() { a.realm_path = Some("hecks/framework".to_string()); }
    let mut other = d.aggregates.iter().find(|a| a.name == "Widget").unwrap().clone();
    other.realm_path = Some("miette/framework".to_string());
    d.aggregates.push(other);
    d
}

#[test]
fn caller_scope_picks_local_dotted_form() {
    let rt = crate::runtime::Runtime::boot(two_widget_domain());
    // Dotted Aggregate.Command : caller in hecks resolves the hecks Widget …
    let r = super::resolve(&rt, "Widget.Make", Some("hecks/framework")).unwrap();
    assert_eq!(rt.domain.aggregates[r.agg_idx()].realm_path.as_deref(), Some("hecks/framework"));
    // … the SAME short ref from miette resolves the miette Widget.
    let r = super::resolve(&rt, "Widget.Make", Some("miette/framework")).unwrap();
    assert_eq!(rt.domain.aggregates[r.agg_idx()].realm_path.as_deref(), Some("miette/framework"));
}

#[test]
fn caller_scope_picks_local_two_seg_form() {
    let rt = crate::runtime::Runtime::boot(two_widget_domain());
    // 2-seg Bluebook::Aggregate.Command hits both ; caller scope disambiguates
    // instead of erroring AmbiguousCommand or first-match-guessing.
    let r = super::resolve(&rt, "Framework::Widget.Make", Some("miette/framework")).unwrap();
    assert_eq!(rt.domain.aggregates[r.agg_idx()].realm_path.as_deref(), Some("miette/framework"));
}

#[test]
fn no_caller_scope_falls_back_to_first_match() {
    let rt = crate::runtime::Runtime::boot(two_widget_domain());
    // ADDITIVE : no caller scope → today's global first-match (hecks declared first).
    let r = super::resolve(&rt, "Widget.Make", None).unwrap();
    assert_eq!(rt.domain.aggregates[r.agg_idx()].realm_path.as_deref(), Some("hecks/framework"));
}

#[test]
fn cascade_short_ref_matching_only_foreign_errors() {
    let rt = crate::runtime::Runtime::boot(two_widget_domain());
    // TIGHTEN : a CASCADE (scoped) short ref whose only matches live in OTHER
    // bluebooks (both Widgets are stamped, neither in this scope) is an error —
    // a cross-bluebook cascade must use the full FQN, not a first-matched short.
    let r = super::resolve(&rt, "Widget.Make", Some("hecks/elsewhere"));
    assert!(r.is_err(), "expected foreign-only cascade short ref to error, got {:?}", r);
}

#[test]
fn cascade_two_seg_foreign_only_errors_but_local_resolves() {
    let rt = crate::runtime::Runtime::boot(two_widget_domain());
    // 2-seg short ref from a scope where NO Widget lives → spans only foreign
    // bluebooks → tighten errors.
    let r = super::resolve(&rt, "Framework::Widget.Make", Some("hecks/elsewhere"));
    assert!(r.is_err(), "expected foreign-only 2-seg cascade ref to error, got {:?}", r);
    // … but the SAME ref from a local scope still resolves (local-first intact).
    let r2 = super::resolve(&rt, "Framework::Widget.Make", Some("miette/framework")).unwrap();
    assert_eq!(rt.domain.aggregates[r2.agg_idx()].realm_path.as_deref(), Some("miette/framework"));
}

// A single Widget stamped in ONE bluebook (no homonym).
fn one_widget_domain() -> crate::ir::Domain {
    let src = r#"
Hecks.bluebook "Framework" do
aggregate "Widget" do
attribute :id, Id
command "Make" do
  attribute :id, Id
end
end
end
"#;
    let mut d = crate::parser::parse(src);
    for a in d.aggregates.iter_mut() { a.realm_path = Some("miette/body/organs".to_string()); }
    d
}

#[test]
fn cascade_unique_foreign_short_ref_resolves() {
    // REGRESSION (pulse-pm cross-bluebook fix) : a CASCADE (scoped) short ref
    // whose only match is a UNIQUE foreign stamped aggregate must RESOLVE, not
    // error — the cross-bluebook PM `dispatch` path (Synapse.CreateSynapse from
    // the Pulse PM, event source in body/cycles, target in body/organs). Only a
    // genuine homonym across 2+ bluebooks errors.
    let rt = crate::runtime::Runtime::boot(one_widget_domain());
    let r = super::resolve(&rt, "Widget.Make", Some("miette/body/cycles")).unwrap();
    assert_eq!(rt.domain.aggregates[r.agg_idx()].realm_path.as_deref(), Some("miette/body/organs"));
}

// ── realm_over_qualified_tail : the realm-tolerant fallback's core (2026-06-30) ──
// Reduces a realm-OVER-qualified dispatch target to its canonical
// Domain::Aggregate.Command tail. The live regression : a hecksagon
// `result_into` of `Hecks::Framework::Cascade::Cascade.RecordResult` derived a
// realm/context no aggregate's realm_path matched, so the strict FQN resolve
// rejected it and EVERY tool's outcome-chain cascade silently failed. The
// fallback retries the tail, which resolves.

#[test]
fn over_qualified_fqn_reduces_to_domain_aggregate_command_tail() {
    assert_eq!(
        super::realm_over_qualified_tail("Hecks::Framework::Cascade::Cascade.RecordResult"),
        Some("Cascade::Cascade.RecordResult".to_string())
    );
    // A deeper realm still reduces to the LAST two namespace segments.
    assert_eq!(
        super::realm_over_qualified_tail("A::B::C::D::Widget.Make"),
        Some("D::Widget.Make".to_string())
    );
}

#[test]
fn already_minimal_fqn_is_not_reduced() {
    // Exactly two segments (Domain::Aggregate) — nothing to strip.
    assert_eq!(super::realm_over_qualified_tail("Cascade::Cascade.RecordResult"), None);
    // One segment before the command — also minimal.
    assert_eq!(super::realm_over_qualified_tail("Widget.Make"), None);
    // No command at all — no tail to build.
    assert_eq!(super::realm_over_qualified_tail("A::B::C::Widget"), None);
}

}
