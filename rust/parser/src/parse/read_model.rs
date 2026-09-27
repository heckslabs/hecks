//! The `ReadModel` construct: `include`, `reference_to`, `group_by`, `where`/`order_by`/`limit`
//! and the open-map option words.

use crate::build::{naming, query_derive, query_options, read_model as build_read_model};
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ReadModel.{word}"))
}

const OPTION_WORDS: &[&str] = &["offset", "cursor", "authorize", "nulls", "inspect_query"];

/// Parses a `report "Name" do ... end` body (`report`/`read_model`).
/// `include`s are resolved into `aggregate_heads` at the end, so declaration order is free.
pub fn parse_body(
    file: &str,
    lines: &[SourceLine],
    pos: &mut usize,
    name: &str,
) -> ParseResult<ir::ReadModel> {
    let mut description: Option<String> = None;
    let mut reference_target: Option<String> = None;
    let mut reference_name: Option<String> = None;
    let mut includes: Vec<(String, Option<String>)> = Vec::new();
    let mut group_by_fields: Vec<String> = Vec::new();
    let mut count = false;
    let mut median_field: Option<String> = None;
    let mut wheres: Vec<ir::WhereClause> = Vec::new();
    let mut order_by: Option<ir::OrderBy> = None;
    let mut limit: Option<ir::LimitSpec> = None;
    let mut options = ir::QueryOptions::default();
    let mut last_line = 0usize;

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "ReadModel")? else {
            break;
        };
        last_line = gated.line.number;

        match gated.row.word {
            "description" => {
                description = Some(super::positional_text(
                    file,
                    last_line,
                    "description",
                    &gated.args,
                    1,
                )?)
            }
            // Ruby refuses a second `reference_to`; that seal is out of scope for this parser.
            "reference_to" => {
                let target_raw =
                    super::positional_constant(file, last_line, "reference_to", &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                // Defaults to the target's snake-cased name.
                reference_name = Some(
                    super::named_symbol(&gated.args, "as")
                        .unwrap_or_else(|| naming::snake(&target)),
                );
                reference_target = Some(target);
            }
            "include" => {
                let target =
                    super::positional_constant(file, last_line, "include", &gated.args, 1)?;
                let as_name = super::named_symbol(&gated.args, "as");
                includes.push((naming::demodulise(target), as_name));
            }
            "group_by" => {
                // Variadic; the argument gate already checked each positional is a symbol.
                group_by_fields = gated
                    .args
                    .positional
                    .iter()
                    .map(|(_, text)| text.trim().trim_start_matches(':').to_string())
                    .collect();
            }
            // A bare word: its presence is the value.
            "count" => count = true,
            "median" => {
                median_field = Some(super::positional_symbol(
                    file,
                    last_line,
                    "median",
                    &gated.args,
                    1,
                )?)
            }
            "where" => {
                query_derive::refuse_on_target(file, last_line, "where", &gated.args.named)?;
                wheres.extend(query_derive::where_clauses(&gated.args.named))
            }
            "order_by" => {
                // The gate already refuses an undeclared `on:`; only `where` needs a check.
                let field = super::positional_symbol(file, last_line, "order_by", &gated.args, 1)?;
                let direction = match gated.args.positional.iter().find(|(idx, _)| *idx == 2) {
                    Some((_, text)) => text.trim().trim_start_matches(':').to_string(),
                    None => "asc".to_string(),
                };
                order_by = Some(ir::OrderBy { field, direction });
            }
            "limit" => {
                let raw = super::positional_constant(file, last_line, "limit", &gated.args, 1)?;
                limit = Some(ir::LimitSpec {
                    value: crate::ruby_value::render(&crate::ruby_value::read(raw)),
                });
            }
            word if OPTION_WORDS.contains(&word) => {
                query_options::apply(file, last_line, word, &gated.args, &mut options)?
            }
            _ => {
                return Err(super::not_built_yet(
                    "ReadModel",
                    gated.row,
                    file,
                    last_line,
                    &gated.call.word,
                ))
            }
        }
    }

    if includes.is_empty() && reference_target.is_none() {
        return Err(Diagnostic::new(
            file,
            last_line,
            format!("{name} needs an aggregate-head reference or at least one include"),
        ));
    }

    let aggregate_heads = build_read_model::aggregate_heads(
        file,
        last_line,
        name,
        &includes,
        reference_target.as_deref(),
    )?;

    Ok(ir::ReadModel {
        name: name.to_string(),
        description,
        reference_name,
        reference_target,
        query_name: naming::snake(name),
        wheres,
        order_by,
        limit,
        aggregate_heads,
        group_by: group_by_fields,
        count,
        median_field,
        options,
    })
}
