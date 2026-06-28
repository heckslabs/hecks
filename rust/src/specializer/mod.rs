//! Specializer — the framework's compiler-output projection layer.
//!
//! The framework's OWN Rust source is hand-written. The self-projection codegen
//! (parser / validator / ir / runtime / … authored as a .bluebook-of-itself) was
//! retired 2026-06-27 as the catalog/Hecksagon anti-pattern — a .bluebook whose
//! only job is to re-emit imperative Rust captures no domain. The per-deployment
//! emitters (wasm worker, cf proxy, wrangler.toml, embedded bluebooks, Procfile)
//! were retired the same day ; their few committed artifacts are hand-maintained.
//!
//! What remains is the Ruby static target — projecting a user's domain to Ruby,
//! the framework's genuine compiler-output job.
//!
//! [antibody-exempt: rust/src/specializer/mod.rs — hand-written module root for
//!  the surviving Ruby static-target emitter. All self-projection + deployment
//!  codegen retired 2026-06-27.]

// Ruby static target — project a domain to Ruby.
pub mod ruby_command_class;
