//! A report, the read model of the Ruby form, in sentences: what it is about or includes, how it
//! groups and totals, and the filter, order and limit on its rows.
//!
//! ```text
//! Report: Card Payment Totals By Status
//!   The total amount of every card charge, added up for each status.
//!   It includes a card payment
//!   It groups by status
//!   It adds up the amount
//! ```

// reason: this builds a few lines of text at a time; `push_str(&format!(..))` reads as the
// line it writes.
#![allow(clippy::format_push_string)]

use super::names::{camel, snake, spoken};
use super::{Matched, Parser, Scope, Step};
use crate::build::{naming, query_derive, read_model as build_read_model};
use crate::diag::ParseResult;
use crate::ir;

impl Parser<'_> {
    /// Reads one `Report:` block into the read model it describes.
    pub(super) fn report(&mut self, header: &Matched) -> ParseResult<ir::ReadModel> {
        let name = camel(&header.text_of("name"));
        let mut model = ir::ReadModel {
            name: name.clone(),
            query_name: naming::snake(&name),
            ..Default::default()
        };
        let mut includes: Vec<(String, Option<String>)> = Vec::new();
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Report", true)? {
            match step {
                Step::Prose { text } => model.description = Some(text),
                Step::Phrase(m) => self.report_line(&m, &mut model, &mut includes)?,
            }
        }
        if includes.is_empty() && model.reference_target.is_none() {
            return Err(self.error(
                header.line,
                header.base_col,
                format!("{} needs something to report on: add `It includes a <thing>` or `It is about a <thing>`", spoken(&name)),
            ));
        }
        model.aggregate_heads = build_read_model::aggregate_heads(
            self.file,
            header.line,
            &name,
            &includes,
            model.reference_target.as_deref(),
        )
        .map_err(|refused| self.error(header.line, header.base_col, refused.message))?;
        Ok(model)
    }

    fn report_line(
        &self,
        m: &Matched,
        model: &mut ir::ReadModel,
        includes: &mut Vec<(String, Option<String>)>,
    ) -> ParseResult<()> {
        let field = |slot: &str| snake(&m.text_of(slot));
        match m.id {
            "includes" | "includes_as" => {
                let alias = (m.id == "includes_as").then(|| field("as"));
                includes.push((camel(&m.text_of("name")), alias));
            }
            "about" | "about_as" => {
                let target = camel(&m.text_of("target"));
                model.reference_name = Some(if m.id == "about_as" { field("as") } else { naming::snake(&target) });
                model.reference_target = Some(target);
            }
            "groups" => model.group_by = m.capture("fields").items.iter().map(|item| snake(item)).collect(),
            "counts" => model.count = true,
            "sums" => model.sum_field = Some(field("field")),
            "averages" => model.avg_field = Some(field("field")),
            "lowest" => model.min_field = Some(field("field")),
            "highest" => model.max_field = Some(field("field")),
            "median" => model.median_field = Some(field("field")),
            "percentile" => {
                model.percentile_field = Some(field("field"));
                model.percentile_at = Some(m.text_of("at"));
            }
            "any_holds" => model.any_field = Some(field("field")),
            "all_hold" => model.all_field = Some(field("field")),
            "report_where" => {
                let cond = self.condition(m)?;
                let (Some(on), Some(value)) = (cond.field, cond.value) else {
                    return Err(self.error(
                        m.line,
                        m.col_of("condition"),
                        "a Where compares a field with a value, like `Where the status is paid`",
                    ));
                };
                model
                    .wheres
                    .extend(query_derive::where_clauses(&[(on.name, format!("\"{value}\""))], None));
            }
            "report_order" => {
                let direction = match m.text_of("direction").to_lowercase().as_str() {
                    "ascending" | "asc" => "asc",
                    "descending" | "desc" => "desc",
                    other => {
                        return Err(self.error(
                            m.line,
                            m.col_of("direction"),
                            format!("'{other}' is not a direction; use ascending or descending"),
                        ));
                    }
                };
                model.order_by = Some(ir::OrderBy {
                    field: m.text_of("path"),
                    direction: direction.to_string(),
                    target: None,
                });
            }
            "report_limit" => {
                model.limit = Some(ir::LimitSpec {
                    value: m.text_of("n"),
                    target: None,
                });
            }
            _ if self.paging_option(m, &mut model.options)? => {}
            _ => return Err(self.unmeant(m)),
        }
        Ok(())
    }
}

