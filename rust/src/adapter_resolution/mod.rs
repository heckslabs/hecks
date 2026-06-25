//! Adapter resolution — the post-dispatch arms that fire named io-adapter
//! families against the just-dispatched command. Carved out of the runtime
//! core into its own GROW concern (loc_ratchet `adapter_resolution`): each
//! family is a mechanical projection of its `framework/adapter_families/
//! <name>.hecksagon` shape, so the resolver Rust grows with the families,
//! not against the kernel's shrink pressure.
//!
//! `Runtime::dispatch` calls into these as thin sibling arms next to the
//! hardcoded `:claude_tool` path:
//!   - `web_tool` — the i569 `:web_tool` family (web_fetch / web_search)
//!   - `mcp`      — the i610 `*.world`-declared MCP server resolution
//!
//! The methods stay on `Runtime` (one `impl` block per file) so the dispatch
//! flow reads unchanged ; only the file the code LIVES in moved.

#[cfg(not(target_arch = "wasm32"))]
pub mod web_tool;
#[cfg(not(target_arch = "wasm32"))]
pub mod mcp;
