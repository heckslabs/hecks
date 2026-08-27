// HAND-WRITTEN, ONCE, GENERIC — a direct port of `Dispatcher#dispatch`'s
// own reaction plumbing (lib/hecks/runtime/dispatcher.rb, read
// directly): every command dispatch runs its OWN pipeline, then hands
// each event it announced to policy matching AND process-manager
// advancement, re-entering dispatch for whatever either fires —
// recursively, inside the SAME call, bounded by a reaction-depth ceiling
// rather than a queue or a separate tick. `PolicyInterpreter#react`+
// `SagaInterpreter#advance` are the Ruby originals this ports; both run
// off the SAME announced-event list, in the same order Ruby runs them in
// (`announced.each { @policies.react }`, THEN `announced.each { @sagas.
// advance }`), which is why they're one function here too, not two.
//
// THE REACTION/SAGA LOG (`registry.reaction_log`/`saga_log`) IS PRODUCED
// NOW, not just the side effects — `PolicyInterpreter#deliver`'s and
// `SagaInterpreter`'s own record-building, ported record shape for record
// shape (`begin_saga`/`advance_saga`/`deliver_saga_dispatch`/`unwind`/
// `end_saga`, split into the SAME five functions below rather than one
// merged pass, because Ruby's own `advance` calls all three of `begin_
// saga`/`advance_saga`/`end_saga` UNCONDITIONALLY per (pm, event) pair —
// each independently gated on its own structural check (`event.name ==
// pm.starts_on`, `pm.handler_for(event.name)`, `event.name == pm.ends_on`)
// — and a single merged gate (this file's OWN prior shape) silently
// produces fewer log entries than Ruby whenever those three checks
// would have disagreed about whether to fire at all.
//
// ONE DELIBERATE, DOCUMENTED, PERMANENT GAP: Ruby's `rescue StandardError`
// branch (`delivered: false, defect: true, error_class: ...`) has no
// Rust equivalent and is NOT ported. That branch exists because Ruby's
// dynamically-typed interpreter can raise a NoMethodError/TypeError/etc.
// from WITHIN a reaction dispatch — a genuine runtime crash a static,
// compiled `dispatch_fn` (`Result<Vec<Event>, Refusal>`, never an
// exception) cannot produce the equivalent of. A bug in generated Rust
// dispatch code is a Rust bug (a compile error, or — if it ever slipped
// through — a panic), and a panic here should propagate and abort, not
// be caught and logged as if it were routine: that is exactly the
// swallow-a-crash-into-normal-operation failure mode Ruby's own comment
// on this branch (`policy_interpreter.rb`) warns against, just prevented
// one layer earlier, by the type system, instead of guarded against at
// runtime. `spec/rust_conformance_spec.rb`'s own comparison excludes
// Ruby's `defect: true` reaction_log entries for exactly this reason —
// see that file's own header.
//
// CROSS-DOMAIN POLICIES (`across "OtherDomain"`) are matched here the
// SAME way a same-domain policy is (event_name/event_qualifier), but
// never dispatched here — this module is the WASM-sandboxed kernel
// (docs/implemented/decisions/0012), no network, no way to reach another domain's
// own deployed Lambda. `react_policies` below pushes a
// `PendingCrossDomainReaction` instead of recursing into `orchestrate`,
// and `kernel::cli::run` carries that list out through this call's own
// JSON output for rust/host (the UNSANDBOXED layer, real AWS SDK access)
// to actually deliver — `rust/host/src/lambda_client.rs` is that
// delivery, a direct port of `Adapters::Lambda::Client`'s own
// function-name computation and invoke shape. See that file's own header
// for the full mirror. NEITHER SIDE OF THAT SPLIT PRODUCES A `reaction_
// log` ENTRY for a cross-domain match today — this kernel genuinely
// cannot know the delivery outcome (that only exists once rust/host
// finishes the call), and rust/host doesn't build one either yet. A
// real, separate, documented gap — docs/HECKS_IMPLEMENTATION_PLAN.md's
// §8 has the fuller account of exactly what is and isn't proven about
// the live-delivery half.

use super::expr::{interpret, EvalContext, Expr, NoFields};
use super::named_query;
use super::repository::AggregateScan;
use super::{Event, Json, MutationRecord, Refusal};
use std::collections::HashMap;

pub const MAX_REACTION_DEPTH: usize = 5;

/// One `policy "Name" do on ... trigger ... end` block — see this file's
/// header and `rust/project/reactions.rb`'s `emit_policy_table` for how
/// `event_qualifier`/`event_name` get split from `on_event` and why
/// cross-domain policies are absent from this table entirely rather than
/// represented and refused at runtime.
pub struct PolicyRule {
    /// `PolicyInterpreter#deliver`'s own `policy.name` — the reaction_log
    /// entry's `policy:` field. Absent before this file's own log-parity
    /// work (its old doc comment: "nothing downstream of a same-domain
    /// reaction ever needed to name the policy that caused it") — needed
    /// now, the same way `CrossDomainPolicyRule` already carries it.
    pub policy_name: &'static str,
    pub event_name: &'static str,
    pub event_qualifier: Option<&'static str>,
    pub target_verb: &'static str,
    /// `where { … }` — `PolicyInterpreter#where_holds?`: the policy's own
    /// predicate over the event payload, the reaction simply not happening
    /// (no log entry, exactly Ruby's `return nil`) when it does not hold.
    /// A function, not an `Expr` — an `Expr` owns boxes and cannot sit in
    /// this `const` table; the generated fn builds it on demand.
    pub where_expr: Option<fn() -> Expr>,
    /// `PolicyInterpreter#deliver_for_each` — the query verb a fan-out
    /// runs, ALREADY domain-qualified by the generator (Ruby's own
    /// `Behaviour::Policy#for_each_route` resolves the bare
    /// "Aggregate.query" spelling against the policy's own domain, and
    /// the answer is a fact about the source, so it is settled at
    /// codegen rather than re-derived here).
    pub for_each: Option<&'static str>,
    /// THE NAME EACH MATCHED ROW'S ID IS MINTED UNDER — resolved at
    /// codegen by asking Ruby's own `Behaviour::Command#addressing_key_
    /// for`, never re-derived here. Two different answers are correct
    /// (`account` for a command self-referencing its own aggregate,
    /// `account_id` for one merely holding a reference to it) and the
    /// rule that tells them apart belongs to the target command, not to
    /// the aggregate name — reimplementing that judgement in a second
    /// language is how the two runtimes would drift.
    pub for_each_key: Option<&'static str>,
    /// `trigger ..., with:` — WHAT THE TRIGGER IS GIVEN. Empty forwards
    /// the event's whole payload verbatim. Each pair is
    /// `(argument_name, binding)`, and a binding beginning ":" names a
    /// field on the source the way `Literal::render` spells a Symbol —
    /// the same wire spelling `DispatchSpec::with_spec` already uses.
    pub with_spec: &'static [(&'static str, &'static str)],
}