/// A read model as a `Report:` block, or the name of what in it the sentence form cannot say.
pub(super) fn said(model: &ir::ReadModel) -> Result<String, String> {
    let refused = |what: &str| format!("the sentence form has no phrase for {what} in report {}", model.name);
    if model.options.offset.as_ref().is_some_and(|offset| offset.target.is_some()) {
        return Err(refused("this paging option"));
    }
    if model.wheres.iter().any(|clause| clause.target.is_some())
        || model.order_by.as_ref().is_some_and(|order| order.target.is_some())
        || model.limit.as_ref().is_some_and(|limit| limit.target.is_some())
    {
        return Err(refused("a clause aimed at one included aggregate"));
    }
    let mut out = format!("\nReport: {}\n", super::format::spoken_title(&model.name));
    if let Some(description) = &model.description {
        out.push_str(&format!("  {description}\n"));
    }
    out.push_str(&heads_said(model, &refused)?);
    if !model.group_by.is_empty() {
        let fields: Vec<String> = model.group_by.iter().map(|f| spoken(f)).collect();
        out.push_str(&format!("  It groups by {}\n", super::format::join_and(&fields)));
    }
    if model.count {
        out.push_str("  It counts them\n");
    }
    let measures = [
        (&model.sum_field, "It adds up the", ""),
        (&model.avg_field, "It averages the", ""),
        (&model.min_field, "It finds the lowest", ""),
        (&model.max_field, "It finds the highest", ""),
        (&model.median_field, "It finds the median", ""),
        (&model.any_field, "It checks if any", " holds"),
        (&model.all_field, "It checks if all", " hold"),
    ];
    for (field, lead, tail) in measures {
        if let Some(field) = field {
            out.push_str(&format!("  {lead} {}{tail}\n", spoken(field)));
        }
    }
    match (&model.percentile_field, &model.percentile_at) {
        (Some(field), Some(at)) if !at.contains('"') => {
            out.push_str(&format!("  It finds the \"{at}\" percentile of the {}\n", spoken(field)));
        }
        (None, None) => {}
        _ => return Err(refused("this percentile")),
    }
    for clause in &model.wheres {
        let value = clause
            .value
            .strip_prefix('"')
            .and_then(|rest| rest.strip_suffix('"'))
            .filter(|value| clause.op == "eq" && super::format::is_word(value) && clause.field.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '_' | '.' | '/')))
            .ok_or_else(|| refused("this filter"))?;
        out.push_str(&format!("  Where the {} is {value}\n", spoken(&clause.field)));
    }
    if let Some(order) = &model.order_by {
        let direction = if order.direction == "desc" { "descending" } else { "ascending" };
        out.push_str(&format!("  Ordered by {}, {direction}\n", order.field));
    }
    if let Some(limit) = &model.limit {
        if limit.value.is_empty() || !limit.value.chars().all(|c| c.is_ascii_digit()) {
            return Err(refused("this limit"));
        }
        out.push_str(&format!("  Limited to {}\n", limit.value));
    }
    out.push_str(&super::queries::paging_said(&model.options, "  ").map_err(refused)?);
    Ok(out)
}

/// The `It includes …` and `It is about …` lines, each with its `as` when the name is not the
/// default.
fn heads_said(model: &ir::ReadModel, refused: &dyn Fn(&str) -> String) -> Result<String, String> {
    let mut out = String::new();
    if let Some(target) = &model.reference_target {
        let default = naming::snake(target);
        let given = model.reference_name.as_deref().unwrap_or(&default);
        let article = super::format::with_article(&spoken(target));
        if given == default {
            out.push_str(&format!("  It is about {article}\n"));
        } else {
            out.push_str(&format!("  It is about {article} as the {}\n", spoken(given)));
        }
    }
    for head in &model.aggregate_heads {
        let default = if head.many { naming::plural(&naming::snake(&head.aggregate)) } else { naming::snake(&head.aggregate) };
        let article = super::format::with_article(&spoken(&head.aggregate));
        if head.as_name == default {
            out.push_str(&format!("  It includes {article}\n"));
        } else {
            out.push_str(&format!("  It includes {article} as the {}\n", spoken(&head.as_name)));
        }
    }
    if model.aggregate_heads.is_empty() && model.reference_target.is_none() {
        return Err(refused("no aggregate"));
    }
    Ok(out)
}
