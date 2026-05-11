/// Match a path against the specializer registry. Either the
/// emitted target file (`rust/src/<name>.rs`) or the
/// specializer module that emits it
/// (`rust/src/specializer/<name>.rs`).
pub fn is_specializer_target(file_path: &str) -> Option<DispatchInfo> {
    let normalized = file_path.replace('\\', "/");

    for target in SPECIALIZER_TARGETS {
        let target_file = format!("rust/src/{}.rs", target);
        let specializer_file = format!("rust/src/specializer/{}.rs", target);
        if normalized.ends_with(&target_file) || normalized.ends_with(&specializer_file) {
            return Some(DispatchInfo {
                source: "rust/src/specializer/mod.rs".into(),
                kind: "specializer target".into(),
                identifier: (*target).to_string(),
            });
        }
    }

    for helper in SPECIALIZER_HELPER_MODULES {
        let path = format!("rust/src/specializer/{}.rs", helper);
        if normalized.ends_with(&path) {
            return Some(DispatchInfo {
                source: "rust/src/specializer/mod.rs".into(),
                kind: "specializer helper module".into(),
                identifier: (*helper).to_string(),
            });
        }
    }

    None
}

// ────────────────────────────────────────────────────────────────
// 2. Hecksagon ShellAdapter scan
// ────────────────────────────────────────────────────────────────

/// Walk every `*.hecksagon` under `corpus_root` and return the first
/// adapter (shell *or* dispatch-bearing IO, e.g. `:daemon`) whose
/// `command` / `args` references the file's basename. Order is
/// determined by filesystem `read_dir` — the query is "is anything
/// claiming this?", not "which thing claims this first?", so order
/// doesn't change the answer.
///
/// Two adapter shapes carry script references in the corpus today :
///
///   - `adapter :shell, name:, command:, args:` → `ShellAdapter` IR.
///     Used for one-shot subprocess calls (`git rev-parse …`).
///   - `adapter :daemon, name:, command:, …` → `IoAdapter` IR with
///     a `command` option. Used for long-running processes
///     (mindstream.sh, heart loop, etc.). boot.hecksagon is the
///     canonical example — it uses `:daemon` for every body shell
///     it spawns.
pub fn is_hecksagon_dispatched(file_path: &str, corpus_root: &Path) -> Option<DispatchInfo> {
    let basename = Path::new(file_path).file_name()?.to_str()?;
    let normalized = file_path.replace('\\', "/");
    // For :web serializer matching the file must live at
    // `rust/src/server/<name>.rs` ; pre-compute the stem if so.
    let server_stem: Option<String> = Path::new(&normalized)
        .file_stem()
        .and_then(|s| s.to_str())
        .filter(|_| normalized.contains("rust/src/server/"))
        .map(|s| s.to_string());
    let mut found: Option<DispatchInfo> = None;
    walk_hecksagons_with_siblings(corpus_root, &mut |path: &Path| {
        if found.is_some() {
            return;
        }
        let Ok(source) = fs::read_to_string(path) else { return };
        let hex = hecksagon_parser::parse(&source);

        // ShellAdapter bucket (`adapter :shell, …`).
        for sh in &hex.shell_adapters {
            if shell_adapter_references(sh, basename) {
                found = Some(DispatchInfo {
                    source: path.to_string_lossy().into_owned(),
                    kind: format!("ShellAdapter :{}", sh.name),
                    identifier: hex.name.clone(),
                });
                return;
            }
        }

        // Dispatch-bearing IoAdapter bucket (`adapter :daemon, …`
        // and similar). The parser routes :daemon to io_adapters
        // because the kind is unknown to the ShellAdapter family ;
        // the `command:` option still names the runnable file.
        for io in &hex.io_adapters {
            if DISPATCH_BEARING_IO_KINDS.contains(&io.kind.as_str())
                && io_adapter_references(io, basename)
            {
                let adapter_name = io_adapter_name(io).unwrap_or_else(|| io.kind.clone());
                found = Some(DispatchInfo {
                    source: path.to_string_lossy().into_owned(),
                    kind: format!("IoAdapter :{} :{}", io.kind, adapter_name),
                    identifier: hex.name.clone(),
                });
                return;
            }

            // :web adapter serializer-implementation bucket. A
            // hecksagon `adapter :web, serializer: :user_flows,
            // …` declares that some rust function in the
            // server/ module implements that serializer. The
            // convention is `rust/src/server/<name>.rs` (one
            // file per serializer family). The declaration IS
            // the structural claim — the hecksagon names the
            // serializer, the file IS that serializer.
            if io.kind == "web" {
                if let Some(stem) = &server_stem {
                    if web_adapter_serializer_matches(io, stem) {
                        found = Some(DispatchInfo {
                            source: path.to_string_lossy().into_owned(),
                            kind: format!(":web serializer :{}", stem),
                            identifier: hex.name.clone(),
                        });
                        return;
                    }
                }
            }
        }
    });
    found
}

