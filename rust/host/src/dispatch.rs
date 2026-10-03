//! Ties the journal and the sandbox together: replays history, then the
//! new step, persisting it only if the module accepts it.

use crate::journal;
use crate::journal::LineageConfig;
use crate::lambda_client::{self, LambdaInvoker};
use crate::wasm_runner;
use std::path::Path;
use tokio::sync::Mutex;
use tokio_postgres::Client;

pub struct Outcome {
    pub result: serde_json::Value,
    pub accepted: bool,
}

/// Who a command is dispatched for: the role they state and, when the host knows who they are, the
/// actor Governance holds assignments for. Both absent is an unidentified caller.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Caller<'a> {
    pub role: Option<&'a str>,
    pub actor_id: Option<&'a str>,
}

/// The role an unidentified caller is dispatched under when roles are enforced: no command declares
/// it, so a command that declares any role refuses it.
pub const ANONYMOUS_ROLE: &str = "Anonymous";

/// What the host does about the role a command declares (`HECKS_ROLE_ENFORCEMENT`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Enforcement {
    /// A caller with no role is unchecked, as before.
    Off,
    /// An unidentified or unassigned caller is let through and logged as `would_refuse_role`.
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
    pub fn effective<'a>(self, caller: Caller<'a>) -> Caller<'a> {
        if self != Self::Off && caller.role.is_none() && caller.actor_id.is_none() {
            return Caller { role: Some(ANONYMOUS_ROLE), actor_id: None };
        }
        caller
    }
}

/// Whether the kernel refused the command for the caller's role.
fn refused_for_role(result: &serde_json::Value) -> bool {
    result.get("refusals").and_then(|r| r.as_array()).is_some_and(|all| {
        all.iter().any(|r| r.get("kind").and_then(|k| k.as_str()) == Some("Unauthorized"))
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
        return KernelAnswer::Failed(error.as_str().map(str::to_string).unwrap_or_else(|| error.to_string()));
    }
    let refused = result.get("refusals").and_then(|r| r.as_array()).is_some_and(|r| !r.is_empty());
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
        KernelAnswer::Failed(message) => anyhow::bail!("the kernel failed before it could run the command: {message}"),
        KernelAnswer::Accepted | KernelAnswer::Refused => Ok(result),
    }
}

// Kept as one opaque object under the journal's `args` column; the kernel
// unwraps `to`/`with` itself, so this needs no journal schema migration.
pub fn routed_invocation(to: serde_json::Value, facts: serde_json::Value) -> anyhow::Result<serde_json::Value> {
    if !facts.is_object() {
        anyhow::bail!("with must be an object of command facts");
    }
    Ok(serde_json::json!({ "to": to, "with": facts }))
}

// No `to` route: used only when a command creates a new aggregate, so
// there is no receiver yet to route to.
pub fn facts_invocation(facts: serde_json::Value) -> anyhow::Result<serde_json::Value> {
    if !facts.is_object() {
        anyhow::bail!("with must be an object of command facts");
    }
    Ok(serde_json::json!({ "with": facts }))
}

