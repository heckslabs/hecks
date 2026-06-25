//! Integration test : Repository writes ↔ foreign reader agreement.
//!
//! The dead-bar incident (i145) named a class of self-validation we
//! didn't have : runtime modules disagreeing on where live state lives.
//! Repository wrote to `<info>/<context>/<aggregate>.heki` (i142
//! Tier 2), the statusline runner read `<info>/<aggregate>.heki`
//! (legacy flat). Daemons populated one path. Statusline starved at
//! another. No unit test caught it because :
//!
//!   - unit tests use isolated tmpdirs, don't exercise live-corpus paths
//!   - parity tests compare IR shape, don't run live state
//!   - behaviors tests are pure-memory, don't write to disk
//!   - the IR-query substrate asks "is this dispatched", orthogonal
//!     to "do two runtime modules agree on paths"
//!
//! The bug only surfaced when the user looked at the bar.
//! User-as-canary, not self-validation.
//!
//! These tests close that gap. Each :
//!
//!   1. Spins up a tmpdir info dir
//!   2. Boots a runtime with a bluebook that declares an aggregate
//!      (with a context, post-i142 default)
//!   3. Dispatches a command through Runtime — Repository.save
//!      persists state to the i142 nested path
//!   4. From a "foreign call site" (mirroring how statusline /
//!      vitals / status report / sleep CLI / wake_review read state),
//!      uses `heki::path_for_lookup` to find the file
//!   5. Reads it via `heki::read`
//!   6. Asserts the dispatched data is visible
//!
//! When future i142-shaped path migrations land (Tier 3, 4, etc.) or
//! when new runtime consumers come online, these tests catch the
//! "writer/reader divergence" class of bug before it reaches the bar.
//!
//! [antibody-exempt: storehouse/tests/heki_path_coherence_test.rs —
//!  runtime integration test that catches level-5 self-validation
//!  drift (i145 companion). Same kernel-surface family as the
//!  existing tests/ entries already in the registry. Retires under
//!  i77/i78 when this test itself emits from a meta-shape — until
//!  then it lives as authored Rust with the same retirement contract
//!  as the substrate it tests.]

use storehouse::heki;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn tempdir(prefix: &str) -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let p = std::env::temp_dir().join(format!("heki_path_coherence_{}_{}", prefix, nanos));
    fs::create_dir_all(&p).unwrap();
    fs::create_dir_all(p.join("information")).unwrap();
    p
}

fn boot_with_data_dir(source: &str, info_dir: &str) -> Runtime {
    let domain = parser::parse(source);
    Runtime::boot_with_data_dir(domain, Some(info_dir.to_string()))
}

fn attrs(pairs: &[(&str, Value)]) -> HashMap<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

fn s(val: &str) -> Value { Value::Str(val.to_string()) }

// ────────────────────────────────────────────────────────────────────
// Test 1 : same-name context (happy path — context == aggregate name)
// ────────────────────────────────────────────────────────────────────
//
// Most common shape : `Hecks.bluebook "Mood" do aggregate "Mood" do`.
// Parser stamps `context = "Mood"` on the aggregate ; Repository
// writes to `<info>/mood/mood.heki`. Foreign reader doing
// `path_for_lookup(info, "mood")` should find the same file.

#[test]
fn writer_and_reader_agree_when_context_equals_name() {
    let tmp = tempdir("happy");
    let info = tmp.join("information");
    let info_str = info.to_string_lossy().to_string();

    let bluebook = r#"Hecks.bluebook "Mood" do
  aggregate "Mood" do
    description "Live affect"
    identified_by :name
    attribute :name, String
    attribute :level, Integer
    command "SetLevel" do
      role "Body"
      attribute :name, String
      attribute :level, Integer
      then_set :name, from: :name
      then_set :level, from: :level
      emits "MoodSet"
    end
  end
end"#;

    let mut rt = boot_with_data_dir(bluebook, &info_str);

    // Dispatch — Repository.save writes to <info>/<context>/<agg>.heki
    rt.dispatch("SetLevel", attrs(&[
        ("name",  s("focused")),
        ("level", Value::Int(7)),
    ])).unwrap();

    // Foreign reader : doesn't know context, just knows the aggregate
    // file's "name" — the way statusline / vitals / sleep CLI reach
    // for state. Resolution must find the writer's file.
    let resolved = heki::path_for_lookup(&info_str, "mood");
    assert!(resolved.contains("/mood/mood.heki"),
        "expected i142 nested path, got {}", resolved);

    let store = heki::read(&resolved).expect("foreign reader resolves the path");
    assert!(!store.is_empty(),
        "writer wrote {} records, foreign reader sees {} — DIVERGENCE",
        1, store.len());

    let _ = fs::remove_dir_all(&tmp);
}

