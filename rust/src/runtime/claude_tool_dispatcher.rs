//! [antibody-exempt: rust/src/runtime/claude_tool_dispatcher.rs —
//!  kernel-floor handler for the `:claude_tool` hecksagon adapter
//!  family (i551 / i556). Implements the `invoke_claude_tool`
//!  behavior_kind declared in
//!  framework/behavior_kinds/invoke_claude_tool.hecksagon : six
//!  native primitives (shell exec, file edit, file read, file
//!  write, grep, glob) that execute when a Tools.X dispatch fires.
//!  Sibling kernel-floor port to llm_dispatcher.rs ; both retire
//!  when the framework-wide kernel-hook registry replaces hard-
//!  coded handler tables.]
//!
//! ClaudeToolDispatcher — kernel hook for the :claude_tool adapter family
//!
//! When a Tools.X command dispatches (e.g. `Tools.Bash` with
//! `shell_command: "ls -la"`), the runtime locates the matching
//! `:claude_tool` adapter declared in a loaded hecksagon (the
//! `framework/tools/tools.hecksagon` bindings), reads its `tool`
//! field, and calls one of the six native primitives below.
//!
//! Pattern mirrors llm_dispatcher : take the adapter's declared
//! fields + the dispatched command's attrs, execute, return a
//! structured result the Runtime can chain back via the adapter's
//! `result_into` target.
//!
//! ── Scope ──
//!
//! The primitives are *Claude-tool-shaped* — they implement what
//! the corresponding Claude tool does, but native rather than
//! through the Claude harness. That's the right shape for now :
//! the runtime isn't yet sophisticated enough to call Claude tools
//! for real (per Chris's 2026-05-12 framing). When it is, the
//! adapter contract stays unchanged and the kernel just changes
//! its execution backend.

use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

/// What a :claude_tool dispatch produced. Fields are populated per
/// the tool kind that ran — :bash sets `output` + `exit_code`,
/// :read sets `contents`, :grep sets `matches`, etc.
#[derive(Debug, Clone, Default)]
pub struct ClaudeToolResult {
    /// The tool that ran ("bash", "edit", "read", "write", "grep", "glob").
    pub tool: String,
    /// True if the tool succeeded — exit 0 for shell, no error for I/O.
    pub ok: bool,
    /// stdout / file contents / match list / file list — kind-specific.
    pub output: String,
    /// Shell exit code when applicable ; 0 otherwise.
    pub exit_code: i32,
    /// Human-readable error message when `ok == false`.
    pub error: Option<String>,
}

/// Dispatch a :claude_tool adapter call. `tool` is the adapter's
/// declared `tool:` field (`"bash"` / `"edit"` / `"read"` / `"write"`
/// / `"grep"` / `"glob"`). `attrs` carries the dispatched command's
/// attributes.
///
/// Output truncation : large reads / greps / globs are capped to
/// ~10 KB so a single dispatch doesn't blow up downstream state.
pub fn dispatch(tool: &str, attrs: &HashMap<String, String>) -> ClaudeToolResult {
    match tool {
        "bash"  => run_bash(attrs),
        "edit"  => run_edit(attrs),
        "read"  => run_read(attrs),
        "write" => run_write(attrs),
        "grep"  => run_grep(attrs),
        "glob"  => run_glob(attrs),
        other   => ClaudeToolResult {
            tool: other.to_string(),
            ok: false,
            error: Some(format!("unknown tool kind: {}", other)),
            ..Default::default()
        },
    }
}

/// Maximum bytes of captured output any tool returns — protects
/// downstream state from huge file reads / wide grep matches.
const OUTPUT_LIMIT_BYTES: usize = 10_240;

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

// ── :bash — spawn /bin/sh -c <shell_command>, capture stdout + exit ──

fn run_bash(attrs: &HashMap<String, String>) -> ClaudeToolResult {
    let cmd = match attrs.get("shell_command") {
        Some(c) => c.clone(),
        None => return err("bash", "missing required attr: shell_command"),
    };
    match Command::new("sh").arg("-c").arg(&cmd).output() {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
            let combined = if stderr.is_empty() { stdout } else { format!("{}{}", stdout, stderr) };
            ClaudeToolResult {
                tool: "bash".into(),
                ok: out.status.success(),
                output: truncate(combined),
                exit_code: out.status.code().unwrap_or(-1),
                error: None,
            }
        }
        Err(e) => err("bash", &format!("spawn failed: {}", e)),
    }
}

// ── :edit — open file_path, replace old_string → new_string, write ──

