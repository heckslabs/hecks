//! Conformance: a family's `produces` output contract is honored by the
//! handler of its adapters (thread "family establishes the binary contract").
//!
//! The family DECLARES what verdict data a conforming handler must emit
//! (`produces :payment_ref`) ; this test resolves the adapter's handler and
//! EXECS it, asserting it actually emits each declared field as a `k=v` line
//! on stdout, and that its exit code maps to the verdict branch (0 success,
//! non-zero failure). The bluebook DECLARES the contract ; this test ENFORCES
//! it — the "followable + checkable" half. The generic exec protocol (stdin
//! payload, stdout k=v, exit branch) lives in the host ; the per-family
//! input+output fields live on the family.
//!
//! [antibody-exempt: rust/tests/handler_contract_conformance_test.rs —
//!  kernel-floor conformance test ; execs a real handler binary and asserts
//!  on its stdout/exit, necessarily Rust. Sibling of specializer_golden_test.]

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust has a parent")
        .to_path_buf()
}

fn dump(root: &PathBuf, rel: &str) -> serde_json::Value {
    let sh = root.join("rust/target/release/storehouse");
    assert!(sh.exists(), "storehouse binary missing — build release first");
    let out = Command::new(&sh)
        .args(["dump-hecksagon", rel])
        .current_dir(root)
        .output()
        .expect("dump-hecksagon failed");
    serde_json::from_slice(&out.stdout).expect("dump-hecksagon emitted non-JSON")
}

fn run_handler(root: &PathBuf, handler: &str, decline: bool) -> (bool, String) {
    let mut cmd = Command::new(root.join(handler));
    cmd.current_dir(root).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    if decline {
        cmd.env("STRIPE_DECLINE", "1");
    }
    let mut child = cmd.spawn().expect("handler binary not spawnable");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"customer_name\":\"Bob\",\"amount\":100}")
        .unwrap();
    let out = child.wait_with_output().expect("handler did not finish");
    (out.status.success(), String::from_utf8_lossy(&out.stdout).to_string())
}

#[test]
fn payment_handler_honors_family_produces_contract() {
    let root = repo_root();

    // 1. The family's declared output contract.
    let fam = dump(&root, "examples/pizzas/bluebook/payment.family");
    let produces: Vec<String> = fam["families"][0]["produces"]
        .as_array()
        .expect("family has a produces array")
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert!(
        produces.contains(&"payment_ref".to_string()),
        "payment family should declare `produces :payment_ref` ; got {:?}",
        produces,
    );

    // 2. The Stripe adapter's declared handler binary.
    let adp = dump(&root, "examples/pizzas/bluebook/stripe.adapter");
    let handler = adp["adapters"][0]["handler"]
        .as_str()
        .expect("adapter declares a handler");
    assert!(!handler.is_empty(), "Stripe adapter must declare a handler");

    // 3. Success branch : exit 0, and every `produces` field present as k=v.
    let (ok, stdout) = run_handler(&root, handler, false);
    assert!(ok, "handler should exit 0 on the success branch");
    for field in &produces {
        assert!(
            stdout.lines().any(|l| l.starts_with(&format!("{}=", field))),
            "handler must emit `{}=` per the family's produces contract ; stdout was:\n{}",
            field,
            stdout,
        );
    }

    // 4. Failure branch : STRIPE_DECLINE=1 maps to a non-zero exit.
    let (ok, _) = run_handler(&root, handler, true);
    assert!(!ok, "STRIPE_DECLINE=1 should exit non-zero (the failure branch)");
}

// ── llm family (slice 1) ────────────────────────────────────────────────
//
// The `llm` family declares `produces :response_text` ; its verdict-capturing
// handler (adapters/llm/llm-handler) must emit `response_text=` on stdout and
// exit 0 (the success branch). Plus an IDEMPOTENCY-REPLAY case : the handler is
// deterministic (TestProvider SHA-256), so re-running it with the same payload
// + fixtures yields byte-identical stdout — a replayed delivery never
// double-produces a different verdict.

