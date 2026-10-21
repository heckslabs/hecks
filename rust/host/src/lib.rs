//! The host as a library: the modules the `bootstrap` binary boots, plus the harness binaries' shared code.
//! Commerce (payments, checkout, newsletter, registrations, mail) plugs in through [`extension::HostExtension`].

pub mod api;
pub mod approval;
pub mod auth;
mod b64;
pub mod boot;
pub mod checkout;
mod clock;
pub mod commerce_ir;
mod crypto;
pub mod dispatch;
pub mod expr_json;
#[cfg(test)]
#[path = "boundary_fuzz/expr_json.rs"]
pub mod expr_json_fuzz;
pub mod extension;
mod http;
// Generated: its static regexes are literals that compile, and the generator always emits
// `r#"…"#`, so the lints below are allowed here.
#[allow(clippy::expect_used, clippy::needless_raw_string_hashes)]
pub mod field_hints;
#[cfg(test)]
pub mod fuzz_support;
pub mod host;
pub mod ir;
pub mod journal;
pub mod lambda_client;
pub mod log;
pub mod mint;
pub mod needs;
pub mod payments;
pub mod platform_signin;
pub mod presentation;
pub mod presentation_write;
pub mod query_step;
pub mod rate_limit;
pub mod reference_transform;
pub mod reference_validate;
pub mod resend;
pub mod secrets;
pub mod server;
pub mod storage_shape;
#[cfg(test)]
pub mod test_pg;
pub mod ui_schema;
pub mod wasm_runner;
pub mod web;
