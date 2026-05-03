/// Sweep source on a `DispatchSpec` (i221-A). Splits the qualified
/// `"Aggregate.query_name"` literal declared via `for_each: { from:
/// "..." }` into the two structured halves. The runtime reads
/// `Aggregate.query_name()` at dispatch time and re-fires the
/// receiving command once per returned record.