/// A `policy "Name" do on ... trigger ... across "OtherDomain" end` block —
/// `PolicyRule`'s own cross-domain twin, docs/decisions/0013's own
/// Consequences section named this gap by name: this single-domain
/// `Store` never compiled `OtherDomain`'s aggregates in, so there is no
/// `dispatch_fn` this WASM module could route into even if it wanted to.
/// PREVIOUSLY this row was simply never emitted (`reactions.rb`'s
/// `emit_policy_table` filtered it out entirely) — represented now
/// instead, the same "loud, not silent" instinct `emit_policy_table`'s own
/// header already applies to the domain-mismatch case. `policy_name` rides
/// along purely for the delivery record a HOST layer produces once this
/// fires (below) — `PolicyRule` has no equivalent field because nothing
/// downstream of a same-domain reaction ever needed to name the policy
/// that caused it; a cross-Lambda invoke that might fail is exactly the
/// case where naming it back to an operator matters.
pub struct CrossDomainPolicyRule {
    pub policy_name: &'static str,
    pub event_name: &'static str,
    pub event_qualifier: Option<&'static str>,
    /// See `PolicyRule::where_expr`.
    pub where_expr: Option<fn() -> Expr>,
    pub target_domain: &'static str,
    pub target_verb: &'static str,
}

/// ONE MATCHED-BUT-UNROUTABLE cross-domain reaction — this WASM module's
/// own honest confession that a policy fired and it could not deliver it,
/// carrying everything an UNSANDBOXED host layer (network access this
/// module structurally lacks — see this file's header and rust/host's own
/// `lambda_client.rs`) needs to finish the job: which Lambda to invoke
/// (`target_domain`), what to invoke it with (`target_verb`), and the
/// SAME whole-payload-verbatim forwarding `react_policies`'s local branch
/// already does for a same-domain policy (this file's own comment on
/// "not reshaped, not filtered" — identical rule, just deferred to a
/// caller instead of applied here).
#[derive(Clone)]
pub struct PendingCrossDomainReaction {
    pub policy_name: String,
    pub target_domain: String,
    pub target_verb: String,
    pub payload: Json,
}

/// A `with:` binding's value — `dispatch "Cmd", with: { key: :symbol_ref,
/// other: { literal: "value" } }`'s two real shapes (`IR.render_value`,
/// read directly: a Symbol or anything else). `Literal` is a function
/// pointer rather than embedded `Json` data because `Json` holds `Vec`/
/// `String` internally and so isn't `const`-constructible in stable Rust —
/// one small generated function per literal (`rust/project/reactions.rb`)
/// builds it fresh each resolution instead.
pub enum WithValue {
    Ref(&'static str),
    Literal(fn() -> Json),
}

pub struct DispatchSpec {
    pub command_name: &'static str,
    pub with: &'static [(&'static str, WithValue)],
}

pub struct Handler {
    pub event_type: &'static str,
    pub from_state: &'static str,
    pub to_state: &'static str,
    pub dispatches: &'static [DispatchSpec],
}

/// One `process_manager "Name" do ... end` block. `initial_state` is
/// `states.first` (Ruby's `begin_saga`: `state: pm.states.first`) —
/// nothing else here needs the FULL declared state list, only the one
/// value a freshly-born instance starts at, so that's all this keeps.
pub struct ProcessManagerDef {
    pub name: &'static str,
    pub correlates_by: &'static str,
    pub starts_on: &'static str,
    pub ends_on: &'static str,
    pub initial_state: &'static str,
    pub handlers: &'static [Handler],
}

/// `IR::ProcessManager::REFUSED`, read directly — the literal event_type a
/// compensating leg (`on :refused do ... end`) is declared under.
pub const REFUSED: &str = "refused";

/// One live process-manager instance — `SagaInterpreter`'s own
/// `{state:, memory:}` shape, keyed `(process_manager_name, correlation)`
/// by whoever owns the map (`kernel/cli.rs` — deliberately NOT a `Store`
/// field: process managers are domain-level, not per-aggregate, and
/// nothing about `Store`'s own generated shape needs to know they exist).
#[derive(Clone)]
pub struct SagaInstance {
    pub state: String,
    pub memory: Json,
}

/// `pm.correlates_by.split(".").first` — `IR::ProcessManager#correlation_
/// head`, read directly (`@correlates_by.to_s.split(".").first.to_sym`).
/// A pure syntactic derivation, computed here rather than carried as a
/// SEPARATE generated field on `ProcessManagerDef` — `resolve_with`
/// below already derived it inline the same way before this existed;
/// factored out once a second call site (`correlation_of`'s new middle
/// tier) needed the identical derivation.
fn correlation_head(correlates_by: &str) -> &str {
    correlates_by.split('.').next().unwrap_or(correlates_by)
}

/// `Correlation#saga_correlation`, all three tiers now — see this file's
/// header. Every tier's result is treated as absent when empty, matching
/// every one of Ruby's own three callers (`begin_saga`/`advance_saga`/
/// `end_saga`) independently checking `correlation.to_s.empty?` after
/// calling this — folded into ONE emptiness check here instead of three
/// repeated ones at every call site, since nothing downstream ever wants
/// an empty-string correlation to behave differently from a genuinely
/// absent one.
fn correlation_of(pm: &ProcessManagerDef, event: &Event, reference_key_fn: fn(&str) -> Option<&'static str>) -> Option<String> {
    // TIER 1 — a dotted path into the CURRENT event's own payload
    // (`TransferRequested`'s `reference.value`, a fresh declaration).
    if let Some(v) = event.payload.dig(pm.correlates_by) {
        if let Ok(id) = v.to_id_component() {
            if !id.is_empty() {
                return Some(id);
            }
        }
    }

    // TIER 2 — THE STAMP: `event.correlation[pm.correlation_head]`, set
    // by a PRIOR call to `orchestrate` when THIS event's own dispatch was
    // itself a saga leg (`deliver_saga_dispatch`'s own `saga_correlation:`
    // argument, mirrored by `orchestrate`'s own stamping step below). The
    // corpus example this exists for: `AccountDebited`'s handler reaches
    // `:destination`, which is present only on the ORIGINAL
    // `TransferRequested` — but the correlation ITSELF (`:reference`,
    // tier 1's own field) is also absent from `AccountDebited`'s payload,
    // so without this tier there would be no way to find the right saga
    // instance to advance at all.
    if let Some(stamp) = &event.correlation {
        if let Some(v) = stamp.get(correlation_head(pm.correlates_by)) {
            if !v.is_empty() {
                return Some(v.clone());
            }
        }
    }

    // TIER 3 — `Naming.reference_key(event.aggregate)`: a leg dispatched
    // through its OWN `reference_to` argument (`Transfer.Credited`'s
    // `transfer:`) announces an event whose payload carries THAT key, not
    // `correlates_by`'s dotted field — see this file's header and
    // `reactions.rb`'s `emit_reference_key_table`.
    let key = reference_key_fn(&event.aggregate)?;
    let id = event.payload.get(key)?.to_id_component().ok()?;
    if id.is_empty() {
        None
    } else {
        Some(id)
    }
}

