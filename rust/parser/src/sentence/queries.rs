//! A query in sentences: the arguments it takes, the `Where` lines that filter, the order, the
//! limit and what it returns.
//!
//! ```text
//! Query: Open For Customer
//!   It takes:
//!     a reference: customer
//!   Where the customer is the reference
//!   Where the status is open
//!   Where the balance is at least 100
//! ```

// reason: this builds a few lines of text at a time; `push_str(&format!(..))` reads as the
// line it writes.
#![allow(clippy::format_push_string)]

use super::lower::{AggState, FieldUse, TypeUse};
use super::names::{camel, snake, spoken};
use super::{Matched, Parser, Scope, Step};
use crate::diag::ParseResult;
use crate::ir;
use crate::ruby_value::{self, Value};

/// The comparison each `Where` phrase says, with the words that follow the field.
const COMPARISONS: [(&str, &str, &str); 7] = [
    ("where_is", "eq", "is"),
    ("where_is_not", "ne", "is not"),
    ("where_over", "gt", "is more than"),
    ("where_at_least", "gte", "is at least"),
    ("where_under", "lt", "is less than"),
    ("where_at_most", "lte", "is at most"),
    ("where_has", "contains", "contains"),
];

/// Words that would start another comparison, so a bare value may not be one of them.
const KEYWORDS: [&str; 7] = ["not", "the", "more", "less", "at", "one", "contains"];

impl Parser<'_> {
    /// Reads one `Query:` block into the query it describes, filing its arguments to be typed.
    pub(super) fn query(&mut self, header: &Matched, st: &mut AggState) -> ParseResult<()> {
        let mut query = ir::Query {
            name: camel(&header.text_of("name")),
            ..Default::default()
        };
        let mut takes: Vec<(ir::Attribute, TypeUse)> = Vec::new();
        let mut where_lines: Vec<Matched> = Vec::new();
        let mut scope = Scope::inside(header.indent);
        while let Some(step) = self.step(&mut scope, "Query", true)? {
            match step {
                Step::Prose { text } => query.description = Some(text),
                Step::Phrase(m) if m.id == "query_takes" => takes.extend(self.attribute_lines(&m)?),
                Step::Phrase(m) if m.id.starts_with("where_") => where_lines.push(m),
                Step::Phrase(m) if m.id == "order" => query.order_by = Some(self.order_of(&m)?),
                Step::Phrase(m) if m.id == "query_limit" => {
                    query.limit = Some(ir::LimitSpec {
                        value: m.text_of("n"),
                        target: None,
                    });
                }
                Step::Phrase(m) if self.paging_option(&m, &mut query.options)? => {}
                Step::Phrase(m) if m.id == "query_returns" => query.returns = Some(camel(&m.text_of("type"))),
                Step::Phrase(m) if m.id == "query_returns_list" => {
                    query.returns = Some(format!("list_of({})", camel(&m.text_of("type"))));
                }
                Step::Phrase(m) => return Err(self.unmeant(&m)),
            }
        }
        let args: Vec<String> = takes.iter().map(|(attribute, _)| attribute.name.clone()).collect();
        for line in &where_lines {
            let clause = self.where_clause(line, &args, st)?;
            query.wheres.push(clause);
        }
        st.query_args.push((st.agg.queries.len(), takes));
        st.agg.queries.push(query);
        Ok(())
    }

    /// Reads a paging or access sentence of a query or a report into `options`; false for any
    /// other.
    pub(super) fn paging_option(&self, m: &Matched, options: &mut ir::QueryOptions) -> ParseResult<bool> {
        match m.id.split_once('_') {
            Some((_, "skip")) => {
                options.offset = Some(ir::OffsetSpec {
                    value: m.text_of("n"),
                    target: None,
                });
            }
            Some((_, "nulls")) => {
                let position = m.text_of("position").to_lowercase();
                if !matches!(position.as_str(), "first" | "last") {
                    return Err(self.error(m.line, m.col_of("position"), "empty values come first or last"));
                }
                options.null_semantics = Some(position);
            }
            Some((_, kind @ ("access" | "access_for"))) => {
                options.authorization = Some(ir::AuthorizationSpec {
                    policy: snake(&m.text_of("policy")),
                    tenant: (kind == "access_for").then(|| snake(&m.text_of("tenant"))),
                });
            }
            Some((_, "inspect")) => options.inspection = Some(m.text_of("mode")),
            Some((_, "cursor")) => options.cursor = Some(format!(":{}", snake(&m.text_of("field")))),
            _ => return Ok(false),
        }
        Ok(true)
    }

    fn order_of(&self, m: &Matched) -> ParseResult<ir::OrderBy> {
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
        Ok(ir::OrderBy {
            field: m.text_of("path"),
            direction: direction.to_string(),
            target: None,
        })
    }

    /// One `Where` line as the clause it filters by.
    fn where_clause(&self, m: &Matched, args: &[String], st: &mut AggState) -> ParseResult<ir::WhereClause> {
        let field = m.text_of("field");
        let named = snake(&field);
        if !named.contains(['/', '.']) {
            st.checks.push(FieldUse {
                name: named.clone(),
                line: m.line,
                col: m.col_of("field"),
            });
        }
        let (op, value) = if m.id == "where_none_in" {
            let held = format!("{}:{}", camel(&m.text_of("aggregate")), m.text_of("state"));
            ("none_in_state", ruby_value::render(&Value::Str(held)))
        } else if m.id == "where_in" {
            ("in", ruby_value::render(&Value::Str(m.capture("values").items.join(","))))
        } else {
            let op = COMPARISONS.iter().find(|(id, ..)| *id == m.id).map_or("eq", |(_, op, _)| op);
            (op, self.where_value(m, args)?)
        };
        Ok(ir::WhereClause {
            field: named,
            op: op.to_string(),
            value,
            target: None,
        })
    }

    /// The Literal-rendered spelling of what a `Where` compares with: quoted text, a number, a bare
    /// word, or `the <argument>`.
    fn where_value(&self, m: &Matched, args: &[String]) -> ParseResult<String> {
        let text = m.text_of("value");
        let col = m.col_of("value");
        if let Some(argument) = text.strip_prefix("the ") {
            let name = snake(argument);
            if !args.contains(&name) {
                let known: Vec<String> = args.iter().map(|arg| spoken(arg)).collect();
                return Err(self.error(
                    m.line,
                    col,
                    format!(
                        "'{}' is not an argument of this query. It takes: {}",
                        argument.trim(),
                        if known.is_empty() { "nothing".to_string() } else { known.join(", ") }
                    ),
                ));
            }
            return Ok(format!(":{name}"));
        }
        match ruby_value::read(&text) {
            value @ (Value::Str(_) | Value::Int(_) | Value::Float(_) | Value::Bool(_)) => Ok(ruby_value::render(&value)),
            _ if text.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-')) && !text.is_empty() => {
                Ok(ruby_value::render(&Value::Str(text)))
            }
            _ => Err(self.error(
                m.line,
                col,
                format!("'{text}' is not a value: write quoted text, a number, a word, or `the <argument>`"),
            )),
        }
    }
}

