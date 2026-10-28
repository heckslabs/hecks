//! Ties the journal and the sandbox together: replays history, then the
//! new step, persisting it only if the module accepts it.

use crate::host::Host;
use crate::journal;
use crate::lambda_client::{self};
use crate::store::{Accepted, DeadLetter, LineageWrite, Store};
use crate::wasm_runner;
use std::path::Path;

pub struct Outcome {
    pub result: serde_json::Value,
    pub accepted: bool,
}

/// Who a command is dispatched for: the role they state and, when the host knows who they are, the
/// actor Governance holds assignments for. Both absent is an unidentified caller.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Caller<'a> {
    pub role: Option<&'a str>,
    pub actor_id: Option<&'a str>,
}

/// The role an unidentified caller is dispatched under when roles are enforced: no command declares
/// it, so a command that declares any role refuses it.
pub const ANONYMOUS_ROLE: &str = "Anonymous";

/// What the host does about the role a command declares (`HECKS_ROLE_ENFORCEMENT`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Enforcement {
    /// A caller with no role is unchecked, as before.
    Off,
    /// An unidentified or unassigned caller is let through and logged as `would_refuse_role`; a
    /// caller that states a role is checked exactly as under `Enforce`, so shadow never accepts
    /// what `Off` would not.
    Shadow,
    /// An unidentified or unassigned caller is refused.
    Enforce,
}

static ENFORCEMENT: std::sync::OnceLock<Enforcement> = std::sync::OnceLock::new();

impl Enforcement {
    /// Reads `off` (the default), `shadow` or `enforce`; anything else is `Off`.
    pub fn parse(value: Option<&str>) -> Self {
        match value.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
            Some("shadow") => Self::Shadow,
            Some("enforce") => Self::Enforce,
            _ => Self::Off,
        }
    }

    /// Fixes the mode for the life of the process; boot calls it with the parsed
    /// `HECKS_ROLE_ENFORCEMENT`. Only the first call has an effect.
    pub fn install(mode: Self) {
        let _ = ENFORCEMENT.set(mode);
    }

    /// The mode boot installed, or `Off` when none was.
    pub fn configured() -> Self {
        ENFORCEMENT.get().copied().unwrap_or(Self::Off)
    }

    /// The caller the kernel is asked to check: an unidentified caller becomes the anonymous role
    /// unless enforcement is off.
    pub fn effective(self, caller: Caller<'_>) -> Caller<'_> {
        if self != Self::Off && caller.role.is_none() && caller.actor_id.is_none() {
            return Caller {
                role: Some(ANONYMOUS_ROLE),
                actor_id: None,
            };
        }
        caller
    }
}

/// Where a dispatch comes from. A host-internal dispatch is the host acting on its own behalf (a
/// signup, a provisioning step, a presentation write); it names no caller and is never subject to
/// `HECKS_ROLE_ENFORCEMENT`, which guards what callers outside the host may do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    /// A caller the host's internal protocol names, from one of its own peers.
    External,
    /// A signed-in request to the console API or the web UI. Its caller is checked as an
    /// `External` one is, and every fact its command needs is the host's answer, never the
    /// request's.
    Request,
    HostInternal,
}

/// Whether a dispatch keeps what it does. A preview asks the kernel whether the command would be
/// accepted and keeps nothing: no journal row, snapshot or saga, no reaction delivered, no log line.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Effect {
    Commit,
    Preview,
}

/// Whether the kernel refused the command for the caller's role.
pub fn refused_for_role(result: &serde_json::Value) -> bool {
    result
        .get("refusals")
        .and_then(|r| r.as_array())
        .is_some_and(|all| {
            all.iter()
                .any(|r| r.get("kind").and_then(|k| k.as_str()) == Some("Unauthorized"))
        })
}

// Distinguishes a module refusal from a kernel failure to run at all.
#[derive(Debug, PartialEq, Eq)]
pub enum KernelAnswer {
    Accepted,
    Refused,
    Failed(String),
}

// A run that never started has no `refusals` array at all, so absence of
// refusals doesn't by itself mean the run succeeded.
pub fn classify(result: &serde_json::Value) -> KernelAnswer {
    if let Some(error) = result.get("error") {
        return KernelAnswer::Failed(
            error
                .as_str()
                .map_or_else(|| error.to_string(), str::to_string),
        );
    }
    let refused = result
        .get("refusals")
        .and_then(|r| r.as_array())
        .is_some_and(|r| !r.is_empty());
    if refused {
        KernelAnswer::Refused
    } else {
        KernelAnswer::Accepted
    }
}

