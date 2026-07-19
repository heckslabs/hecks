//! storehouse_rb — the THIN in-process Ruby <-> Rust binding (projection target).
//!
//! Ruby loads this compiled cdylib and calls `storehouse::embed` IN-PROCESS —
//! no subprocess spawn, no localhost HTTP. The binding does exactly three
//! things per call:
//!   1. Ruby args -> (root, command, HashMap<String,String>, Principal)
//!   2. call `embed::dispatch_once` / `embed::query_once` (already panic-safe;
//!      it catches every load/parse/dispatch panic and returns {ok:false,error}
//!      rather than unwinding into the Ruby VM)
//!   3. serde_json::Value -> Ruby value (recursive: Object->Hash, Array->Array,
//!      String/Bool/Number/Null -> the Ruby equivalent).
//!
//! The SOURCE lives in the hecks tree; the consumer app only ever receives the
//! compiled artifact — bin/project-storehouse builds this crate and drops the
//! .bundle into <app>/vendor/storehouse/. The app carries NO source/build
//! reference back here (the standalone rule, 2026-07-03).
//!
//! Composition root: `#[magnus::init]` registers the sqlite persistence
//! adapter (mirroring cli/main.rs) BEFORE any dispatch — an embedder registers
//! the wired adapters it wants; without this, a hecksagon `adapter :sqlite`
//! would be skipped silently and aggregates would stay on heki.
//!
//! The gate lives in the runtime, not here: a nil `auth` stamps Principal::System
//! (admitted by origin); a non-nil `auth` stamps Principal::Agent{auth_identity_id},
//! which the standing authorize (PDP) gate resolves to a role and evaluates
//! against the Policy rule set (deny-by-default, forbid-override).
//!
//! Usage (Ruby):
//!   require_relative "vendor/storehouse/storehouse_rb"
//!   StorehouseRb.dispatch(root, "Pizzas::Pizza.CreatePizza",
//!     {"name"=>"Margherita","description"=>"Classic","price"=>"1200"}, "alice")
//!   #=> {"ok"=>true, "aggregate_type"=>"Pizza", "aggregate_id"=>"1", ...}

use std::collections::HashMap;

use magnus::r_hash::ForEach;
use magnus::{function, prelude::*, Error, IntoValue, RArray, RHash, Ruby, Value};

use storehouse::embed::{self, Principal};

/// Stringify every key/value of a Ruby Hash into a `HashMap<String,String>` by
/// sending `to_s` to each — the universal Ruby stringifier, so an Integer or
/// Symbol value arrives as its string form (the CLI/HTTP door's attrs are always
/// stringly-typed on the wire).
fn rhash_to_string_map(attrs: RHash) -> Result<HashMap<String, String>, Error> {
    let mut map = HashMap::new();
    attrs.foreach(|k: Value, v: Value| {
        let ks: String = k.funcall("to_s", ())?;
        let vs: String = v.funcall("to_s", ())?;
        map.insert(ks, vs);
        Ok(ForEach::Continue)
    })?;
    Ok(map)
}

/// nil `auth` -> System (admitted by origin); a name -> Agent (RBAC-resolved).
fn principal_of(auth: Option<String>) -> Principal {
    match auth {
        Some(id) if !id.is_empty() => Principal::Agent { auth_identity_id: id },
        _ => Principal::System,
    }
}

/// Recursively convert a serde_json value into a Ruby value. Object -> Hash,
/// Array -> Array, and each scalar to its Ruby equivalent. The Ruby handle is
/// the allocation context for the new String / Hash / Array objects.
fn json_to_ruby(ruby: &Ruby, v: &serde_json::Value) -> Result<Value, Error> {
    Ok(match v {
        serde_json::Value::Null => ruby.qnil().as_value(),
        serde_json::Value::Bool(b) => b.into_value_with(ruby),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.into_value_with(ruby)
            } else if let Some(u) = n.as_u64() {
                u.into_value_with(ruby)
            } else {
                n.as_f64().unwrap_or(0.0).into_value_with(ruby)
            }
        }
        serde_json::Value::String(s) => s.as_str().into_value_with(ruby),
        serde_json::Value::Array(items) => {
            let arr = RArray::new();
            for item in items {
                arr.push(json_to_ruby(ruby, item)?)?;
            }
            arr.as_value()
        }
        serde_json::Value::Object(map) => {
            let hash = RHash::new();
            for (k, val) in map {
                hash.aset(k.as_str(), json_to_ruby(ruby, val)?)?;
            }
            hash.as_value()
        }
    })
}

/// Convert the embed verdict (always a JSON object at the top level — the
/// `{ok,...}` door shape) into a Ruby Hash.
fn value_to_rhash(ruby: &Ruby, v: serde_json::Value) -> Result<RHash, Error> {
    let ruby_val = json_to_ruby(ruby, &v)?;
    RHash::from_value(ruby_val).ok_or_else(|| {
        Error::new(
            ruby.exception_runtime_error(),
            "storehouse_rb: embed did not return a JSON object",
        )
    })
}

/// Dispatch one command against `root` in-process. Thin wrapper over
/// `embed::dispatch_once` — boots a persistence-backed runtime, stamps the
/// principal, runs the governed gate, dispatches, settles the cascade, and
/// returns the `{ok,...}` verdict as a Ruby Hash. Never unwinds into Ruby:
/// embed is panic-safe and returns `{ok:false,error}` on any internal panic.
fn dispatch(
    ruby: &Ruby,
    root: String,
    command: String,
    attrs: RHash,
    auth: Option<String>,
) -> Result<RHash, Error> {
    let attrs = rhash_to_string_map(attrs)?;
    let verdict = embed::dispatch_once(&root, &command, attrs, principal_of(auth));
    value_to_rhash(ruby, verdict)
}

/// Resolve one read-only query against `root` in-process. Same boot + gate as
/// [`dispatch`], returning the query's JSON result as a Ruby Hash.
fn query(
    ruby: &Ruby,
    root: String,
    query: String,
    params: RHash,
    auth: Option<String>,
) -> Result<RHash, Error> {
    let params = rhash_to_string_map(params)?;
    let result = embed::query_once(&root, &query, params, principal_of(auth));
    value_to_rhash(ruby, result)
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    // The composition root — the ONE place wired adapters register in this
    // process (mirror of cli/main.rs). Must run before any dispatch, or a
    // hecksagon `adapter :sqlite` is skipped silently (heki fallback).
    storehouse_sqlite::register();

    let module = ruby.define_module("StorehouseRb")?;
    module.define_module_function("dispatch", function!(dispatch, 4))?;
    module.define_module_function("query", function!(query, 4))?;
    Ok(())
}
