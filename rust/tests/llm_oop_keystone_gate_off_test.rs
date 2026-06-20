//! Keystone proof (slice 1) — the gate-OFF baseline, in its OWN test binary.
//!
//! Lives in a SEPARATE file from the gate-ON test ON PURPOSE : the
//! HECKS_REPLY_OOP_LLM gate is a process-global env var, and two #[test] fns in
//! the same binary run in parallel threads — one setting the var while the other
//! is mid-dispatch would flip the in-process path's early-return and flake.
//! Separate binaries = separate processes = no shared env state. Deterministic
//! by construction.
//!
//! Proves : with the gate OFF (var absent), the in-process LlmAdapter path lands
//! the TestProvider fixture completion into Dream.RecordCompletion.response_text
//! — the equality target the gate-ON OOP drain must match (see
//! llm_oop_keystone_test.rs).
//!
//! [antibody-exempt: rust/tests/llm_oop_keystone_gate_off_test.rs — kernel-floor
//!  conformance test, sibling of llm_oop_keystone_test ; split out to isolate
//!  the process-global gate env var.]

use storehouse::hecksagon_ir::{Hecksagon, LlmAdapter};
use storehouse::parser;
use storehouse::runtime::llm_providers::TestProvider;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

const DREAM: &str = r#"Hecks.bluebook "Dream" do
  aggregate "Dream" do
    identified_by :id
    attribute :id,            DreamId
    attribute :prompt,        Prompt
    attribute :response_text, ResponseText
    attribute :status,        Status, default: "seeded"
    value_object "DreamId" do
      attribute :value, String
    end
    value_object "Prompt" do
      attribute :value, String
    end
    value_object "ResponseText" do
      attribute :value, String
    end
    value_object "Status" do
      attribute :value, String
    end
    command "Seed" do
      role "System"
      attribute :id,     DreamId
      attribute :prompt, Prompt
      then_set :prompt, to: :prompt
      emits "DreamSeeded"
    end
    command "RecordCompletion" do
      role "System"
      attribute :id,            DreamId
      attribute :response_text, ResponseText
      then_set :response_text, to: :response_text
      then_set :status,        to: "completed"
      emits "DreamCompleted"
    end
  end
end
"#;

// MUST match llm_oop_keystone_test.rs so the two baselines are comparable.
const PROMPT: &str = "Imagine the sea at dawn";
const COMPLETION: &str = "La mer a l'aube, calme et doree.";

fn s(v: &str) -> Value {
    Value::Str(v.to_string())
}

#[test]
fn gate_off_in_process_llm_lands_completion() {
    // No gate var in THIS process — the in-process LlmAdapter path is live.
    let domain = parser::parse(DREAM);
    let mut hexa = Hecksagon::default();
    hexa.name = "Dream".into();
    hexa.llm_adapters.push(LlmAdapter {
        name: "in_proc_llm".into(),
        prompt_template: PROMPT.into(),
        model: Some("test-model".into()),
        max_tokens: Some(64),
        trigger_on: Some("Dream.Seed".into()),
        response_into_target: Some("Dream.RecordCompletion".into()),
        response_into_attr: Some("response_text".into()),
        backend: Some("test".into()),
    });
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hexa]);
    let mut fixtures = HashMap::new();
    fixtures.insert(TestProvider::hash_for(PROMPT), COMPLETION.to_string());
    rt.register_llm_provider("test", Box::new(TestProvider::new(fixtures)));

    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), s("d1"));
    attrs.insert("prompt".to_string(), s(PROMPT));
    rt.dispatch("Seed", attrs).expect("Seed dispatches");

    let text = rt
        .find("Dream", "d1")
        .and_then(|s| s.fields.get("response_text").map(|v| v.to_string()))
        .unwrap_or_default();
    assert_eq!(
        text, COMPLETION,
        "gate-OFF in-process llm lands the fixture completion (== the OOP target)"
    );
}
