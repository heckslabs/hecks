//! Keystone proof (slice 2) — the IN-PROCESS side of the shape-derived switch.
//!
//! The COMPLEMENT of llm_oop_keystone_test.rs : the SAME Dream domain + the SAME
//! in-process LlmAdapter + provider, but WITHOUT the effect binding. With no
//! verdict-bearing binding on DreamSeeded, `has_effect_binding_for` is false, the
//! in-process resolver is NOT suppressed, and it lands the TestProvider fixture
//! completion into Dream.RecordCompletion.response_text — with ZERO OutboundEvents
//! recorded (nothing went out-of-process).
//!
//! This is the equality target (== COMPLETION) the gate-ON OOP drain must match,
//! AND the suppression contrast : differ ONLY by the binding, and the field goes
//! from SET+0-OE (here) to UNSET+1-pending-OE (OOP). No env var anywhere.
//!
//! [antibody-exempt: rust/tests/llm_in_process_test.rs — kernel-floor conformance
//!  test, sibling of llm_oop_keystone_test ; the in-process half of the
//!  shape-switch proof.]

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

// MUST match llm_oop_keystone_test.rs so the two halves are comparable.
const PROMPT: &str = "Imagine the sea at dawn";
const COMPLETION: &str = "La mer a l'aube, calme et doree.";

fn s(v: &str) -> Value {
    Value::Str(v.to_string())
}

#[test]
fn no_binding_in_process_lands_completion_and_records_zero_outbound_events() {
    let domain = parser::parse(DREAM);
    // The in-process adapter — IDENTICAL to the one the OOP fixture also carries.
    // The ONLY difference between the two proofs is the effect binding (absent
    // here).
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

    // No verdict binding -> the in-process path is NOT suppressed.
    assert!(
        !rt.has_effect_binding_for("DreamSeeded", "llm"),
        "no effect binding -> the shape-switch leaves the in-process path live"
    );

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
        "in-process llm lands the fixture completion (== the OOP target)"
    );

    // Nothing went out-of-process : ZERO OutboundEvents recorded.
    assert_eq!(
        rt.all("OutboundEvent").len(),
        0,
        "in-process path records NO OutboundEvent (no effect binding to record)"
    );
}
