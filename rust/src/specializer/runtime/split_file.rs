//! Shared emitter for runtime-as-bluebook file-splits (machinery cost #2).
//!
//! i728 runtime-as-bluebook strangler. Each split file (persistence_resolution,
//! event_driving, …) is one `impl Runtime { … }` block built from the
//! `SplitMethod` rows whose `file` attr names it. This helper holds the shared
//! STRUCTURE (load fixtures → filter by file → concatenate verbatim_method
//! bodies, blank-separated, inside the impl block) so each per-file emitter is
//! just its own HEADER const + a one-line delegate. Adding a new split file is
//! then : SplitMethod rows + snippets + a thin emitter + a target registration.
//!
//! Usage :
//!   pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
//!       split_file::emit(repo_root, "event_driving", HEADER)
//!   }
//!
//! [antibody-exempt: rust/src/specializer/runtime/split_file.rs — i728
//!  runtime-as-bluebook strangler file-split specializer (shared structure).
//!  Same i80/i147 kernel-floor retirement contract as its command_dispatch /
//!  root siblings ; retires at the i78 meta-shape.]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str = "codegen/runtime_shape/fixtures/runtime_shape.fixtures";

/// Emit one split file : `header` then an `impl Runtime { … }` block built from
/// the `SplitMethod` rows whose `file` attr == `file_key`, in `order`
/// ascending, verbatim_method bodies separated by one blank line.
pub fn emit(
    repo_root: &Path,
    file_key: &str,
    header: &str,
) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let methods: Vec<_> = util::by_aggregate_sorted(&fixtures, "SplitMethod", "order")
        .into_iter()
        .filter(|m| util::attr(m, "file") == file_key)
        .collect();

    let mut out = String::from(header);
    out.push_str("impl Runtime {\n");
    let last = methods.len().saturating_sub(1);
    for (i, m) in methods.iter().enumerate() {
        let snippet_path = repo_root.join(util::attr(m, "snippet_path"));
        let body = util::read_snippet_raw(&snippet_path)?;
        out.push_str(&body);
        if i != last {
            out.push('\n');
        }
    }
    out.push_str("}\n");
    Ok(out)
}
