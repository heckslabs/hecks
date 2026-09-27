//! Derives `WhereClause`s from a query's `where` arguments, splitting `{gte: 100}` comparators
//! and defaulting a bare value to `eq`.

use crate::ir;
use crate::ruby_value;

/// Splits each `(field, raw-value)` pair into a `WhereClause`; a bare value implies `eq`.
/// `target` (ADR 0055's `on:`, already resolved and demodulised by the caller) applies to
/// every clause this one `where` call declares — `None` in Query context, or when a ReadModel's
/// `where` left `on:` off.
pub fn where_clauses(pairs: &[(String, String)], target: Option<&str>) -> Vec<ir::WhereClause> {
    pairs
        .iter()
        .map(|(field, raw)| {
            let trimmed = raw.trim();
            let (op, operand_raw) = split_comparator(trimmed);
            let value = ruby_value::render(&ruby_value::read(operand_raw));
            ir::WhereClause {
                field: field.clone(),
                op,
                value,
                target: target.map(str::to_string),
            }
        })
        .collect()
}

/// Refuses `on:` on a Query's `where` — ADR 0055 scopes `on:` to ReadModel only (a plain `query`
/// has no many-side heads for it to disambiguate between), so this stays a permanent refusal
/// there, not a not-yet-ported one.
///
/// `where` accepts arbitrary field names as named arguments, so an `on:` target would otherwise
/// misparse as a comparison on a field called "on".
pub fn refuse_on_target(
    file: &str,
    line: usize,
    word: &str,
    named: &[(String, String)],
) -> crate::diag::ParseResult<()> {
    if named.iter().any(|(name, _)| name == "on") {
        return Err(crate::diag::Diagnostic::not_yet_implemented(
            file,
            line,
            format!("{word}(on: ...) — per-target read-model filtering (ADR 0055)"),
        ));
    }
    Ok(())
}

fn split_comparator(raw: &str) -> (String, &str) {
    if raw.starts_with('{') && raw.ends_with('}') {
        let inner = raw[1..raw.len() - 1].trim();
        if let Some((op, operand)) = crate::parse::as_named(inner) {
            return (op.to_string(), operand);
        }
    }
    ("eq".to_string(), raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_an_on_target_cleanly_instead_of_silently_dropping_or_misparsing_it() {
        let named = vec![("on".to_string(), "Character".to_string())];
        let err = refuse_on_target("f.bluebook", 3, "where", &named).unwrap_err();
        assert!(err.message.contains("on: ...) — per-target read-model filtering (ADR 0055)"));
        assert_eq!(err.file, "f.bluebook");
        assert_eq!(err.line, 3);
    }
}
