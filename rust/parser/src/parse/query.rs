//! The `Query` construct (`lib/hecksagain/bluebook/ir/query.rb`, built on
//! `QuerySpecification::Common::Options`). Stage 2+ work: `where`'s pairs
//! comparator splitting (`build/query_derive.rs`), `order_by`/`limit` and
//! the eight open-map options (`offset`/`cursor`/`consistency`/
//! `freshness`/`authorize`/`nulls`/`inspect_query`/`use_index`).

use crate::build::query_derive;
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Query.{word}"))
}

/// Parses a `query "Name" do ... end` body. STAGE 3 adds `description`
/// (identity.bluebook's `ResolvedBy`, governance.bluebook's
/// `AssignmentsForActor`/`Allowed`) — `limit` and the eight open-map
/// options (`offset`/`cursor`/`consistency`/`freshness`/`authorize`/
/// `nulls`/`inspect_query`/`use_index`) are still not exercised by any
/// real corpus member yet and fall through to `not_built_yet`, same as
/// any other still-stubbed word.
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<ir::Query> {
    let mut query = ir::Query { name: name.to_string(), ..Default::default() };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Query")? else {
            return Ok(query);
        };
        let line = gated.line.number;

        match gated.row.word {
            "description" => query.description = Some(super::positional_text(file, line, "description", &gated.args, 1)?),
            "attribute" => query.attributes.push(super::build_attribute(file, line, "attribute", &gated.args)?.0),
            "where" => query.wheres.extend(query_derive::where_clauses(&gated.args.named)),
            "order_by" => {
                let field = super::positional_symbol(file, line, "order_by", &gated.args, 1)?;
                let direction = match gated.args.positional.iter().find(|(idx, _)| *idx == 2) {
                    Some((_, text)) => text.trim().trim_start_matches(':').to_string(),
                    None => "asc".to_string(),
                };
                query.order_by = Some(ir::OrderBy { field, direction });
            }
            _ => return Err(super::not_built_yet("Query", gated.row, file, line, &gated.call.word)),
        }
    }
}