/// A query as a `Query:` block, or the name of what in it the sentence form cannot say.
pub(super) fn said(query: &ir::Query) -> Result<String, String> {
    let refused = |what: &str| format!("the sentence form has no phrase for {what} in query {}", query.name);
    if query.options.offset.as_ref().is_some_and(|offset| offset.target.is_some()) {
        return Err(refused("this paging option"));
    }
    if !query.needs.is_empty() {
        return Err(refused("what the runtime supplies"));
    }
    let mut out = format!("\n  Query: {}\n", super::format::spoken_title(&query.name));
    if let Some(description) = &query.description {
        out.push_str(&format!("    {description}\n"));
    }
    if !query.attributes.is_empty() {
        out.push_str("    It takes:\n");
        for attribute in &query.attributes {
            out.push_str(&format!("      {}\n", super::format::attribute_line(attribute)?));
        }
    }
    for clause in &query.wheres {
        out.push_str(&format!("    {}\n", clause_said(clause).ok_or_else(|| refused("this filter"))?));
    }
    if let Some(order) = &query.order_by {
        if order.target.is_some() {
            return Err(refused("an order aimed at one included aggregate"));
        }
        let direction = if order.direction == "desc" { "descending" } else { "ascending" };
        out.push_str(&format!("    Ordered by {}, {direction}\n", order.field));
    }
    if let Some(limit) = &query.limit {
        if limit.target.is_some() || limit.value.is_empty() || !limit.value.chars().all(|c| c.is_ascii_digit()) {
            return Err(refused("this limit"));
        }
        out.push_str(&format!("    Limited to {}\n", limit.value));
    }
    out.push_str(&paging_said(&query.options, "    ").map_err(refused)?);
    if let Some(returns) = &query.returns {
        out.push_str(&format!("    {}\n", returns_said(returns).ok_or_else(|| refused("this return type"))?));
    }
    Ok(out)
}