// Route-aware entry point; `handle` below stays the compatibility path
// for callers still sending the older mixed args shape.
#[allow(clippy::too_many_arguments)]
pub async fn handle_routed(
    client: &Mutex<Client>,
    wasm_path: &Path,
    verb: &str,
    to: serde_json::Value,
    facts: serde_json::Value,
    role: Option<&str>,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<Outcome> {
    handle(client, wasm_path, verb, routed_invocation(to, facts)?, role, config, invoker).await
}

/// `handle_routed` for a caller the host can name.
#[allow(clippy::too_many_arguments)]
pub async fn handle_routed_as(
    client: &Mutex<Client>,
    wasm_path: &Path,
    verb: &str,
    to: serde_json::Value,
    facts: serde_json::Value,
    caller: Caller<'_>,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<Outcome> {
    handle_as(client, wasm_path, verb, routed_invocation(to, facts)?, caller, config, invoker).await
}

// Facts-only counterpart to `handle_routed`.
#[allow(clippy::too_many_arguments)]
pub async fn handle_facts(
    client: &Mutex<Client>,
    wasm_path: &Path,
    verb: &str,
    facts: serde_json::Value,
    role: Option<&str>,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<Outcome> {
    handle(client, wasm_path, verb, facts_invocation(facts)?, role, config, invoker).await
}

/// `handle_facts` for a caller the host can name.
#[allow(clippy::too_many_arguments)]
pub async fn handle_facts_as(
    client: &Mutex<Client>,
    wasm_path: &Path,
    verb: &str,
    facts: serde_json::Value,
    caller: Caller<'_>,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<Outcome> {
    handle_as(client, wasm_path, verb, facts_invocation(facts)?, caller, config, invoker).await
}

// A Mutex, not a bare Arc<Client>: `handle` needs `Client::transaction`,
// which takes `&mut Client`. Locking also means concurrent callers on
// this connection can't interleave statements.
//
// `config` is required, not optional: `main.rs` already refused to boot
// unless the configured domain/era is provisioned and current, so by the
// time `handle` runs that schema is guaranteed to exist.
//
// `role` is optional, matching `Adapters::Lambda::Client#dispatch`'s own
// `role: nil` default: a step with no role looks the same on the wire
// whether or not a caller is bound.
pub async fn handle(
    client: &Mutex<Client>,
    wasm_path: &Path,
    verb: &str,
    args: serde_json::Value,
    role: Option<&str>,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<Outcome> {
    handle_as(client, wasm_path, verb, args, Caller { role, actor_id: None }, config, invoker).await
}

/// Dispatches for a caller, applying `HECKS_ROLE_ENFORCEMENT`: unidentified callers are refused (or,
/// in shadow, logged as would-be refusals and let through).
pub async fn handle_as(
    client: &Mutex<Client>,
    wasm_path: &Path,
    verb: &str,
    args: serde_json::Value,
    caller: Caller<'_>,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<Outcome> {
    handle_with(Enforcement::from_env(), client, wasm_path, verb, args, caller, config, invoker).await
}

#[allow(clippy::too_many_arguments)]
async fn handle_with(
    mode: Enforcement,
    client: &Mutex<Client>,
    wasm_path: &Path,
    verb: &str,
    args: serde_json::Value,
    caller: Caller<'_>,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<Outcome> {
    let checked = mode.effective(caller);
    let outcome = run(client, wasm_path, verb, args.clone(), checked, config, invoker).await?;
    if mode == Enforcement::Shadow && !outcome.accepted && refused_for_role(&outcome.result) {
        crate::log::error("would_refuse_role", serde_json::json!({
            "verb": verb, "role": checked.role, "actor_id": checked.actor_id,
            "refusals": outcome.result.get("refusals"),
        }));
        return run(client, wasm_path, verb, args, Caller::default(), config, invoker).await;
    }
    Ok(outcome)
}

#[allow(clippy::too_many_arguments)]
async fn run(
    client: &Mutex<Client>,
    wasm_path: &Path,
    verb: &str,
    args: serde_json::Value,
    caller: Caller<'_>,
    config: &LineageConfig,
    invoker: &dyn LambdaInvoker,
) -> anyhow::Result<Outcome> {
    let role = caller.role;
    let mut guard = client.lock().await;
    let txn = guard.transaction().await?;

    // Locks the whole read-then-append sequence, not just the INSERT:
    // two concurrent invocations could otherwise both rehydrate against
    // the same prior steps and both pass a uniqueness check the domain
    // thinks it's enforcing. Domain-scoped so unrelated domains sharing
    // one Postgres instance don't serialize against each other.
    txn.execute(
        "SELECT pg_advisory_xact_lock(hashtext('hecks_lambda_journal.' || $1::text))",
        &[&config.domain],
    )
    .await?;

    // Reads the last snapshot plus only the journal rows after it,
    // instead of replaying the whole history every time. `None` covers
    // a brand-new domain and one with pre-snapshot history alike; both
    // fall back to one full replay, which then leaves a snapshot behind.
    let snapshot = journal::load_snapshot(&txn).await?;
    // `sagas_backfilled` is a latch, not a live check of whether
    // `hecks_lambda_sagas` is empty (empty is the ordinary state, not a
    // signal). Only matters for a domain with real history predating
    // saga durability, where the snapshot cache would otherwise never
    // re-derive sagas from the journal.
    let needs_saga_backfill = snapshot.as_ref().is_some_and(|s| !s.sagas_backfilled);
    let mut steps = match &snapshot {
        Some(s) if !needs_saga_backfill => journal::load_steps_after(&txn, s.ordinal).await?,
        _ => journal::load_steps(&txn).await?,
    };
    // Role goes only on this outermost step; replayed history already
    // carries whatever role it was dispatched with. Built as a mutable
    // step, not inlined into the `json!` literal, so a roleless call
    // still omits the `"role"` key entirely rather than sending null.
    // A fact the command `needs` is answered here, before the kernel's gates read the arguments and
    // before the step is journaled, so a replay re-dispatches the recorded answer (ADR 0081).
    let mut args = args;
    if let Some(domain_ir) = crate::ir::ir() {
        crate::needs::fill_needs(domain_ir, verb, &mut args, &crate::needs::ProcessClock);
        // An argument with a declared default is filled the same way, so the journal holds it too.
        crate::needs::fill_defaults(domain_ir, verb, &mut args);
    }
    let mut step = serde_json::json!({ "verb": verb, "args": args.clone() });
    if let Some(role) = role {
        step["role"] = serde_json::Value::String(role.to_string());
    }
    if let Some(actor_id) = caller.actor_id {
        step["actor_id"] = serde_json::Value::String(actor_id.to_string());
    }
    // Stamped only on this live step; replayed history already carries
    // its own real timestamp, and re-stamping today's time onto a
    // replay would be wrong, not just redundant.
    step["occurred_at"] = serde_json::Value::String(crate::auth::httpdate_now());
    steps.push(step);
    // Must match `steps`' own choice above: a full replay needs an empty
    // seed, or the kernel replays into a world that already has every
    // record being created again, refusing each as a false AlreadyExists.
    let seed = if needs_saga_backfill {
        serde_json::json!({})
    } else {
        snapshot.as_ref().map(|s| s.seed.clone()).unwrap_or_else(|| serde_json::json!({}))
    };

    // Read inside the same advisory-locked transaction: the lock covers
    // saga state too, not just the aggregate journal/snapshot.
    let saga_rows = journal::load_sagas(&txn).await?;
    let sagas_seed = serde_json::json!(saga_rows
        .iter()
        .map(|r| serde_json::json!({
            "process_manager": r.process_manager,
            "correlation": r.correlation,
            "state": r.state,
            "memory": r.memory,
            "completed_compensations": r.completed_compensations,
        }))
        .collect::<Vec<_>>());

    let mut input = serde_json::json!({ "seed": seed, "steps": steps, "sagas": sagas_seed });
    // Lets the kernel answer a reaction's command that needs a fact the same way (ADR 0081).
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
    let input = input.to_string();
    // `wasm_runner::run` is sync, and wasmtime-wasi's sync bridge spins up
    // its own tokio runtime internally — fatal on a thread already
    // driving one. `spawn_blocking` moves it off this async runtime.
    let owned_wasm_path = wasm_path.to_path_buf();
    let output =
        tokio::task::spawn_blocking(move || wasm_runner::run(&owned_wasm_path, &input)).await??;
    // A kernel failure returns here, before anything is written: dropping `txn`
    // rolls it back, so no journal row, snapshot, saga or mutation is saved.
    let mut result = parse_kernel_output(&output)?;

    // See journal.rs's own header: every prior step in this replay
    // already succeeded once, deterministically, so the only step that
    // can legitimately show up in `refusals` is the new one just
    // appended last.
    let accepted = classify(&result) == KernelAnswer::Accepted;

    if accepted {
        let ordinal = journal::append(&txn, verb, &args).await?;

        // The kernel's "instances" output is already the exact seed
        // shape, so nothing here re-derives or filters it.
        let new_seed = result.get("instances").cloned().unwrap_or_else(|| serde_json::json!({}));
        journal::save_snapshot(&txn, ordinal, &new_seed).await?;

        // Persisted in the same transaction, so a saga checkpoint can
        // never commit independently of the command that produced it.
        // Reconciled against `saga_rows` (pre-run state): present now
        // is upserted, present before but absent now is deleted.
        if let Some(saga_snapshot) = result.get("saga_snapshot").and_then(|v| v.as_array()) {
            let mut still_present: std::collections::HashSet<(String, String)> = std::collections::HashSet::new();
            for entry in saga_snapshot {
                let process_manager = entry
                    .get("process_manager")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow::anyhow!("saga_snapshot entry missing \"process_manager\": {entry}"))?;
                let correlation = entry
                    .get("correlation")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow::anyhow!("saga_snapshot entry missing \"correlation\": {entry}"))?;
                let state = entry
                    .get("state")
                    .and_then(|v| v.as_str())
                    .ok_or_else(|| anyhow::anyhow!("saga_snapshot entry missing \"state\": {entry}"))?;
                let memory = entry.get("memory").cloned().unwrap_or_else(|| serde_json::json!({}));
                let completed_compensations = entry.get("completed_compensations").cloned().unwrap_or_else(|| serde_json::json!([]));

                journal::save_saga(&txn, process_manager, correlation, state, &memory, &completed_compensations).await?;
                still_present.insert((process_manager.to_string(), correlation.to_string()));
            }
            for row in &saga_rows {
                let key = (row.process_manager.clone(), row.correlation.clone());
                if !still_present.contains(&key) {
                    journal::delete_saga(&txn, &row.process_manager, &row.correlation).await?;
                }
            }
        }

        // One entry per step in `steps`, so the last entry is this
        // call's own new step. Skipped when `config.era` is `None`: a
        // domain with nothing lineage-capable bound never provisions a
        // head-snapshot table to write into (ADR 0034).
        let step_mutations = if config.era.is_some() {
            result
                .get("mutations")
                .and_then(|m| m.as_array())
                .and_then(|steps| steps.last())
                .and_then(|last| last.as_array())
                .cloned()
                .unwrap_or_default()
        } else {
            Vec::new()
        };

        for mutation in &step_mutations {
            let aggregate = mutation
                .get("aggregate")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow::anyhow!("mutation record missing \"aggregate\": {mutation}"))?;
            // `era.is_some()` means the lineage subsystem exists, not that
            // this aggregate has a mirror: `mint` only provisions head
            // snapshots for the capable set, so mirroring anything else
            // would upsert into a relation nobody created.
            if !config.mirrors(aggregate) {
                continue;
            }
            let id = mutation
                .get("id")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow::anyhow!("mutation record missing \"id\": {mutation}"))?;
            let operation = mutation
                .get("operation")
                .and_then(|v| v.as_str())
                .ok_or_else(|| anyhow::anyhow!("mutation record missing \"operation\": {mutation}"))?;
            let state = mutation
                .get("state")
                .ok_or_else(|| anyhow::anyhow!("mutation record missing \"state\": {mutation}"))?;

            journal::append_lineage_mutation(
                &txn,
                config,
                &journal::Mutation { aggregate, id, operation, state },
            )
            .await?;
        }
    }

    // Only this step's own matches, same reason as `step_mutations`
    // above: replaying a prior step's reaction would re-invoke a sibling
    // Lambda on every later replay. Captured before commit, delivered after.
    let pending_cross_domain = result
        .get("cross_domain_reactions")
        .and_then(|r| r.as_array())
        .and_then(|steps| steps.last())
        .and_then(|last| last.as_array())
        .cloned()
        .unwrap_or_default();

    // Commits (and releases the advisory lock) whether or not anything
    // was appended — a refused command still needs the lock released
    // for the next invocation to proceed.
    txn.commit().await?;

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
                    if let Some(reactions) = response.get_mut("reactions").and_then(|r| r.as_array_mut()) {
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
                crate::log::error("cross_domain_delivery_failed", serde_json::json!({
                    "policy": failure.policy, "target_domain": failure.target_domain,
                    "target_verb": failure.target_verb, "attempts": failure.attempts, "error": error_text,
                }));
                journal::record_dead_letter(
                    &*guard,
                    &failure.policy,
                    &failure.target_domain,
                    &failure.target_verb,
                    &failure.payload,
                    &error_text,
                    failure.attempts as i32,
                )
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
        response.insert("cross_domain_deliveries".to_string(), serde_json::Value::Array(cross_domain_deliveries));
    }

    log_command(verb, role, accepted, &result);
    Ok(Outcome { result, accepted })
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

