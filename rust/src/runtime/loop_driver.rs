//! LoopDriver — continuous-tick PM scheduler
//!
//! The runtime daemon. Boots once, holds a Runtime, ticks at a
//! configured cadence, fires events / dispatches commands that drive
//! process_managers + policies forward without the per-tick boot cost
//! the shell `while true ; do hecks-life ... ; sleep 1 ; done` pattern
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
//!  scheduler. The cadence bluebook (body_tick / heart_tick / breath_tick)
//!  is the declarative source of truth ; this file is the Rust runtime
//!  that drives it. Mirror of policy_engine.rs / pm_engine.rs in scope :
//!  generic interpreter for declared cadences. Retires alongside
//!  mindstream.sh once the cadence-bluebook + block_grammar primitives
//!  land and a future LoopRunner reads cadences declaratively.]
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

pub struct LoopDriver {
    runtime: Runtime,
    interval: Duration,
    actions: Vec<TickAction>,
    stop_flag: Arc<AtomicBool>,
    tick_count: u64,
}

impl LoopDriver {
    pub fn new(runtime: Runtime, interval: Duration) -> Self {
        Self {
            runtime,
            interval,
            actions: Vec::new(),
            stop_flag: Arc::new(AtomicBool::new(false)),
            tick_count: 0,
        }
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
    pub fn tick_once(&mut self) {
        self.tick_count = self.tick_count.wrapping_add(1);
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
                    if let Err(e) = self.runtime.dispatch(&command_name, attrs) {
                        eprintln!("[loop_driver] dispatch error '{}': {:?}",
                                  command_name, e);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser;

    fn empty_runtime() -> Runtime {
        // Minimal bluebook with one no-op aggregate — parser is the
        // canonical way to build a Domain ; constructing the IR by
        // hand bakes in field churn.
        let src = r#"
            Hecks.bluebook "LoopDriverTest" do
              aggregate "Tick" do
                attribute :name, :string
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
}
