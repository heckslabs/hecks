
/// Emits soft validator warnings to stderr — advisories, never failures.
///
/// Wires the four functions in `validator_warnings.rs` (the bluebook-declared
/// rules from `capabilities/validator_warnings_shape/`) into the dispatch arms
/// that touch a parsed Domain. Stays on stderr so parity tests and pipelines
/// keep reading clean stdout.
fn emit_validator_warnings_to_stderr(domain: &storehouse::ir::Domain) {
    if let Some(msg) = validator_warnings::aggregate_count_warning(domain)   { eprintln!("{}", msg); }
    if let Some(msg) = validator_warnings::multi_domain_split_warning(domain) { eprintln!("{}", msg); }
    if let Some(msg) = validator_warnings::mixed_concerns_warning(domain)    { eprintln!("{}", msg); }
    if let Some(msg) = validator_warnings::bluebook_size_warning(domain)     { eprintln!("{}", msg); }
}
