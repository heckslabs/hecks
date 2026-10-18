//! The single-use record of token identifiers.
//!
//! A token may be redeemed once. The store remembers each `jti` until its time window has
//! closed (`exp` plus the skew), so a replay inside that window is refused and
//! nothing is kept longer than it must be.
//!
//! ## Per process, on purpose
//!
//! The record lives in this process's memory. A restart forgets it, which leaves a replay window of
//! at most the token's remaining life plus the skew (90 seconds with the default settings). More
//! than one running instance would each have their own record, so a token could be redeemed once
//! per instance. This store is therefore only right for a site served by a single long-running
//! process; a deployment with several instances or short-lived invocations needs a shared record.
//!
//! ## Bounded, and closed when full
//!
//! At the cap the store refuses new claims rather than grow, so a flood of valid-looking tokens
//! cannot exhaust memory. A refusal is reported like a replay: nobody gets in on a full store.

use std::collections::HashMap;
use std::sync::Mutex;

/// The default cap on remembered identifiers.
pub const DEFAULT_MAX_ENTRIES: usize = 100_000;

/// An in-memory, bounded, atomic set of spent token identifiers.
pub struct JtiStore {
    max_entries: usize,
    seen: Mutex<HashMap<String, i64>>,
}

impl JtiStore {
    /// Builds an empty store with the default cap.
    pub fn new() -> Self {
        Self::with_capacity(DEFAULT_MAX_ENTRIES)
    }

    /// Builds an empty store that remembers at most `max_entries` identifiers.
    pub fn with_capacity(max_entries: usize) -> Self {
        Self {
            max_entries,
            seen: Mutex::new(HashMap::new()),
        }
    }

    /// Records `jti` as spent until `expires_at` (Unix seconds) unless it is already remembered.
    ///
    /// Returns `true` the first time, and `false` while the identifier is remembered or the store
    /// is full. Checking and recording are one step under one lock, so of any number of concurrent
    /// claims of the same identifier exactly one wins.
    pub fn claim(&self, jti: &str, expires_at: i64, now: i64) -> bool {
        let mut seen = self.lock();
        seen.retain(|_, expiry| *expiry > now);
        if seen.contains_key(jti) || seen.len() >= self.max_entries {
            return false;
        }
        seen.insert(jti.to_string(), expires_at);
        true
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, i64>> {
        // A panic in another thread cannot leave the map half-updated, and refusing everything
        // forever would be a lock-out, so a poisoned lock is simply taken over.
        self.seen
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Counts the identifiers still remembered at `now`; expired ones are not counted.
    pub fn len(&self, now: i64) -> usize {
        self.lock().values().filter(|expiry| **expiry > now).count()
    }

    /// Tells whether nothing is remembered at `now`.
    pub fn is_empty(&self, now: i64) -> bool {
        self.len(now) == 0
    }
}

impl Default for JtiStore {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Barrier};

    const NOW: i64 = 1_800_000_000;

    #[test]
    fn an_identifier_is_claimed_once() {
        let store = JtiStore::new();
        assert!(store.claim("a", NOW + 90, NOW));
        assert!(!store.claim("a", NOW + 90, NOW));
        assert!(store.claim("b", NOW + 90, NOW));
        assert_eq!(store.len(NOW), 2);
    }

    #[test]
    fn an_entry_is_remembered_until_its_expiry_and_forgotten_at_it() {
        let store = JtiStore::new();
        assert!(store.claim("a", NOW + 90, NOW));
        assert!(!store.claim("a", NOW + 90, NOW + 89));
        assert_eq!(store.len(NOW + 89), 1);
        assert!(
            store.claim("a", NOW + 200, NOW + 90),
            "forgotten exactly at expires_at"
        );
        assert_eq!(store.len(NOW + 90), 1);
    }

    #[test]
    fn expired_entries_are_not_counted_and_free_room() {
        let store = JtiStore::with_capacity(2);
        assert!(store.claim("a", NOW + 10, NOW));
        assert!(store.claim("b", NOW + 10, NOW));
        assert!(
            !store.claim("c", NOW + 100, NOW + 5),
            "full while both are live"
        );
        assert!(
            store.claim("c", NOW + 100, NOW + 10),
            "expired entries make room"
        );
        assert_eq!(store.len(NOW + 10), 1);
        assert!(store.is_empty(NOW + 100));
    }

    #[test]
    fn the_store_is_bounded_and_fails_closed_at_the_cap() {
        let store = JtiStore::with_capacity(3);
        for id in ["a", "b", "c"] {
            assert!(store.claim(id, NOW + 90, NOW));
        }
        assert!(
            !store.claim("d", NOW + 90, NOW),
            "a new identifier is refused, not stored"
        );
        assert_eq!(store.len(NOW), 3);
        assert!(
            !store.claim("a", NOW + 90, NOW),
            "and an old one is still a replay"
        );
    }

    #[test]
    fn a_refused_claim_records_nothing() {
        let store = JtiStore::with_capacity(1);
        assert!(store.claim("a", NOW + 10, NOW));
        assert!(!store.claim("b", NOW + 10, NOW));
        assert!(
            store.claim("b", NOW + 100, NOW + 10),
            "b was never remembered"
        );
    }

    #[test]
    fn concurrent_claims_of_one_identifier_have_exactly_one_winner() {
        const THREADS: usize = 16;
        for round in 0..300 {
            let store = Arc::new(JtiStore::new());
            let gate = Arc::new(Barrier::new(THREADS));
            let winners = Arc::new(AtomicUsize::new(0));
            let handles: Vec<_> = (0..THREADS)
                .map(|_| {
                    let (store, gate, winners) = (store.clone(), gate.clone(), winners.clone());
                    std::thread::spawn(move || {
                        gate.wait();
                        if store.claim("same-jti", NOW + 90, NOW) {
                            winners.fetch_add(1, Ordering::SeqCst);
                        }
                    })
                })
                .collect();
            for handle in handles {
                handle.join().unwrap();
            }
            assert_eq!(winners.load(Ordering::SeqCst), 1, "round {round}");
        }
    }

    #[test]
    fn a_poisoned_lock_does_not_turn_into_an_open_door() {
        let store = Arc::new(JtiStore::new());
        let clone = store.clone();
        let _ = std::thread::spawn(move || {
            let _guard = clone.seen.lock().unwrap();
            panic!("poison the lock");
        })
        .join();
        assert!(store.claim("a", NOW + 90, NOW));
        assert!(!store.claim("a", NOW + 90, NOW));
    }
}