/// Does this `:web` adapter declare a `serializer:` whose value
/// (with optional leading `:` or surrounding quotes stripped)
/// matches `stem`? `stem` is the file's basename without the .rs
/// extension — e.g. "user_flows" for rust/src/server/user_flows.rs.
fn web_adapter_serializer_matches(io: &IoAdapter, stem: &str) -> bool {
    for (key, val) in &io.options {
        if key == "serializer" {
            let trimmed = val.trim_start_matches(':').trim_matches('"');
            if trimmed == stem {
                return true;
            }
        }
    }
    false
}

fn shell_adapter_references(sh: &ShellAdapter, basename: &str) -> bool {
    if sh.command.contains(basename) {
        return true;
    }
    sh.args.iter().any(|a| a.contains(basename))
}

/// Inspect an `IoAdapter`'s options for `command:` or `args:` values
/// that contain the basename. Options are stored as `(key, value)`
/// pairs ; values are raw strings (often quoted), so a substring
/// match is the right shape.
fn io_adapter_references(io: &IoAdapter, basename: &str) -> bool {
    for (key, val) in &io.options {
        if (key == "command" || key == "args") && val.contains(basename) {
            return true;
        }
    }
    false
}

/// Pull the `name:` option from an IoAdapter (used for nicer log
/// output : "IoAdapter :daemon :mindstream" instead of just
/// "IoAdapter :daemon"). Strips a leading `:` if present (the
/// parser preserves the symbol form).
fn io_adapter_name(io: &IoAdapter) -> Option<String> {
    for (key, val) in &io.options {
        if key == "name" {
            let trimmed = val.trim_start_matches(':').trim_matches('"');
            return Some(trimmed.to_string());
        }
    }
    None
}

/// Walk `corpus_root` plus every known sibling bucket at the repo
/// root (`runtime/`, `discipline/`, `codegen/`, etc.). Mirrors the
/// multi-root scan in main.rs::load_all_hecksagons so hecksagons
/// living outside `hecks_conception/` (like
/// runtime/living_diagram/living_diagram.hecksagon) participate in
/// IR-claim queries. When `corpus_root` already IS the repo root,
/// the buckets are recursed once via the normal walker call below
/// — no duplication because walk_hecksagons stops at the first
/// match per visit.
fn walk_hecksagons_with_siblings(corpus_root: &Path, visit: &mut dyn FnMut(&Path)) {
    walk_hecksagons(corpus_root, visit);
    let Some(repo_root) = infer_repo_root(corpus_root) else { return };
    // If corpus_root IS the repo root, the buckets already got
    // scanned by the call above (they're subdirs of corpus_root).
    if repo_root == corpus_root {
        return;
    }
    for bucket in &[
        "runtime", "discipline", "codegen", "cli",
        "integrations", "tools", "capabilities", "bluebook",
    ] {
        let dir = repo_root.join(bucket);
        if dir.is_dir() {
            walk_hecksagons(&dir, visit);
        }
    }
}

