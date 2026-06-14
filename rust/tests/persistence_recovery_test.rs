//! Persistence-recovery gate — the smoke-test that protects every step of the
//! persistence-port refactor (explicit adapters, structural enforcement, one
//! heki store under ~/hecks). The two invariants the whole refactor must never
//! break :
//!
//!   1. **heki survives a cold reopen** (a process restart) — an aggregate saved
//!      through a heki-backed repository is found again by a FRESH repository
//!      reopened on the same store dir. This is the property the live-store move
//!      to ~/hecks must preserve : organs + plan keep reading their data.
//!   2. **the explicit memory adapter does NOT survive** — a fresh `new_memory`
//!      starts empty. Memory is a wired, transient choice ; it never silently
//!      persists to disk.
//!
//! Run before AND after any change that moves stores or alters persistence
//! resolution. Green here is the gate the plan names — the store move and the
//! enforcement flip do not ship until this stays green.
//!
//! [antibody-exempt: rust/tests/persistence_recovery_test.rs — the
//!  persistence-recovery gate is necessarily Rust : it asserts on
//!  LazyRepository's heki cold-reopen + memory round-trip behaviour (byte-level
//!  repository semantics), the same kind of infrastructure test as
//!  sqlite_repository_test.rs / heki_path_coherence_test.rs. Test-only, no
//!  domain logic ; behaviours suites are pure-memory and cannot test
//!  cross-restart disk recovery. Retires if/when the persistence adapters
//!  become specializer-generated and their goldens cover round-trip.]

use storehouse::heki::WriteContext;
use storehouse::runtime::{AggregateState, LazyRepository, Value};

fn fresh_tmp_dir(name: &str) -> String {
    let p = std::env::temp_dir().join(format!("hecks_persist_recovery_{name}"));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).expect("create temp store dir");
    p.to_string_lossy().into_owned()
}

#[test]
fn heki_survives_cold_reopen() {
    let dir = fresh_tmp_dir("heki");

    // Process 1 : write an aggregate through a heki-backed repository.
    {
        let mut repo = LazyRepository::new("Order", Some(dir.clone()), Some("id".into()), None);
        let mut state = AggregateState::new("order-1");
        state.set("status", Value::Str("placed".into()));
        repo.save(state, WriteContext::OutOfBand { reason: "persistence-recovery-test" });
    }

    // Process 2 (cold reopen) : a FRESH repository on the same store dir must
    // see the persisted aggregate — the recovery property the store move guards.
    let reopened = LazyRepository::new("Order", Some(dir), Some("id".into()), None);
    let found = reopened
        .find("order-1")
        .expect("heki must persist the aggregate across a cold reopen");
    assert_eq!(found.get("status").to_string(), "placed");
    assert_eq!(reopened.count(), 1);
}

#[test]
fn memory_vanishes_on_restart() {
    let mut repo = LazyRepository::new_memory("Order", Some("id".into()), None);
    repo.save(
        AggregateState::new("order-1"),
        WriteContext::OutOfBand { reason: "persistence-recovery-test" },
    );
    assert!(repo.find("order-1").is_some(), "memory retains within the process");

    // A fresh memory adapter (a restart) starts empty — no disk, nothing survives.
    let restarted = LazyRepository::new_memory("Order", Some("id".into()), None);
    assert!(restarted.find("order-1").is_none(), "memory must vanish on restart");
    assert_eq!(restarted.count(), 0);
}
