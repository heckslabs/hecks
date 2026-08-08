// THE CLI ENTRYPOINT — reads a `{"steps": [...]}` script from stdin,
// prints `{"instances", "events", "refusals"}` to stdout. Nothing
// domain-specific: `kernel::cli::run` routes every step through
// `generated::active` (bin/project_rust's own alias to whichever domain
// was last generated), so this file never needs hand-editing when a
// different domain gets regenerated in its place. Compiles unchanged for
// wasm32-wasip1 — WASI implements stdin/stdout the same way a native
// process does, so THIS is "the WASM projector wraps the Rust binary":
// one source, two `cargo build --target` invocations (bin/project_wasm).
mod generated;
mod kernel;

use std::io::Read;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).expect("failed to read stdin");
    println!("{}", kernel::cli::run(&input));
}
