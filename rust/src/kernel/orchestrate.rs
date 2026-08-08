// HAND-WRITTEN, ONCE, GENERIC — a direct port of `Dispatcher#dispatch`'s
// own reaction plumbing (lib/hecksagain/runtime/dispatcher.rb, read
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
// NOT the reaction/saga LOG (`registry.reaction_log`/`saga_log`) — nothing
// in `bin/rust_conformance`'s own comparable surface (`instances`,
// `events`, `refusals`) reads those, so this kernel produces the correct
// SIDE EFFECTS without also building a byte-for-byte log to match. A real,
// separate gap if a future need ever wants to inspect the log itself, not
// silently pretended away.
//
// ALSO NOT REPLICATED: `Correlation#saga_correlation`'s full three-tier
// resolution (dotted lookup into the CURRENT event's payload; else a
// `saga_correlation:` stamp carried on the event itself; else
// `Naming.reference_key` on the event's own aggregate). Only the first
// tier is ported — the one every real handler in this corpus's process
// managers actually needs, confirmed by tracing `spec/corpus/banking.json`
// against the live Ruby runtime before this was written. A real, separate
// gap if a future process manager ever needs the other two tiers.

use super::{Event, Json, Refusal};
use std::collections::HashMap;

pub const MAX_REACTION_DEPTH: usize = 5;

/// One `policy "Name" do on ... trigger ... end` block — see this file's
/// header and `rust/project/reactions.rb`'s `emit_policy_table` for how
/// `event_qualifier`/`event_name` get split from `on_event` and why
/// cross-domain policies are absent from this table entirely rather than
/// represented and refused at runtime.
pub struct PolicyRule {
    pub event_name: &'static str,
    pub event_qualifier: Option<&'static str>,
    pub target_verb: &'static str,
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
pub struct SagaInstance {
    pub state: String,
    pub memory: Json,
}

fn correlation_of(pm: &ProcessManagerDef, event: &Event, reference_key_fn: fn(&str) -> Option<&'static str>) -> Option<String> {
    if let Some(v) = event.payload.dig(pm.correlates_by) {
        if let Ok(id) = v.to_id_component() {
            return Some(id);
        }
    }
    // Tier 3 — `Naming.reference_key(event.aggregate)`: a leg dispatched
    // through its OWN `reference_to` argument (`Transfer.Credited`'s
    // `transfer:`) announces an event whose payload carries THAT key, not
    // `correlates_by`'s dotted field — see this file's header and
    // `reactions.rb`'s `emit_reference_key_table`.
    let key = reference_key_fn(&event.aggregate)?;
    event.payload.get(key)?.to_id_component().ok()
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
            let correlation_head = pm.correlates_by.split('.').next().unwrap_or(pm.correlates_by);
            if *name == correlation_head {
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

fn build_dispatch_args(pm: &ProcessManagerDef, spec: &DispatchSpec, event: &Event, correlation: &str, memory: &Json) -> Json {
    Json::Object(spec.with.iter().map(|(key, value)| (key.to_string(), resolve_with(pm, value, event, correlation, memory))).collect())
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
/// `rescue *DOMAIN_REFUSALS` swallows it (see this file's own header on
/// why the log itself isn't reproduced).
#[allow(clippy::too_many_arguments)]
pub fn orchestrate<S>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>) -> Result<Vec<Event>, Refusal>,
    policies: &'static [PolicyRule],
    process_managers: &'static [ProcessManagerDef],
    reference_key_fn: fn(&str) -> Option<&'static str>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    verb: &str,
    args: &Json,
    caller_role: Option<&str>,
    depth: usize,
    all_events: &mut Vec<Event>,
) -> Result<(), Refusal> {
    let events = dispatch_fn(store, verb, args, caller_role)?;

    for event in events {
        // LOGGED THE MOMENT ITS OWN COMMAND COMMITS — before any reaction
        // it triggers runs, mirroring `CommandInterpreter#step_emit`
        // committing an event before `Dispatcher#dispatch` ever calls
        // `@policies.react`/`@sagas.advance` on it. A reaction fires off
        // an ALREADY-LOGGED fact, never the other way around.
        all_events.push(event.clone());

        if depth + 1 >= MAX_REACTION_DEPTH {
            continue;
        }

        react_policies(store, dispatch_fn, policies, process_managers, reference_key_fn, sagas, &event, depth, all_events);
        advance_process_managers(store, dispatch_fn, policies, process_managers, reference_key_fn, sagas, &event, depth, all_events);
    }

    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn react_policies<S>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>) -> Result<Vec<Event>, Refusal>,
    policies: &'static [PolicyRule],
    process_managers: &'static [ProcessManagerDef],
    reference_key_fn: fn(&str) -> Option<&'static str>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    event: &Event,
    depth: usize,
    all_events: &mut Vec<Event>,
) {
    // `Naming.demodulise(event.aggregate)` — the LAST "::" segment
    // ("Banking::Account" -> "Account").
    let emitting = event.aggregate.rsplit("::").next().unwrap_or(event.aggregate.as_str());

    for policy in policies {
        if policy.event_name != event.name {
            continue;
        }
        if let Some(qualifier) = policy.event_qualifier {
            if qualifier != emitting {
                continue;
            }
        }
        // Forward the event's WHOLE payload verbatim as the trigger's own
        // args — docs/guides/policies-and-process-managers.md: "not
        // reshaped, not filtered." A refusal here is swallowed.
        // `caller_role: None` — `Dispatcher#reenter`'s own `Caller.
        // without`: a policy reaction is system-triggered, never carries
        // whatever caller the ORIGINAL step bound.
        let _ = orchestrate(store, dispatch_fn, policies, process_managers, reference_key_fn, sagas, policy.target_verb, &event.payload, None, depth + 1, all_events);
    }
}

/// `SagaInterpreter#advance` — `begin_saga`/the handler lookup/
/// `apply mutations`-equivalent dispatch fan-out/compensation, in that
/// order, for every declared process manager against this one event.
#[allow(clippy::too_many_arguments)]
fn advance_process_managers<S>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>) -> Result<Vec<Event>, Refusal>,
    policies: &'static [PolicyRule],
    process_managers: &'static [ProcessManagerDef],
    reference_key_fn: fn(&str) -> Option<&'static str>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    event: &Event,
    depth: usize,
    all_events: &mut Vec<Event>,
) {
    for pm in process_managers {
        let Some(correlation) = correlation_of(pm, event, reference_key_fn) else { continue };
        let key = (pm.name.to_string(), correlation.clone());

        // `begin_saga` — births a fresh instance the moment the STARTING
        // event arrives, memory = that event's whole payload.
        if event.name == pm.starts_on {
            sagas.entry(key.clone()).or_insert_with(|| SagaInstance { state: pm.initial_state.to_string(), memory: event.payload.clone() });
        }

        let Some(handler) = pm.handlers.iter().find(|h| h.event_type == event.name) else { continue };
        let Some(instance) = sagas.get(&key) else { continue };
        if instance.state != handler.from_state {
            continue;
        }

        // `advance_saga` — committed BEFORE running this handler's own
        // dispatches, matching Ruby's own ordering — a refused
        // compensation can't re-fire itself, because the state has
        // already moved past `from_state` by the time any dispatch below
        // could even fail.
        let memory = instance.memory.clone();
        if let Some(slot) = sagas.get_mut(&key) {
            slot.state = handler.to_state.to_string();
        }

        for spec in handler.dispatches {
            let args = build_dispatch_args(pm, spec, event, &correlation, &memory);
            // `caller_role: None` — same `Caller.without` reasoning as
            // `react_policies`: a saga leg is system-triggered.
            let outcome = orchestrate(store, dispatch_fn, policies, process_managers, reference_key_fn, sagas, spec.command_name, &args, None, depth + 1, all_events);

            if outcome.is_err() {
                compensate(store, dispatch_fn, policies, process_managers, reference_key_fn, sagas, pm, &key, event, &correlation, &memory, depth, all_events);
            }
        }

        // `end_saga` — the instance is done, whether it just advanced INTO
        // its ends_on event or (Onboarding-shaped) transitioned straight
        // there with no dispatches of its own.
        if event.name == pm.ends_on {
            sagas.remove(&key);
        }
    }
}

