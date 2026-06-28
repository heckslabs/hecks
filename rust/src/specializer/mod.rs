//! Specializer — the framework's compiler-output projection layer.
//!
//! The framework's OWN Rust source is hand-written. What remains here are the
//! genuine compiler OUTPUTS — projecting a USER's domain into a deployment
//! artifact (Cloudflare worker, wrangler.toml, embedded bluebooks, Procfile)
//! or the Ruby static target. That projection is the framework's actual job ;
//! the self-projection codegen (parser / validator / ir / runtime / … authored
//! as a .bluebook-of-itself) was retired 2026-06-27 as the catalog/Hecksagon
//! anti-pattern — a .bluebook whose only job is to re-emit imperative Rust
//! captures no domain.
//!
//! [antibody-exempt: rust/src/specializer/mod.rs — hand-written module root for
//!  the surviving compiler-output emitters (deployment artifacts + the Ruby
//!  static target). Self-projection codegen retired 2026-06-27 ; the engine it
//!  needed (snippet manifests, the emit/regen dispatch, util) went with it.]

// Deployment-artifact emitters — project a user's domain to a deploy target.
pub mod cf_function_proxy;
pub mod embedded_bluebooks;
pub mod procfile;
pub mod wasm_worker;
pub mod wrangler_toml;

// Ruby static target — project a domain to Ruby.
pub mod ruby_command_class;
