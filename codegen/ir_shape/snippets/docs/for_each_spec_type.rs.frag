/// Sweep source on a `DispatchSpec` (i221-A). Splits the qualified
/// `"Aggregate.query_name"` literal declared via `for_each: { from:
/// "..." }` into the structured halves. The runtime reads
/// `Aggregate.query_name()` at dispatch time and re-fires the
/// receiving command once per returned record.
///
/// Two qualified forms accepted :
///   "Aggregate.query_name"            — 2-part (back-compat) ;
///                                       `source_context` is `None`
///   "Context.Aggregate.query_name"    — 3-part, disambiguates when
///                                       multiple bluebooks declare
///                                       the same aggregate name (i142
///                                       Context.Aggregate.Command
///                                       resolution applied to query
///                                       lookups too)
