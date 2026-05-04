/// Enum-keyed dispatch for the block_grammar registry (i218).
///
/// Each variant names one block parser kind. The parser's main loop
/// matches on this enum and calls the right typed `parse_*` function ;
/// adding a new keyword = one variant + one match arm + one row in the
/// canonical bluebook grammar.
///
/// Why an enum (not function pointers) : each parse function returns a
/// different IR struct (Aggregate / Policy / Cadence / ...). A function
/// pointer table would need either `Box<dyn Any>` returns or one giant
/// unified return enum ; matching on the kind and pushing into the
/// right Domain Vec is cleaner and zero-cost.