/// `Correlation#dispatch_args`'s value resolution, first tier only (this
/// file's header) — the correlation head resolves to the correlation
/// itself; anything else checks the CURRENT event's payload, then falls
/// back to the saga's own stashed memory of the event that began it
/// (`AccountDebited`'s handler reaching `:destination`, present only on
/// the original `TransferRequested`, is the corpus's real example of the
/// memory fallback actually firing).
fn resolve_with(pm: &ProcessManagerDef, value: &WithValue, event: &Event, correlation: &str, memory: &Json) -> Json {
    match value {
        WithValue::Literal(build) => build(),
        WithValue::Ref(name) => {
            let head = correlation_head(pm.correlates_by);
            if *name == head {
                Json::Str(correlation.to_string())
            } else if let Some(v) = event.payload.get(name) {
                v.clone()
            } else if let Some(v) = memory.get(name) {
                v.clone()
            } else {
                Json::Null
            }
        }
    }
}

fn build_dispatch_args(pm: &ProcessManagerDef, spec: &DispatchSpec, event: &Event, correlation: &str, memory: &Json, domain_name: &str, tables: &Tables) -> Json {
    let projected = Json::Object(spec.with.iter().map(|(key, value)| (key.to_string(), resolve_with(pm, value, event, correlation, memory))).collect());
    // A saga leg's own `dispatch ..., with: {...}` is ALWAYS an explicit
    // projection (`DispatchSpec.with` has no "undeclared" shape the way a
    // policy's own `with_spec` does) — split_routed_args's own header.
    //
    // `spec.command_name` is BARE on the wire (`deliver_saga_dispatch`'s
    // own comment on why, and the SAME qualification rule read directly
    // from `SagaInterpreter#qualified`) — `command_creates_fn`/`identity_
    // head_fn` are both keyed by the FULLY qualified verb, so this needs
    // the identical qualification BEFORE the lookup, not after.
    let qualified = if spec.command_name.contains("::") {
        spec.command_name.to_string()
    } else {
        format!("{domain_name}::{}", spec.command_name)
    };
    split_routed_args(projected, &qualified, tables)
}

/// Bundles the "same for the whole call tree" tables/functions every
/// recursive helper below needs, so adding a new one (this file's own
/// growth over time — `reaction_log`/`saga_log` are the newest) touches
/// one struct instead of every function signature in the file.
#[derive(Clone, Copy)]
pub struct Tables<'a> {
    pub policies: &'a [PolicyRule],
    pub cross_domain_policies: &'a [CrossDomainPolicyRule],
    pub process_managers: &'a [ProcessManagerDef],
    pub reference_key_fn: fn(&str) -> Option<&'static str>,
    /// A FAN-OUT RUNS A DECLARED QUERY, so the reaction path needs the
    /// same table `cli::run` already answers top-level asks from.
    pub queries: &'a [crate::kernel::QueryDef],
    /// `split_routed_args`'s own three tables — `reactions.rb`'s `emit_
    /// creates_table`/`emit_identity_head_table`/`emit_command_
    /// attributes_table`, all read directly.
    pub command_creates_fn: fn(&str) -> bool,
    pub identity_head_fn: fn(&str) -> Option<&'static str>,
    /// R1 (docs/audits/2026-08-11-bug-triage.md) — the target command's
    /// own declared attribute names, so a reaction-triggered dispatch's
    /// `with:` facts can be sliced down to them, matching Ruby's own
    /// `ReactionInvocation.command_facts` (`args.slice(*declared)`). See
    /// `emit_command_attributes_table`'s own header for the full story.
    pub command_attributes_fn: fn(&str) -> &'static [&'static str],
}

/// The recursive reentry loop `Dispatcher#dispatch`/`#reenter` are, ported
/// generic over the STORE type — `dispatch_fn` is generated `registry.rs`'s
/// own `dispatch_by_name`, a plain `fn` pointer (not a closure) so this can
/// recurse without fighting Rust's borrow checker over a self-referential
/// closure. Appends EVERY event — the top verb's own AND every reaction's,
/// depth-first, in the order they actually happened — into `all_events`,
/// matching `runtime.events`' own flat, whole-boot accumulation (not just
/// `Result#events`, which only ever carries one dispatch's own direct
/// announcements). Returns `Err` only when the TOP-level `verb` itself
/// refuses — a reaction's own downstream refusal is swallowed exactly the
/// way `PolicyInterpreter#deliver`/`SagaInterpreter#deliver_saga_dispatch`'s
/// `rescue *DOMAIN_REFUSALS` swallows it, but now logged there too (this
/// file's own header).
///
/// `saga_correlation` — `Dispatcher#dispatch`'s own stamping step,
/// `announced.each { (event.correlation ||= {}).merge!(saga_correlation) }`
/// — applied here, once, to every event THIS call's own `dispatch_fn`
/// just produced, before any of them reaches a reaction. `None` at the
/// top-level call (`kernel::cli::run`) and every policy reentry (policies
/// never stamp); `Some(&stamp)` only from `deliver_saga_dispatch` below.
#[allow(clippy::too_many_arguments)]
pub fn orchestrate<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    verb: &str,
    args: &Json,
    caller_role: Option<&str>,
    saga_correlation: Option<&HashMap<String, String>>,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
) -> Result<(), Refusal> {
    let mut events = dispatch_fn(store, verb, args, caller_role, mutations)?;

    if let Some(stamp) = saga_correlation {
        for event in &mut events {
            event.correlation.get_or_insert_with(HashMap::new).extend(stamp.iter().map(|(k, v)| (k.clone(), v.clone())));
        }
    }

    for event in events {
        // LOGGED THE MOMENT ITS OWN COMMAND COMMITS — before any reaction
        // it triggers runs, mirroring `CommandInterpreter#step_emit`
        // committing an event before `Dispatcher#dispatch` ever calls
        // `@policies.react`/`@sagas.advance` on it. A reaction fires off
        // an ALREADY-LOGGED fact, never the other way around.
        all_events.push(event.clone());

        // NOT depth-gated here — Ruby's own `SagaInterpreter#advance`
        // calls `begin_saga`/`advance_saga`/`end_saga` UNCONDITIONALLY
        // for every event, regardless of depth (this file's header); the
        // depth ceiling only ever gates the REENTER attempt itself,
        // checked inside `react_policies`/`deliver_saga_dispatch` below,
        // per match — not a blanket skip here, which used to silently
        // produce fewer log entries than Ruby whenever it fired.
        react_policies(store, dispatch_fn, tables, sagas, &event, depth, all_events, mutations, cross_domain, reaction_log, saga_log);
        begin_saga(tables, sagas, &event, saga_log);
        advance_saga(store, dispatch_fn, tables, sagas, &event, depth, all_events, mutations, cross_domain, reaction_log, saga_log);
        end_saga(tables, sagas, &event, saga_log);
    }

    Ok(())
}

