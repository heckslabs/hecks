//! The host as a library: the modules the `bootstrap` binary boots, plus the harness binaries' shared code.
//! Commerce (payments, checkout, newsletter, registrations, mail) plugs in through [`extension::HostExtension`].

pub use rust_host_core::{
    arg_limits, clock, dispatch, expr_json, field_hints, hecks_naming, host, ir, journal,
    lambda_client, log, needs, plugins, presentation, presentation_write, query_step,
    reference_transform, reference_validate, storage_shape, ui_schema, validation, wasm_runner,
};

pub mod api;
pub mod auth;
pub mod aws_lambda_invoker;
mod b64;
pub mod boot;
pub mod checkout;
pub mod commerce_ir;
mod crypto;
#[cfg(test)]
mod dispatch_tests;
#[cfg(test)]
#[path = "boundary_fuzz/expr_json.rs"]
pub mod expr_json_fuzz;
pub mod extension;
#[cfg(test)]
pub mod fuzz_support;
#[cfg(test)]
mod hecksagon_boundary_tests;
mod http;
#[cfg(test)]
#[path = "boundary_fuzz/ir.rs"]
mod ir_fuzz;
pub mod ledger;
pub mod payments;
pub mod platform_signin;
#[cfg(test)]
mod presentation_tests;
pub mod rate_limit;
pub mod resend;
pub mod secrets;
pub mod server;
pub mod store;
#[cfg(test)]
mod store_conformance;
#[cfg(test)]
pub mod test_pg;
pub mod web;