// A kernel failure becomes `Err`, not a result with no instances read as
// an empty world.
pub fn parse_kernel_output(output: &str) -> anyhow::Result<serde_json::Value> {
    let result: serde_json::Value = serde_json::from_str(output)?;
    match classify(&result) {
        KernelAnswer::Failed(message) => {
            anyhow::bail!("the kernel failed before it could run the command: {message}")
        }
        KernelAnswer::Accepted | KernelAnswer::Refused => Ok(result),
    }
}

// Kept as one opaque object under the journal's `args` column; the kernel
// unwraps `to`/`with` itself, so this needs no journal schema migration.
pub fn routed_invocation(
    to: serde_json::Value,
    facts: serde_json::Value,
) -> anyhow::Result<serde_json::Value> {
    if !facts.is_object() {
        anyhow::bail!("with must be an object of command facts");
    }
    let mut invocation = serde_json::Map::new();
    invocation.insert("to".to_string(), to);
    invocation.insert("with".to_string(), facts);
    Ok(serde_json::Value::Object(invocation))
}

// No `to` route: used only when a command creates a new aggregate, so
// there is no receiver yet to route to.
pub fn facts_invocation(facts: serde_json::Value) -> anyhow::Result<serde_json::Value> {
    if !facts.is_object() {
        anyhow::bail!("with must be an object of command facts");
    }
    let mut invocation = serde_json::Map::new();
    invocation.insert("with".to_string(), facts);
    Ok(serde_json::Value::Object(invocation))
}

// Route-aware entry point; `handle` below stays the compatibility path
// for callers still sending the older mixed args shape.
pub async fn handle_routed(
    host: Host<'_>,
    verb: &str,
    to: serde_json::Value,
    facts: serde_json::Value,
    role: Option<&str>,
) -> anyhow::Result<Outcome> {
    handle(host, verb, routed_invocation(to, facts)?, role).await
}

/// `handle_routed` for a caller the host can name.
pub async fn handle_routed_as(
    host: Host<'_>,
    verb: &str,
    to: serde_json::Value,
    facts: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    handle_as(host, verb, routed_invocation(to, facts)?, caller).await
}

// Facts-only counterpart to `handle_routed`.
pub async fn handle_facts(
    host: Host<'_>,
    verb: &str,
    facts: serde_json::Value,
    role: Option<&str>,
) -> anyhow::Result<Outcome> {
    handle(host, verb, facts_invocation(facts)?, role).await
}

/// `handle_facts` for a caller the host can name.
pub async fn handle_facts_as(
    host: Host<'_>,
    verb: &str,
    facts: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    handle_as(host, verb, facts_invocation(facts)?, caller).await
}

// The store's unit of work holds the domain lock from the first load to the commit, so concurrent
// callers on one store can't interleave their reads and writes.
//
// `config` is required, not optional: `main.rs` already refused to boot
// unless the configured domain/era is provisioned and current, so by the
// time `handle` runs that schema is guaranteed to exist.
//
// `role` is optional, matching `Adapters::Lambda::Client#dispatch`'s own
// `role: nil` default: a step with no role looks the same on the wire
// whether or not a caller is bound.
//
// This entry point and `handle_facts`/`handle_routed` are the host's own: a call with no role is a
// host-internal dispatch and is unchecked in every enforcement mode. A call that names a role is
// still checked against it. A peer naming its caller goes through the `_as` entry points, and a
// request to the console API or the web UI through the `_request` ones.
pub async fn handle(
    host: Host<'_>,
    verb: &str,
    args: serde_json::Value,
    role: Option<&str>,
) -> anyhow::Result<Outcome> {
    let origin = if role.is_none() {
        Origin::HostInternal
    } else {
        Origin::External
    };
    dispatch_in(
        Enforcement::configured(),
        origin,
        host,
        verb,
        args,
        Caller {
            role,
            actor_id: None,
        },
    )
    .await
}

/// `handle_as` for a request from outside the host: the console API and the web UI.
pub async fn handle_request(
    host: Host<'_>,
    verb: &str,
    args: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    dispatch_in(
        Enforcement::configured(),
        Origin::Request,
        host,
        verb,
        args,
        caller,
    )
    .await
}

