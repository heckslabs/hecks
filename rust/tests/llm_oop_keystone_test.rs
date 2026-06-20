//! Keystone proof (slice 2) — the SHAPE-DERIVED switch over the out-of-process
//! `:llm` effect, end-to-end, deterministic (TestProvider SHA-256 fixtures, no
//! network). NO env var : the switch is `has_effect_binding_for` — the presence
//! of a verdict-bearing effect binding on the emitted event.
//!
//! Two fixtures over the SAME Dream domain, differing ONLY by the effect binding
//! (both have the in-process LlmAdapter present + a TestProvider registered, so
//! the in-process path is demonstrably CAPABLE of firing) :
//!
//!   * WITH the effect binding (this file) — OOP. dispatch_deferred records an
//!     OutboundEvent (pending) and the in-process resolver SUPPRESSES itself
//!     (has_effect_binding_for true), so response_text is UNSET and the
//!     OutboundEvent is PENDING after the core returns — PROOF the core did not
//!     block AND the in-process path (though available) did not fire. The drain
//!     then settles it to the SAME completion the in-process path would land.
//!     Replaying the drain is idempotent (Claim's `given status==pending`).
//!   * WITHOUT the binding (llm_in_process_test.rs) — in-process. response_text
//!     is SET after the pump and ZERO OutboundEvents are recorded.
//!
//! Equality target : both land the SAME COMPLETION constant (deterministic
//! TestProvider keyed by SHA-256(prompt)).
//!
//! Plus : claude_tool / mcp events have NO verdict binding — has_effect_binding_for
//! returns false for them, so they always resolve in-process (asserted here).
//!
//! [antibody-exempt: rust/tests/llm_oop_keystone_test.rs — kernel-floor
//!  conformance test ; builds + execs a real handler binary and drives the
//!  runtime drain, necessarily Rust. Sibling of llm_in_process_test +
//!  handler_contract_conformance_test.]

use storehouse::hecksagon_ir::{Hecksagon, LlmAdapter};
use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::runtime::llm_providers::TestProvider;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

// Tests in THIS file binary run as parallel threads sharing ONE process env.
// Both env-touching tests below set/remove `LLM_FIXTURES` ; without
// serialization a sibling thread's set/remove stomps the other's fixtures and
// the handler misses (lenient placeholder instead of the completion). Hold this
// lock across set_var -> drain -> remove_var so the env mutation is atomic
// per-test. Each tests/ file is its own binary, so this lock is file-local.
static ENV_LOCK: Mutex<()> = Mutex::new(());

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

/// Compile the standalone llm-handler once into `out`. Skips the test
/// gracefully if rustc is unavailable.
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
    std::fs::write(path, format!("{}\t{}\n", digest, COMPLETION)).expect("write fixtures");
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

/// The in-process LlmAdapter the WITH-binding fixture ALSO carries — so the
/// in-process path is demonstrably available and the proof is SUPPRESSION, not a
/// missing wiring.
fn in_process_adapter() -> LlmAdapter {
    LlmAdapter {
        name: "in_proc_llm".into(),
        prompt_template: PROMPT.into(),
        model: Some("test-model".into()),
        max_tokens: Some(64),
        trigger_on: Some("Dream.Seed".into()),
        response_into_target: Some("Dream.RecordCompletion".into()),
        response_into_attr: Some("response_text".into()),
        backend: Some("test".into()),
    }
}

/// Boot WITH the effect binding (OOP-owning) PLUS the in-process adapter +
/// provider. The shape-switch must suppress the in-process path.
fn boot_oop(root: &str) -> Runtime {
    let domain = parser::parse(DREAM);
    let handler_rel = "adapters/llm/llm-handler";
    // The in-process adapter rides on a parsed Dream hecksagon so it coexists
    // with the effect binding (which subscribes to the same event's verdict).
    let mut dream_hex = Hecksagon::default();
    dream_hex.name = "Dream".into();
    dream_hex.llm_adapters.push(in_process_adapter());
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
        dream_hex,
    ];
    let mut rt = Runtime::boot_with_hecksagons(domain, None, hecksagons);
    let mut fixtures = HashMap::new();
    fixtures.insert(TestProvider::hash_for(PROMPT), COMPLETION.to_string());
    rt.register_llm_provider("test", Box::new(TestProvider::new(fixtures)));
    rt.aggregates_root = Some(root.to_string());
    rt
}

