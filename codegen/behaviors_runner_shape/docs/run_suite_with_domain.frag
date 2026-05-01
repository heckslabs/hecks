/// Cross-bluebook-aware variant — pass BOTH the source bluebook and
/// the pre-loaded combined domain. The runner picks per-test which
/// to use : `kind: :cross_cascade` tests get the combined domain so
/// cross-bluebook policy chains fire end-to-end ; all other tests
/// get the isolated source bluebook only (preserving strict emit-
/// list assertions that would break with extra cascades).
///
/// The `domain_template` is cloned per test for state isolation —
/// the IR is read-only but Runtime takes ownership.
