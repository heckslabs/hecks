// EXEMPLAR — real, `cargo test`-checked Rust proving every shape
// bin/project_rust's generators (rust/project/*.rb) can produce is valid,
// idiomatic Rust BEFORE any Ruby ever runs. `rust/project/exemplar.rb`
// reads this tree at codegen time, slicing out shapes fenced with
// `// TMPL:<id> BEGIN` / `// TMPL:<id> END` markers and substituting real
// domain names for the `Tmpl`/`tmpl_`/`TMPL_` placeholder vocabulary this
// tree uses throughout.
//
// Every marked shape sits inside a real, complete, compiling item —
// usually a small `tmpl_*_host` function that exists ONLY to give the
// fenced fragment real types to operate on (an `args`/`store`/`record`
// with the right shape). The host functions are never called; `mod.rs`'s
// `#![allow(dead_code, ...)]` is what lets that stand without warnings.
// Only the fenced text inside `TMPL:` markers is ever extracted — the
// hosts are scaffolding, not shapes in their own right.
//
// Never compiled into a release/Lambda/WASM artifact: `#[cfg(test)] pub
// mod exemplar;` in `lib.rs` is the only place this tree is referenced.
// `cargo test --lib` is what proves it compiles — plain `mod` inclusion
// forces full type-checking with no `#[test]` fn required for that.
//
// THE AXES A SHAPE VARIES ALONG ARE NOT INVENTED HERE. `lib/hecksagain/
// language/bluebook/shape.bluebook`'s own `ShapeField` value object
// (`name`/`type`/`list`/`optional`/`pattern`/`default`/`admits`) is
// where this language already names, once, every dimension a real
// attribute's shape can vary along — the same four (list, optional,
// pattern, admits) this tree's `types`/`fielded`/`json`/`mutations`
// shapes branch on. A shape file's own header points back at the
// specific `ShapeField` attribute it corresponds to rather than
// re-deriving that vocabulary as if it were new here.
#![allow(dead_code, unused_variables)]

pub mod commands;
pub mod constraints;
pub mod fielded;
pub mod json;
pub mod mutations;
pub mod queries;
pub mod reactions;
pub mod read_models;
pub mod registry;
pub mod types;
