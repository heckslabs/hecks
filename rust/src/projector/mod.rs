// ONE projector, because the IR is ONE contract.
//
// There were two. `dump.rs` sat beside this from the era when Rust was believed
// to be a PROJECTION of Ruby (retired in "Rust is hand-written — the projection
// thesis is retired"), and it survived the retirement unnoticed : 372 lines
// reachable only through a `--canonical` flag that nothing in the repo invoked
// and the usage message never advertised.
//
// A second projector of the IR is the most expensive kind of dead code, because
// the IR is the contract the two runtimes are held to and NOTHING compared that
// one to Ruby. It was free to drift, and it had : it emitted an attribute's
// `required`, parsed from a spelling written in zero bluebooks, pinned by no
// golden, and carrying a meaning the language did not have. That phantom is what
// `optional` was eventually built out of.
pub mod ir_json;
