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

impl<'a> Caller<'a> {
    /// The caller a signed-in session dispatches as: the role it carries and the identity
    /// Governance holds assignments for. No session is an unidentified caller.
    pub fn signed_in(session: Option<&'a crate::auth::Session>) -> Self {
        session.map_or_else(Self::default, |session| Self {
            role: session.role.as_deref(),
            actor_id: Some(session.identity_id.as_str()).filter(|id| !id.is_empty()),
        })
    }
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

impl Enforcement {
    /// Reads `off` (the default), `shadow` or `enforce`; anything else is `Off`.
    pub fn parse(value: Option<&str>) -> Self {
        match value.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
            Some("shadow") => Self::Shadow,
            Some("enforce") => Self::Enforce,
            _ => Self::Off,
        }
    }

    pub fn from_env() -> Self {
        static MODE: std::sync::OnceLock<Enforcement> = std::sync::OnceLock::new();
        *MODE.get_or_init(|| Self::parse(std::env::var("HECKS_ROLE_ENFORCEMENT").ok().as_deref()))
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
#[derive(Clone, Copy, Debug, PartialEq)]
enum Origin {
    /// A caller the host's internal protocol names, from one of its own peers.
    External,
    /// A signed-in request to the console API or the web UI. Its caller is checked as an
    /// `External` one is, and every fact its command needs is the host's answer, never the
    /// request's.
    Request,
    HostInternal,
}

/// Whether the kernel refused the command for the caller's role.
fn refused_for_role(result: &serde_json::Value) -> bool {
    result
        .get("refusals")
        .and_then(|r| r.as_array())
        .is_some_and(|all| {
            all.iter()
                .any(|r| r.get("kind").and_then(|k| k.as_str()) == Some("Unauthorized"))
        })
}

// Distinguishes a module refusal from a kernel failure to run at all.
#[derive(Debug, PartialEq)]
enum KernelAnswer {
    Accepted,
    Refused,
    Failed(String),
}

// A run that never started has no `refusals` array at all, so absence of
// refusals doesn't by itself mean the run succeeded.
fn classify(result: &serde_json::Value) -> KernelAnswer {
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
fn parse_kernel_output(output: &str) -> anyhow::Result<serde_json::Value> {
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
        Enforcement::from_env(),
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
        Enforcement::from_env(),
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
        Enforcement::from_env(),
        Origin::External,
        host,
        verb,
        args,
        caller,
    )
    .await
}

async fn dispatch_in(
    mode: Enforcement,
    origin: Origin,
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
    let outcome = run(origin, host, verb, args.clone(), checked).await?;
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
        return run(origin, host, verb, args, Caller::default()).await;
    }
    Ok(outcome)
}

async fn run(
    origin: Origin,
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
    let mut step = serde_json::json!({ "verb": verb, "args": args.clone() });
    if let Some(role) = role {
        step["role"] = serde_json::Value::String(role.to_string());
    }
    if let Some(actor_id) = caller.actor_id {
        step["actor_id"] = serde_json::Value::String(actor_id.to_string());
    }
    // Stamped only on this live step. The journal keeps a command's verb and arguments alone, so a
    // replayed step carries no role, actor or timestamp of its own.
    step["occurred_at"] = serde_json::Value::String(crate::auth::httpdate_now());
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
fn fill_arguments(
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

fn command_fields(
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
pub(crate) fn present_with(
    answer: &serde_json::Value,
    run: impl FnOnce(&str) -> anyhow::Result<String>,
) -> anyhow::Result<serde_json::Value> {
    let input = serde_json::json!({ "present": answer }).to_string();
    parse_kernel_output(&run(&input)?)
}

#[cfg(test)]
pub(crate) mod tests {

    #[test]
    fn a_command_log_line_names_the_verb_events_and_refusals_but_never_the_facts() {
        let result = serde_json::json!({
            "events": [{"name": "Registered", "data": {"email": "a@b.c"}}],
            "refusals": [{"verb": "X.Y", "error": "already exists", "kind": "AlreadyExists"}],
        });
        let fields = command_fields("Register", Some("admin"), false, &result);
        assert_eq!(fields["verb"], "Register");
        assert_eq!(fields["role"], "admin");
        assert_eq!(fields["accepted"], false);
        assert_eq!(fields["events"], serde_json::json!(["Registered"]));
        assert_eq!(fields["refusals"][0]["kind"], "AlreadyExists");
        assert!(!fields.to_string().contains("a@b.c"));
    }
    use super::*;
    use crate::journal::LineageConfig;
    use crate::lambda_client::LambdaInvoker;
    use tokio_postgres::{Client, NoTls};

    // A throwaway Postgres database per test, uniquely named so
    // `cargo test`'s default parallelism doesn't race two tests against
    // the same journal table.
    pub(crate) async fn scratch_db(name: &str) -> Store {
        let (admin, conn) = tokio_postgres::connect(&crate::test_pg::conninfo("postgres"), NoTls)
            .await
            .expect("connect to postgres");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        admin
            .batch_execute(&format!("DROP DATABASE IF EXISTS {name} WITH (FORCE)"))
            .await
            .unwrap();
        admin
            .batch_execute(&format!("CREATE DATABASE {name}"))
            .await
            .unwrap();

        let (client, conn) = tokio_postgres::connect(&crate::test_pg::conninfo(name), NoTls)
            .await
            .expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        journal::ensure_schema(&client).await.unwrap();
        Store::postgres(client)
    }

    /// An empty in-memory store, for tests that need a journal and nothing Postgres-specific.
    pub(crate) fn memory_store() -> Store {
        Store::memory(crate::store::MemoryStore::new())
    }

    /// The config a memory-backed host runs under: no era, so nothing mirrors into lineage.
    pub(crate) fn memory_config(domain: &str) -> LineageConfig {
        LineageConfig {
            domain: domain.to_string(),
            era: None,
            mirrored: None,
        }
    }

    // Not Ruby's real provisioning — just enough structure for
    // `journal::current_era` and `append_lineage_mutation` to succeed,
    // without reproducing Ruby's full DDL.
    pub(crate) async fn provision_lineage(
        client: &Client,
        domain: &str,
        era: i32,
        aggregate_storage_names: &[&str],
    ) {
        // `int`, matching Ruby's real DDL: tokio_postgres requires the
        // Rust and Postgres types to match, not just be compatible.
        client
            .batch_execute(
                "CREATE TABLE IF NOT EXISTS hecks_eras (domain text, ordinal int, held_text text)",
            )
            .await
            .unwrap();
        client
            .execute(
                "INSERT INTO hecks_eras (domain, ordinal, held_text) VALUES ($1, $2, 'test')",
                &[&domain, &era],
            )
            .await
            .unwrap();

        let journal_table = format!("hecks_journal_{}", journal::snake(domain));
        client
            .batch_execute(&format!(
                "CREATE TABLE IF NOT EXISTS \"{journal_table}\" (
                    ordinal      bigserial PRIMARY KEY,
                    era          int NOT NULL,
                    aggregate    text NOT NULL,
                    aggregate_id text NOT NULL,
                    operation    text NOT NULL,
                    state        jsonb
                )"
            ))
            .await
            .unwrap();

        for name in aggregate_storage_names {
            // Domain-qualified (ADR 0059), matching what a real write
            // targets.
            let snapshot_table = journal::qualified_name(
                domain,
                &format!("{}_head_snapshot_{era}", journal::snake(name)),
            );
            client
                .batch_execute(&format!(
                    "CREATE TABLE IF NOT EXISTS \"{snapshot_table}\" (id text PRIMARY KEY, ordinal bigint NOT NULL, \
                     operation text NOT NULL DEFAULT 'save', state jsonb)"
                ))
                .await
                .unwrap();
        }
    }

    // Pins a real outage: `era.is_some()` (lineage exists) and "this
    // aggregate has a mirror" are different questions. Under ADR 0034 an
    // aggregate outside the declared capable set has no head snapshot to
    // upsert into.
    #[tokio::test]
    async fn a_domain_whose_ir_declares_nothing_lineage_capable_mirrors_nothing_and_still_writes() {
        let client = scratch_db("rust_host_mirrors_nothing").await;
        {
            let guard = client.lock().await;
            // No head snapshot for Customer, as `mint` leaves an empty
            // capable set.
            guard.batch_execute("CREATE TABLE IF NOT EXISTS hecks_eras (domain text, ordinal int, held_text text)").await.unwrap();
            guard.execute("INSERT INTO hecks_eras (domain, ordinal, held_text) VALUES ('Banking', 1, 'test')", &[]).await.unwrap();
            guard
                .batch_execute(
                    "CREATE TABLE IF NOT EXISTS hecks_journal_banking (ordinal bigserial PRIMARY KEY, era int NOT NULL, \
                     aggregate text NOT NULL, aggregate_id text NOT NULL, operation text NOT NULL, state jsonb)",
                )
                .await
                .unwrap();
        }
        let wasm = wasm_path();
        let invoker = crate::lambda_client::NeverInvoker;
        let open = register("CUST-1");

        // Mirroring everything is the outage: no head snapshot exists to
        // upsert into.
        let everything = LineageConfig {
            domain: "Banking".to_string(),
            era: Some(1),
            mirrored: None,
        };
        let refused = handle_facts(
            Host::new(&client, &wasm, &everything, &invoker),
            "Banking::Customer.Register",
            open.clone(),
            None,
        )
        .await;
        let message = match refused {
            Ok(_) => panic!("expected the missing-relation failure"),
            Err(e) => format!("{e:#}"),
        };
        assert!(
            message.contains("banking_customer_head_snapshot_1"),
            "names the relation it could not write: {message}"
        );
        assert!(
            message.contains("does not exist"),
            "carries the database's own words: {message}"
        );
        assert!(
            message.contains("Banking::Customer"),
            "names the record: {message}"
        );

        // Mirroring what the IR actually declares — nothing — writes
        // cleanly, into this crate's own journal.
        let declared = LineageConfig {
            domain: "Banking".to_string(),
            era: Some(1),
            mirrored: Some(std::collections::BTreeSet::new()),
        };
        let outcome = handle_facts(
            Host::new(&client, &wasm, &declared, &invoker),
            "Banking::Customer.Register",
            open,
            None,
        )
        .await
        .expect("writes");
        assert!(outcome.accepted, "{}", outcome.result);

        let guard = client.lock().await;
        let journalled: i64 = guard
            .query_one("SELECT count(*) FROM hecks_lambda_journal", &[])
            .await
            .unwrap()
            .get(0);
        assert_eq!(
            journalled, 1,
            "durable in this crate's own journal, which is what `read` replays"
        );
        let mirror: Option<String> = guard
            .query_one(
                "SELECT to_regclass('banking_customer_head_snapshot_1')::text",
                &[],
            )
            .await
            .unwrap()
            .get(0);
        assert!(
            mirror.is_none(),
            "and no mirror was invented for an aggregate the IR never called capable"
        );
    }

    // The other half: an aggregate the IR does call capable is still
    // mirrored.
    #[tokio::test]
    async fn an_aggregate_the_ir_declares_capable_is_still_mirrored() {
        let client = scratch_db("rust_host_mirrors_the_capable_one").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = LineageConfig {
            domain: "Banking".to_string(),
            era: Some(1),
            mirrored: Some(std::iter::once("Banking::Customer".to_string()).collect()),
        };

        handle_facts(
            Host::new(
                &client,
                &wasm_path(),
                &config,
                &crate::lambda_client::NeverInvoker,
            ),
            "Banking::Customer.Register",
            register("CUST-2"),
            None,
        )
        .await
        .expect("writes");

        let guard = client.lock().await;
        let mirrored: i64 = guard
            .query_one("SELECT count(*) FROM banking_customer_head_snapshot_1", &[])
            .await
            .unwrap()
            .get(0);
        assert_eq!(mirrored, 1);
    }

    pub(crate) fn test_config(domain: &str, era: i32) -> LineageConfig {
        LineageConfig {
            domain: domain.to_string(),
            era: Some(era),
            mirrored: None,
        }
    }

    #[test]
    fn present_hands_the_kernel_the_answer_under_present_and_answers_what_it_returns() {
        let answer = serde_json::json!({"instances": {"Shop::Item#a": {"name": {"value": "x"}}}});
        let mut sent = String::new();
        let presented = present_with(&answer, |input| {
            sent = input.to_string();
            Ok(r#"{"instances":{"Shop::Item#a":{"name":"x"}}}"#.to_string())
        })
        .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&sent).unwrap(),
            serde_json::json!({ "present": answer })
        );
        assert_eq!(presented["instances"]["Shop::Item#a"]["name"], "x");
    }

    #[test]
    fn present_is_an_error_when_the_kernel_fails() {
        let failed = present_with(&serde_json::json!({}), |_| {
            Ok(r#"{"error":"expected a top-level {\"steps\": [...]} object"}"#.to_string())
        });
        assert!(failed.is_err());
    }

    pub(crate) fn wasm_path() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/banking.wasm")
    }

    pub(crate) fn register(reference: &str) -> serde_json::Value {
        serde_json::json!({
            "reference": { "value": reference },
            "name": { "given": "Ada", "family": "Lovelace" },
            "email": { "address": "ada@example.com" }
        })
    }

    // `query` end to end through the real compiled kernel: a declared
    // query answered against whatever state the journal currently holds.
    #[tokio::test]
    async fn a_declared_query_answers_against_current_state() {
        let client = crate::dispatch::tests::memory_store();
        let config = crate::dispatch::tests::memory_config("Banking");

        handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0100"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registering a customer should succeed");

        // `Customer.Suspended` is `where status == "suspended"` — a
        // freshly registered customer is active, so the query has to
        // answer with a real, empty row set, not everything.
        let before = query(
            &client,
            &wasm_path(),
            "Banking::Customer.Suspended",
            serde_json::json!({}),
        )
        .await
        .unwrap();
        assert_eq!(before["queries"][0]["query"], "Banking::Customer.Suspended");
        assert_eq!(
            before["queries"][0]["rows"].as_array().expect("rows").len(),
            0
        );

        handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Suspend",
            serde_json::json!({ "reference": "CUST-0100", "standing": { "value": "watch" } }),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("suspending a customer should succeed");

        let after = query(
            &client,
            &wasm_path(),
            "Banking::Customer.Suspended",
            serde_json::json!({}),
        )
        .await
        .unwrap();
        let rows = after["queries"][0]["rows"].as_array().expect("rows");
        assert_eq!(
            rows.len(),
            1,
            "the suspended customer should be the one row: {after}"
        );
        assert_eq!(rows[0]["id"], "CUST-0100");
    }

    #[tokio::test]
    async fn accepts_and_persists_a_first_command() {
        let client = scratch_db("rust_host_dispatch_test_1").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;

        let outcome = handle(
            Host::new(
                &client,
                &wasm_path(),
                &test_config("Banking", 1),
                &lambda_client::NeverInvoker,
            ),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
        )
        .await
        .unwrap();

        assert!(outcome.accepted);
        assert_eq!(outcome.result["refusals"].as_array().unwrap().len(), 0);
        let guard = client.lock().await;
        let steps = journal::load_steps(&*guard).await.unwrap();
        assert_eq!(steps.len(), 1);

        // The lineage write itself: a row landed in the era-tagged,
        // storage-name-keyed journal shape, not just the flat log above.
        let journal_rows = guard
            .query(
                "SELECT era, aggregate, aggregate_id, operation FROM hecks_journal_banking",
                &[],
            )
            .await
            .unwrap();
        assert_eq!(journal_rows.len(), 1);
        let row = &journal_rows[0];
        let era: i32 = row.get(0);
        let aggregate: String = row.get(1);
        let aggregate_id: String = row.get(2);
        let operation: String = row.get(3);
        assert_eq!(
            (
                era,
                aggregate.as_str(),
                aggregate_id.as_str(),
                operation.as_str()
            ),
            (1, "customer", "CUST-0001", "save")
        );

        // domain-qualified (docs/decisions/0059) — snake("Banking") == "banking".
        let snapshot_rows = guard
            .query("SELECT id FROM banking_customer_head_snapshot_1", &[])
            .await
            .unwrap();
        assert_eq!(
            snapshot_rows.len(),
            1,
            "the head-snapshot table should carry exactly the one live record"
        );
        let id: String = snapshot_rows[0].get(0);
        assert_eq!(id, "CUST-0001");
    }

    // Proves `occurred_at` end to end through the real wasm module: the
    // string this crate stamps and sends is the one that comes back out
    // in the returned event, not just what the in-kernel unit tests prove.
    #[tokio::test]
    async fn occurred_at_is_stamped_onto_every_returned_event_with_this_crate_s_own_real_clock() {
        let client = crate::dispatch::tests::memory_store();

        let before = crate::auth::httpdate_now();
        let outcome = handle(
            Host::new(
                &client,
                &wasm_path(),
                &crate::dispatch::tests::memory_config("Banking"),
                &lambda_client::NeverInvoker,
            ),
            "Banking::Customer.Register",
            register("CUST-OCCURRED-AT"),
            None,
        )
        .await
        .unwrap();
        let after = crate::auth::httpdate_now();

        assert!(outcome.accepted, "{:?}", outcome.result["refusals"]);
        let events = outcome.result["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        let occurred_at = events[0]["occurred_at"]
            .as_str()
            .expect("occurred_at should be a real string, not null or absent");
        // Lexical comparison is valid: this format's digit-then-letter
        // layout sorts identically to chronological order for stamps
        // less than 10,000 years apart.
        assert!(
            occurred_at >= before.as_str() && occurred_at <= after.as_str(),
            "{occurred_at} should fall between {before} and {after}"
        );
    }

    #[tokio::test]
    async fn rehydrates_prior_history_before_evaluating_the_new_command() {
        let client = crate::dispatch::tests::memory_store();
        let config = crate::dispatch::tests::memory_config("Banking");

        let first = handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
        )
        .await
        .unwrap();
        assert!(
            first.accepted,
            "first registration should succeed: {:?}",
            first.result
        );

        // Proves rehydration happened, not just that two calls each
        // succeeded independently: the second registration only refuses
        // if the first's effect was genuinely rebuilt from Postgres.
        let second = handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
        )
        .await
        .unwrap();

        assert!(
            !second.accepted,
            "duplicate registration should be refused, proving prior state was rehydrated: {:?}",
            second.result
        );
        let steps = client.journal_steps().await;
        assert_eq!(
            steps.len(),
            1,
            "the refused duplicate must not be persisted"
        );
    }