/// WHAT THE TRIGGER IS GIVEN — `PolicyInterpreter#trigger_args`.
///
/// An empty `with_spec` forwards the event's whole payload verbatim, the
/// behaviour every policy had before `with:` existed. Declared, each
/// binding's value either NAMES a field on the source (spelled with a
/// leading ":", `Literal::render`'s own Symbol spelling) or IS a literal
/// the policy supplies itself.
///
/// `extra` is a fan-out's row key, merged into the SOURCE before the
/// projection rather than onto its result — which is what lets a
/// `for_each` trigger name the row and be given nothing else.
/// `PolicyInterpreter#where_holds?` — true with no `where`, else the
/// predicate over the payload (`Json` is `Fielded`, json.rs); an
/// evaluation that cannot resolve reads as not holding.
/// `Literal.read` (`lib/hecks/literal.rb`), the scalar cases only — a
/// policy's `trigger ..., with: { rank: "officer" }` rides the wire
/// ALREADY `Literal.render`'d (`reactions.rb`'s own `with_spec_expr`
/// comment: "so a Symbol keeps its leading colon and stays
/// distinguishable from a literal string of the same spelling"), so
/// `binding` here is never the bare value — a String literal arrives as
/// `"\"officer\""` (its own quote marks are part of the wire text, not
/// this function's own formatting), an Integer as `"1"`, `nil`/`true`/
/// `false` bare. Found live: the un-decoded wire text was passed straight
/// through as a JSON string verbatim (`Json::str(binding.to_string())`),
/// so `Rank::from_json` saw the literal 9 characters `"officer"` (quotes
/// included) instead of the 7-character value `officer` and refused —
/// `Roster::Roster.Honor`'s own real trigger, `where { number.value == 1
/// }`, never actually fired in Rust before this. Hash/Array cases are
/// Ruby's own `Literal.render`/`.read`, not built here — no policy
/// `with:` literal in the corpus is one yet (`.strip_prefix(':')`'s own
/// caller only ever routes a NON-symbol binding here for a scalar), and
/// building either without a real corpus example to verify against would
/// be exactly the guessed-at generality this codebase's own staging
/// discipline argues against.
fn read_literal_wire(binding: &str) -> Json {
    if binding == "nil" {
        return Json::Null;
    }
    if binding == "true" {
        return Json::Bool(true);
    }
    if binding == "false" {
        return Json::Bool(false);
    }
    if let Ok(i) = binding.parse::<i64>() {
        return Json::int(i);
    }
    if let Ok(f) = binding.parse::<f64>() {
        return Json::Float(f);
    }
    if binding.len() >= 2 && binding.starts_with('"') && binding.ends_with('"') {
        let inner = &binding[1..binding.len() - 1];
        let mut unescaped = String::with_capacity(inner.len());
        let mut chars = inner.chars();
        while let Some(c) = chars.next() {
            if c == '\\' {
                if let Some(next) = chars.next() {
                    unescaped.push(next);
                    continue;
                }
            }
            unescaped.push(c);
        }
        return Json::str(unescaped);
    }
    // A bare word `Literal.read` also tolerates (its own comment: "a
    // closed set's members and a few hand-written fields... never
    // rendered") — passed through as-is, matching that same tolerance.
    Json::str(binding.to_string())
}

fn where_holds(where_expr: Option<fn() -> Expr>, event: &Event) -> bool {
    let Some(build) = where_expr else { return true };
    let ctx = EvalContext { args: &event.payload, instance: &NoFields };
    matches!(interpret(&build(), &ctx), Ok(v) if v.truthy())
}

fn trigger_args(policy: &PolicyRule, event: &Event, extra: Option<(&str, String)>, target_verb: &str, tables: &Tables) -> Json {
    let mut source: Vec<(String, Json)> = match &event.payload {
        Json::Object(pairs) => pairs.clone(),
        _ => Vec::new(),
    };
    if let Some((key, id)) = &extra {
        source.retain(|(name, _)| name != key);
        source.push(((*key).to_string(), Json::str(id.clone())));
    }

    if policy.with_spec.is_empty() {
        // `ReactionInvocation.build`'s own `unless explicit` branch — "an
        // optional opportunity to lift same-aggregate Event.id" into an
        // implicit receiver, even with no `with:` declared at all. Scoped
        // to this table's own two known shapes (same aggregate that
        // emitted the event, and a target this corpus's `command_creates_
        // fn` actually has data for): `Pizzas::Order.Purchase`, reacting
        // to `Order`'s own `PizzaPaymentReceived` with no with_spec, is
        // the corpus's live example — its own identity never rides the
        // event payload at all (a bare `reference_to Order`, no declared
        // attribute for it), so without this the record can never be
        // found.
        // Never for a `for_each` dispatch (`extra.is_some()`): its own row
        // identity is ALREADY merged into `source` above, under whatever
        // name the fan-out itself resolved — a for_each row's own
        // aggregate is routinely a DIFFERENT one from the emitting
        // event's, so an `event.aggregate` match here would be
        // coincidence, not signal.
        if extra.is_none() && !(tables.command_creates_fn)(target_verb) {
            if let Some(aggregate_name) = target_verb.rsplit_once('.').map(|(agg, _)| agg) {
                if aggregate_name == event.aggregate {
                    // `args.merge(to: inherited_receiver)` — the lifted receiver
                    // REPLACES any `to` the payload itself carried (a chess
                    // move's own destination square), so that fact never reaches
                    // the target as a fact. Read directly off `build`.
                    source.retain(|(name, _)| name != "to");
                    return Json::obj(vec![("to", Json::str(event.id.clone())), ("with", Json::Object(source))]);
                }
            }
        }
        return Json::Object(source);
    }

    // THE EMITTING RECORD'S OWN IDENTITY IS A FACT A PROJECTION MAY READ
    // — `PolicyInterpreter#emitter_identity`: offered under the emitting
    // aggregate's own identity head, to an EXPLICIT projection only, never
    // over a value the payload itself carries. A cross-aggregate reaction
    // (chess's per-game Graveyard, fed from every piece's own Captured
    // event) names its receiver this way — `with: { label: :label }` —
    // and `split_routed_args` below routes it as `to`.
    if let Some(head) = (tables.identity_head_fn)(&event.aggregate) {
        if !event.id.is_empty() && !source.iter().any(|(name, _)| name == head) {
            source.push((head.to_string(), Json::str(event.id.clone())));
        }
    }

    let projected = policy
        .with_spec
        .iter()
        .map(|(name, binding)| {
            let value = match binding.strip_prefix(':') {
                Some(field) => source
                    .iter()
                    .find(|(held, _)| held == field)
                    .map(|(_, held)| held.clone())
                    .unwrap_or(Json::Null),
                None => read_literal_wire(binding),
            };
            ((*name).to_string(), value)
        })
        .collect();
    // ONLY WHEN `with:` IS EXPLICITLY DECLARED — matching `ReactionInvocation
    // .build`'s own `explicit` gate exactly (an undeclared projection keeps
    // forwarding the event's whole payload verbatim, above, unsplit, the
    // behaviour every policy had before `with:` existed at all).
    let routed = split_routed_args(Json::Object(projected), target_verb, tables);
    // `aggregate_identity ||= inherited_receiver` — the explicit path's own
    // fallback (`build`, read directly): nothing in the projection named
    // the target's identity, so the receiver is the SOURCE's own when the
    // target is the same aggregate and not creating (`source_receiver_
    // for`). Every projected fact — a `to` among them (chess:
    // OpenEnPassant's `with: { to: :to }`, the double-stepped pawn's own
    // square) — stays a fact under `with:`; it was never a receiver.
    if extra.is_none() && !(tables.command_creates_fn)(target_verb) {
        if let Json::Object(pairs) = &routed {
            let already_routed = pairs.iter().any(|(k, _)| k == "to") && pairs.iter().any(|(k, _)| k == "with");
            if !already_routed {
                if let Some(aggregate_name) = target_verb.rsplit_once('.').map(|(agg, _)| agg) {
                    if aggregate_name == event.aggregate {
                        return Json::obj(vec![("to", Json::str(event.id.clone())), ("with", routed)]);
                    }
                }
            }
        }
    }
    routed
}

