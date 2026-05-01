//! Rust-native specializer for `hecks_life/src/run_boot/discover.rs`.
//!
//! i147 Wave 2 target — boot pipeline Phase 1+2 (DiscoverOrgans +
//! WriteCensus) regenerated from the `discover_shape` bluebook +
//! ordered `.rs.frag` snippets.
//!
//! Design — section-as-snippet (mirrors heki_query_shape) :
//!   The shape declares one `Section` row per ordered code section in
//!   the target. Each row's `snippet_path` points at a `.rs.frag`
//!   under `capabilities/discover_shape/snippets/`. The specializer
//!   sorts sections by `order`, reads each snippet verbatim
//!   (`read_snippet_raw` — NOT `read_snippet_body` — because each
//!   snippet's trailing blank line is the section separator), and
//!   concatenates HEADER + snippets to produce byte-identical output.
//!
//! Why HEADER as a const :
//!   The doc + imports prelude is short, stable, and not naturally
//!   tabular ; baking it as a Rust const keeps the shape's tabular
//!   rows uniform (one body_kind, one path attribute). When a future
//!   shape lands that captures imports as data, the HEADER const
//!   retires into a row.
//!
//! Usage :
//!   let rust = run_boot::discover::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: hecks_life/src/specializer/run_boot/discover.rs —
//!  i147 Wave 2 — Rust-native specializer for run_boot/discover.rs]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/discover_shape/fixtures/discover_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let sections = util::by_aggregate_sorted(&fixtures, "Section", "order");

    let mut out = String::new();
    out.push_str(HEADER);
    for sec in &sections {
        match util::attr(sec, "body_kind") {
            "verbatim_section" => {
                let snippet_path = repo_root.join(util::attr(sec, "snippet_path"));
                let body = util::read_snippet_raw(&snippet_path)?;
                out.push_str(&body);
            }
            other => {
                return Err(format!("unknown body_kind: {}", other).into());
            }
        }
    }
    Ok(out)
}

const HEADER: &str = r#"//! Phase 1 + 2 — DiscoverOrgans + WriteCensus
//!
//! Walks `aggregates/` and `capabilities/` recursively under the
//! conception dir, parses each .bluebook into IR, sums up :
//!   - organs        : .bluebook files under aggregates/body/
//!                     (the body anatomy subset — heart, breath,
//!                     ultradian, sleep, dream, wake, organs/, etc.)
//!   - capabilities  : .bluebook files under capabilities/
//!   - aggregates    : sum of `aggregates[]` across all bluebooks
//!                     anywhere under aggregates/
//!   - nerves        : policies whose `target_domain` is set across
//!                     the full tree (cross-domain edges)
//!   - vows          : count of Vow records in <info_dir>/vow.heki
//!                     (taken via Vows.Take dispatch — what matters
//!                     operationally is how many vows the being holds)
//!
//! WriteCensus then upserts these counts into `<info>/census.heki` so
//! anything reading the heki sees the same numbers the runner printed.

use crate::heki;
use crate::parser;

use std::path::Path;

"#;
