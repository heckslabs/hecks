//! Dispatch Query — the validator IR-query substrate (i122).
//!
//! [antibody-exempt: rust/src/dispatch_query.rs — kernel-
//!  surface substrate. This file IS the IR-query that lets future
//!  antibody decisions be structurally derived from bluebook ; it
//!  necessarily lands as Rust before it can introspect Rust. Retires
//!  under i78 (specializer-files-as-bluebook) when dispatch_query
//!  itself is regenerated from a meta-shape.]
//!
//! Asks the bluebook corpus a question shaped like "is this file
//! dispatched by something I declared?" — and answers without
//! consulting any whitelist registry. Three consumers share the
//! substrate :
//!
//!   1. The antibody enforcer (`hecks-life enforce-edit`) — when it
//!      sees an imperative-language edit, it asks here BEFORE the
//!      `exempt_registry.heki` lookup. If the IR claims the file,
//!      the edit is exempt structurally, no marker required.
//!
//!   2. The LoC ratchet (`.github/workflows/ratchet.yml`) — when
//!      non-bluebook lines grow, it asks here whether the growth
//!      lands in an IR-claimed surface. If yes, the growth is
//!      attributed to a declared shape.
//!
//!   3. The inline `[antibody-exempt: ...]` marker parser — when
//!      a source file carries an inline marker, the parser asks
//!      here whether the marker is still needed. Markers that the
//!      IR now covers are flagged for removal.
//!
//! ## Today's coverage
//!
//! Two queries are wired :
//!
//!   - `is_specializer_target(path)` — match against the static
//!     dispatch table in `rust/src/specializer/mod.rs`. Each
//!     known target name `<X>` claims two files :
//!     `rust/src/<X>.rs` (the emitted target) and
//!     `rust/src/specializer/<X>.rs` (the specializer module).
//!
//!   - `is_hecksagon_dispatched(path, root)` — for any file (most
//!     usefully `.sh`), walk every `*.hecksagon` under `root` and
//!     check whether any `ShellAdapter`'s `command` or `args`
//!     references the file's basename.
//!
//! Future queries (i145, i146, i77, i78) will add :
//!
//!   - capability_runner_shape's `CapabilityDetector` rows → claims
//!     `rust/src/run_<name>/mod.rs` paths.
//!   - bluebook adapters declared in `.hecksagon` files → claims
//!     `:rust`, `:llm`, `:llm_local` runtime adapters.
//!   - test_purity_shape's detection patterns → claims `.fixtures`
//!     files used only by allowed callers.
//!
//! Each future query is a new arm under `is_dispatched_by_corpus` ;
//! consumers don't change.

use std::path::Path;
use std::fs;

use crate::hecksagon_ir::{IoAdapter, ShellAdapter};
use crate::hecksagon_parser;

/// Adapter kinds that may carry a `command:` option referencing a
/// runnable file. `:daemon` is the canonical one (boot.hecksagon
/// declares `adapter :daemon, command: "{dir}/mindstream.sh"`) ;
/// `:llm`, `:fs`, `:stdout` etc. don't reference scripts. Listing
/// the kinds explicitly keeps the scan precise — a future adapter
/// kind that runs a file just adds to this list.
const DISPATCH_BEARING_IO_KINDS: &[&str] = &["daemon", "shell"];

/// Result of a successful corpus-dispatch lookup. Carries enough
/// context for the consumer to log a structured exemption reason —
/// "exempt because dispatched by `<source>` as `<kind>`".
#[derive(Debug, Clone)]
pub struct DispatchInfo {
    /// Where the dispatch declaration lives. Either a `.hecksagon`
    /// file path or a synthetic module identifier like
    /// `rust/src/specializer/mod.rs` for the specializer
    /// registry.
    pub source: String,
    /// What kind of dispatch claims this file. Free-form,
    /// human-readable. Examples : `"specializer target"`,
    /// `"ShellAdapter :foo"`, `"capability runner"`.
    pub kind: String,
    /// Specific identifier inside `source` (target name, adapter
    /// name, runner name, etc.). Useful for logs and tests.
    pub identifier: String,
}

/// Top-level corpus query — does anything in the IR claim this
/// file? Walks the available query arms in cheapest-first order :
/// in-process specializer registry, then on-disk hecksagon scan.
pub fn is_dispatched_by_corpus(file_path: &str, corpus_root: &Path) -> Option<DispatchInfo> {
    if let Some(info) = is_specializer_target(file_path) {
        return Some(info);
    }
    is_hecksagon_dispatched(file_path, corpus_root)
}

// ────────────────────────────────────────────────────────────────
// 1. Specializer registry — static dispatch table
// ────────────────────────────────────────────────────────────────

/// The list of targets recognized by `specializer::emit`. Kept as a
/// static array so the query is pure ; a unit test in this module
/// asserts the array matches the actual `emit` arms (see
/// `specializer_targets_match_emit_dispatch_table`).
pub const SPECIALIZER_TARGETS: &[&str] = &[
    "adapter_llm",
    "aggregate_state",
    "assemble",
    "behaviors_fixtures",
    "behaviors_parser",
    "behaviors_runner",
    "cli_dispatch",
    "command_dispatch",
    "conceiver_generator",
    "discover",
    "dispatch_query",
    "dump",
    "fixtures_parser",
    "hecksagon_parser",
    "heki_query",
    "html_domain",
    "interpreter",
    "ir",
    "lifecycle_validator",
    "parse_blocks",
    "parser",
    "parser_helpers",
    "repository",
    "runtime",
    "run_statusline",
    "system_prompt",
    "validator",
    "validator_corpus",
    "validator_warnings",
];

/// Modules that live alongside the specializer targets but aren't
/// emit() arms themselves — shared helpers, declared in mod.rs but
/// not part of the public dispatch table. Included here so the
/// antibody recognizes them as kernel-surface specializer machinery.
pub const SPECIALIZER_HELPER_MODULES: &[&str] = &[
    "behaviors_parser_dispatch",
    "validator_morphology",
    "validator_checks",
    "validator_checks_graph",
    "util",
    "mod",
];

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
    let mut found: Option<DispatchInfo> = None;
    walk_hecksagons(corpus_root, &mut |path: &Path| {
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
            if !DISPATCH_BEARING_IO_KINDS.contains(&io.kind.as_str()) {
                continue;
            }
            if io_adapter_references(io, basename) {
                let adapter_name = io_adapter_name(io).unwrap_or_else(|| io.kind.clone());
                found = Some(DispatchInfo {
                    source: path.to_string_lossy().into_owned(),
                    kind: format!("IoAdapter :{} :{}", io.kind, adapter_name),
                    identifier: hex.name.clone(),
                });
                return;
            }
        }
    });
    found
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
