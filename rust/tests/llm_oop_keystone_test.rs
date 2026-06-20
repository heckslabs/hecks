//! Keystone proof (slice 1) — the primary-adapter synchronous wait over the
//! out-of-process `:llm` effect, end-to-end, deterministic (TestProvider
//! SHA-256 fixtures, no network).
//!
//! Proves, against the SAME Dream domain :
//!   1. gate-OFF : the in-process LlmAdapter path lands the fixture completion
//!      into Dream.RecordCompletion.response_text.
//!   2. gate-ON  : the effect binding records an OutboundEvent ;
//!      drain_outbound_to_quiescence execs the llm-handler (verdict-capturing),
//!      dispatches the success verdict, and the SAME completion lands —
//!      gate-ON == gate-OFF.
//!   3. NO-BLOCK : after dispatch_deferred returns (before the drain), the
//!      OutboundEvent is still `pending` and response_text is unset ; only the
//!      drain settles it. The core never blocked.
//!   4. IDEMPOTENCY : replaying the drain after delivery does NOT re-exec the
//!      handler (Claim's `given status==pending` errors) — the verdict landed
//!      exactly once.
//!
//! [antibody-exempt: rust/tests/llm_oop_keystone_test.rs — kernel-floor
//!  conformance test ; builds + execs a real handler binary and drives the
//!  runtime drain, necessarily Rust. Sibling of effect_outbound_record_test
//!  + handler_contract_conformance_test.]

use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::runtime::llm_providers::TestProvider;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;
use std::path::PathBuf;

// A Dream aggregate : Seed emits DreamSeeded (the effect-binding trigger),
// carrying the substituted `prompt`. RecordCompletion is the verdict command
// both paths land the completion into.
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

const PROMPT: &str = "Imagine the sea at dawn";
const COMPLETION: &str = "La mer a l'aube, calme et doree.";

fn s(v: &str) -> Value {
    Value::Str(v.to_string())
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust has a parent")
        .to_path_buf()
}

/// Compile the standalone llm-handler once into a temp path. Returns its
/// absolute path. Skips the whole test gracefully if rustc is unavailable.
fn build_handler(out: &std::path::Path) -> bool {
    let src = repo_root().join("adapters/llm/llm-handler.rs");
    let status = std::process::Command::new("rustc")
        .args(["-O"])
        .arg(&src)
        .arg("-o")
        .arg(out)
        .status();
    matches!(status, Ok(s) if s.success()) && out.exists()
}

/// Write a flat-TSV fixtures file (sha256(prompt)<TAB>completion).
fn write_fixtures(path: &std::path::Path) {
    let digest = TestProvider::hash_for(PROMPT);
    std::fs::write(path, format!("{}\t{}\n", digest, COMPLETION))
        .expect("write fixtures");
}

fn dream_completion_text(rt: &Runtime) -> String {
    rt.find("Dream", "d1")
        .and_then(|s| s.fields.get("response_text").map(|v| v.to_string()))
        .unwrap_or_default()
}

fn oe_status(rt: &Runtime) -> Option<String> {
    rt.all("OutboundEvent")
        .into_iter()
        .find(|d| d.get("adapter").as_str() == Some("TestLlm"))
        .map(|d| d.get("status").as_str().unwrap_or("").to_string())
}

// The gate-OFF baseline (in-process LlmAdapter path lands COMPLETION) lives in
// llm_oop_keystone_gate_off_test.rs — a SEPARATE test binary, so the
// process-global HECKS_REPLY_OOP_LLM gate var is never set/unset concurrently
// with this gate-ON test. Equality is asserted by both landing the SAME
// COMPLETION constant.

// ---- gate ON : out-of-process effect + inline drain --------------------

