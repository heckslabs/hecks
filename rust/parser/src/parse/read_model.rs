//! The `ReadModel` construct (`lib/hecksagain/bluebook/ir/read_model.rb`,
//! `report` the current spelling — `was: "read_model"`, both answered
//! forever per the rename column). STAGE 3: `description`/`include`/
//! `group_by` — console_settings.bluebook's own `Styles`/`Curated`
//! reports, both ROOTLESS (no `reference_to`) with a single many-side
//! `include` and a `group_by` naming that same head's own fields. STAGE 4
//! adds `reference_to` (the single-root form: `CustomerPortfolio`/
//! `ComplianceDashboard`) and the eight open-map option words PLUS
//! `where`/`order_by`/`limit` — `ReadModelBuilder` `include
//! QuerySpecification::Common::DSL`, the SAME module `parse::query`
//! shares via `build::query_options`; confirmed real by
//! `ComplianceDashboard`'s own filtered/ordered/capped/fresh/indexed
//! shape (banking.bluebook's own comment names it "the one shape
//! seal_query_options allows").

use crate::build::{naming, query_derive, query_options, read_model as build_read_model};
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ReadModel.{word}"))
}

const OPTION_WORDS: &[&str] = &["offset", "cursor", "consistency", "freshness", "authorize", "nulls", "inspect_query", "use_index"];

/// Parses a `report "Name" do ... end` body (`report`/`read_model`).
/// `include`s are gathered raw and resolved into `aggregate_heads` at the
/// END (mirroring `ReadModelBuilder#build`'s own build-time resolution —
/// "order-independent," per that builder's own comment), the same
/// deferred-resolution shape `parse::aggregate`'s own `identified_by`
/// handling already uses for the identical Ruby-side reason — this is
/// also why `reference_to` (needed to compute each head's own `many:`)
/// is read into a plain local rather than applied eagerly.
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<ir::ReadModel> {
    let mut description: Option<String> = None;
    let mut reference_target: Option<String> = None;
    let mut reference_name: Option<String> = None;
    let mut includes: Vec<(String, Option<String>)> = Vec::new();
    let mut group_by_fields: Vec<String> = Vec::new();
    let mut wheres: Vec<ir::WhereClause> = Vec::new();
    let mut order_by: Option<ir::OrderBy> = None;
    let mut limit: Option<ir::LimitSpec> = None;
    let mut options = ir::QueryOptions::default();
    let mut last_line = 0usize;

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "ReadModel")? else { break };
        last_line = gated.line.number;

        match gated.row.word {
            "description" => description = Some(super::positional_text(file, last_line, "description", &gated.args, 1)?),
            // `ReadModelBuilder#reference_to(type, as: nil)` — the
            // single-root form (`CustomerPortfolio`'s own `reference_to
            // Customer`). Ruby refuses a SECOND call ("already has a
            // projection reference") — a `seal`-style declaration-time
            // check, out of scope here the same way `AggregateBuilder`'s
            // own seals are (this parser's job is shape, not semantics);
            // a bluebook that violates it never produced the oracle this
            // parser is compared against in the first place.
            "reference_to" => {
                let target_raw = super::positional_constant(file, last_line, "reference_to", &gated.args, 1)?;
                let target = naming::demodulise(target_raw);
                // `@reference_name = (as || Naming.snake(@reference_target)).to_sym`
                // — ALWAYS set once `reference_to` is called, defaulting
                // to the target's own snake-cased name.
                reference_name = Some(super::named_symbol(&gated.args, "as").unwrap_or_else(|| naming::snake(&target)));
                reference_target = Some(target);
            }
            "include" => {
                let target = super::positional_constant(file, last_line, "include", &gated.args, 1)?;
                let as_name = super::named_symbol(&gated.args, "as");
                includes.push((naming::demodulise(target), as_name));
            }
            "group_by" => {
                // VARIADIC — `argument_gate`'s own `variadic: "true"`
                // handling (syntax.bluebook's own comment on that
                // column) already confirmed every positional here reads
                // as a symbol; just strip each one's leading `:`.
                group_by_fields = gated.args.positional.iter().map(|(_, text)| text.trim().trim_start_matches(':').to_string()).collect();
            }
            "where" => wheres.extend(query_derive::where_clauses(&gated.args.named)),
            "order_by" => {
                let field = super::positional_symbol(file, last_line, "order_by", &gated.args, 1)?;
                let direction = match gated.args.positional.iter().find(|(idx, _)| *idx == 2) {
                    Some((_, text)) => text.trim().trim_start_matches(':').to_string(),
                    None => "asc".to_string(),
                };
                order_by = Some(ir::OrderBy { field, direction });
            }
            "limit" => {
                let raw = super::positional_constant(file, last_line, "limit", &gated.args, 1)?;
                limit = Some(ir::LimitSpec { value: crate::ruby_value::render(&crate::ruby_value::read(raw)) });
            }
            word if OPTION_WORDS.contains(&word) => query_options::apply(file, last_line, word, &gated.args, &mut options)?,
            _ => return Err(super::not_built_yet("ReadModel", gated.row, file, last_line, &gated.call.word)),
        }
    }

    if includes.is_empty() && reference_target.is_none() {
        return Err(Diagnostic::new(file, last_line, format!("{name} needs an aggregate-head reference or at least one include")));
    }

    let aggregate_heads = build_read_model::aggregate_heads(file, last_line, name, &includes, reference_target.as_deref())?;

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
        options,
    })
}
