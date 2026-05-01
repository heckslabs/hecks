//! ShellDispatcher — Rust mirror of lib/hecks/runtime/shell_dispatcher.rb
//!
//! Takes a ShellAdapter from the parsed hecksagon and attrs from the
//! caller, substitutes `{{placeholder}}` tokens into the arg vector,
//! then executes via std::process::Command (no shell).
//!
//! Security (parity with Ruby):
//!   * command is a fixed binary (parser validates no `{{` in it)
//!   * args are per-element — placeholder substitution happens per arg,
//!     no shell-string form, no word splitting
//!   * env starts empty — only entries declared on the adapter pass
//!     through (env_clear equivalent of Ruby's `unsetenv_others: true`)
//!   * stdin is empty
//!   * timeout uses thread-based polling with SIGKILL on expiry
//!     (mirrors Ruby's Process.kill("-KILL", pid))
//!
//! Output formats (parity):
//!   :text       → raw stdout String
//!   :lines      → Vec<String>, chomped, empty lines dropped
//!   :json       → serde_json::Value parsed from full stdout
//!   :json_lines → Vec<Value> one per non-empty line
//!   :exit_code  → i32 (stdout discarded)

use crate::hecksagon_ir::ShellAdapter;
use crate::runtime::adapter_io::substitute;
use std::collections::HashMap;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Return shape for a successful dispatch (parity with Ruby's Result
/// struct in shell_dispatcher.rb).
#[derive(Debug, Clone)]
pub struct Result {
    pub output: Output,
    pub raw_stdout: String,
    pub stderr: String,
    pub exit_status: i32,
}

#[derive(Debug, Clone)]
pub enum Output {
    Text(String),
    Lines(Vec<String>),
    Json(serde_json::Value),
    JsonLines(Vec<serde_json::Value>),
    ExitCode(i32),
}

#[derive(Debug)]
pub enum DispatchError {
    /// Non-zero exit when output_format != :exit_code.
    NonZeroExit { adapter: String, exit_status: i32, stderr: String },
    /// Process still alive after `adapter.timeout` seconds; sent SIGKILL.
    Timeout { adapter: String, seconds: u64 },
    /// Spawn failed (binary not found, permission, etc).
    SpawnFailed { adapter: String, source: String },
    /// output_format parser could not read the bytes.
    ParseFailed { adapter: String, format: String, message: String },
}

impl std::fmt::Display for DispatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DispatchError::NonZeroExit { adapter, exit_status, stderr } =>
                write!(f, "shell adapter :{} exited {}: {}", adapter, exit_status, stderr.trim()),
            DispatchError::Timeout { adapter, seconds } =>
                write!(f, "shell adapter :{} exceeded {}s timeout", adapter, seconds),
            DispatchError::SpawnFailed { adapter, source } =>
                write!(f, "shell adapter :{} spawn failed: {}", adapter, source),
            DispatchError::ParseFailed { adapter, format, message } =>
                write!(f, "shell adapter :{} output_format={} parse failed: {}", adapter, format, message),
        }
    }
}

/// Dispatch a shell adapter with the given attribute bindings.
pub fn call(adapter: &ShellAdapter, attrs: &HashMap<String, String>) -> std::result::Result<Result, DispatchError> {
    let substituted: Vec<String> = adapter.args.iter().map(|a| substitute(a, attrs)).collect();
    run(adapter, &substituted)
}

fn run(adapter: &ShellAdapter, args: &[String]) -> std::result::Result<Result, DispatchError> {
    let working_dir = adapter.working_dir.clone()
        .unwrap_or_else(|| std::env::current_dir().map(|p| p.to_string_lossy().into()).unwrap_or_else(|_| ".".into()));
    let mut cmd = Command::new(&adapter.command);
    cmd.args(args)
       .current_dir(&working_dir)
       .env_clear()
       .stdin(Stdio::null())
       .stdout(Stdio::piped())
       .stderr(Stdio::piped());
    for (k, v) in &adapter.env {
        cmd.env(k, v);
    }
    let (stdout_bytes, stderr_bytes, exit_status) = match adapter.timeout {
        None => spawn_and_wait(adapter, cmd)?,
        Some(secs) => spawn_with_timeout(adapter, cmd, Duration::from_secs(secs))?,
    };
    let stdout = String::from_utf8_lossy(&stdout_bytes).into_owned();
    let stderr = String::from_utf8_lossy(&stderr_bytes).into_owned();

    if exit_status != 0 && adapter.output_format != "exit_code" {
        return Err(DispatchError::NonZeroExit {
            adapter: adapter.name.clone(),
            exit_status,
            stderr,
        });
    }
    let output = parse_output(&adapter.output_format, &stdout, exit_status)
        .map_err(|e| DispatchError::ParseFailed {
            adapter: adapter.name.clone(),
            format: adapter.output_format.clone(),
            message: e,
        })?;
    Ok(Result { output, raw_stdout: stdout, stderr, exit_status })
}

fn spawn_and_wait(adapter: &ShellAdapter, mut cmd: Command)
    -> std::result::Result<(Vec<u8>, Vec<u8>, i32), DispatchError>
{
    let out = cmd.output().map_err(|e| DispatchError::SpawnFailed {
        adapter: adapter.name.clone(),
        source: e.to_string(),
    })?;
    Ok((out.stdout, out.stderr, out.status.code().unwrap_or(-1)))
}

/// Timeout path — poll the child; SIGKILL on expiry. Matches the Ruby
/// `capture_with_timeout` loop that actively kills pgroup on deadline.
fn spawn_with_timeout(adapter: &ShellAdapter, mut cmd: Command, timeout: Duration)
    -> std::result::Result<(Vec<u8>, Vec<u8>, i32), DispatchError>
{
    use std::io::Read;
    let mut child = cmd.spawn().map_err(|e| DispatchError::SpawnFailed {
        adapter: adapter.name.clone(),
        source: e.to_string(),
    })?;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let mut stderr = child.stderr.take().expect("piped stderr");
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let mut out = Vec::new(); let mut err = Vec::new();
                let _ = stdout.read_to_end(&mut out);
                let _ = stderr.read_to_end(&mut err);
                return Ok((out, err, status.code().unwrap_or(-1)));
            }
            Ok(None) => {
                if Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(DispatchError::Timeout {
                        adapter: adapter.name.clone(),
                        seconds: timeout.as_secs(),
                    });
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(e) => return Err(DispatchError::SpawnFailed {
                adapter: adapter.name.clone(),
                source: e.to_string(),
            }),
        }
    }
}

fn parse_output(format: &str, stdout: &str, exit_status: i32)
    -> std::result::Result<Output, String>
{
    match format {
        "text" => Ok(Output::Text(stdout.to_string())),
        "lines" => Ok(Output::Lines(
            stdout.lines().filter(|l| !l.is_empty()).map(|l| l.to_string()).collect()
        )),
        "json" => serde_json::from_str(stdout)
            .map(Output::Json)
            .map_err(|e| e.to_string()),
        "json_lines" => {
            let mut out = Vec::new();
            for line in stdout.lines().filter(|l| !l.trim().is_empty()) {
                let v: serde_json::Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
                out.push(v);
            }
            Ok(Output::JsonLines(out))
        }
        "exit_code" => Ok(Output::ExitCode(exit_status)),
        other => Err(format!("unknown output_format: {}", other)),
    }
}