// ────────────────────────────────────────────────────────────────────
// Test 2 : context ≠ name (boot.bluebook → BootRun case)
// ────────────────────────────────────────────────────────────────────
//
// 28+ bluebooks in the corpus today have bluebook name ≠ aggregate
// name. Example : `Hecks.bluebook "Boot" do aggregate "BootRun" do`.
// Parser stamps `context = "Boot"`. Repository writes to
// `<info>/boot/boot_run.heki`. Foreign reader has only the aggregate
// file's basename ("boot_run") — must walk subdirs to find the right one.

#[test]
fn writer_and_reader_agree_when_context_differs_from_name() {
    let tmp = tempdir("differs");
    let info = tmp.join("information");
    let info_str = info.to_string_lossy().to_string();

    let bluebook = r#"Hecks.bluebook "Boot" do
  aggregate "BootRun" do
    description "One boot pass"
    identified_by :being
    attribute :being, String
    attribute :elapsed, Integer
    command "Complete" do
      role "Boot"
      attribute :being, String
      attribute :elapsed, Integer
      then_set :being, from: :being
      then_set :elapsed, from: :elapsed
      emits "BootCompleted"
    end
  end
end"#;

    let mut rt = boot_with_data_dir(bluebook, &info_str);

    rt.dispatch("Complete", attrs(&[
        ("being",   s("Miette")),
        ("elapsed", Value::Int(2)),
    ])).unwrap();

    // The killer assertion : foreign reader, knowing only "boot_run",
    // finds the file even though the context dir is "boot". Walks
    // subdirs to disambiguate.
    let resolved = heki::path_for_lookup(&info_str, "boot_run");
    assert!(resolved.contains("/boot/boot_run.heki"),
        "subdir scan must find boot/boot_run.heki, got {}", resolved);

    let store = heki::read(&resolved).expect("subdir scan resolves the divergent context");
    assert!(!store.is_empty(),
        "writer wrote 1 record, foreign reader sees {} — context-walk DIVERGENCE",
        store.len());

    let _ = fs::remove_dir_all(&tmp);
}

// ────────────────────────────────────────────────────────────────────
// Test 3 : stale flat file alongside fresh nested file
// ────────────────────────────────────────────────────────────────────
//
// Migration scenario : pre-i142 corpus had `<info>/mood.heki` (flat).
// Post-i142 Repository writes to `<info>/mood/mood.heki` (nested).
// During the transition both files may coexist on disk. The reader
// must prefer the nested one (where post-i142 daemons write the
// fresh state) ; reading the flat file would surface stale data.
// Sentinel against the silent-staleness class of bug.

#[test]
fn lookup_prefers_nested_when_both_exist() {
    let tmp = tempdir("stale");
    let info = tmp.join("information");
    let info_str = info.to_string_lossy().to_string();

    // Stale flat file : pre-i142 leftover.
    let flat = info.join("mood.heki");
    fs::write(&flat, "{\"1\":{\"id\":\"1\",\"level\":\"OLD\"}}").unwrap();

    // Fresh nested file : where the post-i142 daemon writes today.
    fs::create_dir_all(info.join("mood")).unwrap();
    let nested = info.join("mood/mood.heki");
    fs::write(&nested, "{\"1\":{\"id\":\"1\",\"level\":\"FRESH\"}}").unwrap();

    let resolved = heki::path_for_lookup(&info_str, "mood");
    assert_eq!(resolved, nested.to_string_lossy(),
        "lookup must prefer nested (fresh) over flat (stale) when both exist");

    let _ = fs::remove_dir_all(&tmp);
}

// ────────────────────────────────────────────────────────────────────
// Test 4 : path_for and path_for_lookup compose round-trip
// ────────────────────────────────────────────────────────────────────
//
// The pure-function version of the writer-reader invariant : whatever
// path_for(dir, agg, ctx) writes, path_for_lookup(dir, agg) reads,
// regardless of whether ctx matches agg or not. This locks the
// helper-pair contract independent of the runtime — if a future
// refactor changes either function, this test fails before live
// state goes silent.

#[test]
fn helper_pair_round_trip_when_context_matches_name() {
    let tmp = tempdir("rt_match");
    let dir = tmp.to_string_lossy().to_string();

    let writer = heki::path_for(&dir, "Mood", Some("Mood"));
    fs::create_dir_all(std::path::Path::new(&writer).parent().unwrap()).unwrap();
    fs::write(&writer, "{}").unwrap();

    let reader = heki::path_for_lookup(&dir, "mood");
    assert_eq!(writer, reader, "match-context round-trip must agree");

    let _ = fs::remove_dir_all(&tmp);
}

#[test]
fn helper_pair_round_trip_when_context_differs_from_name() {
    let tmp = tempdir("rt_differ");
    let dir = tmp.to_string_lossy().to_string();

    let writer = heki::path_for(&dir, "BootRun", Some("Boot"));
    fs::create_dir_all(std::path::Path::new(&writer).parent().unwrap()).unwrap();
    fs::write(&writer, "{}").unwrap();

    let reader = heki::path_for_lookup(&dir, "boot_run");
    assert_eq!(writer, reader, "differ-context round-trip must agree (subdir scan)");

    let _ = fs::remove_dir_all(&tmp);
}
