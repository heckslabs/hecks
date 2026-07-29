pub mod adapters;
pub mod bluebook;
pub mod ports;
pub mod projector;
pub mod runtime;

#[allow(dead_code)]
pub mod clock;
pub mod fqn;
pub mod naming;
#[allow(dead_code)]
pub mod util;

// Re-exported so the macros below can build payload values for callers without
// requiring every application to name serde_json itself.
pub use serde_json;

pub use adapters::driven::heki;

pub use bluebook::hecksagon_helpers;
pub use bluebook::hecksagon_ir;
pub use bluebook::hecksagon_parser;
pub use bluebook::ir;
pub use bluebook::parse_blocks;
pub use bluebook::parser;
pub use bluebook::parser_helpers;
pub use bluebook::pattern_subset;
pub use bluebook::world;

pub use bluebook::expression::evaluator as interp_givens;
pub use bluebook::expression::resolver as interp_expr;
pub use runtime::dispatcher;
pub use runtime::mutations as interp_mutations;
pub use runtime::value_bridge;

pub use bluebook::router::{boot, dispatch, dispatch_short, query, query_short, Router};
pub use projector::dump;
pub use projector::ir_json;

/// Dispatch a command through the process router without exposing either a
/// router value or a JSON payload map.
///
/// `command!(Examples::Banking::Account::Open, { account_id: 2312 })`
/// resolves to `Examples::Banking::Account.Open` at runtime.
#[macro_export]
macro_rules! command {
    (options(version: $version:expr), $path:path, { $($field:ident : $value:expr),* $(,)? }) => {{
        #[allow(unused_mut)]
        let mut args = $crate::serde_json::Map::new();
        $(
            args.insert(
                stringify!($field).to_string(),
                $crate::serde_json::to_value($value)
                    .expect(concat!("cannot serialize command field ", stringify!($field))),
            );
        )*
        let version = format!("{}", $version);
        $crate::bluebook::router::dispatch_rust_path_with_version(stringify!($path), &version, &args)
    }};
    ($path:path, { $($field:ident : $value:expr),* $(,)? }) => {{
        #[allow(unused_mut)]
        let mut args = $crate::serde_json::Map::new();
        $(
            args.insert(
                stringify!($field).to_string(),
                $crate::serde_json::to_value($value)
                    .expect(concat!("cannot serialize command field ", stringify!($field))),
            );
        )*
        $crate::bluebook::router::dispatch_rust_path(stringify!($path), &args)
    }};
}

/// Query through the process router without exposing either a router value or
/// a JSON payload map.
#[macro_export]
macro_rules! query {
    (options(version: $version:expr), $path:path, { $($field:ident : $value:expr),* $(,)? }) => {{
        #[allow(unused_mut)]
        let mut args = $crate::serde_json::Map::new();
        $(
            args.insert(
                stringify!($field).to_string(),
                $crate::serde_json::to_value($value)
                    .expect(concat!("cannot serialize query field ", stringify!($field))),
            );
        )*
        let version = format!("{}", $version);
        $crate::bluebook::router::query_rust_path_with_version(stringify!($path), &version, &args)
    }};
    ($path:path, { $($field:ident : $value:expr),* $(,)? }) => {{
        #[allow(unused_mut)]
        let mut args = $crate::serde_json::Map::new();
        $(
            args.insert(
                stringify!($field).to_string(),
                $crate::serde_json::to_value($value)
                    .expect(concat!("cannot serialize query field ", stringify!($field))),
            );
        )*
        $crate::bluebook::router::query_rust_path(stringify!($path), &args)
    }};
}