fn boot_oop(root: &str) -> Runtime {
    let domain = parser::parse(DREAM);
    let handler_rel = "adapters/llm/llm-handler"; // resolved against root below
    let hecksagons = vec![
        hecksagon_parser::parse(
            "Hecks.family \"llm\" do\n  verb \"completed_by\"\n  signal :effect\n  field :backend\n  produces :response_text\nend\n",
        ),
        hecksagon_parser::parse(&format!(
            "Hecks.adapter \"TestLlm\" do\n  family \"llm\"\n  handler \"{}\"\nend\n",
            handler_rel
        )),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Dream\" do\n  Dream::Dream.completed_by(\"TestLlm\", on: \"DreamSeeded\") do\n    success \"Dream.RecordCompletion\"\n    failure \"Dream.RecordCompletion\"\n  end\nend\n",
        ),
    ];
    let mut rt = Runtime::boot_with_hecksagons(domain, None, hecksagons);
    rt.aggregates_root = Some(root.to_string());
    rt
}

#[test]
fn gate_on_oop_drain_lands_same_completion_and_is_idempotent() {
    // Build the handler + fixtures into a temp dir that doubles as the
    // aggregates_root (so the relative handler path resolves under it).
    let tmp = std::env::temp_dir().join(format!("llm_oop_keystone_{}", std::process::id()));
    let adapters_dir = tmp.join("adapters/llm");
    std::fs::create_dir_all(&adapters_dir).expect("mkdir");
    let handler_bin = adapters_dir.join("llm-handler");
    if !build_handler(&handler_bin) {
        eprintln!("[skip] rustc unavailable — cannot build llm-handler");
        return;
    }
    let fixtures = tmp.join("llm.fixtures.tsv");
    write_fixtures(&fixtures);
    std::env::set_var("LLM_FIXTURES", &fixtures);
    std::env::set_var("HECKS_REPLY_OOP_LLM", "1");

    let root = tmp.to_string_lossy().into_owned();
    let mut rt = boot_oop(&root);

    // --- 1. dispatch the core mutation only (deferred). The effect is
    //        recorded (OutboundEvent pending) but NOT yet run. ---
    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), s("d1"));
    attrs.insert("prompt".to_string(), s(PROMPT));
    rt.dispatch_deferred("Seed", attrs).expect("Seed dispatches");
    // record_effect_outbound runs inside dispatch_impl, so the delivery exists.
    rt.pump_outbox();
    rt.pump();

    // NO-BLOCK evidence : the core returned with the effect still pending and
    // the completion unset — the wait has not run.
    assert_eq!(
        oe_status(&rt).as_deref(),
        Some("pending"),
        "before the drain, the OutboundEvent is still pending (core did not block)"
    );
    // Unset VO fields read as the runtime's empty sentinel "[0 items]", never
    // the completion — so response_text is genuinely unset before the drain.
    assert_ne!(
        dream_completion_text(&rt),
        COMPLETION,
        "before the drain, response_text is NOT the completion (core did not block on the effect)"
    );

    // --- 2. the primary-adapter wait : drain to quiescence. ---
    let drained = rt.drain_outbound_to_quiescence();
    assert_eq!(drained, 1, "exactly one verdict-bearing delivery drained");

    let gate_on_text = dream_completion_text(&rt);
    assert_eq!(
        gate_on_text, COMPLETION,
        "gate-ON OOP drain lands the SAME completion as gate-OFF (== {})",
        COMPLETION
    );
    assert_eq!(
        oe_status(&rt).as_deref(),
        Some("delivered"),
        "the delivery reached a verdict -> MarkDelivered"
    );

    // --- 3. IDEMPOTENCY : replay the drain. The delivery is no longer
    //        pending, so Claim errors, the handler is NOT re-exec'd, and the
    //        verdict landed exactly once. ---
    let drained_again = rt.drain_outbound_to_quiescence();
    assert_eq!(
        drained_again, 0,
        "a replayed drain claims nothing — the delivery is already delivered"
    );
    assert_eq!(
        dream_completion_text(&rt),
        COMPLETION,
        "replay did not change the completion — verdict landed exactly once"
    );

    // cleanup
    std::env::remove_var("HECKS_REPLY_OOP_LLM");
    std::env::remove_var("LLM_FIXTURES");
    let _ = std::fs::remove_dir_all(&tmp);
}
