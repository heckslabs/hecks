//! The `ReadModel` construct (`lib/hecksagain/bluebook/ir/read_model.rb`,
//! `report` the current spelling — `was: "read_model"`, both answered
//! forever per the rename column). STAGE 3: `description`/`include`/
//! `group_by` — console_settings.bluebook's own `Styles`/`Curated`
//! reports, both ROOTLESS (no `reference_to`) with a single many-side
//! `include` and a `group_by` naming that same head's own fields.
//! `reference_to` and the eight open-map option words (`where`/
//! `order_by`/`limit`/`offset`/`cursor`/`consistency`/`freshness`/
//! `authorize`/`nulls`/`inspect_query`/`use_index`) are declared
//! (`syntax.bluebook`) but not exercised by either real report — still
//! fall through to `not_built_yet`, same as any other still-stubbed word.

use crate::build::{naming, read_model as build_read_model};
use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::lex::SourceLine;

pub fn not_implemented(file: &str, line: usize, word: &str) -> Diagnostic {
    Diagnostic::not_yet_implemented(file, line, format!("ReadModel.{word}"))
}

/// Parses a `report "Name" do ... end` body (`report`/`read_model`).
/// `include`s are gathered raw and resolved into `aggregate_heads` at the
/// END (mirroring `ReadModelBuilder#build`'s own build-time resolution —
/// "order-independent," per that builder's own comment), the same
/// deferred-resolution shape `parse::aggregate`'s own `identified_by`
/// handling already uses for the identical Ruby-side reason.
pub fn parse_body(file: &str, lines: &[SourceLine], pos: &mut usize, name: &str) -> ParseResult<ir::ReadModel> {
    let mut description: Option<String> = None;
    let mut includes: Vec<(String, Option<String>)> = Vec::new();
    let mut group_by_fields: Vec<String> = Vec::new();
    let mut last_line = 0usize;

    loop {
        let Some(gated) = super::next_line(file, lines, pos, "ReadModel")? else { break };
        last_line = gated.line.number;

        match gated.row.word {
            "description" => description = Some(super::positional_text(file, last_line, "description", &gated.args, 1)?),
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
            _ => return Err(super::not_built_yet("ReadModel", gated.row, file, last_line, &gated.call.word)),
        }
    }

    if includes.is_empty() {
        return Err(Diagnostic::new(file, last_line, format!("{name} needs an aggregate-head reference or at least one include")));
    }

    let aggregate_heads = build_read_model::aggregate_heads(file, last_line, name, &includes, None)?;

    Ok(ir::ReadModel {
        name: name.to_string(),
        description,
        reference_name: None,
        reference_target: None,
        query_name: naming::snake(name),
        aggregate_heads,
        group_by: group_by_fields,
        extra_options: std::collections::BTreeMap::new(),
    })
}