/// `SagaInterpreter#unwind` — the `on :refused` leg, run once, against the
/// CURRENT (post-transition) state a failed dispatch left the instance in.
/// Its own dispatches never themselves compensate on failure — matching
/// Ruby's own guard (the state has already moved past `from_state` before
/// a second refusal could reach this same branch again).
#[allow(clippy::too_many_arguments)]
fn compensate<S>(
    store: &mut S,
    dispatch_fn: fn(&mut S, &str, &Json, Option<&str>) -> Result<Vec<Event>, Refusal>,
    policies: &'static [PolicyRule],
    process_managers: &'static [ProcessManagerDef],
    reference_key_fn: fn(&str) -> Option<&'static str>,
    sagas: &mut HashMap<(String, String), SagaInstance>,
    pm: &ProcessManagerDef,
    key: &(String, String),
    event: &Event,
    correlation: &str,
    memory: &Json,
    depth: usize,
    all_events: &mut Vec<Event>,
) {
    let current_state = match sagas.get(key) {
        Some(instance) => instance.state.clone(),
        None => return,
    };

    let Some(compensation) = pm.handlers.iter().find(|h| h.event_type == REFUSED && h.from_state == current_state) else { return };

    if let Some(slot) = sagas.get_mut(key) {
        slot.state = compensation.to_state.to_string();
    }

    for spec in compensation.dispatches {
        let args = build_dispatch_args(pm, spec, event, correlation, memory);
        let _ = orchestrate(store, dispatch_fn, policies, process_managers, reference_key_fn, sagas, spec.command_name, &args, None, depth + 1, all_events);
    }
}