/// `handle_routed_as` for a request from outside the host.
pub async fn handle_routed_request(
    host: Host<'_>,
    verb: &str,
    to: serde_json::Value,
    facts: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    handle_request(host, verb, routed_invocation(to, facts)?, caller).await
}

/// `handle_facts_as` for a request from outside the host.
pub async fn handle_facts_request(
    host: Host<'_>,
    verb: &str,
    facts: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    handle_request(host, verb, facts_invocation(facts)?, caller).await
}

/// Dispatches for a caller, applying `HECKS_ROLE_ENFORCEMENT`: unidentified callers are refused (or,
/// in shadow, logged as would-be refusals and let through).
pub async fn handle_as(
    host: Host<'_>,
    verb: &str,
    args: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    dispatch_in(
        Enforcement::configured(),
        Origin::External,
        host,
        verb,
        args,
        caller,
    )
    .await
}

pub async fn dispatch_in(
    mode: Enforcement,
    origin: Origin,
    host: Host<'_>,
    verb: &str,
    args: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    dispatch_with(mode, origin, Effect::Commit, host, verb, args, caller).await
}

/// What a command would answer for a caller the host can name, without keeping any of it: the
/// kernel's own dry-run step, run on the journal's history and rolled back. The answer is in
/// `result["dry_runs"]`; see `validation::answer`.
pub async fn preview_as(
    host: Host<'_>,
    verb: &str,
    args: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    let mode = Enforcement::configured();
    dispatch_with(
        mode,
        Origin::External,
        Effect::Preview,
        host,
        verb,
        args,
        caller,
    )
    .await
}

/// `preview_as` for a request from outside the host: the console API and the web UI.
pub async fn preview_request(
    host: Host<'_>,
    verb: &str,
    args: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    let mode = Enforcement::configured();
    dispatch_with(
        mode,
        Origin::Request,
        Effect::Preview,
        host,
        verb,
        args,
        caller,
    )
    .await
}

async fn dispatch_with(
    mode: Enforcement,
    origin: Origin,
    effect: Effect,
    host: Host<'_>,
    verb: &str,
    args: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    let checked = if origin == Origin::HostInternal {
        caller
    } else {
        mode.effective(caller)
    };
    let outcome = run(origin, effect, host, verb, args.clone(), checked).await?;
    // Only a caller that stated no role (unidentified, or an actor Governance holds no grant for)
    // is let through; a stated role that does not match stays refused, as it is under `Off`.
    if mode == Enforcement::Shadow
        && caller.role.is_none()
        && !outcome.accepted
        && refused_for_role(&outcome.result)
    {
        crate::log::error(
            "would_refuse_role",
            serde_json::json!({
                "verb": verb, "role": checked.role, "actor_id": checked.actor_id,
                "refusals": outcome.result.get("refusals"),
            }),
        );
        return run(origin, effect, host, verb, args, Caller::default()).await;
    }
    Ok(outcome)
}

