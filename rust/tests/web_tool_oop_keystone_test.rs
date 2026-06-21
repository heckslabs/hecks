//! Keystone proof (slice 2) — the SHAPE-DERIVED switch over the out-of-process
//! `:web_tool` effect, end-to-end, deterministic (TestWeb fixtures, NO network).
//! The web_tool sibling of llm_oop_keystone_test : NO env-gate, the switch is
//! `has_effect_binding_for` — the presence of a verdict-bearing effect binding
//! on the emitted event.
//!
//! web_tool has TWO DISTINCT family constructs sharing the name (see
//! adapters/web_tool/web_tool.family) :
//!   * `Hecks.family "web_tool"` (verb `fetched_by`, `produces :output`) — the
//!     OUT-OF-PROCESS effect form. A verdict-bearing binding on the emitted event
//!     records an OutboundEvent ; the drain execs the handler, threads `output=`
//!     into the success command.
//!   * `adapter :web_tool, command:, tool:, result_into:` — the IN-PROCESS
//!     io-adapter form. `resolve_web_tool_adapters` runs `web_tool_dispatcher`
//!     inline and cascades the result into `result_into`.
//!
//! Three proofs over a `Fetch` domain :
//!   * WITH the effect binding — OOP. The in-process io-adapter is ALSO present
//!     (so the in-process path is demonstrably CAPABLE), yet the shape-switch
//!     suppresses it : the OutboundEvent is PENDING + status is NOT `completed`
//!     after the core returns (core didn't block ; in-process suppressed). The
//!     drain then settles `output` to the EXACT TestWeb fixture value. Replaying
//!     the drain is idempotent (Claim's `given status==pending`).
//!   * WITHOUT the binding — in-process. The io-adapter fires inline and cascades
//!     RecordResult (status -> `completed`), with ZERO OutboundEvents. The input
//!     is a `validate_url`-rejected URL : deterministic, NO network. We assert on
//!     `status` (a mark ONLY the cascade sets) — not on `output`, which the
//!     rejection lands as `""` and would false-green if the resolver never fired.
//!   * claude_tool / mcp events carry NO verdict binding — has_effect_binding_for
//!     is false for them, so they always resolve in-process (asserted here).
//!
//! CROSS-PATH EQUALITY CAVEAT (reported, not faked) : unlike llm — whose
//! in-process path has the `register_llm_provider` test seam — the in-process
//! web_tool path (`web_tool_dispatcher::dispatch`) has NO fixture seam and runs
//! real curl/DuckDuckGo. Its only deterministic no-network output is a
//! `validate_url` rejection, where `err()` lands `output=""` while the handler
//! lands `output=<message>` (and in-process uses `truncate`, the handler
//! `one_line`). So there is NO deterministic no-network input where the two land
//! an equal `output`. We prove the OOP value equals the TestWeb FIXTURE (the
//! deterministic contract), and prove the in-process path FIRES — but byte
//! cross-path equality is NOT claimed for web_tool (it IS for llm). Adding a
//! fixture seam to the kernel dispatcher is out of this slice's scope.
//!
//! [antibody-exempt: rust/tests/web_tool_oop_keystone_test.rs — kernel-floor
//!  conformance test ; builds + execs a real handler binary and drives the
//!  runtime drain, necessarily Rust. Sibling of llm_oop_keystone_test +
//!  handler_contract_conformance_test.]

use storehouse::hecksagon_ir::{Hecksagon, IoAdapter};
use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;

// Tests in THIS file binary run as parallel threads sharing ONE process env.
// The OOP tests set/remove `WEB_TOOL_FIXTURES` (inherited by the drain's handler
// child) ; without serialization a sibling thread stomps the fixtures and the
// handler misses. Hold this lock across set_var -> drain -> remove_var so the
// env mutation is atomic per-test. Each tests/ file is its own binary, so this
// lock is file-local. (The in-process rejection test touches no env -> no lock.)
static ENV_LOCK: Mutex<()> = Mutex::new(());

