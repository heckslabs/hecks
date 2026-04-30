/// The list of targets recognized by `specializer::emit`. Kept as a
/// static array so the query is pure ; a unit test in this module
/// asserts the array matches the actual `emit` arms (see
/// `specializer_targets_match_emit_dispatch_table`).