/// `ReactionInvocation.build`'s own routing split (`{to:, with:}`), ported
/// for the ONE shape this corpus needs: a SINGLE-COMPONENT aggregate
/// identity, addressing an ACTING (non-creating) target. `PolicyInterpreter
/// #trigger_args`/`SagaInterpreter#dispatch_args`'s own resolved args used
/// to forward straight into `dispatch_by_name` as a flat legacy object —
/// correct for a CREATING target (nothing to route to yet), but leaking
/// the addressing key into the acting target's own event payload
/// otherwise (`Compliance::AccountFreezeReview`/`Banking::ExternalTransfer
/// ::SendTransfer`, found live diffing `rust_conformance_spec` against
/// Ruby: `AccountFrozen`'s real payload is `{}`, Ruby's own `ctx.args`
/// never carries the reference key an ACTING command's own hydrate reads
/// it from a SEPARATE channel — `CommandInvocation`'s `to:`, not `with:`).
///
/// Tries the target's own declared identity field name FIRST (`identity_
/// head_fn`, `Identity.of`'s own move), then the generic snake-cased
/// aggregate-name alias (`reference_key_fn`, `Naming.reference_key`'s own
/// move) — the SAME two (of `aggregate_aliases`' three) `Reaction
/// Invocation.identity_for` tries, in the SAME order, minus the bare
/// `:aggregate` literal key and minus per-command `addressing_key_for`
/// (this corpus's own real cases never need either). A COMPOSITE identity
/// (`identity_head_fn` returns `None` for one) or a target this table
/// simply has no data for (`command_creates_fn`'s own `_ => false`
/// default — the honest "don't know, so don't route" answer, never a
/// silent guess) leaves the args flat and unsplit, exactly like today —
/// a real, narrower gap than Ruby's own full `identity_for`, not silently
/// assumed to cover every shape.
///
/// R1 (docs/audits/2026-08-11-bug-triage.md) — `facts` below is the SAME
/// slice `ReactionInvocation.command_facts` computes on the Ruby side
/// (`args.slice(*declared)`), taken from the ORIGINAL, unfiltered
/// `pairs` rather than by removing whichever key got promoted into
/// `to:` — an identity/reference/correlation key a policy or process
/// manager's own `with:` mapping resolved (`reference: :reference`
/// forwarding a Transfer's own reference onto its saga-dispatched
/// Account::Debit/Credit legs is the corpus's own live example) almost
/// never doubles as a declared attribute of the TARGET command, so it's
/// already excluded from `facts` without needing to be found and
/// removed first; a command that DOES happen to redeclare its own
/// identity/reference field as a real attribute keeps it in `facts` too,
/// exactly as Ruby's own slice would. Applied before the creates-check
/// split, same as Ruby's own `command_facts` call sits above BOTH of
/// `ReactionInvocation.build`'s branches.
fn split_routed_args(projected: Json, target_verb: &str, tables: &Tables) -> Json {
    let Json::Object(pairs) = projected else { return projected };
    let declared = (tables.command_attributes_fn)(target_verb);
    let facts: Vec<(String, Json)> = pairs.iter().filter(|(k, _)| declared.contains(&k.as_str())).cloned().collect();

    if (tables.command_creates_fn)(target_verb) {
        return Json::Object(facts);
    }

    let Some(aggregate_name) = target_verb.rsplit_once('.').map(|(agg, _)| agg) else {
        return Json::Object(facts);
    };

    let candidates = [(tables.identity_head_fn)(aggregate_name), (tables.reference_key_fn)(aggregate_name)];
    for key in candidates.into_iter().flatten() {
        if let Some((_, raw_id)) = pairs.iter().find(|(k, _)| k == key) {
            let Ok(id) = raw_id.to_id_component() else { continue };
            if id.is_empty() {
                continue;
            }
            return Json::obj(vec![("to", Json::str(id)), ("with", Json::Object(facts))]);
        }
    }
    Json::Object(facts)
}