fn command_fields(verb: &str, role: Option<&str>, accepted: bool, result: &serde_json::Value) -> serde_json::Value {
    let events: Vec<serde_json::Value> = result
        .get("events")
        .and_then(|v| v.as_array())
        .map(|items| items.iter().filter_map(|item| item.get("name").cloned()).collect())
        .unwrap_or_default();
    serde_json::json!({
        "verb": verb, "role": role, "accepted": accepted, "events": events,
        "refusals": result.get("refusals").cloned().unwrap_or_else(|| serde_json::json!([])),
    })
}

// Read-only: the same seed path `handle` uses, minus the new step and
// any write. No advisory lock needed since nothing here writes.
// Returns the whole kernel result verbatim, not just `instances`, so a
// caller can tell an empty `refusals` from one that was never checked.
pub async fn read(client: &Mutex<Client>, wasm_path: &Path) -> anyhow::Result<serde_json::Value> {
    let guard = client.lock().await;
    let snapshot = journal::load_snapshot(&*guard).await?;

    if let Some(s) = &snapshot {
        let steps_since = journal::load_steps_after(&*guard, s.ordinal).await?;
        drop(guard);

        if steps_since.is_empty() {
            // No wasm invocation needed: the snapshot's seed already is
            // this domain's current "instances" output. Empty
            // events/refusals is correct too — a read reports current
            // state, never event/refusal history.
            return Ok(serde_json::json!({ "instances": s.seed, "events": [], "refusals": [] }));
        }

        // Self-healing: if steps ever go unaccounted for after the last
        // snapshot, seeding from it and replaying just the gap is
        // still correct and cheap.
        let input = serde_json::json!({ "seed": &s.seed, "steps": steps_since }).to_string();
        let owned_wasm_path = wasm_path.to_path_buf();
        let output =
            tokio::task::spawn_blocking(move || wasm_runner::run(&owned_wasm_path, &input)).await??;
        return parse_kernel_output(&output);
    }

    // No snapshot: either a brand-new domain, or one with history from
    // before this snapshot cache existed — either way, one full replay
    // catches it up.
    let steps = journal::load_steps(&*guard).await?;
    drop(guard);
    let input = serde_json::json!({ "steps": steps }).to_string();
    let owned_wasm_path = wasm_path.to_path_buf();
    let output =
        tokio::task::spawn_blocking(move || wasm_runner::run(&owned_wasm_path, &input)).await??;
    parse_kernel_output(&output)
}

