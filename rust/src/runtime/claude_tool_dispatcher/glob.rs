//! [antibody-exempt: rust/src/runtime/claude_tool_dispatcher/glob.rs —
//!  kernel-substrate helper for `Tools.Glob` dispatch ; concern-
//!  extracted from claude_tool_dispatcher/mod.rs to keep the parent
//!  file under the 200-LOC limit. Inherits the dispatcher family's
//!  i551/i556 antibody-exempt status — same kernel-floor scope.]
//!
//! glob — pattern translation + `find` shell-out for `Tools.Glob`.
//!
//! `find -path` matches against the path AS find prints it (rooted at
//! the search root, with a leading `./`), so a caller-supplied bare
//! pattern like `dir/*.rs` never matches `./dir/foo.rs`. We instead
//! split the pattern into a search root + a basename `-name` pattern,
//! and pass `-maxdepth 1` when the pattern was not recursive.

use std::collections::HashMap;
use std::process::Command;
use super::{ClaudeToolResult, attr, err, truncate};

pub(super) fn run_glob(attrs: &HashMap<String, String>) -> ClaudeToolResult {
    let pattern = match attr(attrs, "glob_pattern") {
        Some(p) => p.to_string(),
        None => return err("glob", "missing required attr: glob_pattern"),
    };
    let explicit_root = attr(attrs, "search_path").map(|s| s.to_string());
    let (root, name_pat, recursive) = split_glob(&pattern, explicit_root.as_deref());

    let mut args: Vec<String> = vec![root];
    if !recursive { args.push("-maxdepth".into()); args.push("1".into()); }
    args.push("-name".into());
    args.push(name_pat);

    match Command::new("find").args(&args).output() {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
            let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
            let exit_code = out.status.code().unwrap_or(-1);
            // No-match : find exits 0 with empty stdout — that's success.
            // Real failure : non-zero exit ; surface stderr in error.
            if !out.status.success() {
                let detail = if stderr.is_empty() { "(no stderr)".to_string() } else { stderr.trim().to_string() };
                return ClaudeToolResult {
                    tool: "glob".into(), ok: false,
                    output: truncate(stdout), exit_code,
                    error: Some(format!("find failed (exit {}): {}", exit_code, detail)),
                };
            }
            ClaudeToolResult {
                tool: "glob".into(), ok: true,
                output: truncate(stdout), exit_code, error: None,
            }
        }
        Err(e) => err("glob", &format!("spawn find: {}", e)),
    }
}

/// Split a glob into (search_root, name_pattern, recursive?). Rules :
/// `*.rs`→(".",pat,false) ; `dir/*.rs`→(dir,pat,false) ;
/// `dir/**/*.rs`→(dir,pat,true) ; `**/*.rs`→(".",pat,true).
/// `explicit_root` overrides any dir implied by the pattern.
pub(super) fn split_glob(
    pattern: &str,
    explicit_root: Option<&str>,
) -> (String, String, bool) {
    let basename = |p: &str| p.rsplit('/').next().unwrap_or(p).to_string();
    if let Some((before, after)) = pattern.split_once("/**/") {
        let root = explicit_root.map(|r| r.to_string())
            .unwrap_or_else(|| if before.is_empty() { ".".into() } else { before.into() });
        return (root, basename(after), true);
    }
    if let Some(rest) = pattern.strip_prefix("**/") {
        return (explicit_root.unwrap_or(".").to_string(), basename(rest), true);
    }
    if let Some(idx) = pattern.rfind('/') {
        let (dir, file) = pattern.split_at(idx);
        let root = explicit_root.map(|r| r.to_string())
            .unwrap_or_else(|| if dir.is_empty() { ".".into() } else { dir.into() });
        return (root, file.trim_start_matches('/').to_string(), false);
    }
    (explicit_root.unwrap_or(".").to_string(), pattern.to_string(), false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn translates_directory_patterns() {
        let (r, n, rec) = split_glob("*.rs", None);
        assert_eq!((r.as_str(), n.as_str(), rec), (".", "*.rs", false));

        let (r, n, rec) = split_glob("rust/src/runtime/*.rs", None);
        assert_eq!((r.as_str(), n.as_str(), rec), ("rust/src/runtime", "*.rs", false));

        let (r, n, rec) = split_glob("rust/src/**/*.rs", None);
        assert_eq!((r.as_str(), n.as_str(), rec), ("rust/src", "*.rs", true));

        let (r, n, rec) = split_glob("**/*.rs", None);
        assert_eq!((r.as_str(), n.as_str(), rec), (".", "*.rs", true));

        // explicit search_path overrides
        let (r, n, rec) = split_glob("*.rs", Some("/tmp"));
        assert_eq!((r.as_str(), n.as_str(), rec), ("/tmp", "*.rs", false));
    }
}
