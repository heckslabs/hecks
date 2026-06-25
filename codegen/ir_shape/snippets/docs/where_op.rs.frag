/// Filter operator for a WhereClause. Eq / Ne are the canonical pair
/// (handles `where(field: value)` and `where(field: { ne: value })`) ;
/// Gt / Gte / Lt / Lte cover ordered comparisons against numeric or
/// string fields. The runtime parses the value side as a literal or
/// kwarg-ref and applies the op to each candidate record. In tests
/// list membership : the record field must equal one element of a
/// literal list (`where field: { in: [a, b] }`). (i101)
