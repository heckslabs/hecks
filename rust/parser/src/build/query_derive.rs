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
}
