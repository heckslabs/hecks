//! conception_kernel::sample — the SampleValueRule table as DATA.
//!
//! How a type becomes a placeholder literal in synthesized input, setup
//! kwargs, and expect. Pure lookup — a flat table, no algorithm. This is the
//! conception's `SampleValueRule` aggregate (behaviors_conception.bluebook),
//! and the simplest proof that the DATA layer is real and projectable today:
//! the kernel owns it, and `generator.rs` delegates here until it is deleted
//! at the final gate.
//!
//!   Integer -> 1   Float -> 1.0   Boolean -> "true"   String -> "sample"
//!   <VO>    -> "sample_<lowercased type>"   (the catch-all)
//!
//! Usage:
//!   let lit = conception_kernel::sample::sample_value("Integer"); // "1"

/// Resolve an IR attribute type to the sample literal the runtime would store.
/// A verbatim port of generator.rs's `sample_value` — byte-identical output.
pub fn sample_value(t: &str) -> String {
    match t {
        "Integer" => "1".into(),
        "Float" => "1.0".into(),
        "Boolean" => "\"true\"".into(),
        "String" => "\"sample\"".into(),
        _ => format!("\"sample_{}\"", t.to_lowercase()),
    }
}
