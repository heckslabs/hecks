//! The `Query` construct (`lib/hecksagain/bluebook/ir/query.rb`, built on
//! `QuerySpecification::Common::Options`). Stage 2+ work: `where`'s pairs
//! comparator splitting (`build/query_derive.rs`), `order_by`/`limit` and
//! the eight open-map options (`offset`/`cursor`/`consistency`/
//! `freshness`/`authorize`/`nulls`/`inspect_query`/`use_index`).

use crate::diag::Diagnostic;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Query.{word}"))
}