async fn run(
    origin: Origin,
    effect: Effect,
    host: Host<'_>,
    verb: &str,
    args: serde_json::Value,
    caller: Caller<'_>,
) -> anyhow::Result<Outcome> {
    let Host {
        store,
        wasm_path,
        config,
        invoker,
        ..
    } = host;
    let role = caller.role;
    // Locks the whole read-then-append sequence, not just the append: two concurrent
    // invocations could otherwise both rehydrate against the same prior steps and both pass a
    // uniqueness check the domain thinks it is enforcing.
    let unit = store.begin(&config.domain).await?;

    // The last snapshot plus only the journal rows after it, instead of the whole history every
    // time. No snapshot covers a brand-new domain and one with pre-snapshot history alike; both
    // fall back to one full replay, which then leaves a snapshot behind.
    let state = unit.load().await?;
    // Role goes only on this outermost step; replayed history already
    // carries whatever role it was dispatched with. Built as a mutable
    // step, not inlined into the `json!` literal, so a roleless call
    // still omits the `"role"` key entirely rather than sending null.
    // A fact the command `needs` is answered here, before the kernel's gates read the arguments and
    // before the step is journaled, so a replay re-dispatches the recorded answer (ADR 0081).
    let mut args = args;
    if let Some(domain_ir) = crate::ir::ir() {
        fill_arguments(
            origin,
            domain_ir,
            verb,
            &mut args,
            &crate::needs::ProcessClock,
        );
    }
    let mut step = match effect {
        Effect::Commit => serde_json::json!({ "verb": verb, "args": args.clone() }),
        Effect::Preview => preview_step(verb, &args),
    };
    if let Some(role) = role {
        step["role"] = serde_json::Value::String(role.to_string());
    }
    if let Some(actor_id) = caller.actor_id {
        step["actor_id"] = serde_json::Value::String(actor_id.to_string());
    }
    // Stamped only on this live step. The journal keeps a command's verb and arguments alone, so a
    // replayed step carries no role, actor or timestamp of its own.
    step["occurred_at"] = serde_json::Value::String(crate::clock::iso8601_now());
    // The seed matches the steps: a full replay needs an empty seed, or the kernel replays into a
    // world that already has every record being created again, refusing each as a false
    // AlreadyExists.
    let seed = state.seed();
    let mut steps = state.steps;
    steps.push(step);

    // Read inside the same locked scope: the lock covers saga state too, not just the aggregate
    // journal and snapshot.
    let sagas_seed = serde_json::json!(state
        .sagas
        .iter()
        .map(|r| serde_json::json!({
            "process_manager": r.process_manager,
            "correlation": r.correlation,
            "state": r.state,
            "memory": r.memory,
            "completed_compensations": r.completed_compensations,
        }))
        .collect::<Vec<_>>());

    let input = kernel_input(&seed, &steps, &sagas_seed).to_string();
    // `wasm_runner::run` is sync, and wasmtime-wasi's sync bridge spins up
    // its own tokio runtime internally — fatal on a thread already
    // driving one. `spawn_blocking` moves it off this async runtime.
    let owned_wasm_path = wasm_path.to_path_buf();
    let output =
        tokio::task::spawn_blocking(move || wasm_runner::run(&owned_wasm_path, &input)).await??;
    // A kernel failure returns here, before anything is written: dropping the unit rolls it
    // back, so no journal row, snapshot, saga or mutation is saved.
    let mut result = parse_kernel_output(&output)?;

    // A preview keeps nothing: the unit is rolled back and no reaction is delivered or logged.
    if effect == Effect::Preview {
        unit.rollback().await?;
        let accepted = crate::validation::accepted(&result);
        return Ok(Outcome { result, accepted });
    }

    // See journal.rs's own header: every prior step in this replay
    // already succeeded once, deterministically, so the only step that
    // can legitimately show up in `refusals` is the new one just
    // appended last.
    let accepted = classify(&result) == KernelAnswer::Accepted;

    if accepted {
        let accepted_step = Accepted {
            verb,
            args: &args,
            // The kernel's "instances" output is already the exact seed shape, so nothing here
            // re-derives or filters it.
            new_seed: result
                .get("instances")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({})),
            saga_upserts: saga_upserts(&result)?,
            saga_deletes: saga_deletes(&result, &state.sagas),
            lineage: lineage_write(&result, config)?,
        };
        // Persisted in one scope, so a saga checkpoint can never commit independently of the
        // command that produced it.
        unit.commit(accepted_step).await?;
    } else {
        // Nothing to persist; ending the scope releases the domain lock for the next invocation.
        unit.rollback().await?;
    }

    // Only this step's own matches, same reason as the lineage mutations: replaying a prior
    // step's reaction would re-invoke a sibling Lambda on every later replay. Captured before
    // commit, delivered after.
    let pending_cross_domain = result
        .get("cross_domain_reactions")
        .and_then(|r| r.as_array())
        .and_then(|steps| steps.last())
        .and_then(|last| last.as_array())
        .cloned()
        .unwrap_or_default();

    // Delivered after commit, deliberately: the local command already
    // succeeded and is durable, so a cross-Lambda notification is
    // best-effort, not a precondition of it. A fault that survives every
    // retry still fails this call via `?`, but never unwinds an
    // already-committed transaction.
    // Every reaction gets its own attempt even after an earlier fails:
    // returning early would silently drop the rest, undelivered and
    // never dead-lettered (`SafeDepositBox.Surrender` fires two from one
    // command). `first_failure` remembers only the first error without
    // cutting the loop short.
    let mut cross_domain_deliveries = Vec::new();
    let mut first_failure: Option<anyhow::Error> = None;
    for reaction in &pending_cross_domain {
        match lambda_client::deliver_with_retry(invoker, reaction).await {
            Ok(record) => {
                if let Some(response) = result.as_object_mut() {
                    if let Some(reactions) =
                        response.get_mut("reactions").and_then(|r| r.as_array_mut())
                    {
                        reactions.push(serde_json::json!({
                            "policy": record.policy, "on": reaction.get("on").and_then(|v| v.as_str()).unwrap_or_default(),
                            "trigger": record.target_verb, "delivered": record.delivered, "reason": record.reason,
                        }));
                    }
                }
                cross_domain_deliveries.push(record.to_json());
            }
            Err(failure) => {
                let error_text = format!("{:#}", failure.error);
                crate::log::error(
                    "cross_domain_delivery_failed",
                    serde_json::json!({
                        "policy": failure.policy, "target_domain": failure.target_domain,
                        "target_verb": failure.target_verb, "attempts": failure.attempts, "error": error_text,
                    }),
                );
                store
                    .record_dead_letter(&DeadLetter {
                        policy: &failure.policy,
                        target_domain: &failure.target_domain,
                        target_verb: &failure.target_verb,
                        payload: &failure.payload,
                        error: &error_text,
                        attempts: failure.attempts as i32,
                    })
                    .await?;
                if first_failure.is_none() {
                    first_failure = Some(failure.error);
                }
            }
        }
    }
    if let Some(error) = first_failure {
        return Err(error);
    }
    if let Some(response) = result.as_object_mut() {
        response.insert(
            "cross_domain_deliveries".to_string(),
            serde_json::Value::Array(cross_domain_deliveries),
        );
    }

    log_command(verb, role, accepted, &result);
    Ok(Outcome { result, accepted })
}