    #[tokio::test]
    async fn the_snapshot_stays_current_so_nothing_replays_full_history() {
        // Direct proof (vs. the duplicate-refusal side effect above):
        // after every accepted command, replaying past the snapshot's
        // ordinal should find nothing left to replay.
        let client = scratch_db("rust_host_dispatch_test_5").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);

        for reference in ["CUST-0004", "CUST-0005", "CUST-0006"] {
            let outcome = handle(
                Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
                "Banking::Customer.Register",
                register(reference),
                None,
            )
            .await
            .unwrap();
            assert!(
                outcome.accepted,
                "registering {reference} should succeed: {:?}",
                outcome.result
            );

            let guard = client.lock().await;
            let snapshot = journal::load_snapshot(&*guard)
                .await
                .unwrap()
                .expect("a snapshot should exist after the first accepted command");
            let tail = journal::load_steps_after(&*guard, snapshot.ordinal)
                .await
                .unwrap();
            assert!(tail.is_empty(), "the snapshot should already reflect every accepted command, leaving nothing to replay");

            // And the seed is right, not just non-empty: it should carry
            // every customer registered so far, not just this one.
            let seeded = snapshot.seed.as_object().unwrap();
            assert!(
                seeded.keys().any(|k| k.contains(reference)),
                "the snapshot should carry the record just dispatched: {seeded:?}"
            );
        }

