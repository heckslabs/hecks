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

#[cfg(test)]
mod tests {
    // Stage 2+, once parse/query.rs and parse/command.rs call into this
    // module for real.
}
