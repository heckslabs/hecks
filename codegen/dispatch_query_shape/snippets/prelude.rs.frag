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

/// Imperative-exemption check : asks both the central
/// `exempt_registry.heki` AND the in-file `[antibody-exempt: ...]`
/// marker convention. Either path satisfies the structural
/// exemption ; the marker IS the audit trail (per enforcer.bluebook
/// `ExemptedEdited` event). Used by the antibody enforcer after the
/// IR-claim query (`is_dispatched_by_corpus`) returns None.
pub fn is_imperative_exempt(file_path: &str, corpus_root: &Path) -> bool {
    if file_in_exempt_registry(file_path, corpus_root) { return true; }
    file_has_in_header_marker(file_path)
}

/// Walk the central `exempt_registry.heki` under the corpus root.
/// Each row carries `path` as the natural-key id ; the enforcer only
/// needs `path` for the suffix-match.
fn file_in_exempt_registry(file_path: &str, corpus_root: &Path) -> bool {
    let registry = corpus_root.join("information/exempt_registry.heki");
    if !registry.exists() { return false; }
    let store = match crate::heki::read(registry.to_string_lossy().as_ref()) {
        Ok(s) => s,
        Err(_) => return false,
    };
    for (_id, rec) in &store {
        let Some(path_v) = rec.get("path").and_then(|v| v.as_str()) else { continue };
        if file_path.ends_with(path_v) {
            return true;
        }
    }
    false
}

/// Scan the file's first 30 lines for an `[antibody-exempt: ...]`
/// marker. The convention puts it in the doc-comment header ; past
/// 30 lines is body code. Returns false on any read error — safe
/// default for a hook that must never panic the editor.
fn file_has_in_header_marker(file_path: &str) -> bool {
    let text = match fs::read_to_string(file_path) {
        Ok(s) => s,
        Err(_) => return false,
    };
    text.lines().take(30).any(|line| line.contains("[antibody-exempt:"))
}

// ────────────────────────────────────────────────────────────────
// 1. Specializer registry — static dispatch table
// ────────────────────────────────────────────────────────────────

