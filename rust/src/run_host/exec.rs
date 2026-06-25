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

/// Exec the handler at `path`, payload on stdin, `env` folded into the child
/// environment. Returns Err(message) on a spawn / I/O failure (the host treats
/// that as a retryable transport error) ; Ok on a clean exit (success flag =
/// exit==0).
///
/// `env` arrives as proper (env_name, value) pairs — `run_host::config::map_config`
/// has already applied the family field-source convention (canonical
/// `<FAMILY>_<FIELD>` names ; env/secret fields inherited, not passed). env /
/// secret fields the handler reads come in via the inherited parent env
/// (`Command` inherits it by default). The defensive quote-strip below is a
/// belt-and-suspenders backstop ; map_config already strips direct values.
pub fn run_handler(
    path: &str,
    payload: &str,
    env: &[(String, String)],
) -> Result<HandlerOutcome, String> {
    let mut cmd = Command::new(path);
    for (k, v) in env {
        // Defensive : strip any surrounding quotes still on a value.
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
