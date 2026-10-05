//! The `needs` word, shared by the two declarations that may use it: a command and a query
//! (ADR 0081). Mirrors `Hecks::Bluebook::DSL::NeedWord`.

use crate::diag::{Diagnostic, ParseResult};
use crate::ir;
use crate::parse::ArgumentGateResult;

/// The outside facts a declaration may need, each the name of the attribute the runtime fills;
/// mirrors `NeedWord::NEEDABLE_FACTS`. `now` is the clock port's reading in epoch seconds and
/// `today` the day it falls in, whole days since the epoch in UTC.
const NEEDABLE_FACTS: &[&str] = &["now", "today"];

/// Reads one `needs :fact` line into `needs`.
///
/// Refuses a fact the runtime cannot supply and a fact declared twice, as the Ruby builder does.
pub fn declare(
    file: &str,
    line: usize,
    owner: &str,
    args: &ArgumentGateResult,
    needs: &mut Vec<String>,
) -> ParseResult<()> {
    let fact = super::positional_symbol(file, line, "needs", args, 1)?;
    if !NEEDABLE_FACTS.contains(&fact.as_str()) {
        let supplied: Vec<String> = NEEDABLE_FACTS.iter().map(|known| format!(":{known}")).collect();
        return Err(Diagnostic::new(
            file,
            line,
            format!(
                "{owner} needs :{fact}, which the runtime cannot supply — it supplies {}",
                supplied.join(", ")
            ),
        ));
    }
    if needs.contains(&fact) {
        return Err(Diagnostic::new(file, line, format!("{owner} declares needs :{fact} twice")));
    }
    needs.push(fact);
    Ok(())
}

/// A need names the attribute the runtime fills, so the declaration must have one.
pub fn refuse_undeclared(
    file: &str,
    line: usize,
    owner: &str,
    needs: &[String],
    attributes: &[ir::Attribute],
) -> ParseResult<()> {
    match needs.iter().find(|fact| !attributes.iter().any(|a| &a.name == *fact)) {
        Some(fact) => Err(Diagnostic::new(
            file,
            line,
            format!(
                "{owner} needs :{fact} but declares no attribute :{fact} for the runtime to fill — add `attribute :{fact}, <type>`"
            ),
        )),
        None => Ok(()),
    }
}
