//! [antibody-exempt: rust/src/runtime/exec_dispatcher.rs —
//!  kernel-floor handler for the `:exec` hecksagon adapter family
//!  (i629). Runs the adapter's `exec:` program on dispatch, captures
//!  stdout/stderr/exit, caps output. Sibling of claude_tool_dispatcher
//!  / web_tool_dispatcher ; wired via resolve_exec_adapters in
//!  runtime/mod.rs (mirrors the WIRED :claude_tool arm, not the
//!  unwired i557 registry path). This module IS the close of i629 :
//!  Inbox.Check's :exec binding runs the inbox poller so the 900s
//!  loop dispatch is the Gmail fetch, retiring the transitional
//!  inboxpoll Procfile member.]
//!
//! ExecDispatcher — kernel hook for the :exec adapter family.
//!
//! When a command with a bound `:exec` adapter dispatches, the
//! runtime resolves the matching adapter (one whose `command:`
//! option equals the dispatched Aggregate.Command target), reads its
//! `exec:` field, runs it to completion inheriting the runtime
//! process cwd + env (the overmind loop member already runs from
//! hecks_conception, so relative paths resolve identically whether
//! the loop or a manual storehouse__dispatch fired it), captures
//! stdout/stderr/exit, and the resolver cascades the outcome into
//! the adapter's `result_into` target.

use std::process::Command;

/// What an :exec dispatch produced. `output` is stdout ; on non-zero
/// exit the stderr is appended so the failure is legible in the
/// Cascade record. `exit_code` is the process exit ; `ok` iff == 0.
#[derive(Debug, Clone, Default)]
pub struct ExecResult {
    pub ok: bool,
    pub output: String,
    pub exit_code: i32,
    pub error: Option<String>,
}

/// Maximum bytes of captured output — caps downstream state. Same
/// 100 KB cap web_tool_dispatcher uses.
const OUTPUT_LIMIT_BYTES: usize = 102_400;

fn truncate(s: String) -> String {
    if s.len() <= OUTPUT_LIMIT_BYTES {
        s
    } else {
        let mut t = s.into_bytes();
        t.truncate(OUTPUT_LIMIT_BYTES);
        let mut out = String::from_utf8_lossy(&t).into_owned();
        out.push_str("\n\n... [truncated]");
        out
    }
}

/// Run the adapter's `exec` string. Split on whitespace into
/// program + args (same convenience split parse_shell_adapter uses).
/// cwd + env inherited from the runtime process.
pub fn dispatch(exec: &str) -> ExecResult {
    let mut parts = exec.split_whitespace();
    let program = match parts.next() {
        Some(p) => p,
        None => {
            return ExecResult {
                ok: false,
                exit_code: -1,
                error: Some("empty exec string".into()),
                ..Default::default()
            }
        }
    };
    let args: Vec<&str> = parts.collect();
    match Command::new(program).args(&args).output() {
        Ok(out) => {
            let code = out.status.code().unwrap_or(-1);
            let ok = code == 0;
            let mut output = String::from_utf8_lossy(&out.stdout).into_owned();
            if !ok {
                let err = String::from_utf8_lossy(&out.stderr);
                if !err.trim().is_empty() {
                    output.push_str("\n\n[stderr]\n");
                    output.push_str(&err);
                }
            }
            ExecResult {
                ok,
                output: truncate(output),
                exit_code: code,
                error: if ok { None } else { Some(format!("exec exited {}", code)) },
            }
        }
        Err(e) => ExecResult {
            ok: false,
            output: String::new(),
            exit_code: -1,
            error: Some(format!("failed to spawn {}: {}", program, e)),
        },
    }
}
