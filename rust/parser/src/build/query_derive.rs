//! Mirrors a query's `where` comparator splitting — `where(balance: {gte:
//! 100}, status: "open")` is TWO `WhereClause`s from one line
//! (`PairsShape::elements` — each pair independently becomes a new
//! compound, appended to `wheres`), and a bare value (`status: "open"`)
//! implies the `eq` comparator rather than spelling it. Also covers
//! `sets`' four named forms choosing `Mutation#op` (`Argument#selects`,
//! format `"op=increment"` etc.) — the analogous "which named argument
//! fired chooses a value for another field" derivation on the Command
//! side, grouped here rather than in a separate module since both read
//! the same `selects` column.

use crate::ir;
use crate::ruby_value;

/// `QuerySpecification::Common::DSL#where`'s `split_comparator` —
/// `where(status: "available")` implies `eq` (the bare value itself is
/// the operand); `where(:"pizza.price_cents.cents" => { lt: :ceiling })`
/// names the comparator explicitly, one `{comparator: operand}` pair.
/// `pairs` here is already the (field, raw-value-text) list
/// `parse::mod`'s own `argument_gate_named_pairs` extracted (both the
/// `identifier: value` and the hash-rocket `:"a.b" => value` spellings
/// already folded into one shape by that point) — each becomes its own
/// `WhereClause`, exactly the "one line, several compounds" shape
/// `where(balance: {gte: 100}, status: "open")` needs.
pub fn where_clauses(pairs: &[(String, String)]) -> Vec<ir::WhereClause> {
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
            }
        })
        .collect()
}

/// `where`/`order_by`/`limit`/`offset` are gaining an `on:` target kwarg
/// on the Ruby side (ADR 0055, `docs/decisions/0055-read-model-on-target-
/// for-where-order-by-limit-offset.md` — shipped Ruby-only; naming WHICH
/// many-side `include` an option applies to, once a read model declares
/// more than one) — deliberately not yet ported here (that ADR's own item
/// 3: this parser has no concept of `on:` at all yet).
///
/// Only `where` actually needs this check. `order_by`/`limit`/`offset`
/// each have a FIXED, declared argument schema (`ArgumentRow`s per
/// `(word, context)`), so `validate_named` (`parse/mod.rs`) already
/// refuses an undeclared `on:` upstream, before either construct's own
/// `parse_body` match arm ever runs — confirmed live ("'order_by' takes
/// no 'on:' argument", etc.), so adding this check there too would be
/// dead code. `where`'s own pairs-splitting (above) is structurally
/// exempt from that per-name schema check — it has to accept an
/// arbitrary field name as a named argument, that's the whole point of
/// `where(any_field: value)` — so nothing upstream stops `on: Character`
/// from silently MISPARSING as a second where-clause comparing a field
/// literally named "on". Exactly the "failed open" shape `diag.rs`'s own
/// header names as the one thing this crate never allows — refusing
/// cleanly here instead, until the real port lands.
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
    fn implies_eq_for_a_bare_value() {
        let clauses = where_clauses(&[("status".to_string(), "\"available\"".to_string())]);
        assert_eq!(clauses[0].op, "eq");
        assert_eq!(clauses[0].value, "\"available\"");
    }

    #[test]
    fn reads_an_explicit_comparator_hash() {
        let clauses = where_clauses(&[(
            "pizza.price_cents.cents".to_string(),
            "{ lt: :ceiling }".to_string(),
        )]);
        assert_eq!(clauses[0].op, "lt");
        assert_eq!(clauses[0].value, ":ceiling");
    }

    #[test]
    fn reads_a_number_comparator_operand() {
        let clauses = where_clauses(&[(
            "pizza.price_cents.cents".to_string(),
            "{ gt: 1000 }".to_string(),
        )]);
        assert_eq!(clauses[0].op, "gt");
        assert_eq!(clauses[0].value, "1000");
    }

    #[test]
    fn refuses_an_on_target_cleanly_instead_of_silently_dropping_or_misparsing_it() {
        let named = vec![("on".to_string(), "Character".to_string())];
        let err = refuse_on_target("f.bluebook", 3, "where", &named).unwrap_err();
        assert!(err.message.contains("on: ...) — per-target read-model filtering (ADR 0055)"));
        assert_eq!(err.file, "f.bluebook");
        assert_eq!(err.line, 3);
    }

    #[test]
    fn passes_through_named_args_that_are_not_on() {
        let named = vec![("status".to_string(), "\"available\"".to_string())];
        assert!(refuse_on_target("f.bluebook", 3, "where", &named).is_ok());
    }
}