// A preview names the verb under `dry_run`, which the kernel answers on a copy of the world. A
// routed invocation keeps its `to` and `with` at the step's top level, where the kernel routes a
// dry run as it routes a real step; a flat one stays under `args`.
fn preview_step(verb: &str, args: &serde_json::Value) -> serde_json::Value {
    let mut step = serde_json::json!({ "dry_run": verb });
    if args.get("with").is_some() {
        for key in ["to", "with"] {
            if let Some(value) = args.get(key) {
                step[key] = value.clone();
            }
        }
    } else if let Some(to) = args.get("to").filter(|_| args.is_object()) {
        // The older mixed shape a form posts: the receiver beside the facts it names.
        let mut facts = args.clone();
        if let Some(map) = facts.as_object_mut() {
            map.remove("to");
        }
        step["to"] = to.clone();
        step["with"] = facts;
    } else {
        step["args"] = args.clone();
    }
    step
}

// The kernel's whole input: the seed, every step to replay on it, the saga rows, and the tables
// that answer a command's `needs` and `defaults`, lest a reaction's command lack a fact (ADR 0081).
fn kernel_input(
    seed: &serde_json::Value,
    steps: &[serde_json::Value],
    sagas_seed: &serde_json::Value,
) -> serde_json::Value {
    let mut input = serde_json::json!({ "seed": seed, "steps": steps, "sagas": sagas_seed });
    if let Some(domain_ir) = crate::ir::ir() {
        let table = crate::needs::table(domain_ir);
        if table.as_object().is_some_and(|t| !t.is_empty()) {
            input["needs"] = table;
        }
        let defaults = crate::needs::defaults_table(domain_ir);
        if defaults.as_object().is_some_and(|t| !t.is_empty()) {
            input["defaults"] = defaults;
        }
    }
    input
}

// A string field a saga entry must carry.
fn saga_field<'a>(entry: &'a serde_json::Value, key: &str) -> anyhow::Result<&'a str> {
    entry
        .get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("saga_snapshot entry missing \"{key}\": {entry}"))
}

// Every saga instance the kernel says is live after this step, to be upserted. A result with no
// `saga_snapshot` says nothing about sagas, so nothing is upserted (or deleted).
fn saga_upserts(result: &serde_json::Value) -> anyhow::Result<Vec<journal::SagaRow>> {
    let Some(saga_snapshot) = result.get("saga_snapshot").and_then(|v| v.as_array()) else {
        return Ok(Vec::new());
    };
    saga_snapshot
        .iter()
        .map(|entry| {
            Ok(journal::SagaRow {
                process_manager: saga_field(entry, "process_manager")?.to_string(),
                correlation: saga_field(entry, "correlation")?.to_string(),
                state: saga_field(entry, "state")?.to_string(),
                memory: entry
                    .get("memory")
                    .cloned()
                    .unwrap_or_else(|| serde_json::json!({})),
                completed_compensations: entry
                    .get("completed_compensations")
                    .cloned()
                    .unwrap_or_else(|| serde_json::json!([])),
            })
        })
        .collect()
}

