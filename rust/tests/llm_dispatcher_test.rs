//! [antibody-exempt: rust/tests/llm_dispatcher_test.rs — kernel-floor
//!  LLM dispatcher port (Phase 2 i221) ; parity test harness for the
//!  new runtime modules. Same retirement contract as the other
//!  i221 markers.]
//!
//! Integration tests for the Rust LLM dispatcher (Phase 2 i221 port).
//!
//! Exercises the substituted-prompt path, fixture-keyed TestProvider
//! resolution, and the end-to-end cascade : a top-level dispatch fires
//! an event, the runtime scans loaded hecksagons for a matching `:llm`
//! adapter (response_into_target = "Aggregate.Command"), invokes the
//! TestProvider with the substituted prompt, and chains the response
//! back into the same target with `response_into_attr` populated.

use hecks_life::hecksagon_ir::{Hecksagon, LlmAdapter};
use hecks_life::ir::Domain;
use hecks_life::parser;
use hecks_life::runtime::{AggregateState, Runtime, Value};
use hecks_life::runtime::llm_dispatcher::{self, LlmOutcome};
use hecks_life::runtime::llm_providers::{LlmProvider, TestProvider};
use std::collections::HashMap;

fn dream_adapter() -> LlmAdapter {
    LlmAdapter {
        name: "dream_image".into(),
        prompt_template: "Imagine {{seed_image}}".into(),
        model: Some("test-model".into()),
        max_tokens: Some(100),
        response_into_target: Some("Dream.ProduceImage".into()),
        response_into_attr: Some("text_fr".into()),
        backend: Some("test".into()),
    }
}

#[test]
fn substitute_replaces_placeholders_from_attrs() {
    let mut attrs = HashMap::new();
    attrs.insert("seed_image".into(), "snow falling".into());
    let out = hecks_life::runtime::prompt_scaffolder::substitute(
        "Imagine {{seed_image}}", &attrs, None,
    );
    assert_eq!(out, "Imagine snow falling");
}

#[test]
fn dispatcher_returns_completed_with_fixture_provider() {
    let adapter = dream_adapter();
    // Pre-compute SHA-256 of substituted prompt and register fixture.
    let mut attrs = HashMap::new();
    attrs.insert("seed_image".into(), "blue".into());
    let prompt = hecks_life::runtime::prompt_scaffolder::substitute(
        &adapter.prompt_template, &attrs, None,
    );
    let digest = TestProvider::hash_for(&prompt);

    let mut fixtures = HashMap::new();
    fixtures.insert(digest.clone(), "Bonjour, image bleue.".to_string());
    let provider: Box<dyn LlmProvider> = Box::new(TestProvider::new(fixtures));
    let mut providers: HashMap<String, Box<dyn LlmProvider>> = HashMap::new();
    providers.insert("test".into(), provider);

    let outcome = llm_dispatcher::call(&adapter, None, &attrs, Some(&providers));
    match outcome {
        LlmOutcome::Completed(r) => {
            assert_eq!(r.response_text, "Bonjour, image bleue.");
            assert_eq!(r.prompt, "Imagine blue");
            assert_eq!(r.provider, "test");
            assert_eq!(r.adapter_name, "dream_image");
        }
        LlmOutcome::Skipped(s) => panic!("expected completed, got skipped: {:?}", s),
    }
}

#[test]
fn dispatcher_skips_when_provider_unavailable_for_unknown_backend() {
    let mut adapter = dream_adapter();
    adapter.backend = Some("claude".into());
    let providers: HashMap<String, Box<dyn LlmProvider>> = HashMap::new();
    let outcome = llm_dispatcher::call(&adapter, None, &HashMap::new(), Some(&providers));
    match outcome {
        LlmOutcome::Skipped(s) => assert_eq!(s.reason, "provider_unavailable"),
        LlmOutcome::Completed(_) => panic!("expected skipped"),
    }
}

#[test]
fn dispatcher_alias_fixture_to_test_backend() {
    let mut adapter = dream_adapter();
    adapter.backend = Some("fixture".into());
    let mut attrs = HashMap::new();
    attrs.insert("seed_image".into(), "x".into());
    // No providers map → default :test provider applies (lenient).
    let outcome = llm_dispatcher::call(&adapter, None, &attrs, None);
    match outcome {
        LlmOutcome::Completed(r) => {
            assert_eq!(r.provider, "test");
            assert!(r.response_text.contains("[test-provider:unknown-prompt"));
        }
        LlmOutcome::Skipped(s) => panic!("expected completed (lenient), got skipped: {:?}", s),
    }
}

