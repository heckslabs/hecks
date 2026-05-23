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
/// cwd + env inherited from the runtime process. Any entries in
/// `extra_env` are added to the child's environment (useful for
/// passing event payload to the spawned process).
pub fn dispatch(exec: &str, extra_env: &[(String, String)]) -> ExecResult {
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
    match cmd.output() {
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