#[allow(clippy::too_many_arguments)]
fn react_policies<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    event: &Event,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
) {
    // `Naming.demodulise(event.aggregate)` — the LAST "::" segment
    // ("Banking::Account" -> "Account").
    let emitting = event.aggregate.rsplit("::").next().unwrap_or(event.aggregate.as_str());

    for policy in tables.policies {
        if policy.event_name != event.name {
            continue;
        }
        if let Some(qualifier) = policy.event_qualifier {
            if qualifier != emitting {
                continue;
            }
        }
        if !where_holds(policy.where_expr, event) {
            continue;
        }

        // `PolicyInterpreter#deliver`'s own `record = { policy: policy.
        // name, on: event.name, trigger: target }` — `policy.target_verb`
        // IS `target` already (domain-qualified by `reactions.rb`'s own
        // `local_policy_rows`), no further string-building needed.
        let record = |extra: Vec<(&str, Json)>| -> Json {
            let mut fields = vec![
                ("policy", Json::str(policy.policy_name.to_string())),
                ("on", Json::str(event.name.clone())),
                ("trigger", Json::str(policy.target_verb.to_string())),
            ];
            fields.extend(extra.into_iter().map(|(k, v)| (k, v)));
            Json::obj(fields)
        };

        if depth + 1 >= MAX_REACTION_DEPTH {
            reaction_log.push(record(vec![
                ("delivered", Json::Bool(false)),
                ("reason", Json::str(format!("reaction depth {MAX_REACTION_DEPTH} reached"))),
            ]));
            continue;
        }

        // A FAN-OUT DISPATCHES ONCE PER ROW its declared query answers,
        // never once for the event — `PolicyInterpreter#deliver_for_each`.
        // Each row's own id is merged into the SOURCE a `with:`
        // projection reads from, not onto its result, so a trigger can
        // name the row and be given nothing else.
        if let Some(for_each) = policy.for_each {
            let Some(def) = named_query::find(tables.queries, for_each) else {
                reaction_log.push(record(vec![
                    ("delivered", Json::Bool(false)),
                    ("reason", Json::str(format!("no query {for_each}"))),
                ]));
                continue;
            };
            // THE QUERY READS THE EVENT, never the projection: `with:`
            // says what the TRIGGER is given, and the fan-out is asking
            // a different question (WHICH rows) in the event's own
            // vocabulary.
            let rows = match named_query::run(store, def, &event.payload) {
                Ok(rows) => rows,
                Err(refusal) => {
                    reaction_log.push(record(vec![
                        ("delivered", Json::Bool(false)),
                        ("reason", Json::str(refusal.to_string())),
                    ]));
                    continue;
                }
            };
            for (row_id, _row) in rows {
                let row_record = |extra: Vec<(&str, Json)>| -> Json {
                    let mut fields = vec![("for_row", Json::str(row_id.clone()))];
                    fields.extend(extra.into_iter());
                    let base = record(vec![]);
                    match base {
                        Json::Object(mut pairs) => {
                            pairs.extend(fields.into_iter().map(|(k, v)| (k.to_string(), v)));
                            Json::Object(pairs)
                        }
                        other => other,
                    }
                };
                let args = trigger_args(policy, event, policy.for_each_key.map(|key| (key, row_id.clone())), policy.target_verb, &tables);
                let outcome = orchestrate(
                    store, dispatch_fn, tables, sagas, policy.target_verb, &args, None, None, depth + 1,
                    all_events, mutations, cross_domain, reaction_log, saga_log,
                );
                match outcome {
                    Ok(()) => reaction_log.push(row_record(vec![("delivered", Json::Bool(true))])),
                    Err(refusal) => reaction_log.push(row_record(vec![
                        ("delivered", Json::Bool(false)),
                        ("reason", Json::str(refusal.to_string())),
                    ])),
                }
            }
            continue;
        }

        // Without `with:`, the event's WHOLE payload forwards verbatim as
        // the trigger's own args — docs/implemented/guides/policies-and-process-
        // managers.md: "not reshaped, not filtered." `caller_role: None`
        // — `Dispatcher#reenter`'s own `Caller.without`: a policy
        // reaction is system-triggered, never carries whatever caller the
        // ORIGINAL step bound. `saga_correlation: None` — policies never
        // stamp (only a saga leg's own dispatch does).
        let args = trigger_args(policy, event, None, policy.target_verb, &tables);
        let outcome = orchestrate(
            store, dispatch_fn, tables, sagas, policy.target_verb, &args, None, None, depth + 1,
            all_events, mutations, cross_domain, reaction_log, saga_log,
        );
        match outcome {
            Ok(()) => reaction_log.push(record(vec![("delivered", Json::Bool(true))])),
            // A refusal is a fact about the target domain, recorded and
            // not fatal to the command that emitted `event` — matching
            // `rescue *DOMAIN_REFUSALS`. A genuine Rust panic (this
            // file's own header: the `defect` case's real analogue) is
            // NOT caught here and propagates, on purpose.
            Err(refusal) => reaction_log.push(record(vec![
                ("delivered", Json::Bool(false)),
                ("reason", Json::str(refusal.to_string())),
            ])),
        }
    }

    // CROSS-DOMAIN — matched the identical way, but never dispatched here
    // (this file's own header). Recorded, not recursed into, and NOT
    // logged into `reaction_log` either (this file's header: the delivery
    // outcome doesn't exist yet at this point). Whatever that target verb
    // itself goes on to react to is a SEPARATE WASM module's own
    // `orchestrate` call, run by rust/host after it delivers this one via
    // `lambda_client.rs`, not this call.
    for policy in tables.cross_domain_policies {
        if policy.event_name != event.name {
            continue;
        }
        if let Some(qualifier) = policy.event_qualifier {
            if qualifier != emitting {
                continue;
            }
        }
        if !where_holds(policy.where_expr, event) {
            continue;
        }
        cross_domain.push(PendingCrossDomainReaction {
            policy_name: policy.policy_name.to_string(),
            target_domain: policy.target_domain.to_string(),
            target_verb: policy.target_verb.to_string(),
            payload: event.payload.clone(),
        });
    }
}

/// `SagaInterpreter#begin_saga` — births a fresh instance the moment the
/// STARTING event arrives. NO log entry at all when `event.name !=
/// pm.starts_on` (Ruby's own `return unless ...`, silent) or when the
/// instance already exists (a re-arrival of `starts_on` for an ongoing
/// conversation — also silent in Ruby).
fn begin_saga(tables: Tables<'static>, sagas: &mut HashMap<(String, String), SagaInstance>, event: &Event, saga_log: &mut Vec<Json>) {
    for pm in tables.process_managers {
        if event.name != pm.starts_on {
            continue;
        }

        let Some(correlation) = correlation_of(pm, event, tables.reference_key_fn) else {
            saga_log.push(Json::obj(vec![
                ("process_manager", Json::str(pm.name.to_string())),
                ("on", Json::str(event.name.clone())),
                ("born", Json::Bool(false)),
                ("reason", Json::str(format!("no {} in the payload", pm.correlates_by))),
            ]));
            continue;
        };

        let key = (pm.name.to_string(), correlation.clone());
        if sagas.contains_key(&key) {
            continue;
        }

        sagas.insert(key, SagaInstance { state: pm.initial_state.to_string(), memory: event.payload.clone() });
        saga_log.push(Json::obj(vec![
            ("process_manager", Json::str(pm.name.to_string())),
            ("on", Json::str(event.name.clone())),
            ("instance", Json::str(correlation)),
            ("born", Json::Bool(true)),
            ("state", Json::str(pm.initial_state.to_string())),
        ]));
    }
}

/// `SagaInterpreter#advance_saga` — the handler lookup, the from_state
/// check, then the state transition and its own dispatch fan-out. NO log
/// entry when `pm.handler_for(event.name)` finds nothing (Ruby's own
/// `return unless handler`) or when correlation resolves to nothing
/// (Ruby's own `return if correlation.to_s.empty?`) — both silent.
#[allow(clippy::too_many_arguments)]
fn advance_saga<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    event: &Event,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
) {
    for pm in tables.process_managers {
        let Some(handler) = pm.handlers.iter().find(|h| h.event_type == event.name) else { continue };
        let Some(correlation) = correlation_of(pm, event, tables.reference_key_fn) else { continue };

        let key = (pm.name.to_string(), correlation.clone());
        let record = |extra: Vec<(&str, Json)>| -> Json {
            let mut fields = vec![
                ("process_manager", Json::str(pm.name.to_string())),
                ("on", Json::str(event.name.clone())),
                ("instance", Json::str(correlation.clone())),
            ];
            fields.extend(extra.into_iter().map(|(k, v)| (k, v)));
            Json::obj(fields)
        };

        let Some(state) = sagas.get(&key).map(|instance| instance.state.clone()) else {
            saga_log.push(record(vec![
                ("advanced", Json::Bool(false)),
                ("reason", Json::str(format!("no conversation remembers {correlation:?}"))),
            ]));
            continue;
        };
        if state != handler.from_state {
            saga_log.push(record(vec![
                ("advanced", Json::Bool(false)),
                ("reason", Json::str(format!("in {state:?}, not {:?}", handler.from_state))),
            ]));
            continue;
        }

        if let Some(slot) = sagas.get_mut(&key) {
            slot.state = handler.to_state.to_string();
        }
        saga_log.push(record(vec![
            ("advanced", Json::Bool(true)),
            ("from", Json::str(handler.from_state.to_string())),
            ("to", Json::str(handler.to_state.to_string())),
        ]));

        let memory = sagas.get(&key).map(|instance| instance.memory.clone()).unwrap_or(Json::Null);
        // `event.aggregate` is already `"{domain}::{aggregate}"`
        // (`dispatch.rs`'s own `aggregate_qualified_name`) — the same
        // fact `SagaInterpreter#deliver_saga_dispatch`'s own `domain`
        // argument names, read here rather than threaded as a whole new
        // parameter from every caller above this one.
        let domain_name = event.aggregate.split("::").next().unwrap_or(&event.aggregate);
        let mut refused = false;
        for spec in handler.dispatches {
            let args = build_dispatch_args(pm, spec, event, &correlation, &memory, domain_name, &tables);
            let stamp: HashMap<String, String> = [(correlation_head(pm.correlates_by).to_string(), correlation.clone())].into_iter().collect();
            let delivered = deliver_saga_dispatch(
                store, dispatch_fn, tables, sagas, pm, spec, domain_name, &args, &correlation, depth, all_events, mutations, cross_domain, reaction_log, saga_log, &stamp,
            );
            if delivered == Some(false) {
                refused = true;
            }
        }

        if refused {
            compensate(store, dispatch_fn, tables, sagas, pm, &key, event, &correlation, &memory, depth, all_events, mutations, cross_domain, reaction_log, saga_log);
        }
    }
}