/// Find the repo root by either recognising `corpus_root` as
/// `hecks_conception/` itself, or walking up until we find a dir
/// that contains `hecks_conception/`. Returns the repo root that
/// has both `hecks_conception/` and the runtime/discipline/codegen
/// sibling buckets.
fn infer_repo_root(start_dir: &Path) -> Option<std::path::PathBuf> {
    if start_dir.file_name().and_then(|n| n.to_str()) == Some("hecks_conception") {
        return start_dir.parent().map(|p| p.to_path_buf());
    }
    let mut cur = start_dir.to_path_buf();
    for _ in 0..6 {
        if cur.join("hecks_conception").is_dir() {
            return Some(cur);
        }
        let Some(parent) = cur.parent() else { return None };
        cur = parent.to_path_buf();
    }
    None
}

/// Recursive walker for `*.hecksagon` files. Skips the same
/// directories `load_combined_domain` skips so the substrate doesn't
/// chase into `target/`, `.git/`, `information/`, etc.
fn walk_hecksagons(dir: &Path, visit: &mut dyn FnMut(&Path)) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let p = entry.path();
        let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if matches!(
            name,
            ".git"
                | "target"
                | "information"
                | ".claude"
                | "node_modules"
                | "generated"
                | "fixtures"
                | "snippets"
                | "behaviors"
                | "behaviours"
        ) {
            continue;
        }
        if p.is_dir() {
            walk_hecksagons(&p, visit);
        } else if p.extension().map(|e| e == "hecksagon").unwrap_or(false) {
            visit(&p);
        }
    }
}

