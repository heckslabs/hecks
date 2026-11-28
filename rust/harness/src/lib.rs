//! hecks-harness: runs agent sessions for the Harness bluebook (lib/hecks/harness).
//!
//! [`supervisor`] holds each session's Claude Code child and speaks its stream-json protocol
//! ([`protocol`]), serving the one in-process MCP tool `send_message` ([`mcp`]). [`replay`] plays a
//! child from a tape, so the whole exchange is proven with no model, and [`measure`] reads the
//! supervisor's tells against the mail's baseline. [`journal`] reads a recorded run back as each session's acts and holds a replay to
//! them. [`brief`] turns a role file into a session's
//! brief, [`role`] reads the tools and model it holds, and [`json`] is the std-only reader and writer the wire needs.

/// A role file turned into a session's brief.
pub mod brief;
/// A crew run's journal, and a replay held to it.
pub mod journal;
/// The std-only JSON reader and writer.
pub mod json;
/// The in-process MCP server and its one tool, `send_message`.
pub mod mcp;
/// The mail measured against its baseline.
pub mod measure;
/// Claude Code's stream-json protocol, as a child speaks it.
pub mod protocol;
/// A child played from a tape.
pub mod replay;
/// A role's session: its brief, the tools it may use and its model.
pub mod role;
/// The supervisor: each session's child, its mail and its tells.
pub mod supervisor;
