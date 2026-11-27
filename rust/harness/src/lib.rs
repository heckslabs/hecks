//! hecks-harness: runs agent sessions for the Harness bluebook (lib/hecks/harness).
//!
//! [`supervisor`] holds each session's Claude Code child and speaks its stream-json protocol
//! ([`protocol`]), serving the one in-process MCP tool `send_message` ([`mcp`]). [`replay`] plays a
//! child from a tape, so the whole exchange is proven with no model, and [`measure`] reads the
//! supervisor's tells against the mail's baseline. [`json`] is the std-only reader and writer the
//! wire needs.

pub mod json;
pub mod mcp;
pub mod measure;
pub mod protocol;
pub mod replay;
pub mod supervisor;