/// `SagaInterpreter#deliver_saga_dispatch` — one dispatch spec, shared by
/// BOTH `advance_saga`'s own fan-out above and `compensate`'s (unwind's)
/// below, matching Ruby's own single method serving both callers.
/// Returns `Some(true)`/`Some(false)` for delivered/refused (the caller's
/// own signal for whether to unwind), `None` when the depth ceiling
/// stopped this leg before it ever tried (Ruby's own early return — no
/// refusal to compensate for, because nothing was attempted).
#[allow(clippy::too_many_arguments)]
fn deliver_saga_dispatch<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    pm: &ProcessManagerDef,
    spec: &DispatchSpec,
    domain_name: &str,
    args: &Json,
    correlation: &str,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
    stamp: &HashMap<String, String>,
) -> Option<bool> {
    // `record`'s own `dispatch` field stays BARE — `SagaInterpreter#
    // deliver_saga_dispatch`'s own `record = { ..., dispatch: spec.
    // command_name }`, read directly: Ruby logs the UNqualified name and
    // qualifies separately, only at the actual dispatch call below. This
    // mirrors that exact split, not a codegen-time bake — `spec.
    // command_name` itself stays bare on the wire (DispatchSpec's own
    // static table), matching the wire format everywhere else.
    let record = |extra: Vec<(&str, Json)>| -> Json {
        let mut fields = vec![
            ("process_manager", Json::str(pm.name.to_string())),
            ("instance", Json::str(correlation.to_string())),
            ("dispatch", Json::str(spec.command_name.to_string())),
        ];
        fields.extend(extra.into_iter().map(|(k, v)| (k, v)));
        Json::obj(fields)
    };

    if depth + 1 >= MAX_REACTION_DEPTH {
        saga_log.push(record(vec![
            ("delivered", Json::Bool(false)),
            ("reason", Json::str(format!("reaction depth {MAX_REACTION_DEPTH} reached"))),
        ]));
        return None;
    }

    // `SagaInterpreter#qualified` (saga_interpreter.rb), read directly:
    // `command_name.include?("::") ? command_name : "#{domain}::#{command_name}"`
    // — `spec.command_name` is bare on the wire (confirmed via `bin/ir`
    // against the real exported IR; the OLD comment above `emit_process_
    // manager_table`/`domain_generator.rb`'s manifest loop claiming it was
    // "ALREADY fully domain-qualified on the wire" was simply wrong), so
    // `dispatch_by_name`'s own fully-qualified match arms
    // (`"Banking::Account.Debit"`) could never route to it — a 100%
    // failure rate for every process-manager dispatch this kernel has
    // ever run, previously masked because no rust_conformance fixture
    // ever reached a real same-domain saga dispatch. Item #3, whole-
    // project table-unification survey.
    let qualified = if spec.command_name.contains("::") {
        spec.command_name.to_string()
    } else {
        format!("{domain_name}::{}", spec.command_name)
    };

    // `caller_role: None` — same `Caller.without` reasoning as
    // `react_policies`: a saga leg is system-triggered. `saga_correlation:
    // Some(stamp)` — THE stamp this file's header describes, applied by
    // `orchestrate` to every event this recursive dispatch itself
    // produces.
    let outcome = orchestrate(
        store, dispatch_fn, tables, sagas, &qualified, args, None, Some(stamp), depth + 1,
        all_events, mutations, cross_domain, reaction_log, saga_log,
    );
    match outcome {
        Ok(()) => {
            saga_log.push(record(vec![("delivered", Json::Bool(true))]));
            Some(true)
        }
        Err(refusal) => {
            saga_log.push(record(vec![
                ("delivered", Json::Bool(false)),
                ("reason", Json::str(refusal.to_string())),
            ]));
            Some(false)
        }
    }
}

/// `SagaInterpreter#end_saga` — the instance is done, whether it just
/// advanced INTO its `ends_on` event or transitioned straight there with
/// no dispatches of its own. NO log entry when `event.name != pm.ends_on`,
/// correlation is absent, or no instance existed to remove — all three
/// silent in Ruby.
fn end_saga(tables: Tables<'static>, sagas: &mut HashMap<(String, String), SagaInstance>, event: &Event, saga_log: &mut Vec<Json>) {
    for pm in tables.process_managers {
        if event.name != pm.ends_on {
            continue;
        }
        let Some(correlation) = correlation_of(pm, event, tables.reference_key_fn) else { continue };
        let key = (pm.name.to_string(), correlation.clone());
        if sagas.remove(&key).is_none() {
            continue;
        }

        saga_log.push(Json::obj(vec![
            ("process_manager", Json::str(pm.name.to_string())),
            ("on", Json::str(event.name.clone())),
            ("instance", Json::str(correlation)),
            ("ended", Json::Bool(true)),
        ]));
    }
}

