//! run_host — the generic standalone effect-port HOST.
//!
//! [antibody-exempt: rust/src/run_host/mod.rs — kernel-floor runtime glue.
//!  The standalone adapter HOST that consumes the OutboundEvent transactional
//!  outbox out-of-process. Sibling of run_serve/ and loop_driver.rs : a
//!  long-running runtime DRIVER (boot once, tick at a cadence). A bluebook
//!  can't describe its own process-lifetime polling substrate — the
//!  OutboundEvent LIFECYCLE is the bluebook contract (Claim / MarkDelivered /
//!  MarkFailed / Pending), this module only adds the boot + tick + child-exec
//!  wrapper around it, dispatching the SAME bluebook commands the in-crate
//!  oracle test (effect_outbound_record_test.rs) drives by hand.]
//!
//! `storehouse host <root> [--every <dur>] [--once]`
//!
//! Each tick (default ~1s ; `--once` runs a single pass and exits) :
//!   1. snapshot every OutboundEvent still `pending` (read via `all`, filtered —
//!      the Pending query returns a single `state`, the host wants the whole
//!      set ; the driver reads the full repo and filters, its prerogative).
//!   2. for each pending delivery, in order :
//!        a. Claim it (pending→claimed) BEFORE exec, so a second host can't
//!           double-run. A Claim error means another host took it — skip.
//!        b. resolve the named adapter to its handler program + family, fold
//!           its `.world` config into the child env, exec the handler with the
//!           payload on stdin. Capture stdout `k=v` verdict lines + exit code.
//!        c. VERDICT : a delivery that NAMED a verdict command (effect-with-
//!           verdict, e.g. payment) re-enters it — exit 0 → success_command,
//!           non-zero → failure_command — threading the stdout pairs + the
//!           source_id. A fire-and-forget delivery (both commands empty, e.g.
//!           a voiced_by bind) dispatches no verdict.
//!        d. ACK : a delivery that REACHED a verdict (a verdict command was
//!           dispatched, success OR failure) is MarkDelivered — "delivered"
//!           means HANDLED, not "approved". Only a spawn/exec error, or a
//!           fire-and-forget non-zero with no failure_command, is MarkFailed
//!           (which returns it to pending for a legitimate retry).
//!
//! WHY "reached-verdict → MarkDelivered" and not "non-zero → MarkFailed" :
//! the OutboundEvent.MarkFailed command sets status back to `pending`, NOT to
//! `failed` (read outbound_event.bluebook — no command ever sets "failed").
//! So MarkFailed-ing a DECLINED charge would re-queue it ; the next tick would
//! re-claim and re-exec the handler — re-charging the card every tick. That
//! violates the no-silent-retry standard. A reached decline is a VERDICT, not
//! a retryable transport error : the host dispatches Decline and closes the
//! delivery (the bluebook's MarkFailed description explicitly blesses this
//! "dispatch failure_command + MarkDelivered" host policy).
//!
//! CONCURRENCY (v1) : serial + blocking child wait. A hung handler wedges the
//! whole tick — acceptable for v1, NOT parallelism. A future version moves
//! exec onto a bounded thread pool with the per-adapter timeout from `.world`.

mod config;
/// Public so the in-runtime primary-adapter wait
/// (`Runtime::drain_outbound_to_quiescence`) can reuse `run_handler` — the
/// blocking, verdict-capturing handler exec primitive — without duplicating it.
pub mod exec;

use crate::runtime::{Runtime, Value};
use std::collections::HashMap;
use std::time::Duration;

/// `storehouse host <root> [--every <dur>] [--once]` — the CLI driver. Boots
/// the runtime against `<root>` ONCE (same combined-domain + hecksagons +
/// world path loop/clock use), then runs host passes : `--once` runs a single
/// pass and exits ; otherwise it ticks at `--every` (default 1s) forever.
///
/// `boot_runtime` is injected so the test can construct an in-memory runtime ;
/// the CLI passes the disk boot.
pub fn run(args: &[String], boot_runtime: impl FnOnce() -> Runtime) {
    let once = args.iter().any(|a| a == "--once");
    let every = args
        .iter()
        .position(|a| a == "--every")
        .and_then(|i| args.get(i + 1))
        .and_then(|s| parse_duration(s))
        .unwrap_or_else(|| Duration::from_secs(1));

    let mut rt = boot_runtime();
    if once {
        let n = run_host_pass(&mut rt);
        eprintln!("[storehouse host] single pass acted on {} delivery(ies)", n);
        return;
    }
    eprintln!("[storehouse host] polling every {:?} (Ctrl-C to stop)", every);
    loop {
        run_host_pass(&mut rt);
        std::thread::sleep(every);
    }
}

/// Tiny duration parser (1s / 500ms / 2m). Mirrors loop's accepted forms.
fn parse_duration(s: &str) -> Option<Duration> {
    let s = s.trim();
    if let Some(ms) = s.strip_suffix("ms") {
        return ms.parse::<u64>().ok().map(Duration::from_millis);
    }
    if let Some(sec) = s.strip_suffix('s') {
        return sec.parse::<u64>().ok().map(Duration::from_secs);
    }
    if let Some(m) = s.strip_suffix('m') {
        return m.parse::<u64>().ok().map(|v| Duration::from_secs(v * 60));
    }
    s.parse::<u64>().ok().map(Duration::from_secs)
}