const FETCH: &str = r#"Hecks.bluebook "Fetch" do
  aggregate "Fetch" do
    identified_by :id
    attribute :id,     FetchId
    attribute :tool,   Tool
    attribute :url,    Url
    attribute :output, Output
    attribute :status, Status, default: "started"
    value_object "FetchId" do
      attribute :value, String
    end
    value_object "Tool" do
      attribute :value, String
    end
    value_object "Url" do
      attribute :value, String
    end
    value_object "Output" do
      attribute :value, String
    end
    value_object "Status" do
      attribute :value, String
    end
    command "Start" do
      role "System"
      attribute :id,   FetchId
      attribute :tool, Tool
      attribute :url,  Url
      then_set :tool, to: :tool
      then_set :url,  to: :url
      emits "Fetched"
    end
    command "RecordResult" do
      role "System"
      attribute :id,     FetchId
      attribute :output, Output
      then_set :output, to: :output
      then_set :status, to: "completed"
      emits "FetchRecorded"
    end
  end
end
"#;

const TOOL: &str = "web_fetch";
const URL: &str = "https://example.com/dawn";
const OUTPUT: &str = "the sea at dawn, deterministic body";
// A validate_url-rejected URL : the in-process dispatcher rejects it BEFORE any
// curl, so the WITHOUT-binding proof is no-network deterministic.
const BAD_URL: &str = "file:///etc/passwd";

fn s(v: &str) -> Value {
    Value::Str(v.to_string())
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust has a parent")
        .to_path_buf()
}

/// Compile the standalone web-tool-handler once into `out`. Skips the test
/// gracefully if rustc is unavailable.
fn build_handler(out: &std::path::Path) -> bool {
    let src = repo_root().join("adapters/web_tool/web-tool-handler.rs");
    let status = std::process::Command::new("rustc")
        .args(["-O"])
        .arg(&src)
        .arg("-o")
        .arg(out)
        .status();
    matches!(status, Ok(s) if s.success()) && out.exists()
}

/// Write a flat-TSV fixtures file (`<tool>:<arg><TAB>output`).
fn write_fixtures(path: &std::path::Path) {
    std::fs::write(path, format!("{}:{}\t{}\n", TOOL, URL, OUTPUT)).expect("write fixtures");
}

fn fetch_field(rt: &Runtime, field: &str) -> String {
    rt.find("Fetch", "f1")
        .and_then(|s| s.fields.get(field).map(|v| v.to_string()))
        .unwrap_or_default()
}

fn oe_status(rt: &Runtime) -> Option<String> {
    rt.all("OutboundEvent")
        .into_iter()
        .find(|d| d.get("adapter").as_str() == Some("TestWeb"))
        .map(|d| d.get("status").as_str().unwrap_or("").to_string())
}

/// The in-process io-adapter the WITH-binding fixture ALSO carries — so the
/// in-process path is demonstrably available and the proof is SUPPRESSION, not a
/// missing wiring. `command` matches Fetch.Start ; result_into cascades the
/// fetched body into Fetch.RecordResult.
fn in_process_io_adapter() -> IoAdapter {
    IoAdapter {
        kind: "web_tool".into(),
        options: vec![
            ("command".into(), "Fetch.Start".into()),
            ("tool".into(), "web_fetch".into()),
            ("result_into".into(), "Fetch.RecordResult".into()),
        ],
        on_events: vec![],
    }
}

/// The OOP family + adapter + verdict binding (mirrors the llm boot).
fn oop_hecksagons() -> Vec<Hecksagon> {
    vec![
        hecksagon_parser::parse(
            "Hecks.family \"web_tool\" do\n  verb \"fetched_by\"\n  signal :effect\n  field :tool\n  produces :output\nend\n",
        ),
        hecksagon_parser::parse(
            "Hecks.adapter \"TestWeb\" do\n  family \"web_tool\"\n  handler \"adapters/web_tool/web-tool-handler\"\nend\n",
        ),
        hecksagon_parser::parse(
            "Hecks.hecksagon \"Fetch\" do\n  Fetch::Fetch.fetched_by(\"TestWeb\", on: \"Fetched\") do\n    success \"Fetch.RecordResult\"\n    failure \"Fetch.RecordResult\"\n  end\nend\n",
        ),
    ]
}