/// Build the standalone llm-handler into `out`. Returns false (test skips) if
/// rustc is unavailable.
fn build_llm_handler(root: &PathBuf, out: &std::path::Path) -> bool {
    let src = root.join("adapters/llm/llm-handler.rs");
    let status = Command::new("rustc")
        .args(["-O"]).arg(&src).arg("-o").arg(out).status();
    matches!(status, Ok(s) if s.success()) && out.exists()
}

/// Run the llm-handler : prompt payload on stdin, optional LLM_FIXTURES env.
fn run_llm_handler(bin: &std::path::Path, prompt: &str, fixtures: Option<&std::path::Path>) -> (bool, String) {
    let mut cmd = Command::new(bin);
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    if let Some(f) = fixtures {
        cmd.env("LLM_FIXTURES", f);
    }
    let mut child = cmd.spawn().expect("llm-handler not spawnable");
    child.stdin.take().unwrap()
        .write_all(format!("{{\"prompt\":\"{}\"}}", prompt).as_bytes()).unwrap();
    let out = child.wait_with_output().expect("llm-handler did not finish");
    (out.status.success(), String::from_utf8_lossy(&out.stdout).to_string())
}

#[test]
fn llm_handler_honors_family_produces_contract_and_is_replay_idempotent() {
    let root = repo_root();

    // 1. The family's declared output contract.
    let fam = dump(&root, "adapters/llm/llm.family");
    let produces: Vec<String> = fam["families"][0]["produces"]
        .as_array().expect("llm family has a produces array")
        .iter().map(|v| v.as_str().unwrap().to_string()).collect();
    assert!(
        produces.contains(&"response_text".to_string()),
        "llm family should declare `produces :response_text` ; got {:?}", produces,
    );

    // 2. The adapter's declared handler binary.
    let adp = dump(&root, "adapters/llm/test-llm.adapter");
    let handler = adp["adapters"][0]["handler"].as_str().expect("adapter declares a handler");
    assert_eq!(handler, "adapters/llm/llm-handler", "TestLlm declares the llm-handler");

    // Build the handler into a temp path (the repo doesn't ship the binary).
    let bin = std::env::temp_dir().join(format!("llm_handler_conf_{}", std::process::id()));
    if !build_llm_handler(&root, &bin) {
        eprintln!("[skip] rustc unavailable — cannot build llm-handler");
        return;
    }

    // 3. Success branch : exit 0, every `produces` field present as k=v.
    let (ok, stdout) = run_llm_handler(&bin, "Imagine the sea", None);
    assert!(ok, "llm-handler should exit 0 on the success branch");
    for field in &produces {
        assert!(
            stdout.lines().any(|l| l.starts_with(&format!("{}=", field))),
            "handler must emit `{}=` per produces ; stdout was:\n{}", field, stdout,
        );
    }

    // 4. IDEMPOTENCY-REPLAY : deterministic verdict — re-running with the same
    //    payload yields byte-identical stdout (a replay never double-produces a
    //    different verdict).
    let (ok2, stdout2) = run_llm_handler(&bin, "Imagine the sea", None);
    assert!(ok2);
    assert_eq!(stdout, stdout2, "llm-handler is deterministic — replay is byte-identical");

    let _ = std::fs::remove_file(&bin);
}

// ── web_tool family (slice 2) ────────────────────────────────────────────
//
// The `web_tool` family declares `produces :output` ; its verdict-capturing
// handler (adapters/web_tool/web-tool-handler) must emit `output=` on stdout and
// exit 0 on the success (fixture) branch, and map a failure to a non-zero exit.
// Fixtures ride on WEB_TOOL_FIXTURES set on the CHILD `Command` (race-free,
// never the process env) ; the failure branch uses a validate_url-rejected URL
// with NO fixtures (live path rejects before curl -> exit 1, no network).

/// Build the standalone web-tool-handler into `out`. Returns false (test skips)
/// if rustc is unavailable.
fn build_web_tool_handler(root: &PathBuf, out: &std::path::Path) -> bool {
    let src = root.join("adapters/web_tool/web-tool-handler.rs");
    let status = Command::new("rustc")
        .args(["-O"]).arg(&src).arg("-o").arg(out).status();
    matches!(status, Ok(s) if s.success()) && out.exists()
}

