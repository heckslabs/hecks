    /// Remove an element from a list field — `then_set :deps, remove: :dep`.
    /// The inverse of `Append` : resolves `value` and drops every matching
    /// element from the list (retain not-equal). The command carries ONLY the
    /// element, never the whole list, so a remove never read-modify-writes the
    /// list — killing the lost-update hazard the full-replacement pattern had.