#[test]
fn substitute_falls_back_to_state_when_attr_absent() {
    let adapter = dream_adapter();
    let mut state = AggregateState::new("d1");
    state.set("seed_image", Value::Str("from-state".into()));

    let prompt = hecks_life::runtime::prompt_scaffolder::substitute(
        &adapter.prompt_template, &HashMap::new(), Some(&state),
    );
    assert_eq!(prompt, "Imagine from-state");
}

#[test]
fn split_target_parses_aggregate_command() {
    assert_eq!(
        llm_dispatcher::split_target("Dream.ProduceImage"),
        Some(("Dream".into(), "ProduceImage".into()))
    );
    assert_eq!(llm_dispatcher::split_target("NoDot"), None);
    assert_eq!(llm_dispatcher::split_target("Empty."), None);
    assert_eq!(llm_dispatcher::split_target(".AlsoEmpty"), None);
}

// ─── End-to-end : runtime cascade with hecksagon-driven LLM ─────────

const DREAM_BLUEBOOK: &str = r#"Hecks.bluebook "Dream" do
  aggregate "Dream" do
    identified_by :id
    attribute :id, String
    attribute :seed_image, String
    attribute :text_fr, String

    command "ProduceImage" do
      attribute :id, String
      attribute :seed_image, String
      attribute :text_fr, String
      then_set :seed_image, from: :seed_image
      then_set :text_fr, from: :text_fr
    end
  end
end"#;

#[test]
fn end_to_end_cascade_writes_response_into_target_attr() {
    // Parse the bluebook and load a hecksagon with a matching :llm
    // adapter targeting Dream.ProduceImage.
    let domain: Domain = parser::parse(DREAM_BLUEBOOK);
    let mut hexa = Hecksagon::default();
    hexa.name = "Dream".into();
    hexa.llm_adapters.push(dream_adapter());

    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hexa]);

    // Register a fixture provider keyed on the substituted prompt.
    let prompt = "Imagine snow falling";
    let mut fixtures = HashMap::new();
    fixtures.insert(TestProvider::hash_for(prompt), "Neige qui tombe.".to_string());
    rt.register_llm_provider("test", Box::new(TestProvider::new(fixtures)));

    // Top-level dispatch — first call seeds the aggregate's
    // seed_image and the LLM cascade fires text_fr on the chained
    // dispatch.
    let mut attrs = HashMap::new();
    attrs.insert("id".into(), Value::Str("d1".into()));
    attrs.insert("seed_image".into(), Value::Str("snow falling".into()));
    let result = rt.dispatch("Dream.ProduceImage", attrs)
        .expect("dispatch should succeed");

    // After the cascade, the aggregate's text_fr should hold the
    // fixture response.
    let state = rt.find(&result.aggregate_type, &result.aggregate_id)
        .expect("dream aggregate was created by ProduceImage");
    let text_fr = state.fields.get("text_fr")
        .map(|v| v.to_string()).unwrap_or_default();
    assert_eq!(text_fr, "Neige qui tombe.",
        "expected text_fr populated via :llm cascade ; got {:?}", state.fields);
}

#[test]
fn dispatcher_skips_silently_when_no_hecksagon_loaded() {
    let domain: Domain = parser::parse(DREAM_BLUEBOOK);
    // boot_with_data_dir sets hecksagons to Vec::new()
    let mut rt = Runtime::boot_with_data_dir(domain, None);
    let mut attrs = HashMap::new();
    attrs.insert("id".into(), Value::Str("d2".into()));
    attrs.insert("seed_image".into(), Value::Str("x".into()));
    let result = rt.dispatch("Dream.ProduceImage", attrs).unwrap();
    let state = rt.find(&result.aggregate_type, &result.aggregate_id).unwrap();
    let text_fr = state.fields.get("text_fr")
        .map(|v| v.to_string()).unwrap_or_default();
    // No cascade fired → text_fr stays whatever the command set
    // (empty for the bare attribute), confirming the dispatcher
    // didn't run when hecksagons were absent.
    assert!(text_fr.is_empty() || text_fr == "null",
        "expected empty text_fr without hecksagon, got {:?}", text_fr);
}