/// Run the web-tool-handler : payload JSON on stdin, optional WEB_TOOL_FIXTURES
/// on the child env (never the process).
fn run_web_tool_handler(
    bin: &std::path::Path,
    payload: &str,
    fixtures: Option<&std::path::Path>,
) -> (bool, String) {
    let mut cmd = Command::new(bin);
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    if let Some(f) = fixtures {
        cmd.env("WEB_TOOL_FIXTURES", f);
    }
    let mut child = cmd.spawn().expect("web-tool-handler not spawnable");
    child.stdin.take().unwrap().write_all(payload.as_bytes()).unwrap();
    let out = child.wait_with_output().expect("web-tool-handler did not finish");
    (out.status.success(), String::from_utf8_lossy(&out.stdout).to_string())
}

#[test]
fn web_tool_handler_honors_family_produces_contract_and_maps_exit_branches() {
    let root = repo_root();

    // 1. The family's declared output contract.
    let fam = dump(&root, "adapters/web_tool/web_tool.family");
    let produces: Vec<String> = fam["families"][0]["produces"]
        .as_array().expect("web_tool family has a produces array")
        .iter().map(|v| v.as_str().unwrap().to_string()).collect();
    assert!(
        produces.contains(&"output".to_string()),
        "web_tool family should declare `produces :output` ; got {:?}", produces,
    );

    // 2. The adapter's declared handler binary.
    let adp = dump(&root, "adapters/web_tool/test-web.adapter");
    let handler = adp["adapters"][0]["handler"].as_str().expect("adapter declares a handler");
    assert_eq!(handler, "adapters/web_tool/web-tool-handler", "TestWeb declares the web-tool-handler");

    // Build the handler into a temp path.
    let bin = std::env::temp_dir().join(format!("web_tool_handler_conf_{}", std::process::id()));
    if !build_web_tool_handler(&root, &bin) {
        eprintln!("[skip] rustc unavailable — cannot build web-tool-handler");
        return;
    }

    // A deterministic fixtures file : `<tool>:<url><TAB>output`.
    let fixtures = std::env::temp_dir().join(format!("web_tool_conf_fix_{}.tsv", std::process::id()));
    std::fs::write(&fixtures, "web_fetch:https://example.com\tHELLO_BODY\n").expect("write fixtures");
    let ok_payload = "{\"tool\":\"web_fetch\",\"url\":\"https://example.com\"}";

    // 3. Success branch : exit 0, every `produces` field present as k=v.
    let (ok, stdout) = run_web_tool_handler(&bin, ok_payload, Some(&fixtures));
    assert!(ok, "web-tool-handler should exit 0 on the fixture (success) branch");
    for field in &produces {
        assert!(
            stdout.lines().any(|l| l.starts_with(&format!("{}=", field))),
            "handler must emit `{}=` per produces ; stdout was:\n{}", field, stdout,
        );
    }
    assert!(stdout.contains("output=HELLO_BODY"), "fixture body threaded into output= ; got:\n{}", stdout);

    // 4. IDEMPOTENCY-REPLAY : deterministic — replay is byte-identical.
    let (ok2, stdout2) = run_web_tool_handler(&bin, ok_payload, Some(&fixtures));
    assert!(ok2);
    assert_eq!(stdout, stdout2, "web-tool-handler is deterministic — replay is byte-identical");

    // 5. Failure branch : a validate_url-rejected URL on the LIVE path (no
    //    fixtures) rejects BEFORE any curl -> exit 1 (the failure branch), no
    //    network. Still emits an `output=` line (the contract holds on both
    //    branches) but maps to a non-zero exit.
    let bad_payload = "{\"tool\":\"web_fetch\",\"url\":\"file:///etc/passwd\"}";
    let (ok3, stdout3) = run_web_tool_handler(&bin, bad_payload, None);
    assert!(!ok3, "a validate_url-rejected URL maps to the non-zero (failure) exit branch");
    assert!(
        stdout3.lines().any(|l| l.starts_with("output=")),
        "handler still emits output= on the failure branch ; got:\n{}", stdout3,
    );

    let _ = std::fs::remove_file(&bin);
    let _ = std::fs::remove_file(&fixtures);
}
