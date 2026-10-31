//! The `audience` word of a command: who a launcher lists it for (ADR 0163). Mirrors
//! `Hecks::Bluebook::DSL::CommandBuilder#audience_impl`.

use crate::diag::{Diagnostic, ParseResult};
use crate::parse::ArgumentGateResult;

/// The audiences a command may be listed for; mirrors `CommandBuilder::AUDIENCES`.
const AUDIENCES: &[&str] = &["person", "agent", "ci", "record"];

/// Reads one `audience :a, :b` line into `audience`.
///
/// Refuses a second declaration, an empty one, a name that is not an audience and a name given
/// twice, as the Ruby builder does.
pub fn declare(
    file: &str,
    line: usize,
    owner: &str,
    args: &ArgumentGateResult,
    audience: &mut Vec<String>,
) -> ParseResult<()> {
    if !audience.is_empty() {
        return Err(Diagnostic::new(
            file,
            line,
            format!("{owner} declares its audience twice"),
        ));
    }
    let mut names = Vec::new();
    for at in 1..=args.positional.len() {
        names.push(super::positional_symbol(file, line, "audience", args, at)?);
    }
    refuse(file, line, owner, &names)?;
    *audience = names;
    Ok(())
}

/// Refuses the names that are not a list of distinct audiences.
fn refuse(file: &str, line: usize, owner: &str, names: &[String]) -> ParseResult<()> {
    let problem = match unknown(names) {
        _ if names.is_empty() => Some(format!("{owner} names no audience")),
        unknown if !unknown.is_empty() => Some(format!(
            "{owner} names {} as an audience; the audiences are {}",
            unknown.join(", "),
            AUDIENCES.join(", ")
        )),
        _ if twice(names) => Some(format!("{owner} names an audience twice")),
        _ => None,
    };
    problem.map_or(Ok(()), |text| Err(Diagnostic::new(file, line, text)))
}

fn unknown(names: &[String]) -> Vec<&str> {
    names
        .iter()
        .map(String::as_str)
        .filter(|name| !AUDIENCES.contains(name))
        .collect()
}

fn twice(names: &[String]) -> bool {
    let mut distinct = names.to_vec();
    distinct.sort();
    distinct.dedup();
    distinct.len() != names.len()
}
