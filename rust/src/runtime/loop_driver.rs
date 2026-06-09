//! LoopDriver — continuous-tick PM scheduler
//!
//! The runtime daemon. Boots once, holds a Runtime, ticks at a
//! configured cadence, fires events / dispatches commands that drive
//! process_managers + policies forward without the per-tick boot cost
//! the shell `while true ; do storehouse ... ; sleep 1 ; done` pattern
//! pays.
//!
//! Substrate for retiring `mindstream.sh` : that shell exists because
//! no Rust scheduler does. With LoopDriver, the cadence becomes Rust
//! and the bluebook-declared PMs (SleepCycle, Dream, Mind) react to
//! each tick's events through the same machinery that runs in the
//! one-shot dispatch path.
//!
//! Usage :
//!   let mut driver = LoopDriver::new(runtime, Duration::from_secs(1));
//!   driver.add_dispatch("Pulse.Emit", attrs);
//!   driver.run();   // blocks until interrupted
//!
//! [antibody-exempt: rust/src/runtime/loop_driver.rs — kernel-floor
//!  scheduler. Honors the LoopDriver aggregate declared in
//!  runtime/loop_driver/loop_driver.bluebook (Tick command + lifecycle ;
//!  RegisterAction / RegisterBootstrap / Stop). The cadence bluebooks
//!  (body_tick / heart_tick / breath_tick) declare WHICH cadences
//!  exist ; LoopDriver declares HOW each tick orchestrates. Mirror
//!  of policy_engine.rs / pm_engine.rs in scope : generic interpreter
//!  for declared cadences. Retires alongside mindstream.sh once the
//!  block_grammar primitives land and a future LoopRunner reads
//!  cadences declaratively.
//!  i223 (2026-05-02) — adds BootstrapEmit : a one-shot first-tick
//!  synthetic-event injection gated on an aggregate-state predicate.
//!  Closes the mind-pm-bootstrap-on-attentive-restart gap.
//!  i517 (2026-05-09) — adds the freshness sweep at the start of
//!  each tick (refresh_repositories_from_heki). Honors the
//!  storage.bluebook RefreshOnPulse policy ; the loop's in-memory
//!  view of state stays current with disk between processes.]
//!
//! Time : `std::thread::sleep`. The runtime is sync ; bringing in tokio
//! is a much larger choice. Sync sleep gives us 1Hz cadence with
//! sub-millisecond drift across reasonable runs ; if drift matters,
//! switch to a deadline-based scheduler in a follow-up.
//!
//! Shutdown : the loop checks an `AtomicBool` between ticks. Callers
//! can flip the flag from a signal handler (or from a test). PM state
//! is persisted on every transition by the existing `drain_policies`
//! cascade in `runtime/mod.rs`, so even hard-kill loses no PM state —
//! the worst case is replaying one tick's policy cascade.

