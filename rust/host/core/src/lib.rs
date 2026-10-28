//! The host's runtime, free of any driver: dispatch, the journal's data, the [`store::Store`] and
//! its [`store::Backend`] trait, the IR, the expression engine and the presentation code.
//!
//! The adapters crate (`rust_host`) implements the backends and the transports on top of this.
//! Nothing in this crate's dependency table can open a connection or a socket, so a leak of a
//! driver into the runtime is a compile error rather than a convention.

pub mod arg_limits;
pub mod clock;
pub mod dispatch;
pub mod expr_json;
// Generated: its static regexes are literals that compile, and the generator always emits
// `r#"…"#`, so the lints below are allowed here.
#[allow(clippy::expect_used, clippy::needless_raw_string_hashes)]
pub mod field_hints;
pub mod host;
// The one `Hecks::Naming` port, compiled from `hecks-codegen`'s source: the host and the codegen
// are independent Cargo projects, so the file is shared by path rather than by dependency.
#[allow(dead_code)]
#[path = "../../../codegen/src/hecks_naming.rs"]
pub mod hecks_naming;
pub mod ir;
pub mod journal;
pub mod lambda_client;
pub mod log;
pub mod needs;
pub mod plugins;
pub mod presentation;
pub mod presentation_write;
pub mod query_step;
pub mod reference_transform;
pub mod reference_validate;
pub mod storage_shape;
pub mod store;
pub mod ui_schema;
pub mod validation;
pub mod wasm_runner;