/// The paging and access sentences of a query or a report, each led by `indent`.
pub(super) fn paging_said(options: &ir::QueryOptions, indent: &str) -> Result<String, &'static str> {
    let mut out = String::new();
    if let Some(offset) = &options.offset {
        if offset.value.is_empty() || !offset.value.chars().all(|c| c.is_ascii_digit()) {
            return Err("this offset");
        }
        out.push_str(&format!("{indent}Skipping the first {}\n", offset.value));
    }
    if let Some(position) = &options.null_semantics {
        if !matches!(position.as_str(), "first" | "last") {
            return Err("this way of placing empty values");
        }
        out.push_str(&format!("{indent}Empty values come {position}\n"));
    }
    if let Some(access) = &options.authorization {
        if !super::format::is_name(&access.policy) || access.tenant.as_deref().is_some_and(|t| !super::format::is_name(t)) {
            return Err("this access check");
        }
        match &access.tenant {
            Some(tenant) => out.push_str(&format!("{indent}Access is checked by {} for each {}\n", spoken(&access.policy), spoken(tenant))),
            None => out.push_str(&format!("{indent}Access is checked by {}\n", spoken(&access.policy))),
        }
    }
    if let Some(cursor) = &options.cursor {
        let field = cursor.strip_prefix(':').filter(|field| super::format::is_name(field)).ok_or("this cursor")?;
        out.push_str(&format!("{indent}A caller walks it a page at a time by the {}\n", spoken(field)));
    }
    if let Some(mode) = &options.inspection {
        if !super::format::is_word(mode) {
            return Err("this inspection");
        }
        out.push_str(&format!("{indent}It can be inspected as {mode}\n"));
    }
    Ok(out)
}

/// `It returns doubling` or `It returns list of doubling` for `Doubling` and `list_of(Doubling)`.
fn returns_said(returns: &str) -> Option<String> {
    let simple = |name: &str| !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric());
    match returns.strip_prefix("list_of(").and_then(|rest| rest.strip_suffix(')')) {
        Some(name) if simple(name) => Some(format!("It returns list of {}", spoken(name))),
        Some(_) => None,
        None if simple(returns) => Some(format!("It returns {}", spoken(returns))),
        None => None,
    }
}

/// One clause as its `Where` sentence, or nothing when no phrase says that comparison.
fn clause_said(clause: &ir::WhereClause) -> Option<String> {
    if clause.target.is_some() || clause.field.is_empty() || clause.field.contains(char::is_whitespace) {
        return None;
    }
    let field = clause.field.replace('_', " ");
    let spoken_field = if clause.field.contains(['/', '.']) { clause.field.clone() } else { field };
    let value = ruby_value::read(&clause.value);
    if clause.op == "in" {
        let Value::Str(joined) = value else { return None };
        let items: Vec<String> = joined.split(',').map(str::to_string).collect();
        if items.iter().any(|item| !super::format::is_listable(item) || item.contains(' ')) {
            return None;
        }
        return Some(format!("Where the {spoken_field} is one of {}", super::format::join_and(&items)));
    }
    if clause.op == "none_in_state" {
        let Value::Str(held) = value else { return None };
        let (aggregate, state) = held.split_once(':')?;
        let simple = |name: &str| !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
        if !simple(aggregate) || !simple(state) {
            return None;
        }
        return Some(format!("Where the {spoken_field} has no {} in {state}", spoken(aggregate)));
    }
    let (_, _, words) = COMPARISONS.iter().find(|(_, op, _)| *op == clause.op)?;
    let tail = match value {
        Value::Symbol(name) => format!("the {}", spoken(&name)),
        Value::Int(_) | Value::Float(_) => ruby_value::render(&value),
        Value::Str(text) => text_said(&text)?,
        _ => return None,
    };
    Some(format!("Where the {spoken_field} {words} {tail}"))
}

/// A text value: bare when a plain word that reads back as text, else quoted.
fn text_said(text: &str) -> Option<String> {
    if text.contains('"') {
        return None;
    }
    let plain = super::format::is_word(text)
        && !matches!(ruby_value::read(text), Value::Int(_) | Value::Float(_) | Value::Bool(_) | Value::Nil)
        && !KEYWORDS.contains(&text);
    Some(if plain { text.to_string() } else { format!("\"{text}\"") })
}
