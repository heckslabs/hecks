//! run_host::exec — spawn one thin adapter handler out-of-process.
//!
//! The handler contract (mirrors examples/adapter_host_demo/stripe-handler) :
//!   - the event PAYLOAD arrives on stdin (the OutboundEvent.payload JSON),
//!   - per-adapter config arrives in the ENV,
//!   - the handler writes verdict `k=v` lines to stdout (threaded into the
//!     verdict command), logs to stderr,
//!   - EXIT CODE picks the branch : 0 = success, non-zero = failure.
//!
//! v1 : serial + blocking wait. A hung handler wedges the tick — acceptable
//! for v1, NOT parallelism (see run_host/mod.rs).

use std::io::Write;
use std::process::{Command, Stdio};

/// The handler's outcome : the exit branch + the parsed stdout verdict pairs.
pub struct HandlerOutcome {
    /// True iff the handler exited 0.
    pub success: bool,
    /// The `k=v` lines the handler wrote to stdout, parsed in order.
    pub verdict_pairs: Vec<(String, String)>,
}

/// Exec the handler at `path`, payload on stdin, `config` folded into the env.
/// Returns Err(message) on a spawn / I/O failure (the host treats that as a
/// retryable transport error) ; Ok on a clean exit (success flag = exit==0).
///
/// CONFIG→ENV LIMITATION (v1) : the `.world` key/value pairs are folded into
/// the child env VERBATIM (key uppercased is NOT done — the value is set under
/// the literal `.world` key). The family's FamilyField `source` semantics
/// (direct vs env vs secret) and the mapping from a `.world` key (`endpoint`)
/// to the handler's expected env-var NAME (`PIZZAS_PAYMENT_ENDPOINT`) are NOT
/// yet wired. Today the demo has no `.world`, so `config` is empty and the
/// handler takes its built-in demo-authorize path. Wiring the field-source +
/// env-name mapping is the remaining plumbing (the 3rd "discovery" port).
pub fn run_handler(
    path: &str,
    payload: &str,
    config: &[(String, String)],
) -> Result<HandlerOutcome, String> {
    let mut cmd = Command::new(path);
    for (k, v) in config {
        // Strip surrounding quotes the .world parser keeps on string literals.
        let val = v.trim_matches('"');
        cmd.env(k, val);
    }
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|e| format!("spawn {} failed: {}", path, e))?;

    if let Some(mut sin) = child.stdin.take() {
        sin.write_all(payload.as_bytes())
            .map_err(|e| format!("write stdin failed: {}", e))?;
    }

    let out = child
        .wait_with_output()
        .map_err(|e| format!("wait {} failed: {}", path, e))?;

    let stdout = String::from_utf8_lossy(&out.stdout);
    let verdict_pairs = parse_pairs(&stdout);
    Ok(HandlerOutcome {
        success: out.status.success(),
        verdict_pairs,
    })
}

/// Parse `k=v` lines from handler stdout. Blank lines and lines without `=`
/// are skipped. Only the first `=` splits (values may contain `=`).
fn parse_pairs(stdout: &str) -> Vec<(String, String)> {
    stdout
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() {
                return None;
            }
            line.split_once('=')
                .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        })
        .collect()
}