fn run_edit(attrs: &HashMap<String, String>) -> ClaudeToolResult {
    let path = match attrs.get("file_path") {
        Some(p) => p.clone(),
        None => return err("edit", "missing required attr: file_path"),
    };
    let old = match attrs.get("old_string") {
        Some(s) => s.clone(),
        None => return err("edit", "missing required attr: old_string"),
    };
    let new = attrs.get("new_string").cloned().unwrap_or_default();
    let replace_all = attrs.get("replace_all").map(|s| s == "true").unwrap_or(false);

    let contents = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(e) => return err("edit", &format!("read {}: {}", path, e)),
    };

    // Enforce uniqueness unless replace_all=true.
    if !replace_all {
        let count = contents.matches(&old).count();
        if count == 0 {
            return err("edit", &format!("old_string not found in {}", path));
        }
        if count > 1 {
            return err("edit", &format!(
                "old_string appears {} times in {} — pass replace_all=true or extend the match",
                count, path));
        }
    }
    let new_contents = if replace_all {
        contents.replace(&old, &new)
    } else {
        contents.replacen(&old, &new, 1)
    };

    match std::fs::write(&path, &new_contents) {
        Ok(_) => ClaudeToolResult {
            tool: "edit".into(),
            ok: true,
            output: format!("edited {}", path),
            exit_code: 0,
            error: None,
        },
        Err(e) => err("edit", &format!("write {}: {}", path, e)),
    }
}

// ── :read — read file_path, return contents (truncated) ──

fn run_read(attrs: &HashMap<String, String>) -> ClaudeToolResult {
    let path = match attrs.get("file_path") {
        Some(p) => p.clone(),
        None => return err("read", "missing required attr: file_path"),
    };
    match std::fs::read_to_string(&path) {
        Ok(c) => ClaudeToolResult {
            tool: "read".into(),
            ok: true,
            output: truncate(c),
            exit_code: 0,
            error: None,
        },
        Err(e) => err("read", &format!("read {}: {}", path, e)),
    }
}

// ── :write — write content to file_path, creating dirs as needed ──

fn run_write(attrs: &HashMap<String, String>) -> ClaudeToolResult {
    let path = match attrs.get("file_path") {
        Some(p) => p.clone(),
        None => return err("write", "missing required attr: file_path"),
    };
    let content = attrs.get("content").cloned().unwrap_or_default();
    if let Some(parent) = Path::new(&path).parent() {
        if !parent.as_os_str().is_empty() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                return err("write", &format!("mkdir {}: {}", parent.display(), e));
            }
        }
    }
    match std::fs::write(&path, &content) {
        Ok(_) => ClaudeToolResult {
            tool: "write".into(),
            ok: true,
            output: format!("wrote {} bytes to {}", content.len(), path),
            exit_code: 0,
            error: None,
        },
        Err(e) => err("write", &format!("write {}: {}", path, e)),
    }
}

// ── :grep — search files for pattern, return matches (uses ripgrep / grep) ──

fn run_grep(attrs: &HashMap<String, String>) -> ClaudeToolResult {
    let pattern = match attrs.get("pattern") {
        Some(p) => p.clone(),
        None => return err("grep", "missing required attr: pattern"),
    };
    let search_path = attrs.get("search_path").cloned().unwrap_or_else(|| ".".into());

    // Prefer ripgrep if available ; fall back to grep -r.
    let rg_exists = Command::new("rg").arg("--version").output().is_ok();
    let (prog, args): (&str, Vec<String>) = if rg_exists {
        ("rg", vec!["-n".into(), "--no-heading".into(), pattern.clone(), search_path.clone()])
    } else {
        ("grep", vec!["-rn".into(), pattern.clone(), search_path.clone()])
    };

    match Command::new(prog).args(&args).output() {
        Ok(out) => {
            // rg/grep exits 1 when no matches — that's "ok no matches", not a failure.
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            ClaudeToolResult {
                tool: "grep".into(),
                ok: true,
                output: truncate(stdout),
                exit_code: out.status.code().unwrap_or(-1),
                error: None,
            }
        }
        Err(e) => err("grep", &format!("spawn {}: {}", prog, e)),
    }
}

// ── :glob — walk filesystem with glob_pattern, return matching paths ──
//
// Uses `find` for portability — globs in shell would need bash for **
// double-star expansion ; find -path handles the same shape natively.