/// Boot WITH the effect binding (OOP-owning) PLUS the in-process io-adapter. The
/// shape-switch must suppress the in-process path.
fn boot_oop(root: &str) -> Runtime {
    let domain = parser::parse(FETCH);
    let mut hexes = oop_hecksagons();
    // Ride the in-process io-adapter on a Fetch hecksagon so it coexists with the
    // effect binding (both attach to the Start dispatch / its emitted event).
    let mut fetch_hex = Hecksagon::default();
    fetch_hex.name = "Fetch".into();
    fetch_hex.io_adapters.push(in_process_io_adapter());
    hexes.push(fetch_hex);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, hexes);
    rt.aggregates_root = Some(root.to_string());
    rt
}

fn start_attrs() -> HashMap<String, Value> {
    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), s("f1"));
    attrs.insert("tool".to_string(), s(TOOL));
    attrs.insert("url".to_string(), s(URL));
    attrs
}

#[test]
fn shape_switch_with_binding_suppresses_in_process_and_drain_settles_fixture_output() {
    let _env = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = std::env::temp_dir().join(format!("web_tool_keystone_{}", std::process::id()));
    let adapters_dir = tmp.join("adapters/web_tool");
    std::fs::create_dir_all(&adapters_dir).expect("mkdir");
    let handler_bin = adapters_dir.join("web-tool-handler");
    if !build_handler(&handler_bin) {
        eprintln!("[skip] rustc unavailable — cannot build web-tool-handler");
        return;
    }
    let fixtures = tmp.join("web_tool.fixtures.tsv");
    write_fixtures(&fixtures);
    std::env::set_var("WEB_TOOL_FIXTURES", &fixtures);

    let root = tmp.to_string_lossy().into_owned();
    let mut rt = boot_oop(&root);

    rt.dispatch_deferred("Start", start_attrs()).expect("Start dispatches");
    rt.pump_outbox();
    rt.pump();

    // SUPPRESSION evidence : the in-process io-adapter is present + CAPABLE, yet
    // the OutboundEvent is pending and status is NOT completed (the cascade that
    // only the in-process path would have run did not run). Only the shape-switch
    // could have held the in-process path off.
    assert_eq!(
        oe_status(&rt).as_deref(),
        Some("pending"),
        "before the drain, the OutboundEvent is still pending (core did not block; in-process suppressed)"
    );
    assert_ne!(
        fetch_field(&rt, "status"),
        "completed",
        "before the drain, status is NOT completed (in-process cascade SUPPRESSED despite being available)"
    );

    // The primary-adapter wait : drain to quiescence.
    let drained = rt.drain_outbound_to_quiescence();
    assert_eq!(drained, 1, "exactly one verdict-bearing delivery drained");

    assert_eq!(
        fetch_field(&rt, "output"),
        OUTPUT,
        "OOP drain lands the EXACT TestWeb fixture output (the deterministic produces contract)"
    );
    assert_eq!(
        fetch_field(&rt, "status"),
        "completed",
        "the success verdict (RecordResult) ran -> status completed"
    );
    assert_eq!(
        oe_status(&rt).as_deref(),
        Some("delivered"),
        "the delivery reached a verdict -> MarkDelivered"
    );

    // IDEMPOTENCY : replay the drain. The delivery is no longer pending, so Claim
    // errors, the handler is NOT re-exec'd, the verdict landed exactly once.
    let drained_again = rt.drain_outbound_to_quiescence();
    assert_eq!(
        drained_again, 0,
        "a replayed drain claims nothing — the delivery is already delivered"
    );
    assert_eq!(
        fetch_field(&rt, "output"),
        OUTPUT,
        "replay did not change output — verdict landed exactly once"
    );

    std::env::remove_var("WEB_TOOL_FIXTURES");
    let _ = std::fs::remove_dir_all(&tmp);
}

