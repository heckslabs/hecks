//! [antibody-exempt: rust/src/runtime/exec_dispatcher.rs —
//!  the kernel-floor spawn leaf (i629). Runs a literal program string,
//!  captures stdout/stderr/exit, caps output. The spawn syscall is
//!  irreducibly imperative ; the surrounding PROTOCOL (fire → run →
//!  cascade) is now ordinary bluebook policy/cascade. The bespoke
//!  `resolve_exec_adapters` arm that used to drive this leaf is
//!  RETIRED — it is now reached ONLY through `resolve_primitive_spawn`
//!  (the generic `Primitive::Process.Spawn` hook).]
//!
//! ExecDispatcher — the kernel-floor process-spawn leaf.
//!
//! Reached via `resolve_primitive_spawn` when a `Primitive::Process.Spawn`
//! command dispatches (whether top-level or from a policy/PM cascade).
//! Reads the literal program string off the dispatch's `cmd` attr, runs
//! it to completion inheriting the runtime process cwd + env (the
//! overmind loop member already runs from hecks_conception, so relative
//! paths resolve identically whether the loop or a manual
//! storehouse__dispatch fired it), captures stdout/stderr/exit, and the
//! primitive cascades the outcome into the dispatch's `result_into`
//! target. Every former `:exec` binding is now a bluebook policy
//! firing this primitive — see resolve_primitive_spawn's doc comment.
//!
//! Bin-wrapper convention (sq/policy-cmd-bin-wrappers):
//!   * `AGG_ID`     — the triggering event's aggregate_id (the join key
//!                    a `Record*` cascade lands back on).
//!   * `AGG_TYPE`   — the triggering event's aggregate_type.
//!   * `EVENT_NAME` — the triggering event's name.
//!   * stdin        — the full event payload JSON (same shape
//!                    `STOREHOUSE_TRIGGER_EVENT` carries, for scripts
//!                    that want to read it without parsing env).
//! Scripts are declarative bluebook policies' tooling arm : they live
//! in bin/, read AGG_ID + optional stdin JSON, print one JSON line,
//! exit 0 on ok / non-zero on not-ok.

use std::io::Write;
use std::process::{Command, Stdio};

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
/// cwd + env inherited from the runtime process. Any entries in
/// `extra_env` are added to the child's environment (useful for
/// passing event payload to the spawned process). `stdin_payload`,
/// when non-empty, is piped to the child's stdin and stdin is then
/// closed so the script can drain to EOF.
pub fn dispatch(
    exec: &str,
    extra_env: &[(String, String)],
    stdin_payload: Option<&str>,
) -> ExecResult {
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
    let mut cmd = Command::new(program);
    cmd.args(&args);
    for (k, v) in extra_env {
        cmd.env(k, v);
    }
    // Always pipe stdout/stderr ; pipe stdin only when we have a
    // payload (an explicit None lets the child inherit, matching the
    // pre-stdin behaviour for callers that don't need it).
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    if stdin_payload.is_some() {
        cmd.stdin(Stdio::piped());
    }

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            return ExecResult {
                ok: false,
                output: String::new(),
                exit_code: -1,
                error: Some(format!("failed to spawn {}: {}", program, e)),
            }
        }
    };

    if let Some(payload) = stdin_payload {
        if let Some(mut sin) = child.stdin.take() {
            // Best-effort write ; if the child closed stdin early, we
            // still want to collect its exit + stdout, not panic. The
            // write error rides on the ExecResult only if the wait
            // also fails downstream.
            let _ = sin.write_all(payload.as_bytes());
            // dropping `sin` closes stdin so the child sees EOF.
        }
    }

    match child.wait_with_output() {
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
            error: Some(format!("failed to wait on {}: {}", program, e)),
        },
    }
}
