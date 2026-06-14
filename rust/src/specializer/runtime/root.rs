//! Rust-native specializer for `rust/src/runtime/mod.rs`.
//!
//! i147 Wave 5-B target — the runtime kernel root regenerated from
//! the `runtime_shape` bluebook + ordered `.rs.frag` snippets +
//! per-method / per-phase rows.
//!
//! Design — three-level section / method / phase nesting. The shape
//! declares one `Section` row per top-level partition in the file, in
//! source order. Each row's `body_kind` picks the emission template :
//!
//! ```text
//!     verbatim_section — read snippet_path raw, emit unchanged.
//!                        Used for the Runtime struct, the Value enum
//!                        + impls, the RuntimeError enum + Display
//!                        impl, the attrs! macro, the repo_key /
//!                        repo_lookup_key helpers, and the trigram
//!                        helpers.
//!
//!     runtime_impl     — emit the `impl Runtime { … }` block by
//!                        walking RuntimeMethod rows in `order`
//!                        ascending, wrapped by the impl opener and
//!                        closing brace.
//! ```
//!
//! Each RuntimeMethod row's body_kind in turn picks :
//!
//! ```text
//!     verbatim_method  — read snippet_path raw, emit unchanged. The
//!                        snippet is the full method (incl. leading
//!                        doc comment when present and trailing blank
//!                        when present — separator handling is encoded
//!                        in the snippet itself).
//!     boot_pipeline    — emit `pub fn boot_with_data_dir(domain,
//!                        data_dir) -> Self { … }` by walking
//!                        BootPhase rows in `order` ascending. The
//!                        function header and closing brace + trailing
//!                        blank are emitted by the template ; phase
//!                        snippets carry the inter-phase blank-line
//!                        separators inline.
//! ```
//!
//! Real compression : adding a boot phase (e.g. wire_adapters when the
//! adapter wiring lifts out of terminal/io into the boot pipeline) is
//! a single fixture row + snippet pair, not a hand-edit to the boot
//! function. Same for adding a Runtime impl method.
//!
//! Usage :
//!
//! ```ignore
//!   let rust = runtime::root::emit(repo_root)?;
//!   print!("{}", rust);
//! ```
//!
//! [antibody-exempt: rust/src/specializer/runtime/root.rs —
//!  i147 Wave 5-B Rust-native specializer for runtime/mod.rs.
//!  Retires when the specializer itself is regenerated from a
//!  meta-shape (i78).]

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/runtime_shape/fixtures/runtime_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;

    let sections = util::by_aggregate_sorted(&fixtures, "Section", "order");

    let mut out = String::new();
    for sec in &sections {
        out.push_str(&emit_one_section(repo_root, sec, &fixtures)?);
    }
    Ok(out)
}

/// Emit a single Section by its `name` attr — the scoped sub-target behind
/// `storehouse specialize runtime --section <name>`. This powers the
/// per-concern byte-identity goldens the runtime-as-bluebook strangler
/// relies on while the whole-file `runtime` golden stays `#[ignore]`d
/// during the drift-reduction program (see inbox/runtime-as-bluebook.md).
pub fn emit_section(repo_root: &Path, name: &str) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let sections = util::by_aggregate_sorted(&fixtures, "Section", "order");
    let sec = sections
        .iter()
        .find(|s| util::attr(s, "name") == name)
        .ok_or_else(|| format!("no runtime Section named '{}'", name))?;
    emit_one_section(repo_root, sec, &fixtures)
}

/// Emit one Section, dispatching on its `body_kind`. Shared by the
/// whole-file `emit` walk and the scoped `emit_section` sub-target so both
/// paths produce byte-identical output for the same row.
fn emit_one_section(
    repo_root: &Path,
    sec: &Fixture,
    fixtures: &[Fixture],
) -> Result<String, Box<dyn Error>> {
    match util::attr(sec, "body_kind") {
        "verbatim_section" => {
            let snippet_path = repo_root.join(util::attr(sec, "snippet_path"));
            Ok(util::read_snippet_raw(&snippet_path)?)
        }
        "runtime_impl" => emit_runtime_impl(repo_root, fixtures),
        other => Err(format!("unknown body_kind: {}", other).into()),
    }
}

/// Emit the `impl Runtime { … }` block. Walks RuntimeMethod rows in
/// `order` ascending, dispatching each row by its own body_kind
/// (verbatim_method or boot_pipeline). The impl opener and closing
/// brace are emitted by this template ; method-level blank-line
/// separators are encoded in the snippets themselves (each verbatim
/// method snippet ends with a trailing blank ; the boot_pipeline
/// emitter likewise appends a trailing blank after its closing brace).
///
/// Two methods deviate from the trailing-blank pattern :
///   - query_projection ends with `    }\n` and is followed
///     immediately by resolve_query's leading doc comment with NO
///     intervening blank line. Its snippet therefore has no trailing
///     blank, and resolve_query's snippet has no leading blank.
///   - run_interactive (the last method) ends with `    }\n` directly
///     adjacent to the impl block's closing `}\n`. Its snippet has
///     no trailing blank, and the closing brace below provides the
///     hand-off to the next Section.
fn emit_runtime_impl(
    repo_root: &Path,
    fixtures: &[Fixture],
) -> Result<String, Box<dyn Error>> {
    let methods = util::by_aggregate_sorted(fixtures, "RuntimeMethod", "order");

    let mut out = String::new();
    out.push_str("impl Runtime {\n");
    for m in &methods {
        match util::attr(m, "body_kind") {
            "verbatim_method" => {
                let snippet_path = repo_root.join(util::attr(m, "snippet_path"));
                let body = util::read_snippet_raw(&snippet_path)?;
                out.push_str(&body);
            }
            "boot_pipeline" => {
                out.push_str(&emit_boot_pipeline(repo_root, fixtures)?);
            }
            other => {
                return Err(format!("unknown method body_kind: {}", other).into());
            }
        }
    }
    out.push_str("}\n");
    Ok(out)
}

/// Emit the `pub fn boot_with_data_dir(domain, data_dir) -> Self { … }`
/// function by walking BootPhase rows in `order` ascending. The
/// function signature and closing brace + trailing blank line (which
/// separates boot_with_data_dir from the next method) are emitted by
/// this template ; phase snippets carry the inter-phase blank lines
/// internally (each phase snippet except the last ends with a trailing
/// blank line that becomes the separator between phases).
fn emit_boot_pipeline(
    repo_root: &Path,
    fixtures: &[Fixture],
) -> Result<String, Box<dyn Error>> {
    let phases = util::by_aggregate_sorted(fixtures, "BootPhase", "order");

    let mut out = String::new();
    out.push_str("    pub fn boot_with_data_dir(domain: Domain, data_dir: Option<String>) -> Self {\n");
    for p in &phases {
        let snippet_path = repo_root.join(util::attr(p, "snippet_path"));
        let body = util::read_snippet_raw(&snippet_path)?;
        out.push_str(&body);
    }
    // Closing brace of the function + trailing blank to separate from
    // the next method (`dispatch`). The phase_4 snippet ends with the
    // Runtime literal's closing `        }` so this template emits the
    // function-level closing `    }` + the inter-method blank.
    out.push_str("    }\n\n");
    Ok(out)
}