// The sagas present before this step (`before`) absent from the kernel's report now: they ended.
fn saga_deletes(result: &serde_json::Value, before: &[journal::SagaRow]) -> Vec<(String, String)> {
    let Some(saga_snapshot) = result.get("saga_snapshot").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    let still_present: std::collections::HashSet<(&str, &str)> = saga_snapshot
        .iter()
        .filter_map(|entry| {
            Some((
                entry.get("process_manager")?.as_str()?,
                entry.get("correlation")?.as_str()?,
            ))
        })
        .collect();
    before
        .iter()
        .filter(|row| {
            !still_present.contains(&(row.process_manager.as_str(), row.correlation.as_str()))
        })
        .map(|row| (row.process_manager.clone(), row.correlation.clone()))
        .collect()
}

// One entry per step in `steps`, so the last entry is this call's own new step. None when
// `config.era` is `None`: a domain with nothing lineage-capable bound never provisions a
// head-snapshot table to write into (ADR 0034).
fn lineage_write<'a>(
    result: &'a serde_json::Value,
    config: &'a journal::LineageConfig,
) -> anyhow::Result<Option<LineageWrite<'a>>> {
    if config.era.is_none() {
        return Ok(None);
    }
    let step_mutations = result
        .get("mutations")
        .and_then(|m| m.as_array())
        .and_then(|steps| steps.last())
        .and_then(|last| last.as_array())
        .map_or(&[][..], Vec::as_slice);
    let mut mutations = Vec::new();
    for mutation in step_mutations {
        let aggregate = mutation_field(mutation, "aggregate")?;
        // `era.is_some()` means the lineage subsystem exists, not that this aggregate has a
        // mirror: `mint` only provisions head snapshots for the capable set, so mirroring
        // anything else would upsert into a relation nobody created.
        if !config.mirrors(aggregate) {
            continue;
        }
        mutations.push(journal::Mutation {
            aggregate,
            id: mutation_field(mutation, "id")?,
            operation: mutation_field(mutation, "operation")?,
            state: mutation
                .get("state")
                .ok_or_else(|| anyhow::anyhow!("mutation record missing \"state\": {mutation}"))?,
        });
    }
    Ok(Some(LineageWrite { config, mutations }))
}

// A string field a mutation record must carry.
fn mutation_field<'a>(mutation: &'a serde_json::Value, key: &str) -> anyhow::Result<&'a str> {
    mutation
        .get(key)
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("mutation record missing \"{key}\": {mutation}"))
}

// Answers the facts the command needs and fills its declared defaults. A value the caller supplied
// for a needed fact is kept (ADR 0081) unless the dispatch is a request from outside the host,
// which may not set the clock a time-window guard reads.
pub fn fill_arguments(
    origin: Origin,
    domain_ir: &serde_json::Value,
    verb: &str,
    args: &mut serde_json::Value,
    clock: &dyn crate::needs::Clock,
) {
    if origin == Origin::Request {
        crate::needs::answer_needs(domain_ir, verb, args, clock);
    } else {
        crate::needs::fill_needs(domain_ir, verb, args, clock);
    }
    // An argument with a declared default is filled the same way, so the journal holds it too.
    crate::needs::fill_defaults(domain_ir, verb, args);
}

// One line per dispatched command: what was asked (verb, role — never
// the facts) and what the domain answered.
fn log_command(verb: &str, role: Option<&str>, accepted: bool, result: &serde_json::Value) {
    let fields = command_fields(verb, role, accepted, result);
    if accepted {
        crate::log::info("command", fields);
    } else {
        crate::log::error("command", fields);
    }
}

pub fn command_fields(
    verb: &str,
    role: Option<&str>,
    accepted: bool,
    result: &serde_json::Value,
) -> serde_json::Value {
    let events: Vec<serde_json::Value> = result
        .get("events")
        .and_then(|v| v.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.get("name").cloned())
                .collect()
        })
        .unwrap_or_default();
    serde_json::json!({
        "verb": verb, "role": role, "accepted": accepted, "events": events,
        "refusals": result.get("refusals").cloned().unwrap_or_else(|| serde_json::json!([])),
    })
}

