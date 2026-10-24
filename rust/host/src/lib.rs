//! The host as a library: the modules the `bootstrap` binary boots, plus the harness binaries' shared code.
//! Commerce (payments, checkout, newsletter, registrations, mail) plugs in through [`extension::HostExtension`].

pub mod api;
pub mod arg_limits;
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
// The one `Hecks::Naming` port, compiled from `hecks-codegen`'s source: the host and the codegen
// are independent Cargo projects, so the file is shared by path rather than by dependency.
#[allow(dead_code)]
#[path = "../../codegen/src/hecks_naming.rs"]
pub mod hecks_naming;
pub mod ir;
pub mod journal;
pub mod lambda_client;
pub mod log;
pub mod mint;
pub mod needs;
pub mod payments;
pub mod platform_signin;
pub mod plugins;
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
mod store_conformance;
#[cfg(test)]
pub mod test_pg;
pub mod ui_schema;
pub mod wasm_runner;
pub mod web;