use super::{Event, Runtime, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Resolve `{now}` / `{now+N}` / `{now-N}` clock tokens in a dispatched
/// attr map (the cadence-loop write path, mirroring interpolate_event on
/// the hecksagon write path). Only string values are scanned ; the
/// resolver is a no-op for any value without a `{now` token, so the
/// per-tick cost is one substring check per string attr. HECKS_NOW pins
/// the base instant for deterministic tests.
fn resolve_now_attrs(attrs: HashMap<String, Value>) -> HashMap<String, Value> {
    attrs
        .into_iter()
        .map(|(k, v)| match v {
            Value::Str(s) => (
                k,
                Value::Str(crate::runtime::storehouse_log::interpolate_now_tokens(&s)),
            ),
            other => (k, other),
        })
        .collect()
}

/// One scheduled action per tick. Either a synthetic event (drives
/// PMs only, no command pipeline) or a command dispatch (full
/// pipeline : givens → mutations → emit → cascade).
#[derive(Debug, Clone)]
pub enum TickAction {
    Emit {
        event_name: String,
        aggregate_type: String,
        aggregate_id: String,
        data: HashMap<String, Value>,
    },
    Dispatch {
        command_name: String,
        attrs: HashMap<String, Value>,
    },
}

/// One-shot bootstrap on the FIRST tick — fires the embedded `event`
/// only when the named aggregate's named field equals the expected
/// value. Closes the i223 gap : a daemon restarting while
/// `Consciousness.state == "attentive"` never sees a fresh `WokenUp`,
/// so PMs that `starts_on "WokenUp"` (Mind, future ones) are stranded
/// — no instance, the wake handler is inert. The bootstrap injects a
/// synthetic WokenUp on first tick when the state predicate matches,
/// putting Mind PM's instance into existence without requiring a
/// sleep/wake cycle.
///
/// The `event` field is a `TickAction::Emit` ; we reuse the variant
/// instead of a fresh struct so the bootstrap path runs through the
/// same `publish_synthetic_event` plumbing as a normal emit.
#[derive(Debug, Clone)]
pub struct BootstrapEmit {
    pub aggregate_type: String,
    pub aggregate_id: String,
    pub field: String,
    pub expected: String,
    pub event: TickAction,
}

pub struct LoopDriver {
    runtime: Runtime,
    interval: Duration,
    actions: Vec<TickAction>,
    /// i223 — bootstraps fire ONCE on the first tick when their
    /// state predicate matches. Drained after the first tick so the
    /// emission can never replay.
    bootstraps: Vec<BootstrapEmit>,
    stop_flag: Arc<AtomicBool>,
    tick_count: u64,
}

impl LoopDriver {
    pub fn new(runtime: Runtime, interval: Duration) -> Self {
        Self {
            runtime,
            interval,
            actions: Vec::new(),
            bootstraps: Vec::new(),
            stop_flag: Arc::new(AtomicBool::new(false)),
            tick_count: 0,
        }
    }

    /// i223 — register a one-shot bootstrap. Fires once on the first
    /// tick if `aggregate.field == expected` ; the embedded event is
    /// then injected via `publish_synthetic_event`. After the first
    /// tick the bootstrap is drained, regardless of whether the
    /// predicate matched (predicate is evaluated against state at
    /// boot time ; later transitions will produce real WokenUp events
    /// through the regular dispatch path).
    pub fn add_bootstrap(&mut self, bootstrap: BootstrapEmit) {
        self.bootstraps.push(bootstrap);
    }

    /// Stop flag — flip from a signal handler or test thread to break
    /// the run loop on the next tick boundary.
    pub fn stop_flag(&self) -> Arc<AtomicBool> {
        self.stop_flag.clone()
    }

    pub fn add_action(&mut self, action: TickAction) {
        self.actions.push(action);
    }

    pub fn add_emit(
        &mut self,
        event_name: &str,
        aggregate_type: &str,
        aggregate_id: &str,
        data: HashMap<String, Value>,
    ) {
        self.add_action(TickAction::Emit {
            event_name: event_name.to_string(),
            aggregate_type: aggregate_type.to_string(),
            aggregate_id: aggregate_id.to_string(),
            data,
        });
    }

    pub fn add_dispatch(&mut self, command_name: &str, attrs: HashMap<String, Value>) {
        self.add_action(TickAction::Dispatch {
            command_name: command_name.to_string(),
            attrs,
        });
    }

    /// Borrow the inner runtime — tests inspect PM state through this.
    pub fn runtime(&self) -> &Runtime { &self.runtime }
    pub fn runtime_mut(&mut self) -> &mut Runtime { &mut self.runtime }

    pub fn tick_count(&self) -> u64 { self.tick_count }

    /// Run forever (or until `stop_flag` is set). Sleeps `interval`
    /// between ticks ; the tick itself fires every action in order.
    pub fn run(&mut self) {
        while !self.stop_flag.load(Ordering::Relaxed) {
            let started = Instant::now();
            self.tick_once();
            let elapsed = started.elapsed();
            if elapsed < self.interval {
                std::thread::sleep(self.interval - elapsed);
            }
        }
    }

    /// Run for a fixed number of ticks. Used by tests that want
    /// deterministic loop progression without spawning a stop thread.
    pub fn run_ticks(&mut self, ticks: u64) {
        for _ in 0..ticks {
            if self.stop_flag.load(Ordering::Relaxed) { break; }
            self.tick_once();
        }
    }

    /// One tick : fire every registered action, swallowing errors so
    /// a single bad dispatch can't kill the daemon. Errors print to
    /// stderr ; the audit trail for production diagnosis is heki +
    /// the existing dispatch-context breadcrumbs.
    ///
    /// First tick only : drain `bootstraps` first so the predicate-
    /// gated synthetic emissions (WokenUp on attentive-restart, i223)
    /// land BEFORE regular cadence actions on the same tick. Order
    /// matters : Mind PM must see WokenUp before BodyPulse so the
    /// instance exists when BodyPulse arrives and the wake handler
    /// can match the engaged_in_wake transition.
    pub fn tick_once(&mut self) {
        self.tick_count = self.tick_count.wrapping_add(1);
        // Freshness sweep — reload any repo whose heki file has been
        // written by a sibling process since our last touch. The
        // kernel-floor implementation of the RefreshOnPulse policy
        // declared in runtime/storage/storage.bluebook. Runs BEFORE
        // bootstraps + actions so the predicate-and-emit + cascade
        // dispatches see the freshest state. Cost when nothing
        // changed : one stat() per repo per tick. Closes the i517
        // cross-process staleness root cause.
        self.runtime.refresh_repositories_from_heki();
        if !self.bootstraps.is_empty() {
            let drained: Vec<BootstrapEmit> = std::mem::take(&mut self.bootstraps);
            for boot in drained {
                self.fire_bootstrap(boot);
            }
        }
        for action in self.actions.clone() {
            match action {
                TickAction::Emit { event_name, aggregate_type, aggregate_id, data } => {
                    let event = Event {
                        name: event_name,
                        aggregate_type,
                        aggregate_id,
                        data,
                    };
                    self.runtime.publish_synthetic_event(event);
                }
                TickAction::Dispatch { command_name, attrs } => {
                    // Resolve `{now}` / `{now+N}` / `{now-N}` clock tokens
                    // FRESH on every tick, so a cadence line like
                    // `storehouse loop ... Worker.Heartbeat stale_after={now+N}`
                    // writes the real wall-clock instant each beat (not a
                    // value frozen at registration time). HECKS_NOW still
                    // freezes it for deterministic tests.
                    let attrs = resolve_now_attrs(attrs);
                    if let Err(e) = self.runtime.dispatch(&command_name, attrs) {
                        eprintln!("[loop_driver] dispatch error '{}': {:?}",
                                  command_name, e);
                    }
                    // C3 (transactional outbox) — drain the persistent queue
                    // each tick. No-op while gated off; wired for the cutover.
                    self.runtime.pump_outbox();
                }
            }
        }
        // Sprint 14 — fire every attached `driving on cron` adapter
        // handler once per tick. v1 doesn't evaluate the cron
        // expression : every tick fires every cron handler. A follow-up
        // card adds expression-aware scheduling (parse 5-field cron,
        // keep last-fire-at per handler, fire only when due). No-op
        // when no hecksagons are attached or no cron handlers declared,
        // so this stays free for the historical `storehouse loop` path.
        self.runtime.fire_driving_cron_ticks();
    }

    /// i223 — evaluate a bootstrap's predicate against the current
    /// runtime state and fire its embedded emit when matched. Reads
    /// the named aggregate's identified record (looking up by
    /// aggregate_id) and compares `field` against `expected` as a
    /// string. Mismatch / missing aggregate / missing field all skip
    /// the emission silently — the bootstrap's whole point is to be
    /// inert when the predicate doesn't apply.
    ///
    /// String comparison only : the runtime stores Values in mixed
    /// shapes (Str, Int, Bool) but the bootstrap CLI surface only
    /// passes string expected values, so we render the field with
    /// `format_value_string` and compare bytes. Equivalent to how
    /// `--gate` (i108) compares heki field values.
    fn fire_bootstrap(&mut self, boot: BootstrapEmit) {
        let matched = match self.runtime.find(&boot.aggregate_type, &boot.aggregate_id) {
            Some(state) => {
                let actual = format_value_string(state.get(&boot.field));
                actual == boot.expected
            }
            None => false,
        };
        if !matched {
            eprintln!(
                "[loop_driver] bootstrap skipped : {}.{}={} did not match (aggregate {} not found or field absent)",
                boot.aggregate_type, boot.field, boot.expected, boot.aggregate_id
            );
            return;
        }
        if let TickAction::Emit { event_name, aggregate_type, aggregate_id, data } = boot.event {
            eprintln!(
                "[loop_driver] bootstrap fired : {}.{}={} → emit {}:{}:{}",
                boot.aggregate_type, boot.field, boot.expected,
                event_name, aggregate_type, aggregate_id
            );
            let event = Event {
                name: event_name,
                aggregate_type,
                aggregate_id,
                data,
            };
            self.runtime.publish_synthetic_event(event);
        }
    }
}

/// Render a Value into its bare string form for predicate
/// comparison. Matches the stringification the heki/cli layer
/// produces ; numeric values keep their literal digits, booleans
/// become "true"/"false", null renders empty.
fn format_value_string(v: &Value) -> String {
    match v {
        Value::Str(s) => s.clone(),
        Value::Int(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Null => String::new(),
        Value::List(_) | Value::Map(_) => format!("{:?}", v),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser;

    fn empty_runtime() -> Runtime {
        // Minimal bluebook with one no-op aggregate — parser is the
        // canonical way to build a Domain ; constructing the IR by
        // hand bakes in field churn. `identified_by :name` so the
        // repository keys saved records by their `name` field, which
        // matches the dispatch path the i223 bootstrap predicate
        // queries against.
        let src = r#"
            Hecks.bluebook "LoopDriverTest" do
              aggregate "Tick" do
                identified_by :name
                attribute :name, :string
                attribute :state, :string
              end
            end
        "#;
        Runtime::boot(parser::parse(src))
    }

    #[test]
    fn run_ticks_advances_tick_count() {
        let mut d = LoopDriver::new(empty_runtime(), Duration::from_millis(1));
        d.run_ticks(3);
        assert_eq!(d.tick_count(), 3);
    }

    #[test]
    fn stop_flag_breaks_run_ticks_early() {
        let mut d = LoopDriver::new(empty_runtime(), Duration::from_millis(1));
        d.stop_flag().store(true, Ordering::Relaxed);
        d.run_ticks(10);
        assert_eq!(d.tick_count(), 0);
    }

    #[test]
    fn emit_fires_event_into_bus() {
        let mut d = LoopDriver::new(empty_runtime(), Duration::from_millis(1));
        d.add_emit("BodyPulse", "Pulse", "pulse", HashMap::new());
        d.run_ticks(2);
        assert_eq!(d.runtime().event_bus.events().len(), 2);
        assert_eq!(d.runtime().event_bus.events()[0].name, "BodyPulse");
    }

    /// i223 — seed an aggregate state directly into the runtime's
    /// repository. Bypasses the dispatch path (the DSL parser-built
    /// runtime in this test module has no commands defined) so the
    /// bootstrap predicate has something to read against.
    /// Repos may key by either bare name or "Context::Name" depending
    /// on whether the bluebook declared a context — find the right
    /// key by suffix.
    fn seed_tick_state(rt: &mut Runtime, id: &str, state_value: &str) {
        use crate::runtime::AggregateState;
        let mut s = AggregateState::new(id);
        s.set("state", Value::Str(state_value.into()));
        let key = rt.repositories.keys()
            .find(|k| k.as_str() == "Tick" || k.ends_with("::Tick"))
            .cloned()
            .expect("Tick repository must exist");
        let repo = rt.repositories.get_mut(&key).unwrap();
        let ctx = crate::heki::WriteContext::OutOfBand { reason: "test seed" };
        repo.save(s, ctx);
    }

    /// i223 — bootstrap predicate matches → embedded emit fires
    /// once on the first tick, before regular cadence actions.
    #[test]
    fn bootstrap_fires_when_predicate_matches() {
        let mut rt = empty_runtime();
        seed_tick_state(&mut rt, "tick", "attentive");

        let mut d = LoopDriver::new(rt, Duration::from_millis(1));
        d.add_bootstrap(BootstrapEmit {
            aggregate_type: "Tick".into(),
            aggregate_id: "tick".into(),
            field: "state".into(),
            expected: "attentive".into(),
            event: TickAction::Emit {
                event_name: "WokenUp".into(),
                aggregate_type: "Tick".into(),
                aggregate_id: "tick".into(),
                data: HashMap::new(),
            },
        });
        d.run_ticks(2);

        let events = d.runtime().event_bus.events();
        // WokenUp from bootstrap on tick 1. No re-emit on tick 2 —
        // bootstraps drain after first tick.
        let woken = events.iter().filter(|e| e.name == "WokenUp").count();
        assert_eq!(woken, 1, "bootstrap fires exactly once");
    }

    /// i223 — bootstrap predicate fails → no emit, no panic.
    #[test]
    fn bootstrap_silent_when_predicate_does_not_match() {
        let mut rt = empty_runtime();
        seed_tick_state(&mut rt, "tick", "sleeping");

        let mut d = LoopDriver::new(rt, Duration::from_millis(1));
        d.add_bootstrap(BootstrapEmit {
            aggregate_type: "Tick".into(),
            aggregate_id: "tick".into(),
            field: "state".into(),
            expected: "attentive".into(),
            event: TickAction::Emit {
                event_name: "WokenUp".into(),
                aggregate_type: "Tick".into(),
                aggregate_id: "tick".into(),
                data: HashMap::new(),
            },
        });
        d.run_ticks(1);
        let woken = d.runtime().event_bus.events()
            .iter().filter(|e| e.name == "WokenUp").count();
        assert_eq!(woken, 0, "predicate mismatch → no emit");
    }

    /// i223 — bootstrap with missing aggregate → silent skip.
    #[test]
    fn bootstrap_silent_when_aggregate_absent() {
        let mut d = LoopDriver::new(empty_runtime(), Duration::from_millis(1));
        d.add_bootstrap(BootstrapEmit {
            aggregate_type: "Tick".into(),
            aggregate_id: "missing".into(),
            field: "state".into(),
            expected: "attentive".into(),
            event: TickAction::Emit {
                event_name: "WokenUp".into(),
                aggregate_type: "Tick".into(),
                aggregate_id: "missing".into(),
                data: HashMap::new(),
            },
        });
        d.run_ticks(1);
        let woken = d.runtime().event_bus.events()
            .iter().filter(|e| e.name == "WokenUp").count();
        assert_eq!(woken, 0);
    }
}
