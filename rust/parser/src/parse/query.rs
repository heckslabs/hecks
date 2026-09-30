//! The `Query` construct: `where`, `order_by`, `limit` and the open-map option words.

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
            "where" => {
                query_derive::refuse_on_target(file, line, "where", &gated.args.named)?;
                query
                    .wheres
                    .extend(query_derive::where_clauses(&gated.args.named, None))
            }
            "order_by" => {
                // The gate already refuses an undeclared `on:`; only `where` needs a check.
                let field = super::positional_symbol(file, line, "order_by", &gated.args, 1)?;
                let direction = match gated.args.positional.iter().find(|(idx, _)| *idx == 2) {
                    Some((_, text)) => text.trim().trim_start_matches(':').to_string(),
                    None => "asc".to_string(),
                };
                query.order_by = Some(ir::OrderBy { field, direction, target: None });
            }
            // `positional_constant` only fetches raw text; the gate already checked it is numeric.
            "limit" => {
                let raw = super::positional_constant(file, line, "limit", &gated.args, 1)?;
                query.limit = Some(ir::LimitSpec {
                    value: crate::ruby_value::render(&crate::ruby_value::read(raw)),
                    target: None,
                });
            }
            "returns" => {
                if query.returns.is_some() {
                    return Err(Diagnostic::new(
                        file,
                        line,
                        format!("{name} declares returns twice — a query answers in one shape"),
                    ));
                }
                let raw = super::positional_constant(file, line, "returns", &gated.args, 1)?;
                let (type_name, list, _) =
                    super::resolve_type_expression(file, line, "returns", "returns", raw)?;
                let type_name = crate::build::naming::demodulise(&type_name);
                query.returns = Some(if list {
                    format!("list_of({type_name})")
                } else {
                    type_name
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
