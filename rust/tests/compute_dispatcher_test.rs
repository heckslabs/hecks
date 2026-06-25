//! [antibody-exempt: rust/tests/compute_dispatcher_test.rs — kernel-floor
//!  compute dispatcher (i220 sub-gap 5, compute-adapter-primitive) ; parity
//!  test harness mirroring rust/tests/llm_dispatcher_test.rs. Same
//!  retirement contract as the llm dispatcher's test marker.]
//!
//! Integration tests for the Rust compute dispatcher (i220 sub-gap 5
//! port).
//!
//! Exercises the function-registry path, end-to-end runtime cascade :
//! a top-level dispatch fires an event, the runtime scans loaded
//! hecksagons for a matching `:compute` adapter
//! (effective_trigger = "Aggregate.Command"), invokes the named
//! function via the static registry, and chains the response back
//! into the response_into target with response_into_attr populated.

use storehouse::hecksagon_ir::{ComputeAdapter, Hecksagon};
use storehouse::ir::Domain;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use storehouse::runtime::compute_dispatcher::{self, ComputeOutcome};
use std::collections::HashMap;

fn summary_adapter() -> ComputeAdapter {
    ComputeAdapter {
        name: "recent_musings_summary".into(),
        function_name: "summarize_recent_musings".into(),
        trigger_on: None,
        response_into_target: Some("MusingMint.MintMusing".into()),
        response_into_attr: Some("recent_musings_summary".into()),
    }
}

#[test]
fn dispatcher_skips_when_function_unset() {
    let mut adapter = summary_adapter();
    adapter.function_name = "".into();
    let outcome = compute_dispatcher::call(&adapter, None, &HashMap::new(), None);
    match outcome {
        ComputeOutcome::Skipped(s) => assert_eq!(s.reason, "function_unset"),
        ComputeOutcome::Completed(_) => panic!("expected skipped"),
    }
}

#[test]
fn dispatcher_skips_when_function_unregistered() {
    let mut adapter = summary_adapter();
    adapter.function_name = "no_such_function".into();
    let outcome = compute_dispatcher::call(&adapter, None, &HashMap::new(), None);
    match outcome {
        ComputeOutcome::Skipped(s) => assert_eq!(s.reason, "function_unregistered"),
        ComputeOutcome::Completed(_) => panic!("expected skipped"),
    }
}

#[test]
fn dispatcher_returns_empty_summary_with_no_data_dir() {
    let adapter = summary_adapter();
    let outcome = compute_dispatcher::call(&adapter, None, &HashMap::new(), None);
    match outcome {
        ComputeOutcome::Completed(r) => {
            assert_eq!(r.adapter_name, "recent_musings_summary");
            assert_eq!(r.function_name, "summarize_recent_musings");
            assert_eq!(r.response_text, "",
                "no data_dir should produce empty summary");
        }
        ComputeOutcome::Skipped(s) => panic!("expected completed, got {:?}", s),
    }
}

#[test]
fn split_target_parses_aggregate_command() {
    assert_eq!(
        compute_dispatcher::split_target("MusingMint.MintMusing"),
        Some(("MusingMint".into(), "MintMusing".into()))
    );
    assert_eq!(compute_dispatcher::split_target("NoDot"), None);
    assert_eq!(compute_dispatcher::split_target("Empty."), None);
    assert_eq!(compute_dispatcher::split_target(".AlsoEmpty"), None);
}

#[test]
fn registry_invoke_for_unregistered_returns_none() {
    let result = storehouse::runtime::compute_functions::invoke(
        "totally_made_up_name", None, &HashMap::new(), None,
    );
    assert!(result.is_none());
}

// ─── End-to-end : runtime cascade with hecksagon-driven compute ─────

const MINT_BLUEBOOK: &str = r#"Hecks.bluebook "MusingMint" do
  aggregate "MusingMint" do
    identified_by :id
    attribute :id, String
    attribute :recent_musings_summary, String
    attribute :idea, String

    command "RequestMint" do
      attribute :id, String
      then_set :id, from: :id
    end

    command "MintMusing" do
      attribute :id, String
      attribute :recent_musings_summary, String
      then_set :recent_musings_summary, from: :recent_musings_summary
    end
  end
end"#;