/// One pending delivery, snapshotted out of the runtime under the immutable
/// borrow so the mutable Claim/dispatch/ack phase can take `&mut rt`.
struct Delivery {
    delivery_id: String,
    adapter: String,
    source_id: String,
    payload: String,
    success_command: String,
    failure_command: String,
}

fn field(state: &crate::runtime::AggregateState, key: &str) -> String {
    state.get(key).as_str().unwrap_or("").to_string()
}

/// Snapshot every OutboundEvent still pending — the host's poll. Read via
/// `all` + filter (not the Pending query, which returns one `state`) so a
/// single pass drains the whole backlog.
fn pending_deliveries(rt: &Runtime) -> Vec<Delivery> {
    rt.all("OutboundEvent")
        .into_iter()
        .filter(|s| field(s, "status") == "pending")
        .map(|s| Delivery {
            delivery_id: field(s, "delivery_id"),
            adapter: field(s, "adapter"),
            source_id: field(s, "source_id"),
            payload: field(s, "payload"),
            success_command: field(s, "success_command"),
            failure_command: field(s, "failure_command"),
        })
        .collect()
}

fn str_attr(k: &str, v: &str) -> (String, Value) {
    (k.to_string(), Value::Str(v.to_string()))
}

/// Run ONE host pass : claim, exec, dispatch verdict, ack — for every delivery
/// pending at pass start. Returns the number of deliveries acted on. This is
/// the testable core (`--once` and each `--every` tick call it) ; the oracle
/// test drives it directly against an in-memory runtime.
pub fn run_host_pass(rt: &mut Runtime) -> usize {
    let deliveries = pending_deliveries(rt);
    let mut acted = 0;
    for d in deliveries {
        // a. Claim BEFORE exec — the at-least-once guard. `given status ==
        //    pending` makes a second host's Claim error : skip, it's not ours.
        let mut claim = HashMap::new();
        claim.insert("delivery_id".to_string(), Value::Str(d.delivery_id.clone()));
        if rt.dispatch("Claim", claim).is_err() {
            continue;
        }
        acted += 1;

        // b. Resolve the adapter's handler + family, map its `.world` block
        //    onto the canonical child env (field-source convention), exec
        //    off-core.
        let (handler, family) = rt.adapter_handler(&d.adapter).unwrap_or_default();
        if handler.is_empty() {
            mark_failed(rt, &d.delivery_id, &format!("no handler for adapter {}", d.adapter));
            continue;
        }
        let world = rt.adapter_world_config(&d.adapter);
        let env = config::map_config(&family, &world, &rt.family_fields(&family));
        let outcome = exec::run_handler(&handler, &d.payload, &env);

        match outcome {
            Err(e) => {
                // Spawn / exec error — a retryable transport failure, not a
                // verdict. Return to pending (MarkFailed) for another pass.
                mark_failed(rt, &d.delivery_id, &e);
            }
            Ok(result) => {
                let verdict = if result.success {
                    &d.success_command
                } else {
                    &d.failure_command
                };
                if verdict.is_empty() {
                    // Fire-and-forget edge (e.g. a voiced_by bind) : no verdict to
                    // re-enter. Exit 0 is delivered ; a non-zero with no
                    // failure_command to dispatch is a failed attempt (retry).
                    if result.success {
                        mark_delivered(rt, &d.delivery_id);
                    } else {
                        mark_failed(rt, &d.delivery_id, "handler failed (fire-and-forget, no failure_command)");
                    }
                } else {
                    // Effect-with-verdict : re-enter the named command through
                    // the command port, threading the stdout k=v pairs + the
                    // originating source_id (universal-id fallback).
                    let mut attrs: HashMap<String, Value> = result
                        .verdict_pairs
                        .iter()
                        .map(|(k, v)| str_attr(k, v))
                        .collect();
                    attrs.insert("id".to_string(), Value::Str(d.source_id.clone()));
                    // The verdict is the FQN the binding recorded
                    // (e.g. "Shop::Order.Authorize") ; dispatch resolves it.
                    if let Err(e) = rt.dispatch(verdict, attrs) {
                        eprintln!("[storehouse host] verdict {} error: {:?}", verdict, e);
                    }
                    // A reached verdict (approved OR declined) is HANDLED.
                    mark_delivered(rt, &d.delivery_id);
                }
            }
        }
    }
    acted
}

fn mark_delivered(rt: &mut Runtime, delivery_id: &str) {
    let mut a = HashMap::new();
    a.insert("delivery_id".to_string(), Value::Str(delivery_id.to_string()));
    if let Err(e) = rt.dispatch("MarkDelivered", a) {
        eprintln!("[storehouse host] MarkDelivered({}) error: {:?}", delivery_id, e);
    }
}

fn mark_failed(rt: &mut Runtime, delivery_id: &str, error: &str) {
    let mut a = HashMap::new();
    a.insert("delivery_id".to_string(), Value::Str(delivery_id.to_string()));
    a.insert("error".to_string(), Value::Str(error.to_string()));
    if let Err(e) = rt.dispatch("MarkFailed", a) {
        eprintln!("[storehouse host] MarkFailed({}) error: {:?}", delivery_id, e);
    }
}