#[test]
fn shape_switch_with_binding_suppresses_in_process_and_drain_settles_same_completion() {
    let _env = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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

    let root = tmp.to_string_lossy().into_owned();
    let mut rt = boot_oop(&root);

    // --- dispatch the core mutation (deferred). dispatch_impl records the
    //     OutboundEvent AND runs react_ports (the in-process resolver, which
    //     SUPPRESSES itself because the event carries a verdict binding). ---
    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), s("d1"));
    attrs.insert("prompt".to_string(), s(PROMPT));
    rt.dispatch_deferred("Seed", attrs).expect("Seed dispatches");
    rt.pump_outbox();
    rt.pump();

    // SUPPRESSION evidence : the in-process adapter + provider are present and
    // CAPABLE, yet response_text is unset and the OutboundEvent is pending. Only
    // the shape-switch could have held the in-process path off.
    assert_eq!(
        oe_status(&rt).as_deref(),
        Some("pending"),
        "before the drain, the OutboundEvent is still pending (core did not block; in-process suppressed)"
    );
    assert_ne!(
        dream_completion_text(&rt),
        COMPLETION,
        "before the drain, response_text is NOT the completion (in-process path SUPPRESSED despite being available)"
    );

    // --- the primary-adapter wait : drain to quiescence. ---
    let drained = rt.drain_outbound_to_quiescence();
    assert_eq!(drained, 1, "exactly one verdict-bearing delivery drained");

    assert_eq!(
        dream_completion_text(&rt),
        COMPLETION,
        "OOP drain lands the SAME completion the in-process path would (== {})",
        COMPLETION
    );
    assert_eq!(
        oe_status(&rt).as_deref(),
        Some("delivered"),
        "the delivery reached a verdict -> MarkDelivered"
    );

    // --- IDEMPOTENCY : replay the drain. The delivery is no longer pending, so
    //     Claim errors, the handler is NOT re-exec'd, the verdict landed once. ---
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

    std::env::remove_var("LLM_FIXTURES");
    let _ = std::fs::remove_dir_all(&tmp);
}

/// 3x determinism : the OOP drain lands the SAME completion every run.
#[test]
fn shape_switch_oop_drain_is_deterministic_across_runs() {
    let _env = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = std::env::temp_dir().join(format!("llm_oop_keystone_det_{}", std::process::id()));
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
    let root = tmp.to_string_lossy().into_owned();

    for _ in 0..3 {
        let mut rt = boot_oop(&root);
        let mut attrs = HashMap::new();
        attrs.insert("id".to_string(), s("d1"));
        attrs.insert("prompt".to_string(), s(PROMPT));
        rt.dispatch_deferred("Seed", attrs).expect("Seed dispatches");
        rt.pump_outbox();
        rt.pump();
        assert_eq!(rt.drain_outbound_to_quiescence(), 1);
        assert_eq!(dream_completion_text(&rt), COMPLETION, "deterministic OOP completion");
    }

    std::env::remove_var("LLM_FIXTURES");
    let _ = std::fs::remove_dir_all(&tmp);
}

/// claude_tool / mcp events carry NO verdict binding — has_effect_binding_for is
/// false for them, so they are NEVER suppressed (always in-process). This is the
/// explicit "don't touch claude_tool/mcp" assertion the slice requires.
#[test]
fn claude_tool_and_mcp_events_have_no_verdict_binding_so_never_suppressed() {
    let domain = parser::parse(DREAM);
    let rt = boot_oop_switch_probe(domain);
    // The llm event IS verdict-bound -> suppressed.
    assert!(
        rt.has_effect_binding_for("DreamSeeded", "llm"),
        "the llm effect binding on DreamSeeded is verdict-bearing -> OOP owns it"
    );
    // claude_tool / mcp have no such binding here -> in-process.
    assert!(
        !rt.has_effect_binding_for("DreamSeeded", "claude_tool"),
        "claude_tool has no verdict binding -> never suppressed (stays in-process)"
    );
    assert!(
        !rt.has_effect_binding_for("DreamSeeded", "mcp"),
        "mcp has no verdict binding -> never suppressed (stays in-process)"
    );
    // An unrelated event name matches nothing.
    assert!(
        !rt.has_effect_binding_for("NoSuchEvent", "llm"),
        "no binding on an unrelated event"
    );
    // Empty event -> false (no event means nothing could have been recorded oop).
    assert!(!rt.has_effect_binding_for("", "llm"), "empty event name -> false");
}

fn boot_oop_switch_probe(domain: storehouse::ir::Domain) -> Runtime {
    let hecksagons = vec![
        hecksagon_parser::parse(
            "Hecks.family \"llm\" do\n  verb \"completed_by\"\n  signal :effect\n  field :backend\n  produces :response_text\nend\n",
        ),
        hecksagon_parser::parse(
            "Hecks.adapter \"TestLlm\" do\n  family \"llm\"\n  handler \"adapters/llm/llm-handler\"\nend\n",
        ),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Dream\" do\n  Dream::Dream.completed_by(\"TestLlm\", on: \"DreamSeeded\") do\n    success \"Dream.RecordCompletion\"\n    failure \"Dream.RecordCompletion\"\n  end\nend\n",
        ),
    ];
    Runtime::boot_with_hecksagons(domain, None, hecksagons)
}