#[test]
fn end_to_end_compute_cascade_writes_response_into_target_attr() {
    // Parse the bluebook and load a hecksagon with a matching :compute
    // adapter targeting MusingMint.RequestMint -> MusingMint.MintMusing.
    let domain: Domain = parser::parse(MINT_BLUEBOOK);
    let mut hexa = Hecksagon::default();
    hexa.name = "MusingMint".into();
    let mut adapter = summary_adapter();
    // Trigger ON RequestMint, response routed INTO MintMusing — this
    // is the i227 PM-context-population pattern.
    adapter.trigger_on = Some("MusingMint.RequestMint".into());
    hexa.compute_adapters.push(adapter);

    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hexa]);

    // Top-level dispatch — RequestMint is the trigger ; the compute
    // hook fires, looks up summarize_recent_musings (returns empty
    // string since no data_dir), and chains into MintMusing with
    // recent_musings_summary populated (to "" in this case).
    let mut attrs = HashMap::new();
    attrs.insert("id".into(), Value::Str("m1".into()));
    let _result = rt.dispatch("MusingMint.RequestMint", attrs)
        .expect("dispatch should succeed");

    // The chained MintMusing should have been dispatched ; verify the
    // MintMusing aggregate state carries the recent_musings_summary
    // field (even though the value is empty in this test, the cascade
    // dispatch landed).
    let state = rt.find("MusingMint", "m1")
        .expect("MusingMint aggregate was created by RequestMint");
    // The recent_musings_summary field exists (was set by the
    // chained MintMusing's then_set) — empty value is the contract
    // for "no musings yet".
    assert!(state.fields.contains_key("recent_musings_summary"),
        "expected recent_musings_summary field set by cascade ; got {:?}",
        state.fields);
}

#[test]
fn dispatcher_skips_silently_when_no_hecksagon_loaded() {
    let domain: Domain = parser::parse(MINT_BLUEBOOK);
    let mut rt = Runtime::boot_with_data_dir(domain, None);
    let mut attrs = HashMap::new();
    attrs.insert("id".into(), Value::Str("m2".into()));
    let result = rt.dispatch("MusingMint.RequestMint", attrs).unwrap();
    let state = rt.find(&result.aggregate_type, &result.aggregate_id).unwrap();
    let summary = state.fields.get("recent_musings_summary")
        .map(|v| v.to_string()).unwrap_or_default();
    // No compute hook fired → field stays empty, no cascade.
    assert!(summary.is_empty() || summary == "null",
        "expected empty summary without hecksagon, got {:?}", summary);
}

// ─── aggregate_corpus_window tests ───────────────────────────────────

#[test]
fn aggregate_corpus_window_returns_empty_without_data_dir() {
    let result = storehouse::runtime::compute_functions::invoke(
        "aggregate_corpus_window", None, &HashMap::new(), None,
    );
    assert_eq!(result, Some("".to_string()));
}

#[test]
fn aggregate_corpus_window_returns_empty_when_bounds_missing() {
    // heki + field default to wake-review values ; without bound
    // attrs (or sleep_entered_at/woke_at fallbacks) the function
    // returns empty.
    let attrs: HashMap<String, String> = HashMap::new();
    let result = storehouse::runtime::compute_functions::invoke(
        "aggregate_corpus_window", None, &attrs, Some("/tmp"),
    );
    assert_eq!(result, Some("".to_string()),
        "should return empty when bound attrs absent");
}

#[test]
fn aggregate_corpus_window_falls_back_to_wake_review_state_attrs() {
    use std::fs;
    use serde_json::json;

    let tmpdir = std::env::temp_dir().join(format!(
        "acw_test_wr_{}", std::process::id()
    ));
    let _ = fs::remove_dir_all(&tmpdir);
    fs::create_dir_all(&tmpdir).expect("mkdir tmpdir");

    let mut store = storehouse::heki::Store::new();
    let mut r1 = storehouse::heki::Record::new();
    r1.insert("updated_at".into(), json!("2026-05-03T10:00:00Z"));
    r1.insert("dream_images".into(), json!("le poisson dort"));
    store.insert("k1".into(), r1);

    let path = tmpdir.join("dream_state.heki");
    let path_str = path.to_str().unwrap().to_string();
    storehouse::heki::write(
        &path_str, &store,
        storehouse::heki::WriteContext::OutOfBand { reason: "test setup" },
    ).expect("write store");

    // No `heki:`, `field:`, `lower_bound:`, `upper_bound:` — purely
    // the WakeReview state field names. Function should default heki
    // to dream_state, field to dream_images, and use the WakeReview
    // bounds aliases.
    let mut attrs: HashMap<String, String> = HashMap::new();
    attrs.insert("sleep_entered_at".into(), "2026-05-03T09:00:00Z".into());
    attrs.insert("woke_at".into(), "2026-05-03T12:00:00Z".into());

    let result = storehouse::runtime::compute_functions::invoke(
        "aggregate_corpus_window", None, &attrs,
        Some(tmpdir.to_str().unwrap()),
    ).expect("function should return Some");

    assert_eq!(result, "le poisson dort",
        "expected wake-review default fallbacks to work, got {:?}", result);

    let _ = fs::remove_dir_all(&tmpdir);
}

