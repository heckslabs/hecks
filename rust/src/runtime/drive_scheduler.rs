//! drive_scheduler — the pure tick-counter core of `storehouse drive`.
//!
//! `storehouse drive` is the single-owner daemon that fires `driving on`
//! handlers live (the interval kind in this slice ; cron/clock are the
//! documented follow-on). It polls at a fixed cadence (`--poll`), so an
//! interval of N at poll P fires every `ceil(N/P)` ticks. Modelling the
//! cadence as a TICK COUNTER (not a wall-clock `Instant`) makes the whole
//! due-decision pure integer arithmetic : deterministic, unit-testable
//! without faking time, and "fire immediately on the first tick after a
//! restart" falls out of the `None` (never-fired) case for free.
//!
//! State lives in the daemon's memory (no Driver aggregate — Chris) : a
//! `HashMap<handler_id, last_fired_tick>`. On restart the map is empty, so
//! every handler is due on the first tick and fires once early — acceptable
//! because driving handlers are idempotent sweeps (ExpireStale, Poll).
//!
//! Usage :
//!   let mut sched = DriveScheduler::new(Duration::from_secs(1));
//!   let due: Vec<String> = sched.tick(&[("id".into(), Duration::from_secs(2))]);
//!   // tick 1 -> due (never fired) ; tick 2 -> not ; tick 3 -> due ; ...

use std::collections::HashMap;
use std::time::Duration;

/// Number of poll ticks between fires for an interval at a given poll
/// cadence : `ceil(interval / poll)`, floored at 1 (a handler can never
/// fire faster than the poll). Both operands are clamped to >= 1ms so a
/// zero duration can't divide-by-zero or yield a 0-tick (every-tick storm).
pub fn ticks_for(interval: Duration, poll: Duration) -> u64 {
    let i = interval.as_millis().max(1);
    let p = poll.as_millis().max(1);
    (((i + p - 1) / p) as u64).max(1)
}

/// Due iff never fired, or at least `interval_ticks` ticks have elapsed
/// since the last fire. `interval_ticks` is floored at 1 so a mis-sized
/// handler still fires at most once per tick, never every-tick-twice.
pub fn is_due(last_fired_tick: Option<u64>, current_tick: u64, interval_ticks: u64) -> bool {
    match last_fired_tick {
        None => true,
        Some(last) => current_tick.saturating_sub(last) >= interval_ticks.max(1),
    }
}

/// The stateful scheduler the drive daemon owns across ticks. Pure : holds
/// no Runtime, does no IO — the daemon enumerates handlers + fires the due
/// ids it returns.
pub struct DriveScheduler {
    poll: Duration,
    last_fired: HashMap<String, u64>,
    tick: u64,
}

impl DriveScheduler {
    pub fn new(poll: Duration) -> Self {
        Self { poll, last_fired: HashMap::new(), tick: 0 }
    }

    /// Advance one tick. Given every interval handler present THIS tick as
    /// `(handler_id, interval)`, return the ids due to fire now and record
    /// them as fired at the current tick. Handlers absent this tick keep
    /// their last-fired mark untouched (a vanished handler simply stops
    /// being asked about).
    pub fn tick(&mut self, handlers: &[(String, Duration)]) -> Vec<String> {
        self.tick += 1;
        let mut due = Vec::new();
        for (id, interval) in handlers {
            let interval_ticks = ticks_for(*interval, self.poll);
            if is_due(self.last_fired.get(id).copied(), self.tick, interval_ticks) {
                self.last_fired.insert(id.clone(), self.tick);
                due.push(id.clone());
            }
        }
        due
    }

    pub fn current_tick(&self) -> u64 {
        self.tick
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    #[test]
    fn ticks_for_ceils_and_floors_at_one() {
        assert_eq!(ticks_for(secs(2), secs(1)), 2);
        assert_eq!(ticks_for(secs(10), secs(1)), 10);
        // interval below poll still fires (floored at 1 tick).
        assert_eq!(ticks_for(Duration::from_millis(500), secs(1)), 1);
        // non-multiple rounds UP (2.5s at 1s poll -> 3 ticks).
        assert_eq!(ticks_for(Duration::from_millis(2500), secs(1)), 3);
        // zero guards : degenerate inputs the CLI never produces (poll
        // defaults to 1s) must never panic and never yield 0 ticks (an
        // every-tick storm). The exact value is not meaningful — only that
        // the guard holds : >= 1, no divide-by-zero.
        assert_eq!(ticks_for(Duration::ZERO, secs(1)), 1); // 0ms interval -> 1 tick
        assert!(ticks_for(secs(5), Duration::ZERO) >= 1);  // 0 poll clamps to 1ms, no storm/panic
    }

    #[test]
    fn never_fired_is_due() {
        assert!(is_due(None, 1, 5));
    }

    #[test]
    fn fires_only_when_interval_elapsed() {
        assert!(!is_due(Some(3), 4, 5)); // 1 tick since fire, need 5
        assert!(!is_due(Some(3), 7, 5)); // 4 ticks, still short
        assert!(is_due(Some(3), 8, 5));  // exactly 5 ticks -> due
        assert!(is_due(Some(3), 99, 5)); // long overdue -> due
    }

    #[test]
    fn first_tick_fires_then_respects_period() {
        // interval 2s at poll 1s -> every 2 ticks. Expect fire on 1,3,5,...
        let mut s = DriveScheduler::new(secs(1));
        let h = vec![("a".to_string(), secs(2))];
        assert_eq!(s.tick(&h), vec!["a"]); // tick 1 : never-fired -> fire
        assert_eq!(s.tick(&h), Vec::<String>::new()); // tick 2 : 1 since fire
        assert_eq!(s.tick(&h), vec!["a"]); // tick 3 : 2 since fire -> fire
        assert_eq!(s.tick(&h), Vec::<String>::new()); // tick 4
        assert_eq!(s.tick(&h), vec!["a"]); // tick 5
    }

    #[test]
    fn independent_handlers_track_separately() {
        let mut s = DriveScheduler::new(secs(1));
        let h = vec![("fast".to_string(), secs(1)), ("slow".to_string(), secs(3))];
        // tick 1 : both never-fired -> both fire.
        let mut t1 = s.tick(&h);
        t1.sort();
        assert_eq!(t1, vec!["fast", "slow"]);
        // tick 2 : fast (every tick) fires ; slow (every 3) not yet.
        assert_eq!(s.tick(&h), vec!["fast"]);
        // tick 3 : fast fires ; slow not (2 ticks since its tick-1 fire).
        assert_eq!(s.tick(&h), vec!["fast"]);
        // tick 4 : fast fires ; slow fires (3 ticks elapsed).
        let mut t4 = s.tick(&h);
        t4.sort();
        assert_eq!(t4, vec!["fast", "slow"]);
    }

    #[test]
    fn restart_with_empty_state_fires_immediately() {
        // A fresh scheduler (restart) has no last-fired marks, so the first
        // tick fires every handler once — the documented restart-early-fire.
        let mut s = DriveScheduler::new(secs(1));
        let h = vec![("x".to_string(), secs(900))]; // 15-min interval
        assert_eq!(s.tick(&h), vec!["x"]); // still fires on first tick post-restart
        assert_eq!(s.tick(&h), Vec::<String>::new()); // then waits the full period
    }
}