/// `SagaInterpreter#unwind` — the `on :refused` leg, run once, against the
/// CURRENT (post-transition) state a failed dispatch left the instance in.
/// Its own dispatches never themselves compensate on failure — matching
/// Ruby's own guard (the state has already moved past `from_state` before
/// a second refusal could reach this same branch again). Shares `deliver_
/// saga_dispatch` with `advance_saga` above, exactly like Ruby's own
/// `unwind` calls the SAME `deliver_saga_dispatch` its sibling does.
#[allow(clippy::too_many_arguments)]
fn compensate<S: AggregateScan>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>, &mut Vec<MutationRecord>) -> Result<Vec<Event>, Refusal>,
    tables: Tables<'static>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    pm: &ProcessManagerDef,
    key: &(String, String),
    event: &Event,
    correlation: &str,
    memory: &Json,
    depth: usize,
    all_events: &mut Vec<Event>,
    mutations: &mut Vec<MutationRecord>,
    cross_domain: &mut Vec<PendingCrossDomainReaction>,
    reaction_log: &mut Vec<Json>,
    saga_log: &mut Vec<Json>,
) {
    let Some(current_state) = sagas.get(key).map(|instance| instance.state.clone()) else { return };
    // `pm.handler_for(REFUSED)` — event_type ALONE, read directly
    // (`IR::ProcessManager#handler_for`: `@handlers.find { |h| h.
    // event_type == event.to_s }`, no from_state in the match at all). A
    // from_state mismatch is a SEPARATE check below, logged as its own
    // `advanced: false` finding — folding it into this `find`'s own
    // predicate (this file's prior bug) made that branch unreachable and
    // silently dropped the log entry Ruby produces for exactly this case.
    let Some(compensation) = pm.handlers.iter().find(|h| h.event_type == REFUSED) else { return };

    let record = |extra: Vec<(&str, Json)>| -> Json {
        let mut fields = vec![
            ("process_manager", Json::str(pm.name.to_string())),
            ("on", Json::str(REFUSED.to_string())),
            ("instance", Json::str(correlation.to_string())),
        ];
        fields.extend(extra.into_iter().map(|(k, v)| (k, v)));
        Json::obj(fields)
    };

    if current_state != compensation.from_state {
        saga_log.push(record(vec![
            ("advanced", Json::Bool(false)),
            ("reason", Json::str(format!("in {current_state:?}, not {:?}", compensation.from_state))),
        ]));
        return;
    }

    if let Some(slot) = sagas.get_mut(key) {
        slot.state = compensation.to_state.to_string();
    }
    saga_log.push(record(vec![
        ("advanced", Json::Bool(true)),
        ("from", Json::str(compensation.from_state.to_string())),
        ("to", Json::str(compensation.to_state.to_string())),
    ]));

    // See `advance_saga`'s own identical comment — same derivation, same
    // reason.
    let domain_name = event.aggregate.split("::").next().unwrap_or(&event.aggregate);
    for spec in compensation.dispatches {
        let args = build_dispatch_args(pm, spec, event, correlation, memory, domain_name, &tables);
        let stamp: HashMap<String, String> = [(correlation_head(pm.correlates_by).to_string(), correlation.to_string())].into_iter().collect();
        deliver_saga_dispatch(
            store, dispatch_fn, tables, sagas, pm, spec, domain_name, &args, correlation, depth, all_events, mutations, cross_domain, reaction_log, saga_log, &stamp,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // `read_literal_wire` — a policy `with:` literal rides the wire
    // already `Literal.render`'d (`reactions.rb`'s own `with_spec_expr`),
    // so the un-decoded text is never the real value. Found live:
    // `Roster::Roster.Honor`'s own `trigger ..., with: { rank: "officer"
    // }` passed the RAW wire text `"officer"` (9 chars, quotes included)
    // straight through as a JSON string, and `Rank::from_json` refused
    // it — the trigger silently never fired.
    #[test]
    fn decodes_a_quoted_string_literal_back_to_its_bare_value() {
        assert_eq!(read_literal_wire("\"officer\""), Json::str("officer"));
    }

    #[test]
    fn unescapes_an_embedded_quote_or_backslash_the_same_way_literal_quote_escaped_it() {
        assert_eq!(read_literal_wire("\"a\\\"b\\\\c\""), Json::str("a\"b\\c"));
    }

    #[test]
    fn decodes_the_bare_scalar_forms_literal_render_never_quotes() {
        assert_eq!(read_literal_wire("nil"), Json::Null);
        assert_eq!(read_literal_wire("true"), Json::Bool(true));
        assert_eq!(read_literal_wire("false"), Json::Bool(false));
        assert_eq!(read_literal_wire("42"), Json::int(42));
        assert_eq!(read_literal_wire("3.5"), Json::Float(3.5));
    }

    #[test]
    fn passes_a_bare_unrendered_word_through_unchanged() {
        // `Literal.read`'s own tolerance (lib/hecks/literal.rb): a
        // closed set's members and a few hand-written fields are stored
        // as plain text that was never rendered at all.
        assert_eq!(read_literal_wire("officer"), Json::str("officer"));
    }

    fn pm(correlates_by: &'static str) -> ProcessManagerDef {
        ProcessManagerDef {
            name: "TestSaga",
            correlates_by,
            starts_on: "Started",
            ends_on: "Ended",
            initial_state: "start",
            handlers: &[],
        }
    }

    fn no_reference_key(_aggregate: &str) -> Option<&'static str> {
        None
    }

    // TIER 2, in isolation — `Correlation#saga_correlation`'s own middle
    // tier: the corpus scenario this exists for (`AccountDebited`'s
    // handler reaching `:destination`, only present on the ORIGINAL
    // `TransferRequested`) always has tier 1 (a genuinely present
    // `reference`-shaped field) available too, so the full conformance
    // corpus alone never proves tier 2 fires on its OWN. This does: tier
    // 1 finds nothing (`correlates_by` names a field the payload doesn't
    // have at all), tier 3 finds nothing (no reference-key function
    // configured), so only the STAMP `orchestrate`'s own event.
    // correlation field carries can resolve it.
    #[test]
    fn correlation_of_reads_the_stamp_when_the_payload_has_nothing_and_no_reference_key_applies() {
        let pm = pm("reference.value");
        let event = Event {
            name: "SomeEvent".to_string(),
            aggregate: "Domain::Thing".to_string(),
            id: "thing-1".to_string(),
            payload: Json::Object(vec![]),
            correlation: Some([("reference".to_string(), "xfer-1".to_string())].into_iter().collect()),
        };

        assert_eq!(correlation_of(&pm, &event, no_reference_key), Some("xfer-1".to_string()));
    }

    #[test]
    fn correlation_of_prefers_tier_1_over_the_stamp_when_both_are_present() {
        let pm = pm("reference.value");
        let event = Event {
            name: "SomeEvent".to_string(),
            aggregate: "Domain::Thing".to_string(),
            id: "thing-1".to_string(),
            payload: Json::Object(vec![("reference".to_string(), Json::Object(vec![("value".to_string(), Json::Str("from-payload".to_string()))]))]),
            correlation: Some([("reference".to_string(), "from-stamp".to_string())].into_iter().collect()),
        };

        assert_eq!(correlation_of(&pm, &event, no_reference_key), Some("from-payload".to_string()));
    }

    #[test]
    fn correlation_of_ignores_an_empty_stamped_value_and_falls_through() {
        let pm = pm("reference.value");
        let event = Event {
            name: "SomeEvent".to_string(),
            aggregate: "Domain::Thing".to_string(),
            id: "thing-1".to_string(),
            payload: Json::Object(vec![]),
            correlation: Some([("reference".to_string(), String::new())].into_iter().collect()),
        };

        assert_eq!(correlation_of(&pm, &event, no_reference_key), None);
    }

    // `orchestrate`'s own stamping step — proven directly here rather
    // than only through the full recursive call (which needs a real
    // `dispatch_fn`/`Store`): the exact `(event.correlation ||= {}).
    // merge!(saga_correlation)` Ruby's `Dispatcher#dispatch` performs.
    #[test]
    fn stamping_merges_into_an_existing_correlation_map_rather_than_replacing_it() {
        let mut events = vec![
            Event {
                name: "E".to_string(),
                aggregate: "Domain::Thing".to_string(),
                id: "thing-1".to_string(),
                payload: Json::Null,
                correlation: Some([("already".to_string(), "here".to_string())].into_iter().collect()),
            },
        ];
        let stamp: HashMap<String, String> = [("reference".to_string(), "xfer-1".to_string())].into_iter().collect();
        for event in &mut events {
            event.correlation.get_or_insert_with(HashMap::new).extend(stamp.iter().map(|(k, v)| (k.clone(), v.clone())));
        }

        let correlation = events[0].correlation.as_ref().unwrap();
        assert_eq!(correlation.get("already"), Some(&"here".to_string()));
        assert_eq!(correlation.get("reference"), Some(&"xfer-1".to_string()));
    }
}
