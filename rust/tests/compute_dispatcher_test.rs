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

use hecks_life::hecksagon_ir::{ComputeAdapter, Hecksagon};
use hecks_life::ir::Domain;
use hecks_life::parser;
use hecks_life::runtime::{Runtime, Value};
use hecks_life::runtime::compute_dispatcher::{self, ComputeOutcome};
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
    let result = hecks_life::runtime::compute_functions::invoke(
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
