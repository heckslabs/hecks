//! The host as a library: the modules the `bootstrap` binary boots, plus the harness binaries' shared code.
//! Commerce (payments, checkout, newsletter, registrations, mail) plugs in through [`extension::HostExtension`].

pub mod api;
pub mod approval;
pub mod auth;
pub mod checkout;
pub mod dispatch;
pub mod expr_json;
pub mod extension;
pub mod field_hints;
#[cfg(test)]
pub mod fuzz_support;
#[cfg(test)]
#[path = "boundary_fuzz/expr_json.rs"]
pub mod expr_json_fuzz;
pub mod ir;
pub mod journal;
pub mod lambda_client;
pub mod log;
pub mod mint;
pub mod needs;
pub mod payments;
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