        let final_snapshot = journal::load_snapshot(&*client.lock().await)
            .await
            .unwrap()
            .unwrap();
        let final_seed = final_snapshot.seed.as_object().unwrap();
        assert_eq!(final_seed.len(), 3, "the snapshot should accumulate all three registrations, not just the latest: {final_seed:?}");
    }

    #[test]
    fn a_top_level_error_is_a_kernel_failure_and_nothing_else_is() {
        let failed = serde_json::json!({"error": "invalid seed: Registration.status: missing from JSON args"});
        assert_eq!(
            classify(&failed),
            KernelAnswer::Failed(
                "invalid seed: Registration.status: missing from JSON args".to_string()
            )
        );
        assert_eq!(
            classify(&serde_json::json!({"error": {"code": 7}})),
            KernelAnswer::Failed("{\"code\":7}".to_string()),
            "a non-text error is still a failure"
        );

        let accepted = serde_json::json!({"instances": {}, "events": [], "refusals": []});
        assert_eq!(classify(&accepted), KernelAnswer::Accepted);

        // A refusal carries its own nested `error`; that is the module deciding,
        // not the kernel failing.
        let refused = serde_json::json!({
            "instances": {}, "events": [],
            "refusals": [{"verb": "Banking::Customer.Register", "error": "already exists", "kind": "AlreadyExists"}]
        });
        assert_eq!(classify(&refused), KernelAnswer::Refused);

        // A run whose query step failed reports it inside `queries`, still a finished run.
        let query_error = serde_json::json!({"instances": {}, "refusals": [], "queries": [{"query": "X", "rows": null, "error": "no such query"}]});
        assert_eq!(classify(&query_error), KernelAnswer::Accepted);
    }

    #[test]
    fn parse_kernel_output_turns_a_failure_into_an_error_and_keeps_refusals_as_results() {
        let error = parse_kernel_output(
            r#"{"error":"invalid seed: Customer.status: missing from JSON args"}"#,
        )
        .unwrap_err();
        assert!(
            format!("{error:#}").contains("invalid seed: Customer.status: missing from JSON args"),
            "{error:#}"
        );
        let refused = parse_kernel_output(
            r#"{"instances":{},"refusals":[{"verb":"v","error":"no","kind":"K"}]}"#,
        )
        .unwrap();
        assert_eq!(classify(&refused), KernelAnswer::Refused);
        assert!(parse_kernel_output("not json").is_err());
    }

    #[tokio::test]
    async fn a_kernel_failure_is_an_error_and_writes_nothing() {
        // Simulates a snapshot missing a field its shape now requires.
        // The kernel refuses to load it; this must fail the call and
        // leave the journal and snapshot untouched.
        let client = scratch_db("rust_host_dispatch_kernel_failure").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);
        let noinvoke = lambda_client::NeverInvoker;

        let first = handle(
            Host::new(&client, &wasm_path(), &config, &noinvoke),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
        )
        .await
        .unwrap();
        assert!(first.accepted, "{:?}", first.result);

        let whole_world = journal::load_snapshot(&*client.lock().await)
            .await
            .unwrap()
            .unwrap()
            .seed;
        let mut damaged = whole_world.clone();
        let customer = damaged
            .as_object_mut()
            .unwrap()
            .values_mut()
            .next()
            .unwrap()
            .as_object_mut()
            .unwrap();
        assert!(
            customer.remove("status").is_some(),
            "the fixture Customer carries a status"
        );
        client
            .lock()
            .await
            .execute("UPDATE hecks_lambda_snapshot SET seed = $1", &[&damaged])
            .await
            .unwrap();

        let before = snapshot_and_journal(&client).await;
        let failure = handle(
            Host::new(&client, &wasm_path(), &config, &noinvoke),
            "Banking::Customer.Register",
            register("CUST-0002"),
            None,
        )
        .await;
        let message = format!(
            "{:#}",
            failure
                .err()
                .expect("a kernel failure must be an error, not an accepted outcome")
        );
        assert!(
            message.contains("invalid seed") && message.contains("status"),
            "{message}"
        );

        assert_eq!(
            snapshot_and_journal(&client).await,
            before,
            "the failed command left the journal and the snapshot byte-identical"
        );
        assert_eq!(before.2, 1, "and only the first command was ever journaled");
        let lineage_rows: i64 = client
            .lock()
            .await
            .query_one("SELECT count(*) FROM hecks_journal_banking", &[])
            .await
            .unwrap()
            .get(0);
        assert_eq!(
            lineage_rows, 1,
            "nothing was mirrored into the era journal either"
        );

        // A read that must run the kernel over the damaged snapshot fails
        // the same way, instead of answering an empty world.
        client
            .lock()
            .await
            .execute(
                "INSERT INTO hecks_lambda_journal (verb, args) VALUES ($1, $2)",
                &[&"Banking::Customer.Register", &register("CUST-0009")],
            )
            .await
            .unwrap();
        let read_failure = read(&client, &wasm_path())
            .await
            .expect_err("a kernel failure is not an empty read");
        assert!(
            format!("{read_failure:#}").contains("invalid seed"),
            "{read_failure:#}"
        );
        let query_failure = query(
            &client,
            &wasm_path(),
            "Banking::Customer.Suspended",
            serde_json::json!({}),
        )
        .await
        .err();
        assert!(query_failure.is_some_and(|e| format!("{e:#}").contains("invalid seed")));
        client.lock().await.execute("DELETE FROM hecks_lambda_journal WHERE verb = 'Banking::Customer.Register' AND ordinal > 1", &[]).await.unwrap();

        // Once the snapshot is whole again the next command works, and the
        // snapshot afterwards holds the whole world, not just its own instance.
        client
            .lock()
            .await
            .execute(
                "UPDATE hecks_lambda_snapshot SET seed = $1",
                &[&whole_world],
            )
            .await
            .unwrap();
        let second = handle(
            Host::new(&client, &wasm_path(), &config, &noinvoke),
            "Banking::Customer.Register",
            register("CUST-0002"),
            None,
        )
        .await
        .unwrap();
        assert!(second.accepted, "{:?}", second.result);
        let after = journal::load_snapshot(&*client.lock().await)
            .await
            .unwrap()
            .unwrap()
            .seed;
        let keys: Vec<&String> = after.as_object().unwrap().keys().collect();
        assert_eq!(keys.len(), 2, "the snapshot holds both customers: {keys:?}");
        assert!(
            keys.iter().any(|k| k.contains("CUST-0001"))
                && keys.iter().any(|k| k.contains("CUST-0002")),
            "{keys:?}"
        );
    }

    // The snapshot's ordinal and exact seed text, and how many commands are journaled.
    async fn snapshot_and_journal(client: &Store) -> (i64, String, i64) {
        let guard = client.lock().await;
        let snapshot = guard
            .query_one("SELECT ordinal, seed::text FROM hecks_lambda_snapshot", &[])
            .await
            .unwrap();
        let journaled: i64 = guard
            .query_one("SELECT count(*) FROM hecks_lambda_journal", &[])
            .await
            .unwrap()
            .get(0);
        (snapshot.get(0), snapshot.get(1), journaled)
    }

    #[tokio::test]
    async fn serializes_concurrent_invocations_against_the_same_journal() {
        // **The race the advisory lock closes**: without it, two concurrent
        // registrations of the same reference could both rehydrate
        // against zero prior steps, both see no conflict, and both get
        // appended — silently violating the uniqueness the domain
        // itself enforces. With the lock serializing the whole
        // read-then-append sequence, exactly one must be accepted.
        let client = crate::dispatch::tests::memory_store();
        let config = crate::dispatch::tests::memory_config("Banking");
        let wasm_path = wasm_path();

        let (first, second) = tokio::join!(
            handle(
                Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
                "Banking::Customer.Register",
                register("CUST-0002"),
                None
            ),
            handle(
                Host::new(&client, &wasm_path, &config, &lambda_client::NeverInvoker),
                "Banking::Customer.Register",
                register("CUST-0002"),
                None
            ),
        );
        let (first, second) = (first.unwrap(), second.unwrap());

        assert_ne!(
            first.accepted, second.accepted,
            "exactly one of two concurrent duplicate registrations should be accepted: {:?} / {:?}",
            first.result, second.result
        );
        let steps = client.journal_steps().await;
        assert_eq!(
            steps.len(),
            1,
            "only the accepted registration should be persisted"
        );
    }

    #[tokio::test]
    async fn read_reflects_prior_dispatches_without_persisting_anything_new() {
        let client = crate::dispatch::tests::memory_store();

        handle(
            Host::new(
                &client,
                &wasm_path(),
                &crate::dispatch::tests::memory_config("Banking"),
                &lambda_client::NeverInvoker,
            ),
            "Banking::Customer.Register",
            register("CUST-0003"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let result = read(&client, &wasm_path()).await.unwrap();

        assert!(
            result["refusals"].as_array().unwrap().is_empty(),
            "a read replaying only already-accepted history should never refuse: {result:?}"
        );
        let instances = result["instances"].as_object().unwrap();
        assert!(
            instances.keys().any(|k| k.contains("CUST-0003")),
            "read should reflect the prior dispatch: {instances:?}"
        );

        // The sharp proof a read never appends: the journal is exactly
        // as long after the read as it was before it.
        let steps = client.journal_steps().await;
        assert_eq!(steps.len(), 1, "a read must never persist a journal row");
    }

    // Records every call and answers with a canned "nothing refused"
    // body, proving a cross-domain policy reaches `lambda_client::deliver`
    // with the right name/payload end to end, short of a real AWS Lambda.
    pub(crate) struct RecordingInvoker {
        calls: std::sync::Mutex<Vec<(String, String)>>,
    }

    impl RecordingInvoker {
        pub(crate) fn new() -> Self {
            Self {
                calls: std::sync::Mutex::new(Vec::new()),
            }
        }
    }

    #[async_trait::async_trait]
    impl LambdaInvoker for RecordingInvoker {
        async fn invoke(
            &self,
            function_name: &str,
            payload: &str,
        ) -> anyhow::Result<lambda_client::InvokeOutcome> {
            self.calls
                .lock()
                .unwrap()
                .push((function_name.to_string(), payload.to_string()));
            Ok(lambda_client::InvokeOutcome {
                body: serde_json::json!({ "refusals": [] }),
                function_error: false,
            })
        }
    }

    #[tokio::test]
    async fn a_cross_domain_policy_delivers_through_the_real_rehydrate_replay_path() {
        let client = crate::dispatch::tests::memory_store();
        let config = crate::dispatch::tests::memory_config("Banking");
        let invoker = RecordingInvoker::new();

        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0007"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let open_args = serde_json::json!({
            "number": { "value": "acct-freeze-me" },
            "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 },
            "customer": "CUST-0007",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.Open",
            open_args,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("account open should succeed");

        // `FreezeAccount` announces `AccountFrozen`, matched by
        // `ReviewOnFreeze` (`across "Compliance"`) — the real trigger
        // this feature exists for.
        let freeze_args = serde_json::json!({ "number": { "value": "acct-freeze-me" } });
        let outcome = handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.FreezeAccount",
            freeze_args,
            None,
        )
        .await
        .unwrap();
        assert!(
            outcome.accepted,
            "freeze should succeed: {:?}",
            outcome.result
        );

        let deliveries = outcome.result["cross_domain_deliveries"]
            .as_array()
            .unwrap();
        assert_eq!(
            deliveries.len(),
            1,
            "exactly one cross-domain reaction should have fired: {deliveries:?}"
        );
        assert_eq!(deliveries[0]["policy"], "ReviewOnFreeze");
        assert_eq!(deliveries[0]["target_domain"], "Compliance");
        assert_eq!(deliveries[0]["delivered"], true);

        // The same delivery also merges into "reactions"
        // ({policy, on, trigger, delivered, reason}), alongside the
        // differently-shaped "cross_domain_deliveries" entry above.
        let reactions = outcome.result["reactions"].as_array().unwrap();
        let merged = reactions
            .iter()
            .find(|r| r["policy"] == "ReviewOnFreeze")
            .expect("ReviewOnFreeze should appear in \"reactions\" too");
        assert_eq!(merged["on"], "AccountFrozen");
        assert_eq!(merged["trigger"], "Compliance::AccountFreezeReview.Open");
        assert_eq!(merged["delivered"], true);

        {
            let calls = invoker.calls.lock().unwrap();
            assert_eq!(calls.len(), 1);
            let (function_name, payload) = &calls[0];
            assert_eq!(function_name, "hecks-compliance");
            let sent: serde_json::Value = serde_json::from_str(payload).unwrap();
            // Fully qualified, not the bare "Compliance.OpenReview":
            // generated match arms are always "Domain::Aggregate.Command",
            // and Compliance's own aggregate is named `AccountFreezeReview`.
            assert_eq!(sent["verb"], "Compliance::AccountFreezeReview.Open");
            assert_eq!(sent["args"]["number"]["value"], "acct-freeze-me");
        }

        // Never re-delivered on a later replay: `pending_cross_domain`
        // only ever reads the last step's own reactions, so rehydrating
        // history here doesn't re-invoke the sibling Lambda.
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0008"),
            None,
        )
        .await
        .unwrap();
        assert_eq!(
            invoker.calls.lock().unwrap().len(),
            1,
            "replaying prior history must not re-deliver its cross-domain reaction"
        );
    }

    // Pins the fix: this is the first test that reaches `check_role`
    // with a caller role actually bound and checked, not the unchecked
    // "no role at all" path every other test in this file uses.
    // `Register` requires `Some("Branch clerk")` in the generated
    // registry — real, corpus-declared.
    #[tokio::test]
    async fn a_role_gated_command_is_actually_checked_against_the_caller_role() {
        let client = crate::dispatch::tests::memory_store();
        let config = crate::dispatch::tests::memory_config("Banking");

        // The correct role succeeds, same as every other registration,
        // just now with a caller actually bound and matching.
        let matching = handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0009"),
            Some("Branch clerk"),
        )
        .await
        .unwrap();
        assert!(
            matching.accepted,
            "the declared role should be admitted: {:?}",
            matching.result
        );

        // The actual proof: with role genuinely threaded through, a
        // caller stating the wrong role must be refused, not silently
        // admitted via the unchecked no-role path.
        let mismatched = handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0010"),
            Some("Teller"),
        )
        .await
        .unwrap();
        assert!(
            !mismatched.accepted,
            "a caller stating the wrong role must be refused, not silently admitted: {:?}",
            mismatched.result
        );
        let refusals = mismatched.result["refusals"].as_array().unwrap();
        assert_eq!(refusals.len(), 1);
        let error = refusals[0]["error"].as_str().unwrap();
        assert!(
            error.contains("Branch clerk") && error.contains("Teller"),
            "the refusal should name both the declared role and the caller's mismatched one \
             (`check_role`'s own message shape): {refusals:?}"
        );

        // And the refused command was never persisted — same discipline
        // every other refusal in this file is held to.
        let steps = client.journal_steps().await;
        assert_eq!(
            steps.len(),
            1,
            "only the correctly-authorized registration should be persisted"
        );
    }

    // ADR 0081 keeps a needed fact the caller supplied, but only the host and its peers may: a
    // request's `now` would move a time-window guard.
    #[test]
    fn only_a_request_from_outside_the_host_has_its_needed_facts_replaced() {
        let ir = serde_json::json!({"name": "Lease", "aggregates": [{"name": "Slot", "commands": [
            {"name": "Take", "attributes": [{"name": "now", "type": "Integer"}],
             "needs": [{"fact": "now"}]}
        ]}]});
        let fill = |origin: Origin| {
            let mut args = serde_json::json!({"with": {"now": 42}});
            let clock = crate::needs::FixedClock(7);
            fill_arguments(origin, &ir, "Lease::Slot.Take", &mut args, &clock);
            args["with"]["now"].clone()
        };
        assert_eq!(fill(Origin::Request), serde_json::json!(7));
        assert_eq!(fill(Origin::External), serde_json::json!(42));
        assert_eq!(fill(Origin::HostInternal), serde_json::json!(42));
    }

    #[test]
    fn enforcement_reads_off_shadow_and_enforce_and_treats_anything_else_as_off() {
        assert_eq!(Enforcement::parse(None), Enforcement::Off);
        assert_eq!(Enforcement::parse(Some("")), Enforcement::Off);
        assert_eq!(Enforcement::parse(Some("nonsense")), Enforcement::Off);
        assert_eq!(Enforcement::parse(Some("Shadow")), Enforcement::Shadow);
        assert_eq!(Enforcement::parse(Some(" enforce ")), Enforcement::Enforce);
    }

    #[test]
    fn only_an_unidentified_caller_becomes_anonymous_and_only_when_roles_are_checked() {
        let nobody = Caller::default();
        assert_eq!(Enforcement::Off.effective(nobody), nobody);
        for mode in [Enforcement::Shadow, Enforcement::Enforce] {
            assert_eq!(mode.effective(nobody).role, Some(ANONYMOUS_ROLE));
            let stated = Caller {
                role: Some("Teller"),
                actor_id: None,
            };
            assert_eq!(mode.effective(stated), stated, "a stated role is kept");
            let identified = Caller {
                role: None,
                actor_id: Some("u1"),
            };
            assert_eq!(
                mode.effective(identified),
                identified,
                "an identified caller is kept"
            );
        }
    }

    // The unidentified caller is the case the host never refused: no role at all.
    #[tokio::test]
    async fn an_unidentified_caller_is_refused_when_enforced_and_let_through_when_off_or_shadowed()
    {
        let client = crate::dispatch::tests::memory_store();
        let config = crate::dispatch::tests::memory_config("Banking");
        let go = |mode: Enforcement, id: &'static str| {
            let client = &client;
            let config = &config;
            async move {
                dispatch_in(
                    mode,
                    Origin::External,
                    Host::new(client, &wasm_path(), config, &lambda_client::NeverInvoker),
                    "Banking::Customer.Register",
                    register(id),
                    Caller::default(),
                )
                .await
                .unwrap()
            }
        };

        let off = go(Enforcement::Off, "CUST-0021").await;
        assert!(
            off.accepted,
            "off keeps the old behaviour: {:?}",
            off.result
        );

        let enforced = go(Enforcement::Enforce, "CUST-0022").await;
        assert!(
            !enforced.accepted,
            "an unidentified caller must be refused: {:?}",
            enforced.result
        );
        assert!(refused_for_role(&enforced.result), "{:?}", enforced.result);
        let error = enforced.result["refusals"][0]["error"].as_str().unwrap();
        assert!(
            error.contains("Branch clerk") && error.contains(ANONYMOUS_ROLE),
            "{error}"
        );

        let shadowed = go(Enforcement::Shadow, "CUST-0023").await;
        assert!(
            shadowed.accepted,
            "shadow lets the command through: {:?}",
            shadowed.result
        );

        let steps = client.journal_steps().await;
        assert_eq!(
            steps.len(),
            2,
            "the enforced refusal was not persisted; off and shadow were"
        );
    }

    // Shadow may only let through what Off would: a caller that stated a wrong role is refused.
    #[tokio::test]
    async fn shadow_refuses_a_stated_wrong_role_and_still_lets_an_unidentified_caller_through() {
        let client = crate::dispatch::tests::memory_store();
        let config = crate::dispatch::tests::memory_config("Banking");
        let go = |mode: Enforcement, origin: Origin, caller: Caller<'static>, id: &'static str| {
            let client = &client;
            let config = &config;
            async move {
                dispatch_in(
                    mode,
                    origin,
                    Host::new(client, &wasm_path(), config, &lambda_client::NeverInvoker),
                    "Banking::Customer.Register",
                    register(id),
                    caller,
                )
                .await
                .unwrap()
            }
        };
        let wrong = Caller {
            role: Some("Auditor"),
            actor_id: None,
        };

        let shadow_wrong = go(Enforcement::Shadow, Origin::External, wrong, "CUST-0031").await;
        assert!(
            !shadow_wrong.accepted,
            "shadow must not accept a stated wrong role: {:?}",
            shadow_wrong.result
        );
        assert!(
            refused_for_role(&shadow_wrong.result),
            "{:?}",
            shadow_wrong.result
        );
        let off_wrong = go(Enforcement::Off, Origin::External, wrong, "CUST-0032").await;
        assert!(
            !off_wrong.accepted,
            "off refuses it too: {:?}",
            off_wrong.result
        );

        let nobody = go(
            Enforcement::Shadow,
            Origin::External,
            Caller::default(),
            "CUST-0033",
        )
        .await;
        assert!(
            nobody.accepted,
            "shadow lets an unidentified caller through: {:?}",
            nobody.result
        );

        let steps = client.journal_steps().await;
        assert_eq!(
            steps.len(),
            1,
            "only the unidentified caller's registration was persisted"
        );
    }

    // A host-internal dispatch names no caller and is unchecked in every mode, while an external
    // unidentified caller is refused under enforce.
    #[tokio::test]
    async fn a_host_internal_dispatch_is_unchecked_under_enforce_but_an_external_one_is_refused() {
        let client = crate::dispatch::tests::memory_store();
        let config = crate::dispatch::tests::memory_config("Banking");
        let go = |mode: Enforcement, origin: Origin, id: &'static str| {
            let client = &client;
            let config = &config;
            async move {
                dispatch_in(
                    mode,
                    origin,
                    Host::new(client, &wasm_path(), config, &lambda_client::NeverInvoker),
                    "Banking::Customer.Register",
                    register(id),
                    Caller::default(),
                )
                .await
                .unwrap()
            }
        };

        let external = go(Enforcement::Enforce, Origin::External, "CUST-0041").await;
        assert!(!external.accepted, "{:?}", external.result);
        for (mode, id) in [
            (Enforcement::Enforce, "CUST-0042"),
            (Enforcement::Shadow, "CUST-0043"),
            (Enforcement::Off, "CUST-0044"),
        ] {
            let internal = go(mode, Origin::HostInternal, id).await;
            assert!(internal.accepted, "{mode:?}: {:?}", internal.result);
        }
    }

    #[tokio::test]
    async fn a_mid_transaction_failure_rolls_back_any_saga_state_already_written() {
        // Deliberately doesn't provision "Transfer": its mutation fails
        // after `begin_saga` already wrote into `hecks_lambda_sagas`,
        // proving that write rolls back with the rest of the transaction.
        let client = scratch_db("rust_host_dispatch_test_9").await;
        provision_lineage(
            &*client.lock().await,
            "Banking",
            1,
            &["Customer", "Account"],
        )
        .await;
        let config = test_config("Banking", 1);

        handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Customer.Register",
            register("CUST-0012"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let open_src = serde_json::json!({
            "number": { "value": "src-rollback" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0012",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Account.Open",
            open_src,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("source account open should succeed");
        let open_dst = serde_json::json!({
            "number": { "value": "dst-rollback" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0012",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Account.Open",
            open_dst,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("destination account open should succeed");
        handle(Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker), "Banking::Account.Credit", serde_json::json!({ "number": "src-rollback", "amount": { "cents": 1000 }, "narrative": { "text": "opening balance" } }), None)
        .await.unwrap().accepted.then_some(()).expect("credit should succeed");

        // `Transfer.Request`'s own mutation is the first one this step
        // produces, and "Transfer" was never provisioned, so it fails
        // before the saga cascade runs further.
        let transfer_args = serde_json::json!({
            "reference": { "value": "tr-rollback" }, "amount": { "cents": 200 },
            "narrative": { "text": "rollback test" }, "source": "src-rollback", "destination": "dst-rollback",
        });
        let outcome = handle(
            Host::new(&client, &wasm_path(), &config, &lambda_client::NeverInvoker),
            "Banking::Transfer.Request",
            transfer_args,
            None,
        )
        .await;
        assert!(
            outcome.is_err(),
            "the unprovisioned Transfer lineage table should make this whole invocation fail"
        );

        let guard = client.lock().await;
        let saga_rows = guard
            .query(
                "SELECT process_manager, correlation FROM hecks_lambda_sagas",
                &[],
            )
            .await
            .unwrap();
        assert_eq!(
            saga_rows.len(), 0,
            "a saga write inside a transaction that ultimately fails must roll back with it, not commit independently: {saga_rows:?}"
        );
    }

    #[tokio::test]
    async fn a_pre_existing_snapshot_without_the_sagas_backfilled_latch_forces_one_full_replay() {
        let client = scratch_db("rust_host_dispatch_test_10").await;
        provision_lineage(
            &*client.lock().await,
            "Banking",
            1,
            &["Customer", "Account", "Transfer"],
        )
        .await;
        let config = test_config("Banking", 1);
        // `ReviewOnFreeze` fires on every `FreezeAccount` in this domain
        // (proven above), so `NeverInvoker` would panic here.
        let invoker = RecordingInvoker::new();

        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0013"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let open_src = serde_json::json!({
            "number": { "value": "src-backfill" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0013",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.Open",
            open_src,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("source account open should succeed");
        let open_dst = serde_json::json!({
            "number": { "value": "dst-backfill" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0013",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.Open",
            open_dst,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("destination account open should succeed");
        handle(Host::new(&client, &wasm_path(), &config, &invoker), "Banking::Account.Credit", serde_json::json!({ "number": "src-backfill", "amount": { "cents": 1000 }, "narrative": { "text": "opening balance" } }), None)
        .await.unwrap().accepted.then_some(()).expect("credit should succeed");

        // Freezing the destination first means the credit leg refuses
        // and Settlement compensates, leaving the saga stuck "reversed"
        // — exactly the mid-flight shape this test needs to recover.
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.FreezeAccount",
            serde_json::json!({ "number": { "value": "dst-backfill" } }),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("freeze should succeed");
        let transfer_args = serde_json::json!({
            "reference": { "value": "tr-backfill" }, "amount": { "cents": 200 },
            "narrative": { "text": "backfill test" }, "source": "src-backfill", "destination": "dst-backfill",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Transfer.Request",
            transfer_args,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("the Transfer.Request COMMAND succeeds; the saga's own credit leg is what refuses");

        {
            let guard = client.lock().await;
            let before = guard
                .query(
                    "SELECT process_manager, correlation, state FROM hecks_lambda_sagas",
                    &[],
                )
                .await
                .unwrap();
            assert_eq!(before.len(), 1, "the reversed Settlement instance should already be tracked before the simulated reset: {before:?}");
        }

        // Simulates a pre-saga-durability snapshot: the latch false and
        // `hecks_lambda_sagas` empty, even though a saga is genuinely
        // mid-flight.
        {
            let guard = client.lock().await;
            guard
                .execute(
                    "UPDATE hecks_lambda_snapshot SET sagas_backfilled = false",
                    &[],
                )
                .await
                .unwrap();
            guard
                .execute("DELETE FROM hecks_lambda_sagas", &[])
                .await
                .unwrap();
        }

        // One more command should trigger a full replay, whose saga
        // cascade re-running as a side effect repopulates
        // `hecks_lambda_sagas`.
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0014"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("second registration should succeed");

        let guard = client.lock().await;
        let saga_rows = guard
            .query(
                "SELECT process_manager, correlation, state FROM hecks_lambda_sagas",
                &[],
            )
            .await
            .unwrap();
        assert_eq!(saga_rows.len(), 1, "the backfill replay should have recovered the in-flight Settlement instance: {saga_rows:?}");
        let process_manager: String = saga_rows[0].get(0);
        let correlation: String = saga_rows[0].get(1);
        let state: String = saga_rows[0].get(2);
        assert_eq!(process_manager, "Settlement");
        assert_eq!(correlation, "tr-backfill");
        assert_eq!(state, "reversed");

        let latched: bool = guard
            .query_one("SELECT sagas_backfilled FROM hecks_lambda_snapshot", &[])
            .await
            .unwrap()
            .get(0);
        assert!(latched, "after the backfill replay, the latch should be set so this doesn't repeat every invocation");
    }

    // Always fails with a hard invoke fault, the shape an unreachable
    // Lambda has — proves the exhausted-retry/dead-letter path.
    struct AlwaysFailingInvoker {
        calls: std::sync::Mutex<u32>,
    }

    impl AlwaysFailingInvoker {
        fn new() -> Self {
            Self {
                calls: std::sync::Mutex::new(0),
            }
        }
    }

    #[async_trait::async_trait]
    impl LambdaInvoker for AlwaysFailingInvoker {
        async fn invoke(
            &self,
            _function_name: &str,
            _payload: &str,
        ) -> anyhow::Result<lambda_client::InvokeOutcome> {
            *self.calls.lock().unwrap() += 1;
            anyhow::bail!("ResourceNotFoundException: function not found")
        }
    }

    #[tokio::test]
    async fn a_cross_domain_delivery_that_exhausts_every_retry_dead_letters_and_still_fails_the_invocation(
    ) {
        let client = crate::dispatch::tests::memory_store();
        let config = crate::dispatch::tests::memory_config("Banking");
        let invoker = AlwaysFailingInvoker::new();

        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0011"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let open_args = serde_json::json!({
            "number": { "value": "acct-freeze-dead-letter" },
            "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 },
            "customer": "CUST-0011",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.Open",
            open_args,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("account open should succeed");

        // `ReviewOnFreeze` fires here — every attempt against
        // `AlwaysFailingInvoker` fails, so `deliver_with_retry` exhausts
        // `MAX_DELIVERY_ATTEMPTS` before `handle` ever sees a result.
        let freeze_args = serde_json::json!({ "number": { "value": "acct-freeze-dead-letter" } });
        let outcome = handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Account.FreezeAccount",
            freeze_args,
            None,
        )
        .await;

        assert!(
            outcome.is_err(),
            "a cross-domain delivery that exhausts every retry should still fail THIS invocation \
             visibly — the local Freeze already committed regardless (checked below), this is only \
             about what the CALLER sees"
        );
        assert_eq!(
            *invoker.calls.lock().unwrap(),
            lambda_client::MAX_DELIVERY_ATTEMPTS,
            "should have retried exactly MAX_DELIVERY_ATTEMPTS times before giving up"
        );

        // The local command still committed: cross-domain delivery runs
        // strictly after commit, so a delivery failure never unwinds it.
        // The dead letter existing at all proves the match already ran.
        let dead_letters = client.dead_letter_rows().await;
        assert_eq!(
            dead_letters.len(),
            1,
            "exactly one exhausted delivery should have been dead-lettered: {dead_letters:?}"
        );
        let (policy, target_domain, target_verb, attempts) = dead_letters[0].clone();
        assert_eq!(policy, "ReviewOnFreeze");
        assert_eq!(target_domain, "Compliance");
        assert_eq!(target_verb, "Compliance::AccountFreezeReview.Open");
        assert_eq!(attempts, lambda_client::MAX_DELIVERY_ATTEMPTS as i32);
    }

    // Pins a real drop: a second cross-domain reaction from the same
    // step must not go dark just because the first one's delivery
    // exhausted its retries. `SafeDepositBox.Surrender` emits both
    // `BoxSurrendered` (-> Compliance) and `KeyReturnDue` (-> Notifications)
    // from one command.
    #[tokio::test]
    async fn a_failed_cross_domain_delivery_does_not_drop_a_sibling_reaction_from_the_same_step() {
        let client = crate::dispatch::tests::memory_store();
        let config = crate::dispatch::tests::memory_config("Banking");
        let invoker = AlwaysFailingInvoker::new();

        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::Customer.Register",
            register("CUST-0022"),
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("registration should succeed");

        let rent_args = serde_json::json!({
            "branch_code": { "value": "downtown" },
            "box_number": { "value": 12 },
            "size": { "value": "small" },
            "customer": "CUST-0022",
        });
        handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::SafeDepositBox.Rent",
            rent_args,
            None,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("rent should succeed");

        // Both ReviewOnBoxSurrender (-> Compliance) and FlagKeyReturn
        // (-> Notifications) fire here; both deliveries exhaust every
        // retry against AlwaysFailingInvoker.
        let surrender_args = serde_json::json!({ "branch_code": { "value": "downtown" }, "box_number": { "value": 12 } });
        let outcome = handle(
            Host::new(&client, &wasm_path(), &config, &invoker),
            "Banking::SafeDepositBox.Surrender",
            surrender_args,
            None,
        )
        .await;

        assert!(
            outcome.is_err(),
            "still fails the invocation visibly, same contract as a single failed delivery"
        );
        assert_eq!(
            *invoker.calls.lock().unwrap(),
            lambda_client::MAX_DELIVERY_ATTEMPTS * 2,
            "BOTH reactions should have been attempted MAX_DELIVERY_ATTEMPTS times each — \
             the fix under test is exactly this: a fresh Vec would only ever show one policy's worth"
        );

        let policies: Vec<String> = client
            .dead_letter_rows()
            .await
            .into_iter()
            .map(|row| row.0)
            .collect();
        assert_eq!(
            policies,
            vec!["FlagKeyReturn".to_string(), "ReviewOnBoxSurrender".to_string()],
            "BOTH sibling reactions must be dead-lettered, not just whichever ran first: {policies:?}"
        );
    }
    /// The wasm plugin fixture (spec/fixtures/rust_host/pluginned): its kernel and its IR, which
    /// carries the doubler plugin that answers `Ledger.Doubled` and refuses `Ledger.Tripled`.
    fn pluginned() -> (std::path::PathBuf, serde_json::Value) {
        let dist = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist");
        let ir = std::fs::read_to_string(dist.join("pluginned.ir.json"))
            .expect("build the pluginned fixture");
        (
            dist.join("pluginned.wasm"),
            serde_json::from_str(&ir).unwrap(),
        )
    }

    async fn ask_pluginned(
        client: &Mutex<Client>,
        question: &str,
        args: serde_json::Value,
    ) -> serde_json::Value {
        let (wasm, ir) = pluginned();
        let asked = serde_json::json!({ "query": question, "args": args });
        crate::query_step::answer(&asked, Some(&ir), "Pluginned", client, &wasm)
            .await
            .unwrap()
    }

    /// A query a wasm plugin answers, end to end: a command through the real kernel stores the
    /// ledger, and the query step hands the plugin that record's state, read back from Postgres.
    #[tokio::test]
    async fn a_plugin_answers_with_the_referenced_record_as_stored() {
        let client = scratch_db("rust_host_dispatch_test_plugin").await;
        provision_lineage(&*client.lock().await, "Pluginned", 1, &["Ledger"]).await;
        let (wasm, _) = pluginned();
        let config = test_config("Pluginned", 1);
        let opened = handle(
            Host::new(&client, &wasm, &config, &lambda_client::NeverInvoker),
            "Pluginned::Ledger.Open",
            serde_json::json!({ "name": { "value": "house" }, "note": { "value": "rent" } }),
            None,
        )
        .await
        .unwrap();
        assert!(
            opened.accepted,
            "opening the ledger: {}",
            opened.result["refusals"]
        );

        let answer = ask_pluginned(
            &client,
            "Pluginned::Ledger.Doubled",
            serde_json::json!({ "entry": "house", "amount": 21 }),
        )
        .await;

        assert_eq!(
            answer["queries"][0]["rows"],
            serde_json::json!([{ "amount": 42, "note": "rent" }])
        );
    }

    #[tokio::test]
    async fn a_plugin_refusal_and_a_missing_record_come_back_as_refusals() {
        let client = scratch_db("rust_host_dispatch_test_plugin_refusals").await;
        provision_lineage(&*client.lock().await, "Pluginned", 1, &["Ledger"]).await;

        let refused = ask_pluginned(
            &client,
            "Pluginned::Ledger.Tripled",
            serde_json::json!({ "amount": 1 }),
        )
        .await;
        let missing = ask_pluginned(
            &client,
            "Pluginned::Ledger.Doubled",
            serde_json::json!({ "entry": "nowhere", "amount": 1 }),
        )
        .await;

        assert_eq!(refused["refusals"][0]["kind"], "PluginRefusal");
        let refusal = refused["refusals"][0]["error"].as_str().unwrap();
        assert!(
            refusal.contains("doubler does not answer Pluginned::Ledger.Tripled"),
            "{refusal}"
        );
        assert_eq!(missing["refusals"][0]["kind"], "NotFound");
        assert_eq!(
            missing["refusals"][0]["error"],
            "entry: no Ledger \"nowhere\""
        );
    }
}