// A declared query, answered against current state. Seeds from `read`
// rather than replaying history itself, so it sees exactly the state a
// read would report and pays at most one wasm invocation.
pub async fn query(
    client: &Mutex<Client>,
    wasm_path: &Path,
    question: &str,
    args: serde_json::Value,
) -> anyhow::Result<serde_json::Value> {
    let state = read(client, wasm_path).await?;
    let seed = state.get("instances").cloned().unwrap_or_else(|| serde_json::json!({}));
    let input = serde_json::json!({ "seed": seed, "steps": [{ "query": question, "args": args }] }).to_string();
    let owned_wasm_path = wasm_path.to_path_buf();
    let output = tokio::task::spawn_blocking(move || wasm_runner::run(&owned_wasm_path, &input)).await??;
    parse_kernel_output(&output)
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
    use tokio_postgres::NoTls;

    // A throwaway Postgres database per test, uniquely named so
    // `cargo test`'s default parallelism doesn't race two tests against
    // the same journal table.
    pub(crate) async fn scratch_db(name: &str) -> Mutex<Client> {
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

        let (client, conn) =
            tokio_postgres::connect(&crate::test_pg::conninfo(&name), NoTls)
                .await
                .expect("connect to scratch db");
        tokio::spawn(async move {
            let _ = conn.await;
        });
        journal::ensure_schema(&client).await.unwrap();
        Mutex::new(client)
    }

    // Not Ruby's real provisioning — just enough structure for
    // `journal::current_era` and `append_lineage_mutation` to succeed,
    // without reproducing Ruby's full DDL.
    pub(crate) async fn provision_lineage(client: &Client, domain: &str, era: i32, aggregate_storage_names: &[&str]) {
        // `int`, matching Ruby's real DDL: tokio_postgres requires the
        // Rust and Postgres types to match, not just be compatible.
        client
            .batch_execute("CREATE TABLE IF NOT EXISTS hecks_eras (domain text, ordinal int, held_text text)")
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
            let snapshot_table = journal::qualified_name(domain, &format!("{}_head_snapshot_{era}", journal::snake(name)));
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
        let everything = LineageConfig { domain: "Banking".to_string(), era: Some(1), mirrored: None };
        let refused = handle_facts(&client, &wasm, "Banking::Customer.Register", open.clone(), None, &everything, &invoker).await;
        let message = match refused {
            Ok(_) => panic!("expected the missing-relation failure"),
            Err(e) => format!("{e:#}"),
        };
        assert!(message.contains("banking_customer_head_snapshot_1"), "names the relation it could not write: {message}");
        assert!(message.contains("does not exist"), "carries the database's own words: {message}");
        assert!(message.contains("Banking::Customer"), "names the record: {message}");

        // Mirroring what the IR actually declares — nothing — writes
        // cleanly, into this crate's own journal.
        let declared = LineageConfig {
            domain: "Banking".to_string(),
            era: Some(1),
            mirrored: Some(std::collections::BTreeSet::new()),
        };
        let outcome = handle_facts(&client, &wasm, "Banking::Customer.Register", open, None, &declared, &invoker)
            .await
            .expect("writes");
        assert!(outcome.accepted, "{}", outcome.result);

        let guard = client.lock().await;
        let journalled: i64 = guard.query_one("SELECT count(*) FROM hecks_lambda_journal", &[]).await.unwrap().get(0);
        assert_eq!(journalled, 1, "durable in this crate's own journal, which is what `read` replays");
        let mirror: Option<String> =
            guard.query_one("SELECT to_regclass('banking_customer_head_snapshot_1')::text", &[]).await.unwrap().get(0);
        assert!(mirror.is_none(), "and no mirror was invented for an aggregate the IR never called capable");
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
            mirrored: Some(["Banking::Customer".to_string()].into_iter().collect()),
        };

        handle_facts(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-2"),
            None,
            &config,
            &crate::lambda_client::NeverInvoker,
        )
        .await
        .expect("writes");

        let guard = client.lock().await;
        let mirrored: i64 =
            guard.query_one("SELECT count(*) FROM banking_customer_head_snapshot_1", &[]).await.unwrap().get(0);
        assert_eq!(mirrored, 1);
    }

    fn test_config(domain: &str, era: i32) -> LineageConfig {
        LineageConfig { domain: domain.to_string(), era: Some(era), mirrored: None }
    }

    pub(crate) fn wasm_path() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../dist/banking.wasm")
    }

    fn register(reference: &str) -> serde_json::Value {
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
        let client = scratch_db("rust_host_dispatch_test_query").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);

        handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0100"), None, &config, &lambda_client::NeverInvoker)
            .await
            .unwrap()
            .accepted
            .then_some(())
            .expect("registering a customer should succeed");

        // `Customer.Suspended` is `where status == "suspended"` — a
        // freshly registered customer is active, so the query has to
        // answer with a real, empty row set, not everything.
        let before = query(&client, &wasm_path(), "Banking::Customer.Suspended", serde_json::json!({})).await.unwrap();
        assert_eq!(before["queries"][0]["query"], "Banking::Customer.Suspended");
        assert_eq!(before["queries"][0]["rows"].as_array().expect("rows").len(), 0);

        handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Suspend",
            serde_json::json!({ "reference": "CUST-0100", "standing": { "value": "watch" } }),
            None,
            &config,
            &lambda_client::NeverInvoker,
        )
        .await
        .unwrap()
        .accepted
        .then_some(())
        .expect("suspending a customer should succeed");

        let after = query(&client, &wasm_path(), "Banking::Customer.Suspended", serde_json::json!({})).await.unwrap();
        let rows = after["queries"][0]["rows"].as_array().expect("rows");
        assert_eq!(rows.len(), 1, "the suspended customer should be the one row: {after}");
        assert_eq!(rows[0]["id"], "CUST-0100");
    }

    #[tokio::test]
    async fn accepts_and_persists_a_first_command() {
        let client = scratch_db("rust_host_dispatch_test_1").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;

        let outcome = handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
            &test_config("Banking", 1),
            &lambda_client::NeverInvoker,
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
            .query("SELECT era, aggregate, aggregate_id, operation FROM hecks_journal_banking", &[])
            .await
            .unwrap();
        assert_eq!(journal_rows.len(), 1);
        let row = &journal_rows[0];
        let era: i32 = row.get(0);
        let aggregate: String = row.get(1);
        let aggregate_id: String = row.get(2);
        let operation: String = row.get(3);
        assert_eq!((era, aggregate.as_str(), aggregate_id.as_str(), operation.as_str()), (1, "customer", "CUST-0001", "save"));

        // domain-qualified (docs/decisions/0059) — snake("Banking") == "banking".
        let snapshot_rows = guard
            .query("SELECT id FROM banking_customer_head_snapshot_1", &[])
            .await
            .unwrap();
        assert_eq!(snapshot_rows.len(), 1, "the head-snapshot table should carry exactly the one live record");
        let id: String = snapshot_rows[0].get(0);
        assert_eq!(id, "CUST-0001");
    }

    // Proves `occurred_at` end to end through the real wasm module: the
    // string this crate stamps and sends is the one that comes back out
    // in the returned event, not just what the in-kernel unit tests prove.
    #[tokio::test]
    async fn occurred_at_is_stamped_onto_every_returned_event_with_this_crate_s_own_real_clock() {
        let client = scratch_db("rust_host_dispatch_test_occurred_at").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;

        let before = crate::auth::httpdate_now();
        let outcome = handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-OCCURRED-AT"),
            None,
            &test_config("Banking", 1),
            &lambda_client::NeverInvoker,
        )
        .await
        .unwrap();
        let after = crate::auth::httpdate_now();

        assert!(outcome.accepted, "{:?}", outcome.result["refusals"]);
        let events = outcome.result["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        let occurred_at = events[0]["occurred_at"].as_str().expect("occurred_at should be a real string, not null or absent");
        // Lexical comparison is valid: this format's digit-then-letter
        // layout sorts identically to chronological order for stamps
        // less than 10,000 years apart.
        assert!(occurred_at >= before.as_str() && occurred_at <= after.as_str(), "{occurred_at} should fall between {before} and {after}");
    }

    #[tokio::test]
    async fn rehydrates_prior_history_before_evaluating_the_new_command() {
        let client = scratch_db("rust_host_dispatch_test_2").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);

        let first = handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
            &config,
            &lambda_client::NeverInvoker,
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
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0001"),
            None,
            &config,
            &lambda_client::NeverInvoker,
        )
        .await
        .unwrap();

        assert!(
            !second.accepted,
            "duplicate registration should be refused, proving prior state was rehydrated: {:?}",
            second.result
        );
        let steps = journal::load_steps(&*client.lock().await).await.unwrap();
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
            let outcome = handle(&client, &wasm_path(), "Banking::Customer.Register", register(reference), None, &config, &lambda_client::NeverInvoker)
                .await
                .unwrap();
            assert!(outcome.accepted, "registering {reference} should succeed: {:?}", outcome.result);

            let guard = client.lock().await;
            let snapshot = journal::load_snapshot(&*guard)
                .await
                .unwrap()
                .expect("a snapshot should exist after the first accepted command");
            let tail = journal::load_steps_after(&*guard, snapshot.ordinal).await.unwrap();
            assert!(tail.is_empty(), "the snapshot should already reflect every accepted command, leaving nothing to replay");

            // And the seed is right, not just non-empty: it should carry
            // every customer registered so far, not just this one.
            let seeded = snapshot.seed.as_object().unwrap();
            assert!(
                seeded.keys().any(|k| k.contains(reference)),
                "the snapshot should carry the record just dispatched: {seeded:?}"
            );
        }

        let final_snapshot = journal::load_snapshot(&*client.lock().await).await.unwrap().unwrap();
        let final_seed = final_snapshot.seed.as_object().unwrap();
        assert_eq!(final_seed.len(), 3, "the snapshot should accumulate all three registrations, not just the latest: {final_seed:?}");
    }

    #[test]
    fn a_top_level_error_is_a_kernel_failure_and_nothing_else_is() {
        let failed = serde_json::json!({"error": "invalid seed: Registration.status: missing from JSON args"});
        assert_eq!(classify(&failed), KernelAnswer::Failed("invalid seed: Registration.status: missing from JSON args".to_string()));
        assert_eq!(classify(&serde_json::json!({"error": {"code": 7}})), KernelAnswer::Failed("{\"code\":7}".to_string()), "a non-text error is still a failure");

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
        let error = parse_kernel_output(r#"{"error":"invalid seed: Customer.status: missing from JSON args"}"#).unwrap_err();
        assert!(format!("{error:#}").contains("invalid seed: Customer.status: missing from JSON args"), "{error:#}");
        let refused = parse_kernel_output(r#"{"instances":{},"refusals":[{"verb":"v","error":"no","kind":"K"}]}"#).unwrap();
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

        let first = handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0001"), None, &config, &noinvoke).await.unwrap();
        assert!(first.accepted, "{:?}", first.result);

        let whole_world = journal::load_snapshot(&*client.lock().await).await.unwrap().unwrap().seed;
        let mut damaged = whole_world.clone();
        let customer = damaged.as_object_mut().unwrap().values_mut().next().unwrap().as_object_mut().unwrap();
        assert!(customer.remove("status").is_some(), "the fixture Customer carries a status");
        client.lock().await.execute("UPDATE hecks_lambda_snapshot SET seed = $1", &[&damaged]).await.unwrap();

        let before = snapshot_and_journal(&client).await;
        let failure = handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0002"), None, &config, &noinvoke).await;
        let message = format!("{:#}", failure.err().expect("a kernel failure must be an error, not an accepted outcome"));
        assert!(message.contains("invalid seed") && message.contains("status"), "{message}");

        assert_eq!(snapshot_and_journal(&client).await, before, "the failed command left the journal and the snapshot byte-identical");
        assert_eq!(before.2, 1, "and only the first command was ever journaled");
        let lineage_rows: i64 = client.lock().await.query_one("SELECT count(*) FROM hecks_journal_banking", &[]).await.unwrap().get(0);
        assert_eq!(lineage_rows, 1, "nothing was mirrored into the era journal either");

        // A read that must run the kernel over the damaged snapshot fails
        // the same way, instead of answering an empty world.
        client
            .lock()
            .await
            .execute("INSERT INTO hecks_lambda_journal (verb, args) VALUES ($1, $2)", &[&"Banking::Customer.Register", &register("CUST-0009")])
            .await
            .unwrap();
        let read_failure = read(&client, &wasm_path()).await.err().expect("a kernel failure is not an empty read");
        assert!(format!("{read_failure:#}").contains("invalid seed"), "{read_failure:#}");
        let query_failure = query(&client, &wasm_path(), "Banking::Customer.Suspended", serde_json::json!({})).await.err();
        assert!(query_failure.is_some_and(|e| format!("{e:#}").contains("invalid seed")));
        client.lock().await.execute("DELETE FROM hecks_lambda_journal WHERE verb = 'Banking::Customer.Register' AND ordinal > 1", &[]).await.unwrap();

        // Once the snapshot is whole again the next command works, and the
        // snapshot afterwards holds the whole world, not just its own instance.
        client.lock().await.execute("UPDATE hecks_lambda_snapshot SET seed = $1", &[&whole_world]).await.unwrap();
        let second = handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0002"), None, &config, &noinvoke).await.unwrap();
        assert!(second.accepted, "{:?}", second.result);
        let after = journal::load_snapshot(&*client.lock().await).await.unwrap().unwrap().seed;
        let keys: Vec<&String> = after.as_object().unwrap().keys().collect();
        assert_eq!(keys.len(), 2, "the snapshot holds both customers: {keys:?}");
        assert!(keys.iter().any(|k| k.contains("CUST-0001")) && keys.iter().any(|k| k.contains("CUST-0002")), "{keys:?}");
    }

    // The snapshot's ordinal and exact seed text, and how many commands are journaled.
    async fn snapshot_and_journal(client: &Mutex<Client>) -> (i64, String, i64) {
        let guard = client.lock().await;
        let snapshot = guard.query_one("SELECT ordinal, seed::text FROM hecks_lambda_snapshot", &[]).await.unwrap();
        let journaled: i64 = guard.query_one("SELECT count(*) FROM hecks_lambda_journal", &[]).await.unwrap().get(0);
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
        let client = scratch_db("rust_host_dispatch_test_3").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);
        let wasm_path = wasm_path();

        let (first, second) = tokio::join!(
            handle(&client, &wasm_path, "Banking::Customer.Register", register("CUST-0002"), None, &config, &lambda_client::NeverInvoker),
            handle(&client, &wasm_path, "Banking::Customer.Register", register("CUST-0002"), None, &config, &lambda_client::NeverInvoker),
        );
        let (first, second) = (first.unwrap(), second.unwrap());

        assert_ne!(
            first.accepted, second.accepted,
            "exactly one of two concurrent duplicate registrations should be accepted: {:?} / {:?}",
            first.result, second.result
        );
        let steps = journal::load_steps(&*client.lock().await).await.unwrap();
        assert_eq!(steps.len(), 1, "only the accepted registration should be persisted");
    }

    #[tokio::test]
    async fn read_reflects_prior_dispatches_without_persisting_anything_new() {
        let client = scratch_db("rust_host_dispatch_test_4").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;

        handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0003"),
            None,
            &test_config("Banking", 1),
            &lambda_client::NeverInvoker,
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
        let steps = journal::load_steps(&*client.lock().await).await.unwrap();
        assert_eq!(steps.len(), 1, "a read must never persist a journal row");
    }

    // Records every call and answers with a canned "nothing refused"
    // body, proving a cross-domain policy reaches `lambda_client::deliver`
    // with the right name/payload end to end, short of a real AWS Lambda.
    struct RecordingInvoker {
        calls: std::sync::Mutex<Vec<(String, String)>>,
    }

    impl RecordingInvoker {
        fn new() -> Self {
            Self { calls: std::sync::Mutex::new(Vec::new()) }
        }
    }

    #[async_trait::async_trait]
    impl LambdaInvoker for RecordingInvoker {
        async fn invoke(&self, function_name: &str, payload: &str) -> anyhow::Result<lambda_client::InvokeOutcome> {
            self.calls.lock().unwrap().push((function_name.to_string(), payload.to_string()));
            Ok(lambda_client::InvokeOutcome { body: serde_json::json!({ "refusals": [] }), function_error: false })
        }
    }

    #[tokio::test]
    async fn a_cross_domain_policy_delivers_through_the_real_rehydrate_replay_path() {
        let client = scratch_db("rust_host_dispatch_test_6").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer", "Account"]).await;
        let config = test_config("Banking", 1);
        let invoker = RecordingInvoker::new();

        handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0007"), None, &config, &invoker)
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
        handle(&client, &wasm_path(), "Banking::Account.Open", open_args, None, &config, &invoker)
            .await
            .unwrap()
            .accepted
            .then_some(())
            .expect("account open should succeed");

        // `FreezeAccount` announces `AccountFrozen`, matched by
        // `ReviewOnFreeze` (`across "Compliance"`) — the real trigger
        // this feature exists for.
        let freeze_args = serde_json::json!({ "number": { "value": "acct-freeze-me" } });
        let outcome = handle(&client, &wasm_path(), "Banking::Account.FreezeAccount", freeze_args, None, &config, &invoker)
            .await
            .unwrap();
        assert!(outcome.accepted, "freeze should succeed: {:?}", outcome.result);

        let deliveries = outcome.result["cross_domain_deliveries"].as_array().unwrap();
        assert_eq!(deliveries.len(), 1, "exactly one cross-domain reaction should have fired: {deliveries:?}");
        assert_eq!(deliveries[0]["policy"], "ReviewOnFreeze");
        assert_eq!(deliveries[0]["target_domain"], "Compliance");
        assert_eq!(deliveries[0]["delivered"], true);

        // The same delivery also merges into "reactions"
        // ({policy, on, trigger, delivered, reason}), alongside the
        // differently-shaped "cross_domain_deliveries" entry above.
        let reactions = outcome.result["reactions"].as_array().unwrap();
        let merged = reactions.iter().find(|r| r["policy"] == "ReviewOnFreeze").expect("ReviewOnFreeze should appear in \"reactions\" too");
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
        handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0008"), None, &config, &invoker)
            .await
            .unwrap();
        assert_eq!(invoker.calls.lock().unwrap().len(), 1, "replaying prior history must not re-deliver its cross-domain reaction");
    }

    // Pins the fix: this is the first test that reaches `check_role`
    // with a caller role actually bound and checked, not the unchecked
    // "no role at all" path every other test in this file uses.
    // `Register` requires `Some("Branch clerk")` in the generated
    // registry — real, corpus-declared.
    #[tokio::test]
    async fn a_role_gated_command_is_actually_checked_against_the_caller_role() {
        let client = scratch_db("rust_host_dispatch_test_7").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);

        // The correct role succeeds, same as every other registration,
        // just now with a caller actually bound and matching.
        let matching = handle(
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0009"),
            Some("Branch clerk"),
            &config,
            &lambda_client::NeverInvoker,
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
            &client,
            &wasm_path(),
            "Banking::Customer.Register",
            register("CUST-0010"),
            Some("Teller"),
            &config,
            &lambda_client::NeverInvoker,
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
        let steps = journal::load_steps(&*client.lock().await).await.unwrap();
        assert_eq!(steps.len(), 1, "only the correctly-authorized registration should be persisted");
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
            let stated = Caller { role: Some("Teller"), actor_id: None };
            assert_eq!(mode.effective(stated), stated, "a stated role is kept");
            let identified = Caller { role: None, actor_id: Some("u1") };
            assert_eq!(mode.effective(identified), identified, "an identified caller is kept");
        }
    }

    // The unidentified caller is the case the host never refused: no role at all.
    #[tokio::test]
    async fn an_unidentified_caller_is_refused_when_enforced_and_let_through_when_off_or_shadowed() {
        let client = scratch_db("rust_host_dispatch_test_enforce").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer"]).await;
        let config = test_config("Banking", 1);
        let go = |mode: Enforcement, id: &'static str| {
            let client = &client;
            let config = &config;
            async move {
                handle_with(mode, client, &wasm_path(), "Banking::Customer.Register", register(id), Caller::default(), config, &lambda_client::NeverInvoker)
                    .await
                    .unwrap()
            }
        };

        let off = go(Enforcement::Off, "CUST-0021").await;
        assert!(off.accepted, "off keeps the old behaviour: {:?}", off.result);

        let enforced = go(Enforcement::Enforce, "CUST-0022").await;
        assert!(!enforced.accepted, "an unidentified caller must be refused: {:?}", enforced.result);
        assert!(refused_for_role(&enforced.result), "{:?}", enforced.result);
        let error = enforced.result["refusals"][0]["error"].as_str().unwrap();
        assert!(error.contains("Branch clerk") && error.contains(ANONYMOUS_ROLE), "{error}");

        let shadowed = go(Enforcement::Shadow, "CUST-0023").await;
        assert!(shadowed.accepted, "shadow lets the command through: {:?}", shadowed.result);

        let steps = journal::load_steps(&*client.lock().await).await.unwrap();
        assert_eq!(steps.len(), 2, "the enforced refusal was not persisted; off and shadow were");
    }

    #[tokio::test]
    async fn a_mid_transaction_failure_rolls_back_any_saga_state_already_written() {
        // Deliberately doesn't provision "Transfer": its mutation fails
        // after `begin_saga` already wrote into `hecks_lambda_sagas`,
        // proving that write rolls back with the rest of the transaction.
        let client = scratch_db("rust_host_dispatch_test_9").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer", "Account"]).await;
        let config = test_config("Banking", 1);

        handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0012"), None, &config, &lambda_client::NeverInvoker)
            .await.unwrap().accepted.then_some(()).expect("registration should succeed");

        let open_src = serde_json::json!({
            "number": { "value": "src-rollback" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0012",
        });
        handle(&client, &wasm_path(), "Banking::Account.Open", open_src, None, &config, &lambda_client::NeverInvoker)
            .await.unwrap().accepted.then_some(()).expect("source account open should succeed");
        let open_dst = serde_json::json!({
            "number": { "value": "dst-rollback" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0012",
        });
        handle(&client, &wasm_path(), "Banking::Account.Open", open_dst, None, &config, &lambda_client::NeverInvoker)
            .await.unwrap().accepted.then_some(()).expect("destination account open should succeed");
        handle(
            &client, &wasm_path(), "Banking::Account.Credit",
            serde_json::json!({ "number": "src-rollback", "amount": { "cents": 1000 }, "narrative": { "text": "opening balance" } }),
            None, &config, &lambda_client::NeverInvoker,
        )
        .await.unwrap().accepted.then_some(()).expect("credit should succeed");

        // `Transfer.Request`'s own mutation is the first one this step
        // produces, and "Transfer" was never provisioned, so it fails
        // before the saga cascade runs further.
        let transfer_args = serde_json::json!({
            "reference": { "value": "tr-rollback" }, "amount": { "cents": 200 },
            "narrative": { "text": "rollback test" }, "source": "src-rollback", "destination": "dst-rollback",
        });
        let outcome = handle(&client, &wasm_path(), "Banking::Transfer.Request", transfer_args, None, &config, &lambda_client::NeverInvoker).await;
        assert!(outcome.is_err(), "the unprovisioned Transfer lineage table should make this whole invocation fail");

        let guard = client.lock().await;
        let saga_rows = guard.query("SELECT process_manager, correlation FROM hecks_lambda_sagas", &[]).await.unwrap();
        assert_eq!(
            saga_rows.len(), 0,
            "a saga write inside a transaction that ultimately fails must roll back with it, not commit independently: {saga_rows:?}"
        );
    }

    #[tokio::test]
    async fn a_pre_existing_snapshot_without_the_sagas_backfilled_latch_forces_one_full_replay() {
        let client = scratch_db("rust_host_dispatch_test_10").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer", "Account", "Transfer"]).await;
        let config = test_config("Banking", 1);
        // `ReviewOnFreeze` fires on every `FreezeAccount` in this domain
        // (proven above), so `NeverInvoker` would panic here.
        let invoker = RecordingInvoker::new();

        handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0013"), None, &config, &invoker)
            .await.unwrap().accepted.then_some(()).expect("registration should succeed");

        let open_src = serde_json::json!({
            "number": { "value": "src-backfill" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0013",
        });
        handle(&client, &wasm_path(), "Banking::Account.Open", open_src, None, &config, &invoker)
            .await.unwrap().accepted.then_some(()).expect("source account open should succeed");
        let open_dst = serde_json::json!({
            "number": { "value": "dst-backfill" }, "kind": { "name": "current" },
            "daily_limit": { "cents": 50000 }, "customer": "CUST-0013",
        });
        handle(&client, &wasm_path(), "Banking::Account.Open", open_dst, None, &config, &invoker)
            .await.unwrap().accepted.then_some(()).expect("destination account open should succeed");
        handle(
            &client, &wasm_path(), "Banking::Account.Credit",
            serde_json::json!({ "number": "src-backfill", "amount": { "cents": 1000 }, "narrative": { "text": "opening balance" } }),
            None, &config, &invoker,
        )
        .await.unwrap().accepted.then_some(()).expect("credit should succeed");

        // Freezing the destination first means the credit leg refuses
        // and Settlement compensates, leaving the saga stuck "reversed"
        // — exactly the mid-flight shape this test needs to recover.
        handle(&client, &wasm_path(), "Banking::Account.FreezeAccount", serde_json::json!({ "number": { "value": "dst-backfill" } }), None, &config, &invoker)
            .await.unwrap().accepted.then_some(()).expect("freeze should succeed");
        let transfer_args = serde_json::json!({
            "reference": { "value": "tr-backfill" }, "amount": { "cents": 200 },
            "narrative": { "text": "backfill test" }, "source": "src-backfill", "destination": "dst-backfill",
        });
        handle(&client, &wasm_path(), "Banking::Transfer.Request", transfer_args, None, &config, &invoker)
            .await.unwrap().accepted.then_some(()).expect("the Transfer.Request COMMAND succeeds; the saga's own credit leg is what refuses");

        {
            let guard = client.lock().await;
            let before = guard.query("SELECT process_manager, correlation, state FROM hecks_lambda_sagas", &[]).await.unwrap();
            assert_eq!(before.len(), 1, "the reversed Settlement instance should already be tracked before the simulated reset: {before:?}");
        }

        // Simulates a pre-saga-durability snapshot: the latch false and
        // `hecks_lambda_sagas` empty, even though a saga is genuinely
        // mid-flight.
        {
            let guard = client.lock().await;
            guard.execute("UPDATE hecks_lambda_snapshot SET sagas_backfilled = false", &[]).await.unwrap();
            guard.execute("DELETE FROM hecks_lambda_sagas", &[]).await.unwrap();
        }

        // One more command should trigger a full replay, whose saga
        // cascade re-running as a side effect repopulates
        // `hecks_lambda_sagas`.
        handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0014"), None, &config, &invoker)
            .await.unwrap().accepted.then_some(()).expect("second registration should succeed");

        let guard = client.lock().await;
        let saga_rows = guard.query("SELECT process_manager, correlation, state FROM hecks_lambda_sagas", &[]).await.unwrap();
        assert_eq!(saga_rows.len(), 1, "the backfill replay should have recovered the in-flight Settlement instance: {saga_rows:?}");
        let process_manager: String = saga_rows[0].get(0);
        let correlation: String = saga_rows[0].get(1);
        let state: String = saga_rows[0].get(2);
        assert_eq!(process_manager, "Settlement");
        assert_eq!(correlation, "tr-backfill");
        assert_eq!(state, "reversed");

        let latched: bool = guard.query_one("SELECT sagas_backfilled FROM hecks_lambda_snapshot", &[]).await.unwrap().get(0);
        assert!(latched, "after the backfill replay, the latch should be set so this doesn't repeat every invocation");
    }

    // Always fails with a hard invoke fault, the shape an unreachable
    // Lambda has — proves the exhausted-retry/dead-letter path.
    struct AlwaysFailingInvoker {
        calls: std::sync::Mutex<u32>,
    }

    impl AlwaysFailingInvoker {
        fn new() -> Self {
            Self { calls: std::sync::Mutex::new(0) }
        }
    }

    #[async_trait::async_trait]
    impl LambdaInvoker for AlwaysFailingInvoker {
        async fn invoke(&self, _function_name: &str, _payload: &str) -> anyhow::Result<lambda_client::InvokeOutcome> {
            *self.calls.lock().unwrap() += 1;
            anyhow::bail!("ResourceNotFoundException: function not found")
        }
    }

    #[tokio::test]
    async fn a_cross_domain_delivery_that_exhausts_every_retry_dead_letters_and_still_fails_the_invocation() {
        let client = scratch_db("rust_host_dispatch_test_8").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer", "Account"]).await;
        let config = test_config("Banking", 1);
        let invoker = AlwaysFailingInvoker::new();

        handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0011"), None, &config, &invoker)
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
        handle(&client, &wasm_path(), "Banking::Account.Open", open_args, None, &config, &invoker)
            .await
            .unwrap()
            .accepted
            .then_some(())
            .expect("account open should succeed");

        // `ReviewOnFreeze` fires here — every attempt against
        // `AlwaysFailingInvoker` fails, so `deliver_with_retry` exhausts
        // `MAX_DELIVERY_ATTEMPTS` before `handle` ever sees a result.
        let freeze_args = serde_json::json!({ "number": { "value": "acct-freeze-dead-letter" } });
        let outcome = handle(&client, &wasm_path(), "Banking::Account.FreezeAccount", freeze_args, None, &config, &invoker).await;

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
        let guard = client.lock().await;
        let dead_letters = guard
            .query("SELECT policy, target_domain, target_verb, attempts FROM hecks_cross_domain_dead_letters", &[])
            .await
            .unwrap();
        assert_eq!(dead_letters.len(), 1, "exactly one exhausted delivery should have been dead-lettered: {dead_letters:?}");
        let policy: String = dead_letters[0].get(0);
        let target_domain: String = dead_letters[0].get(1);
        let target_verb: String = dead_letters[0].get(2);
        let attempts: i32 = dead_letters[0].get(3);
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
        let client = scratch_db("rust_host_dispatch_test_11").await;
        provision_lineage(&*client.lock().await, "Banking", 1, &["Customer", "SafeDepositBox"]).await;
        let config = test_config("Banking", 1);
        let invoker = AlwaysFailingInvoker::new();

        handle(&client, &wasm_path(), "Banking::Customer.Register", register("CUST-0022"), None, &config, &invoker)
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
        handle(&client, &wasm_path(), "Banking::SafeDepositBox.Rent", rent_args, None, &config, &invoker)
            .await
            .unwrap()
            .accepted
            .then_some(())
            .expect("rent should succeed");

        // Both ReviewOnBoxSurrender (-> Compliance) and FlagKeyReturn
        // (-> Notifications) fire here; both deliveries exhaust every
        // retry against AlwaysFailingInvoker.
        let surrender_args = serde_json::json!({ "branch_code": { "value": "downtown" }, "box_number": { "value": 12 } });
        let outcome =
            handle(&client, &wasm_path(), "Banking::SafeDepositBox.Surrender", surrender_args, None, &config, &invoker)
                .await;

        assert!(outcome.is_err(), "still fails the invocation visibly, same contract as a single failed delivery");
        assert_eq!(
            *invoker.calls.lock().unwrap(),
            lambda_client::MAX_DELIVERY_ATTEMPTS * 2,
            "BOTH reactions should have been attempted MAX_DELIVERY_ATTEMPTS times each — \
             the fix under test is exactly this: a fresh Vec would only ever show one policy's worth"
        );

        let guard = client.lock().await;
        let dead_letters = guard
            .query("SELECT policy FROM hecks_cross_domain_dead_letters ORDER BY policy", &[])
            .await
            .unwrap();
        let policies: Vec<String> = dead_letters.iter().map(|row| row.get(0)).collect();
        assert_eq!(
            policies,
            vec!["FlagKeyReturn".to_string(), "ReviewOnBoxSurrender".to_string()],
            "BOTH sibling reactions must be dead-lettered, not just whichever ran first: {policies:?}"
        );
    }
}