#[test]
fn aggregate_corpus_window_returns_empty_when_heki_missing() {
    let mut attrs: HashMap<String, String> = HashMap::new();
    attrs.insert("heki".into(), "no_such_corpus_xyz".into());
    attrs.insert("field".into(), "dream_images".into());
    attrs.insert("lower_bound".into(), "2026-01-01T00:00:00Z".into());
    attrs.insert("upper_bound".into(), "2026-12-31T23:59:59Z".into());
    let result = storehouse::runtime::compute_functions::invoke(
        "aggregate_corpus_window", None, &attrs, Some("/tmp"),
    );
    assert_eq!(result, Some("".to_string()),
        "missing heki file → empty corpus");
}

#[test]
fn aggregate_corpus_window_filters_by_window_and_joins_field() {
    use std::fs;
    use serde_json::json;

    // Set up a temp directory with a fabricated dream_state.heki.
    let tmpdir = std::env::temp_dir().join(format!(
        "acw_test_{}", std::process::id()
    ));
    let _ = fs::remove_dir_all(&tmpdir);
    fs::create_dir_all(&tmpdir).expect("mkdir tmpdir");

    // Build a Store with three records — two inside the window, one outside.
    let mut store = storehouse::heki::Store::new();
    let mut r1 = storehouse::heki::Record::new();
    r1.insert("updated_at".into(), json!("2026-05-03T10:00:00Z"));
    r1.insert("dream_images".into(), json!("first dream image"));
    store.insert("k1".into(), r1);
    let mut r2 = storehouse::heki::Record::new();
    r2.insert("updated_at".into(), json!("2026-05-03T11:00:00Z"));
    r2.insert("dream_images".into(), json!("second dream image"));
    store.insert("k2".into(), r2);
    let mut r3 = storehouse::heki::Record::new();
    r3.insert("updated_at".into(), json!("2026-05-03T20:00:00Z"));
    r3.insert("dream_images".into(), json!("OUT-OF-WINDOW image"));
    store.insert("k3".into(), r3);

    let path = tmpdir.join("dream_state.heki");
    let path_str = path.to_str().unwrap().to_string();
    storehouse::heki::write(
        &path_str, &store,
        storehouse::heki::WriteContext::OutOfBand { reason: "test setup" },
    ).expect("write store");

    let mut attrs: HashMap<String, String> = HashMap::new();
    attrs.insert("heki".into(), "dream_state".into());
    attrs.insert("field".into(), "dream_images".into());
    attrs.insert("lower_bound".into(), "2026-05-03T09:00:00Z".into());
    attrs.insert("upper_bound".into(), "2026-05-03T12:00:00Z".into());

    let result = storehouse::runtime::compute_functions::invoke(
        "aggregate_corpus_window", None, &attrs,
        Some(tmpdir.to_str().unwrap()),
    ).expect("function should return Some");

    // Records inside the window joined by \n, in chronological order.
    assert_eq!(result, "first dream image\nsecond dream image",
        "expected window-filtered + chronological join, got {:?}", result);

    let _ = fs::remove_dir_all(&tmpdir);
}

#[test]
fn aggregate_corpus_window_honors_custom_timestamp_field() {
    use std::fs;
    use serde_json::json;

    let tmpdir = std::env::temp_dir().join(format!(
        "acw_test_ts_{}", std::process::id()
    ));
    let _ = fs::remove_dir_all(&tmpdir);
    fs::create_dir_all(&tmpdir).expect("mkdir tmpdir");

    let mut store = storehouse::heki::Store::new();
    let mut r1 = storehouse::heki::Record::new();
    // Use `created_at` as the timestamp field (default would be `updated_at`).
    r1.insert("created_at".into(), json!("2026-05-03T10:00:00Z"));
    r1.insert("dream_images".into(), json!("only image"));
    store.insert("k1".into(), r1);

    let path = tmpdir.join("dream_state.heki");
    let path_str = path.to_str().unwrap().to_string();
    storehouse::heki::write(
        &path_str, &store,
        storehouse::heki::WriteContext::OutOfBand { reason: "test setup" },
    ).expect("write store");

    let mut attrs: HashMap<String, String> = HashMap::new();
    attrs.insert("heki".into(), "dream_state".into());
    attrs.insert("field".into(), "dream_images".into());
    attrs.insert("timestamp_field".into(), "created_at".into());
    attrs.insert("lower_bound".into(), "2026-05-03T09:00:00Z".into());
    attrs.insert("upper_bound".into(), "2026-05-03T12:00:00Z".into());

    let result = storehouse::runtime::compute_functions::invoke(
        "aggregate_corpus_window", None, &attrs,
        Some(tmpdir.to_str().unwrap()),
    ).expect("function should return Some");

    assert_eq!(result, "only image");

    let _ = fs::remove_dir_all(&tmpdir);
}
