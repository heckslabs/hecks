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