/// 3x determinism : the OOP drain lands the SAME fixture output every run.
#[test]
fn shape_switch_oop_drain_is_deterministic_across_runs() {
    let _env = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let tmp = std::env::temp_dir().join(format!("web_tool_keystone_det_{}", std::process::id()));
    let adapters_dir = tmp.join("adapters/web_tool");
    std::fs::create_dir_all(&adapters_dir).expect("mkdir");
    let handler_bin = adapters_dir.join("web-tool-handler");
    if !build_handler(&handler_bin) {
        eprintln!("[skip] rustc unavailable — cannot build web-tool-handler");
        return;
    }
    let fixtures = tmp.join("web_tool.fixtures.tsv");
    write_fixtures(&fixtures);
    std::env::set_var("WEB_TOOL_FIXTURES", &fixtures);
    let root = tmp.to_string_lossy().into_owned();

    for _ in 0..3 {
        let mut rt = boot_oop(&root);
        rt.dispatch_deferred("Start", start_attrs()).expect("Start dispatches");
        rt.pump_outbox();
        rt.pump();
        assert_eq!(rt.drain_outbound_to_quiescence(), 1);
        assert_eq!(fetch_field(&rt, "output"), OUTPUT, "deterministic OOP output");
    }

    std::env::remove_var("WEB_TOOL_FIXTURES");
    let _ = std::fs::remove_dir_all(&tmp);
}

/// WITHOUT the binding — the in-process io-adapter fires inline and cascades
/// RecordResult, with ZERO OutboundEvents. Driven by a validate_url-rejected URL
/// so it's no-network deterministic. We assert on `status` (a mark ONLY the
/// cascade sets) so the proof can't false-green on `output==""`.
#[test]
fn no_binding_in_process_fires_cascade_and_records_zero_outbound_events() {
    let domain = parser::parse(FETCH);
    // The in-process io-adapter — IDENTICAL to the one the OOP fixture carries.
    // The ONLY difference is the absent effect binding.
    let mut hex = Hecksagon::default();
    hex.name = "Fetch".into();
    hex.io_adapters.push(in_process_io_adapter());
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hex]);

    // No verdict binding -> the in-process path is NOT suppressed.
    assert!(
        !rt.has_effect_binding_for("Fetched", "web_tool"),
        "no effect binding -> the shape-switch leaves the in-process path live"
    );

    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), s("f1"));
    attrs.insert("tool".to_string(), s(TOOL));
    attrs.insert("url".to_string(), s(BAD_URL));
    rt.dispatch("Start", attrs).expect("Start dispatches");

    // The cascade RAN : status was flipped to completed by RecordResult. (The
    // rejection lands output="" — so we assert on status, the firing mark, not
    // output, which would be "" whether or not the resolver fired.)
    assert_eq!(
        fetch_field(&rt, "status"),
        "completed",
        "in-process io-adapter fired its result_into cascade (status -> completed)"
    );

    // Nothing went out-of-process : ZERO OutboundEvents recorded.
    assert_eq!(
        rt.all("OutboundEvent").len(),
        0,
        "in-process path records NO OutboundEvent (no effect binding to record)"
    );
}

/// claude_tool / mcp events carry NO verdict binding — has_effect_binding_for is
/// false for them, so they are NEVER suppressed (always in-process). The
/// explicit "don't touch claude_tool/mcp" assertion the slice requires.
#[test]
fn claude_tool_and_mcp_events_have_no_verdict_binding_so_never_suppressed() {
    let domain = parser::parse(FETCH);
    let rt = Runtime::boot_with_hecksagons(domain, None, oop_hecksagons());
    // The web_tool event IS verdict-bound -> suppressed.
    assert!(
        rt.has_effect_binding_for("Fetched", "web_tool"),
        "the web_tool effect binding on Fetched is verdict-bearing -> OOP owns it"
    );
    // claude_tool / mcp have no such binding here -> in-process.
    assert!(
        !rt.has_effect_binding_for("Fetched", "claude_tool"),
        "claude_tool has no verdict binding -> never suppressed (stays in-process)"
    );
    assert!(
        !rt.has_effect_binding_for("Fetched", "mcp"),
        "mcp has no verdict binding -> never suppressed (stays in-process)"
    );
    // An unrelated event name matches nothing.
    assert!(
        !rt.has_effect_binding_for("NoSuchEvent", "web_tool"),
        "no binding on an unrelated event"
    );
    // Empty event -> false.
    assert!(!rt.has_effect_binding_for("", "web_tool"), "empty event name -> false");
}
