//! Rust-native specializer for `storehouse/src/heki_query.rs`.
//!
//! i147 Part B target — kernel-surface heki query primitives
//! (Filter / OrderSpec / OrderKey / field_to_string) regenerated from
//! the `heki_query_shape` bluebook + ordered `.rs.frag` snippets.
//!
//! Design — section-as-snippet :
//!   The shape declares one `Section` row per ordered code section in
//!   the target. Each row's `snippet_path` points at a `.rs.frag`
//!   under `capabilities/heki_query_shape/snippets/`. The specializer
//!   sorts sections by `order`, reads each snippet verbatim
//!   (`read_snippet_raw` — NOT `read_snippet_body` — because the
//!   leading `// ----` dividers in each section are file content, not
//!   doc-strip fodder), and concatenates HEADER + IMPORTS + snippets
//!   to produce byte-identical output.
//!
//! Why a separate body_kind from dump_shape's embedded_helper :
//!   embedded_helper wraps a snippet in `fn name(...) -> ret { … }` ;
//!   here the snippet IS already the surrounding Rust (struct + impl
//!   + tests) so no wrapper is emitted. New body_kind name keeps the
//!   semantic distinct.
//!
//! Usage :
//!   let rust = heki_query::emit(repo_root)?;
//!   print!("{}", rust);

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/heki_query_shape/fixtures/heki_query_shape.fixtures";

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

const HEADER: &str = r#"//! HekiQuery — filter / order / project logic for .heki stores
//!
//! Pure functions over `heki::Store`. No IO — the CLI is responsible for
//! reading the store and printing the result. This module is the
//! engine room the new `heki list / count / mark / next-ref / ...`
//! subcommands share.
//!
//! [antibody-exempt: storehouse heki subcommand expansion; prerequisite
//!  for i37 Phase B (replace python3 -c invocations in shell scripts).
//!  Retires when heki dispatch moves to a bluebook + hecksagon.]
//!
//! Usage:
//!   let filter = Filter::parse("status=queued")?;
//!   let records = filter_records(&store, &[filter]);
//!   let ordered = order_records(records, &OrderSpec::parse("priority:enum=high,medium,normal,low")?);
//!
//! Filter ops (derived from shell python patterns):
//!   k=v    exact equality (string compare on the JSON stringified value)
//!   k!=v   not equal
//!   k~=v   prefix match
//!   k*=v   substring match
//!
//! Order spec:
//!   field                    — ascending
//!   field:asc / field:desc   — explicit direction
//!   field:enum=a,b,c         — explicit enum ordering (a first, c last)
//!   Ties on primary key break on created_at (stable byte-for-byte).

use crate::heki::{Record, Store};

"#;
