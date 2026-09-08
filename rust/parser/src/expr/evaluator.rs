//! Port of `evaluator.rb`'s `parse` step only — see `expr/mod.rs`'s own
//! header.

use super::resolver::{self, Resolver};
use super::{top_level_index, Operator, OPERATORS};

#[derive(Debug, Clone)]
pub enum Evaluator {
    Or(Box<Evaluator>, Box<Evaluator>),
    And(Box<Evaluator>, Box<Evaluator>),
    Not(Box<Evaluator>),
    Compare { operator: Operator, left: Resolver, right: Resolver },
    Include { haystack: Resolver, needle: Resolver },
    Resolve(Resolver),
}

pub fn parse(expr: &str) -> Evaluator {
    let expr = super::strip_parens(expr.trim());

    if let Some((left, right)) = split_top_level(&expr, "||") {
        return Evaluator::Or(Box::new(parse(left)), Box::new(parse(right)));
    }
    if let Some((left, right)) = split_top_level(&expr, "&&") {
        return Evaluator::And(Box::new(parse(left)), Box::new(parse(right)));
    }
    if let Some((haystack, needle)) = match_include(&expr) {
        return Evaluator::Include { haystack: resolver::parse(haystack), needle: resolver::parse(needle) };
    }

    for op in OPERATORS.iter() {
        if let Some((left, right)) = split_comparison(&expr, op.symbol) {
            return Evaluator::Compare { operator: *op, left: resolver::parse(left), right: resolver::parse(right) };
        }
    }

    if let Some(inner) = expr.strip_prefix('!') {
        if !inner.is_empty() {
            return Evaluator::Not(Box::new(parse(inner)));
        }
    }

    Evaluator::Resolve(resolver::parse(&expr))
}

fn split_top_level<'a>(expr: &'a str, operator: &str) -> Option<(&'a str, &'a str)> {
    let index = top_level_index(expr, operator, |_| true)?;
    Some((expr[..index].trim(), expr[index + operator.len()..].trim()))
}

fn split_comparison<'a>(expr: &'a str, operator: &str) -> Option<(&'a str, &'a str)> {
    let index = top_level_index(expr, operator, |at| !part_of_longer(expr, at, operator))?;
    Some((expr[..index].trim(), expr[index + operator.len()..].trim()))
}

fn part_of_longer(expr: &str, index: usize, operator: &str) -> bool {
    let bytes = expr.as_bytes();
    let after = bytes.get(index + operator.len()).copied();
    let before = if index > 0 { bytes.get(index - 1).copied() } else { None };

    if after == Some(b'=') && !operator.ends_with('=') {
        return true;
    }
    if let Some(b) = before {
        if (b == b'<' || b == b'>' || b == b'!' || b == b'=') && operator.starts_with('=') {
            return true;
        }
    }
    false
}

/// `expr.rindex(".include?(")` + `end_with?(")")`.
fn match_include(expr: &str) -> Option<(&str, &str)> {
    if !expr.ends_with(')') {
        return None;
    }
    let marker = ".include?(";
    let index = expr.rfind(marker)?;
    Some((&expr[..index], &expr[index + marker.len()..expr.len() - 1]))
}