fn run_glob(attrs: &HashMap<String, String>) -> ClaudeToolResult {
    let pattern = match attrs.get("glob_pattern") {
        Some(p) => p.clone(),
        None => return err("glob", "missing required attr: glob_pattern"),
    };
    let search_path = attrs.get("search_path").cloned().unwrap_or_else(|| ".".into());

    // Translate glob → find -path :  "**/*.rs" → -path "*/*.rs" (find handles ** as glob expansion)
    // For straight patterns like "*.rs" use -name. Heuristic : if pattern
    // contains '/', use -path ; otherwise -name.
    let (flag, val) = if pattern.contains('/') {
        ("-path", pattern.clone())
    } else {
        ("-name", pattern.clone())
    };

    match Command::new("find").args(&[&search_path, flag, &val]).output() {
        Ok(out) => ClaudeToolResult {
            tool: "glob".into(),
            ok: out.status.success(),
            output: truncate(String::from_utf8_lossy(&out.stdout).into_owned()),
            exit_code: out.status.code().unwrap_or(-1),
            error: None,
        },
        Err(e) => err("glob", &format!("spawn find: {}", e)),
    }
}

// ── helpers ──

fn err(tool: &str, msg: &str) -> ClaudeToolResult {
    ClaudeToolResult {
        tool: tool.to_string(),
        ok: false,
        error: Some(msg.to_string()),
        exit_code: 1,
        ..Default::default()
    }
}

// ── FrameworkRegistry-compatible wrapper (i557 part 1) ──
//
// `dispatch` takes a positional `tool` arg and returns a
// `ClaudeToolResult`. The Phase-2 framework registry calls every
// kernel hook through one uniform signature :
//   fn(&HashMap<String,String>, &HashMap<String,String>) -> KernelResult
// so families compose interchangeably.
//
// This wrapper adapts : it reads the adapter's `tool` field from the
// first map (the adapter's declared fields), forwards the second map
// (the dispatched command's attrs) to the underlying dispatch, and
// folds the ClaudeToolResult into a KernelResult. Lives here next to
// the dispatcher so the two stay in sync — registry doesn't reach
// across crates to translate.

/// Adapt `dispatch(tool, attrs)` to the `KernelHook` signature the
/// framework registry expects. `adapter_fields` carries the adapter's
/// declared fields (`tool`, `command`, `result_into`, ...) ;
/// `command_attrs` carries the dispatched command's attributes
/// (`shell_command`, `file_path`, ...). Reads `tool` from
/// `adapter_fields` and dispatches with `command_attrs`.
pub fn dispatch_via_registry(
    adapter_fields: &HashMap<String, String>,
    command_attrs: &HashMap<String, String>,
) -> super::framework_registry::KernelResult {
    let tool = adapter_fields
        .get("tool")
        .cloned()
        .unwrap_or_default();
    let r = dispatch(&tool, command_attrs);
    super::framework_registry::KernelResult {
        kind: r.tool,
        ok: r.ok,
        output: r.output,
        exit_code: r.exit_code,
        error: r.error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attrs(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn bash_echo_runs_and_captures_output() {
        let r = dispatch("bash", &attrs(&[("shell_command", "echo hello")]));
        assert!(r.ok, "{:?}", r);
        assert!(r.output.contains("hello"));
        assert_eq!(r.exit_code, 0);
    }

    #[test]
    fn bash_nonzero_exit_marks_not_ok() {
        let r = dispatch("bash", &attrs(&[("shell_command", "false")]));
        assert!(!r.ok);
        assert_ne!(r.exit_code, 0);
    }

    #[test]
    fn read_write_round_trip() {
        let tmp = format!("/tmp/claude_tool_test_{}.txt", std::process::id());
        let w = dispatch("write", &attrs(&[("file_path", &tmp), ("content", "hi there")]));
        assert!(w.ok, "{:?}", w);
        let r = dispatch("read", &attrs(&[("file_path", &tmp)]));
        assert!(r.ok && r.output == "hi there", "{:?}", r);
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn edit_replaces_unique_substring() {
        let tmp = format!("/tmp/claude_tool_edit_{}.txt", std::process::id());
        std::fs::write(&tmp, "alpha beta gamma").unwrap();
        let e = dispatch("edit", &attrs(&[
            ("file_path", &tmp),
            ("old_string", "beta"),
            ("new_string", "BETA"),
        ]));
        assert!(e.ok, "{:?}", e);
        assert_eq!(std::fs::read_to_string(&tmp).unwrap(), "alpha BETA gamma");
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn unknown_tool_returns_error() {
        let r = dispatch("nonsense", &attrs(&[]));
        assert!(!r.ok);
        assert!(r.error.unwrap().contains("unknown tool kind"));
    }
}