// ────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn specializer_targets_recognized_at_target_path() {
        let info = is_specializer_target("rust/src/validator_warnings.rs")
            .expect("validator_warnings.rs is a specializer target");
        assert_eq!(info.identifier, "validator_warnings");
        assert_eq!(info.kind, "specializer target");
    }

    #[test]
    fn specializer_targets_recognized_at_specializer_path() {
        let info = is_specializer_target("rust/src/specializer/validator.rs")
            .expect("specializer/validator.rs is a specializer target");
        assert_eq!(info.identifier, "validator");
    }

    #[test]
    fn specializer_targets_recognized_at_absolute_path() {
        let info = is_specializer_target(
            "/Users/foo/Projects/hecks/rust/src/dump.rs",
        )
        .expect("absolute paths must match by suffix");
        assert_eq!(info.identifier, "dump");
    }

    #[test]
    fn unknown_rs_files_return_none() {
        assert!(is_specializer_target("rust/src/main.rs").is_none());
        assert!(is_specializer_target("rust/src/runtime/repository.rs").is_none());
    }

    #[test]
    fn specializer_helpers_recognized() {
        let info = is_specializer_target("rust/src/specializer/util.rs")
            .expect("util.rs is a recognized specializer helper");
        assert_eq!(info.kind, "specializer helper module");
    }

    #[test]
    fn hecksagon_walker_finds_daemon_dispatched_basename() {
        // boot.hecksagon's real shape : `adapter :daemon, name:,
        // pidfile:, command: "{dir}/mindstream.sh"`. The :daemon
        // adapter parses into io_adapters (not shell_adapters) so
        // the substrate has to scan there too.
        let tmp = tempdir_under("dispatch_query_test_daemon_");
        fs::write(
            tmp.join("toy.hecksagon"),
            r#"Hecks.hecksagon "Toy" do
  adapter :daemon, name: :runner,
    pidfile: "{info}/.runner.pid",
    command: "{dir}/runner.sh"
end
"#,
        )
        .unwrap();

        let info = is_hecksagon_dispatched("path/to/runner.sh", &tmp)
            .expect("daemon adapter dispatches runner.sh by basename");
        assert!(info.kind.starts_with("IoAdapter :daemon"));
        assert_eq!(info.identifier, "Toy");

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn hecksagon_walker_finds_shell_dispatched_basename() {
        // Build a tmpdir corpus with one hecksagon that dispatches
        // a hypothetical `marker.sh`.
        let tmp = tempdir_under("dispatch_query_test_");
        let hex_path = tmp.join("toy.hecksagon");
        fs::write(
            &hex_path,
            r#"Hecks.hecksagon "Toy" do
  adapter :shell, name: :marker, command: "{dir}/marker.sh", ok_exit: 0
end
"#,
        )
        .unwrap();

        let info = is_hecksagon_dispatched("some/path/marker.sh", &tmp)
            .expect("hecksagon dispatches marker.sh by basename");
        assert_eq!(info.kind, "ShellAdapter :marker");
        assert_eq!(info.identifier, "Toy");
        assert!(info.source.ends_with("toy.hecksagon"));

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn hecksagon_walker_finds_web_serializer_implementation() {
        // A hecksagon that declares a :web adapter with `serializer:
        // :my_serializer` claims `rust/src/server/my_serializer.rs`
        // as the implementing file. The declaration IS the structural
        // claim — the file IS the named serializer.
        let tmp = tempdir_under("dispatch_query_test_web_");
        let hex_path = tmp.join("toy.hecksagon");
        fs::write(
            &hex_path,
            r#"Hecks.hecksagon "Toy" do
  adapter :web,
    name: :my_serializer,
    get: "/toy/thing.json",
    serializer: :my_serializer,
    content_type: "application/json"
end
"#,
        )
        .unwrap();

        let info = is_hecksagon_dispatched(
            "rust/src/server/my_serializer.rs",
            &tmp,
        )
        .expect(":web serializer claims server/my_serializer.rs");
        assert_eq!(info.kind, ":web serializer :my_serializer");
        assert_eq!(info.identifier, "Toy");

        // Sibling files in the same dir that don't match the
        // declared serializer name must NOT be claimed.
        assert!(is_hecksagon_dispatched("rust/src/server/mod.rs", &tmp).is_none());
        assert!(is_hecksagon_dispatched("rust/src/server/multi.rs", &tmp).is_none());
        // A file NOT in rust/src/server/ with the same stem also doesn't
        // match — the convention requires the server/ path prefix.
        assert!(is_hecksagon_dispatched("rust/src/my_serializer.rs", &tmp).is_none());

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn hecksagon_walker_returns_none_when_unclaimed() {
        let tmp = tempdir_under("dispatch_query_test_unclaimed_");
        // Empty corpus — nothing claims marker.sh.
        let info = is_hecksagon_dispatched("any/marker.sh", &tmp);
        assert!(info.is_none());
        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn hecksagon_walker_skips_blacklisted_dirs() {
        // Confirm `target/`, `.git/`, etc. don't get scanned.
        let tmp = tempdir_under("dispatch_query_test_blacklist_");
        let target_dir = tmp.join("target");
        fs::create_dir_all(&target_dir).unwrap();
        fs::write(
            target_dir.join("buried.hecksagon"),
            r#"Hecks.hecksagon "Buried" do
  adapter :shell, name: :ghost, command: "marker.sh", ok_exit: 0
end
"#,
        )
        .unwrap();

        let info = is_hecksagon_dispatched("marker.sh", &tmp);
        assert!(info.is_none(), "target/ must not be scanned");

        let _ = fs::remove_dir_all(&tmp);
    }

    #[test]
    fn top_level_query_falls_through_specializer_to_hecksagon() {
        let tmp = tempdir_under("dispatch_query_test_fallthrough_");
        fs::write(
            tmp.join("toy.hecksagon"),
            r#"Hecks.hecksagon "Toy" do
  adapter :shell, name: :runner, command: "{dir}/runner.sh", ok_exit: 0
end
"#,
        )
        .unwrap();

        // .rs in specializer table — first arm hits.
        let info = is_dispatched_by_corpus("rust/src/dump.rs", &tmp)
            .expect("specializer arm");
        assert_eq!(info.kind, "specializer target");

        // .sh referenced by a hecksagon — second arm hits.
        let info = is_dispatched_by_corpus("any/runner.sh", &tmp)
            .expect("hecksagon arm");
        assert!(info.kind.starts_with("ShellAdapter"));

        // Unknown path — neither arm hits.
        assert!(is_dispatched_by_corpus("rust/src/main.rs", &tmp).is_none());

        let _ = fs::remove_dir_all(&tmp);
    }

    /// Pure-test helper. Mirrors what `tempfile::tempdir` would do
    /// without pulling tempfile in as a dependency. Returns a path
    /// the caller is responsible for cleaning up.
    fn tempdir_under(prefix: &str) -> std::path::PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let p = std::env::temp_dir().join(format!("{}{}", prefix, nanos));
        fs::create_dir_all(&p).unwrap();
        p
    }
}
