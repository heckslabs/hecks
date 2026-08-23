//! The `Query` construct (`lib/hecksagain/bluebook/ir/query.rb`, built on
//! `QuerySpecification::Common::Options`). `where`'s pairs comparator
//! splitting (`build/query_derive.rs`), `order_by`. STAGE 4 adds `limit`
//! and the five open-map options (`offset`/`cursor`/`authorize`/`nulls`/
//! `inspect_query`, all via the shared `build::query_options` — the SAME
//! module `parse::read_model` uses, since both Ruby builders `include
//! QuerySpecification::Common::DSL`) — confirmed real: `Account
//! .Overdrawn`'s own `limit`, `SafeDepositBox.Rented`'s own `authorize`.

use crate::build::{query_derive, query_options};
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("Query.{word}"))
}

const OPTION_WORDS: &[&str] = &["offset", "cursor", "authorize", "nulls", "inspect_query"];

/// Parses a `query "Name" do ... end` body.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
) -> ParseResult<ir::Query> {
    let mut query = ir::Query {
        name: name.to_string(),
        ..Default::default()
    };

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "Query")? else {
            return Ok(query);
        };
        let line = gated.line.number;

        match gated.row.word {
            "description" => {
                query.description = Some(super::positional_text(
                    file,
                    line,
                    "description",
                    &gated.args,
                    1,
                )?)
            }
            "attribute" => query
                .attributes
                .push(super::build_attribute(file, line, "attribute", &gated.args)?.0),
            "where" => query
                .wheres
                .extend(query_derive::where_clauses(&gated.args.named)),
            "order_by" => {
                let field = super::positional_symbol(file, line, "order_by", &gated.args, 1)?;
                let direction = match gated.args.positional.iter().find(|(idx, _)| *idx == 2) {
                    Some((_, text)) => text.trim().trim_start_matches(':').to_string(),
                    None => "asc".to_string(),
                };
                query.order_by = Some(ir::OrderBy { field, direction });
            }
            // `LimitSpec#to_h`'s own `value: render_value(value)` —
            // `positional_constant` here is just "the raw text at
            // position 1," not an assertion the token IS a constant; the
            // argument gate already confirmed it reads as a number.
            "limit" => {
                let raw = super::positional_constant(file, line, "limit", &gated.args, 1)?;
                query.limit = Some(ir::LimitSpec {
                    value: crate::ruby_value::render(&crate::ruby_value::read(raw)),
                });
            }
            word if OPTION_WORDS.contains(&word) => {
                query_options::apply(file, line, word, &gated.args, &mut query.options)?
            }
            _ => {
                return Err(super::not_built_yet(
                    "Query",
                    gated.row,
                    file,
                    line,
                    &gated.call.word,
                ))
            }
        }
    }
}