// Read-only: the same seed path `handle` uses, minus the new step and
// any write. No domain lock needed since nothing here writes.
// Returns the whole kernel result verbatim, not just `instances`, so a
// caller can tell an empty `refusals` from one that was never checked.
pub async fn read(store: &Store, wasm_path: &Path) -> anyhow::Result<serde_json::Value> {
    let state = store.read_state().await?;

    if let Some(s) = &state.snapshot {
        if state.steps.is_empty() {
            // No wasm invocation needed: the snapshot's seed already is
            // this domain's current "instances" output. Empty
            // events/refusals is correct too — a read reports current
            // state, never event/refusal history.
            return Ok(serde_json::json!({ "instances": s.seed, "events": [], "refusals": [] }));
        }

        // Self-healing: if steps ever go unaccounted for after the last
        // snapshot, seeding from it and replaying just the gap is
        // still correct and cheap.
        let input = serde_json::json!({ "seed": &s.seed, "steps": state.steps }).to_string();
        return run_read(wasm_path, input).await;
    }

    // No snapshot: either a brand-new domain, or one with history from
    // before this snapshot cache existed — either way, one full replay
    // catches it up.
    run_read(
        wasm_path,
        serde_json::json!({ "steps": state.steps }).to_string(),
    )
    .await
}

async fn run_read(wasm_path: &Path, input: String) -> anyhow::Result<serde_json::Value> {
    let owned_wasm_path = wasm_path.to_path_buf();
    let output =
        tokio::task::spawn_blocking(move || wasm_runner::run(&owned_wasm_path, &input)).await??;
    parse_kernel_output(&output)
}

// A declared query, answered against current state. Seeds from `read`
// rather than replaying history itself, so it sees exactly the state a
// read would report and pays at most one wasm invocation.
pub async fn query(
    store: &Store,
    wasm_path: &Path,
    question: &str,
    args: serde_json::Value,
) -> anyhow::Result<serde_json::Value> {
    // A fact the query `needs` is answered before the kernel checks its arguments (ADR 0081).
    let mut args = args;
    if let Some(domain_ir) = crate::ir::ir() {
        crate::needs::fill_query_needs(domain_ir, question, &mut args, &crate::needs::ProcessClock);
    }
    answer_query(store, wasm_path, question, args).await
}

/// `query` for a request from outside the host: every fact the query needs is the host's answer,
/// never the request's.
pub async fn query_request(
    store: &Store,
    wasm_path: &Path,
    question: &str,
    args: serde_json::Value,
) -> anyhow::Result<serde_json::Value> {
    let mut args = args;
    if let Some(domain_ir) = crate::ir::ir() {
        crate::needs::answer_query_needs(
            domain_ir,
            question,
            &mut args,
            &crate::needs::ProcessClock,
        );
    }
    answer_query(store, wasm_path, question, args).await
}

async fn answer_query(
    store: &Store,
    wasm_path: &Path,
    question: &str,
    args: serde_json::Value,
) -> anyhow::Result<serde_json::Value> {
    let state = read(store, wasm_path).await?;
    let seed = state
        .get("instances")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({}));
    let input = serde_json::json!({ "seed": seed, "steps": [{ "query": question, "args": args }] })
        .to_string();
    let owned_wasm_path = wasm_path.to_path_buf();
    let output =
        tokio::task::spawn_blocking(move || wasm_runner::run(&owned_wasm_path, &input)).await??;
    parse_kernel_output(&output)
}

/// Answers `answer` (a kernel answer already computed and persisted) in the bare shape a caller
/// reads, by one more wasm run of the kernel's `{"present": answer}` input: each single-field
/// value object as its sole field. Nothing is stored or replayed.
pub async fn present(
    wasm_path: &Path,
    answer: serde_json::Value,
) -> anyhow::Result<serde_json::Value> {
    let owned_wasm_path = wasm_path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        present_with(&answer, |input| wasm_runner::run(&owned_wasm_path, input))
    })
    .await?
}

/// Presents `answer` as `present` does, with `run` standing in for the kernel (text in, text out).
pub fn present_with(
    answer: &serde_json::Value,
    run: impl FnOnce(&str) -> anyhow::Result<String>,
) -> anyhow::Result<serde_json::Value> {
    let input = serde_json::json!({ "present": answer }).to_string();
    parse_kernel_output(&run(&input)?)
}
