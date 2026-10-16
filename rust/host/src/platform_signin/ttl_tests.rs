//! The key set cache honours how long the issuer says its answer may be kept, within bounds.

use std::sync::atomic::{AtomicI64, AtomicUsize, Ordering};
use std::sync::Arc;

use super::jwks::{FetchFailed, JwksCache, JwksFetcher, KeySource, MAX_TTL_SECONDS};
use super::test_support::{jwks_document, KEY_A};

struct Hinted {
    fetches: Arc<AtomicUsize>,
    hint: Arc<AtomicI64>,
}

impl JwksFetcher for Hinted {
    fn fetch(&self) -> Result<String, FetchFailed> {
        self.fetches.fetch_add(1, Ordering::SeqCst);
        Ok(jwks_document(&[&KEY_A]))
    }

    fn ttl_hint(&self) -> Option<i64> {
        let hint = self.hint.load(Ordering::SeqCst);
        (hint >= 0).then_some(hint)
    }
}

const START: i64 = 1_000;

fn cache(hint: i64) -> (JwksCache<Hinted>, Arc<AtomicUsize>, Arc<AtomicI64>) {
    let fetches = Arc::new(AtomicUsize::new(0));
    let hint = Arc::new(AtomicI64::new(hint));
    let fetcher = Hinted {
        fetches: fetches.clone(),
        hint: hint.clone(),
    };
    (JwksCache::new(fetcher), fetches, hint)
}

/// Asks for the known key at `START + offset` and returns how many fetches have happened.
fn ask(cache: &JwksCache<Hinted>, fetches: &AtomicUsize, offset: i64) -> usize {
    assert!(cache.key_for(&KEY_A.kid(), START + offset).is_some());
    fetches.load(Ordering::SeqCst)
}

#[test]
fn without_a_hint_the_default_time_to_live_applies() {
    let (cache, fetches, _) = cache(-1);
    assert_eq!(ask(&cache, &fetches, 0), 1);
    assert_eq!(ask(&cache, &fetches, 299), 1);
    assert_eq!(ask(&cache, &fetches, 300), 2);
}

#[test]
fn a_shorter_hint_makes_the_keys_stale_sooner() {
    let (cache, fetches, _) = cache(120);
    assert_eq!(ask(&cache, &fetches, 0), 1);
    assert_eq!(ask(&cache, &fetches, 119), 1);
    assert_eq!(ask(&cache, &fetches, 120), 2);
}

#[test]
fn a_longer_hint_keeps_the_keys_longer() {
    let (cache, fetches, _) = cache(900);
    assert_eq!(ask(&cache, &fetches, 0), 1);
    assert_eq!(ask(&cache, &fetches, 899), 1);
    assert_eq!(ask(&cache, &fetches, 900), 2);
}

#[test]
fn a_huge_hint_is_capped() {
    let (cache, fetches, _) = cache(10_000_000);
    assert_eq!(ask(&cache, &fetches, 0), 1);
    assert_eq!(ask(&cache, &fetches, MAX_TTL_SECONDS - 1), 1);
    assert_eq!(ask(&cache, &fetches, MAX_TTL_SECONDS), 2);
}

#[test]
fn a_tiny_hint_cannot_turn_the_cache_into_a_fetch_amplifier() {
    for hint in [0, 1, 29] {
        let (cache, fetches, _) = cache(hint);
        assert_eq!(ask(&cache, &fetches, 0), 1, "hint {hint}");
        assert_eq!(ask(&cache, &fetches, 29), 1, "hint {hint}");
        assert_eq!(ask(&cache, &fetches, 30), 2, "hint {hint}");
    }
}

#[test]
fn the_next_fetch_without_a_hint_returns_to_the_default() {
    let (cache, fetches, hint) = cache(60);
    assert_eq!(ask(&cache, &fetches, 0), 1);
    hint.store(-1, Ordering::SeqCst);
    assert_eq!(ask(&cache, &fetches, 60), 2);
    assert_eq!(ask(&cache, &fetches, 60 + 299), 2);
    assert_eq!(ask(&cache, &fetches, 60 + 300), 3);
}
