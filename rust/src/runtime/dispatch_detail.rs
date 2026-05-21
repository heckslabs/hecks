//! Rich dispatch-detail emitter — i697
//!
//! [antibody-exempt: rust/src/runtime/dispatch_detail.rs — rich storehouse
//!  log emitter, impl of the StorehouseEntry contract at
//!  framework/session/storehouse_log.bluebook. Sibling of
//!  rust/src/runtime/storehouse_log.rs (kernel-floor). Owns the
//!  thread-local per-dispatch event collector + the pretty-JSON,
//!  ANSI-coloured block one object per top-level dispatch. Retires
//!  alongside storehouse_log's exemption when the framework-wide
//!  kernel-hook registry absorbs the logging surface.]
//!
//! Where `storehouse_log` emits terse one-line records for interleaved
//! tracing, this module emits ONE rich, pretty-printed (2-space indent)
//! JSON block per top-level `Runtime::dispatch`, blank-line separated so
//! `tail -f` reads cleanly. It is the runtime side of the StorehouseEntry
//! bluebook : invocation_id, command, summary, args, outcome,
//! result_state, elapsed_ms, source_tag, metadata, and the full per-event
//! timeline (dispatch / event / cascade / adapter / policy / attr /
//! error / fallback).
//!
//! Lifecycle :
//!   1. `Runtime::dispatch` opens a `DispatchScope` as its first line.
//!      The scope reads `STOREHOUSE_SOURCE_TAG` (fallback HECKS_DAEMON →
//!      process-manager, else operator) and starts the wall-clock.
//!   2. The terse surfaces (`storehouse_log::dispatch_entry`,
//!      `event_emitted`, `cascade_step`, `policy_reaction`,
//!      `attribute_trace`) call `record_event` — which appends an
//!      EventTrace to the thread-local IFF a scope is open. Cascades go
//!      through `command_dispatch::dispatch_cascade`, NOT
//!      `Runtime::dispatch`, so there is exactly one open scope per
//!      top-level dispatch and the events form one clean tree.
//!   3. On scope drop (covers the `?` error path too) the collected
//!      timeline + the outcome/result fields the scope was fed are
//!      serialised into one rich block and emitted.
//!
//! ANSI + routing : the rich block is ANSI-coloured by kind and written
//! to the FILE sink ONLY (see `storehouse_log::emit_dual`) — never to the
//! dispatching process's stdout, which is reserved for the CLI's
//! contractual result line (the MCP wrapper + golden tests + piped
//! scripts parse stdout ; a pretty JSON block there contaminates them).
//! The "live stream" the block feeds is `storehouse follow` — a separate
//! tail process that reads the file and renders the colours natively.
//! `strip_ansi` (public) is the stripper for grep/parse-clean reads.

use std::cell::RefCell;

use crate::runtime::storehouse_log;

// ── ANSI palette ────────────────────────────────────────────────────

pub const RESET: &str = "\x1b[0m";
pub const CYAN: &str = "\x1b[36m";
pub const GREEN: &str = "\x1b[32m";
pub const RED: &str = "\x1b[31m";
pub const BRIGHT_RED: &str = "\x1b[91m";
pub const MAGENTA: &str = "\x1b[35m";
pub const YELLOW: &str = "\x1b[33m";
pub const DIM: &str = "\x1b[2m";

/// Colour a string by event kind. dispatch=cyan, event/cascade-ok=green,
/// cascade-fail=red, adapter=magenta, error=bright-red, fallback=yellow,
/// policy/attr=dim. `ok` disambiguates cascade/adapter steps.
pub fn colour_for(kind: &str, ok: bool) -> &'static str {
    match kind {
        "dispatch" => CYAN,
        "event" => GREEN,
        "cascade" => if ok { GREEN } else { RED },
        "adapter" => if ok { MAGENTA } else { RED },
        "error" => BRIGHT_RED,
        "fallback" => YELLOW,
        "policy" | "attr" => DIM,
        _ => RESET,
    }
}

/// Strip ANSI SGR escape sequences (`\x1b[...m`) from a string so the
/// persistent file copy stays plain. Hand-rolled to avoid a dependency.
pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b && i + 1 < bytes.len() && bytes[i + 1] == b'[' {
            // Skip until the final byte of the CSI sequence (a letter).
            i += 2;
            while i < bytes.len() && !bytes[i].is_ascii_alphabetic() {
                i += 1;
            }
            if i < bytes.len() {
                i += 1; // consume the final letter
            }
        } else {
            out.push(bytes[i] as char);
            i += 1;
        }
    }
    out
}

// ── EventTrace + thread-local collector ─────────────────────────────

/// One step in a dispatch's execution timeline — mirrors the EventTrace
/// VO in the bluebook (kind + verb + ok).
#[derive(Clone, Debug)]
pub struct EventTrace {
    pub kind: String,
    pub verb: String,
    pub ok: bool,
}

thread_local! {
    static COLLECTOR: RefCell<Option<Vec<EventTrace>>> = const { RefCell::new(None) };
}

/// True when a `DispatchScope` is currently open on this thread.
pub fn is_in_scope() -> bool {
    COLLECTOR.with(|c| c.borrow().is_some())
}

/// Append one EventTrace to the open scope, if any. Called by the terse
/// `storehouse_log` surfaces so the rich block captures the same timeline
/// they print. No-op when no scope is open (detached threads, ad-hoc
/// lines) so those surfaces stay terse-only.
pub fn record_event(kind: &str, verb: &str, ok: bool) {
    COLLECTOR.with(|c| {
        if let Some(v) = c.borrow_mut().as_mut() {
            v.push(EventTrace { kind: kind.to_string(), verb: verb.to_string(), ok });
        }
    });
}

// ── DispatchScope : RAII guard, emits the rich block on drop ────────

/// Resolve the source_tag from the dispatch context. Honors an explicit
/// `STOREHOUSE_SOURCE_TAG` env var ; else `HECKS_DAEMON=1` →
/// `process-manager` ; else `operator` (manual CLI + MCP default).
fn resolve_source_tag() -> String {
    if let Ok(v) = std::env::var("STOREHOUSE_SOURCE_TAG") {
        if !v.is_empty() {
            return v;
        }
    }
    if std::env::var("HECKS_DAEMON").ok().as_deref() == Some("1") {
        return "process-manager".to_string();
    }
    "operator".to_string()
}

/// Open per-`Runtime::dispatch` scope. Built as the first line of
/// `dispatch` ; fed the outcome/result fields as they become known ;
/// emits the rich block on drop (so the `?` error path is still
/// captured).
pub struct DispatchScope {
    invocation_id: String,
    command: String,
    args_json: String,
    summary: String,
    metadata_json: String,
    source_tag: String,
    dispatched_at: String,
    started: std::time::Duration,
    outcome: String,
    result_state: String,
    parent_invocation_id: String,
    armed: bool,
}

impl DispatchScope {
    /// Begin a scope. Installs a fresh thread-local collector, captures
    /// the wall-clock start + source_tag. `summary`/`metadata_json` come
    /// from env (the MCP wrapper sets them) so the rich render surfaces
    /// the operator's intent + the command metadata.
    pub fn begin(invocation_id: &str, command: &str, args_json: String) -> Self {
        COLLECTOR.with(|c| *c.borrow_mut() = Some(Vec::new()));
        let summary = std::env::var("STOREHOUSE_DISPATCH_SUMMARY").unwrap_or_default();
        let metadata_json = std::env::var("STOREHOUSE_DISPATCH_METADATA").unwrap_or_default();
        DispatchScope {
            invocation_id: invocation_id.to_string(),
            command: command.to_string(),
            args_json,
            summary,
            metadata_json,
            source_tag: resolve_source_tag(),
            dispatched_at: storehouse_log::now_iso8601(),
            started: crate::heki::now_duration(),
            outcome: "ok".to_string(),
            result_state: String::new(),
            parent_invocation_id: String::new(),
            armed: true,
        }
    }

    /// Record the dispatch outcome (`ok` | `error`) + the result-state
    /// JSON (or the error message). Fed by `Runtime::dispatch` before the
    /// scope drops.
    pub fn finish(&mut self, outcome: &str, result_state: String) {
        self.outcome = outcome.to_string();
        self.result_state = result_state;
    }
}

impl Drop for DispatchScope {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let events = COLLECTOR.with(|c| c.borrow_mut().take()).unwrap_or_default();
        let block = render_block(self, &events);
        storehouse_log::emit_dual(&block);
    }
}

/// Parse a dispatched FQN into its `[Domain Aggregate Command]` parts.
/// `Domain::Aggregate.Command` → `("Domain", "Aggregate", "Command")`.
/// A domain-less `Aggregate.Command` → `("", "Aggregate", "Command")`.
/// Anything that doesn't split cleanly falls back to the whole string in
/// the command slot so the header never lies about a malformed FQN.
pub fn parse_fqn(fqn: &str) -> (String, String, String) {
    let (domain, rest) = match fqn.split_once("::") {
        Some((d, r)) => (d.to_string(), r),
        None => (String::new(), fqn),
    };
    match rest.rsplit_once('.') {
        Some((agg, cmd)) => (domain, agg.to_string(), cmd.to_string()),
        None => (domain, String::new(), rest.to_string()),
    }
}

/// Build the scannable bracketed header line for a dispatched FQN —
/// `[Domain Aggregate Command]`, space-separated, with the three parts
/// coloured distinctly (domain DIM, aggregate plain, command CYAN). A
/// domain-less FQN renders only the parts it has, never an empty slot.
pub fn header_line(fqn: &str) -> String {
    let (domain, aggregate, command) = parse_fqn(fqn);
    let mut parts: Vec<String> = Vec::new();
    if !domain.is_empty() {
        parts.push(format!("{}{}{}", DIM, domain, RESET));
    }
    if !aggregate.is_empty() {
        parts.push(aggregate);
    }
    if !command.is_empty() {
        parts.push(format!("{}{}{}", CYAN, command, RESET));
    }
    format!("{}[{}{}{}]{}", DIM, RESET, parts.join(" "), DIM, RESET)
}

/// Render the rich, pretty-printed (2-space) JSON block for one dispatch,
/// ANSI-coloured by kind, with a blank line separator for clean `tail`.
/// A scannable `[Domain Aggregate Command]` header leads each block.
fn render_block(scope: &DispatchScope, events: &[EventTrace]) -> String {
    let elapsed_ms = crate::heki::now_duration()
        .saturating_sub(scope.started)
        .as_millis() as u64;
    let outcome_colour = if scope.outcome == "error" { BRIGHT_RED } else { GREEN };

    let mut out = String::new();
    out.push_str(&header_line(&scope.command));
    out.push('\n');
    out.push_str(&format!("{}{{{}\n", DIM, RESET));
    out.push_str(&format!("  \"invocation_id\": \"{}\",\n", esc(&scope.invocation_id)));
    out.push_str(&format!("  \"command\": {}\"{}\"{},\n", CYAN, esc(&scope.command), RESET));
    out.push_str(&format!("  \"source_tag\": {}\"{}\"{},\n", MAGENTA, esc(&scope.source_tag), RESET));
    if !scope.summary.is_empty() {
        out.push_str(&format!("  \"summary\": \"{}\",\n", esc(&scope.summary)));
    }
    if !scope.args_json.is_empty() {
        out.push_str(&format!("  \"args\": {},\n", scope.args_json));
    }
    out.push_str(&format!("  \"outcome\": {}\"{}\"{},\n", outcome_colour, esc(&scope.outcome), RESET));
    if !scope.result_state.is_empty() {
        out.push_str(&format!("  \"result_state\": {},\n", scope.result_state));
    }
    if !scope.metadata_json.is_empty() {
        out.push_str(&format!("  \"metadata\": {},\n", scope.metadata_json));
    }
    out.push_str(&format!("  \"elapsed_ms\": {}{}{},\n", YELLOW, elapsed_ms, RESET));
    out.push_str(&format!("  \"dispatched_at\": \"{}\",\n", esc(&scope.dispatched_at)));
    if !scope.parent_invocation_id.is_empty() {
        out.push_str(&format!("  \"parent_invocation_id\": \"{}\",\n", esc(&scope.parent_invocation_id)));
    }
    out.push_str(&format!("  \"event_count\": {},\n", events.len()));
    out.push_str("  \"events\": [");
    if events.is_empty() {
        out.push(']');
    } else {
        out.push('\n');
        for (i, ev) in events.iter().enumerate() {
            let col = colour_for(&ev.kind, ev.ok);
            let comma = if i + 1 < events.len() { "," } else { "" };
            out.push_str(&format!(
                "    {}{{ \"kind\": \"{}\", \"verb\": \"{}\", \"ok\": {} }}{}{}\n",
                col, ev.kind, esc(&ev.verb), ev.ok, RESET, comma
            ));
        }
        out.push_str("  ]");
    }
    out.push('\n');
    out.push_str(&format!("{}}}{}", DIM, RESET));
    out
}

/// Minimal JSON string escaping for the hand-built block — quotes,
/// backslashes, and the control chars a verb/summary might carry.
fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_ansi_removes_colour_codes() {
        let coloured = format!("{}hello{} world", CYAN, RESET);
        assert_eq!(strip_ansi(&coloured), "hello world");
    }

    #[test]
    fn strip_ansi_leaves_plain_text() {
        assert_eq!(strip_ansi("no codes here"), "no codes here");
    }

    #[test]
    fn colour_for_cascade_fail_is_red() {
        assert_eq!(colour_for("cascade", false), RED);
        assert_eq!(colour_for("cascade", true), GREEN);
    }

    #[test]
    fn colour_for_adapter_ok_is_magenta() {
        assert_eq!(colour_for("adapter", true), MAGENTA);
    }

    #[test]
    fn esc_escapes_quotes_and_newlines() {
        assert_eq!(esc("a\"b\nc"), "a\\\"b\\nc");
    }

    #[test]
    fn record_event_noop_without_scope() {
        // No scope open : record_event must not panic and must not
        // leave a collector behind.
        record_event("dispatch", "Foo.Bar", true);
        assert!(!is_in_scope());
    }

    #[test]
    fn parse_fqn_three_parts() {
        assert_eq!(
            parse_fqn("Voice::Voice.Speak"),
            ("Voice".to_string(), "Voice".to_string(), "Speak".to_string())
        );
        assert_eq!(
            parse_fqn("Tools::ShellTool.Bash"),
            ("Tools".to_string(), "ShellTool".to_string(), "Bash".to_string())
        );
    }

    #[test]
    fn parse_fqn_domainless() {
        assert_eq!(
            parse_fqn("Heart.Beat"),
            (String::new(), "Heart".to_string(), "Beat".to_string())
        );
    }

    #[test]
    fn header_line_renders_three_bracketed_parts() {
        let plain = strip_ansi(&header_line("Voice::Voice.Speak"));
        assert_eq!(plain, "[Voice Voice Speak]");
    }

    #[test]
    fn header_line_domainless_has_no_empty_slot() {
        let plain = strip_ansi(&header_line("Heart.Beat"));
        assert_eq!(plain, "[Heart Beat]");
    }

    #[test]
    fn render_block_leads_with_header() {
        let scope = DispatchScope::begin("inv_h", "Tools::ShellTool.Bash", "{}".to_string());
        let plain = strip_ansi(&render_block(&scope, &[]));
        assert!(plain.starts_with("[Tools ShellTool Bash]\n"));
        // Cleanup so Drop doesn't emit to the real log.
        let mut scope = scope;
        scope.armed = false;
        COLLECTOR.with(|c| *c.borrow_mut() = None);
    }

    #[test]
    fn scope_collects_events_into_block() {
        let mut scope = DispatchScope::begin("inv_t", "Foo::Bar.Baz", "{}".to_string());
        assert!(is_in_scope());
        record_event("dispatch", "Foo::Bar.Baz", true);
        record_event("event", "Bar.Bazzed", true);
        scope.finish("ok", "{\"n\":1}".to_string());
        let events = COLLECTOR.with(|c| c.borrow().clone()).unwrap();
        assert_eq!(events.len(), 2);
        let block = render_block(&scope, &events);
        let plain = strip_ansi(&block);
        assert!(plain.contains("\"command\": \"Foo::Bar.Baz\""));
        assert!(plain.contains("\"event_count\": 2"));
        assert!(plain.contains("\"kind\": \"dispatch\""));
        // Disarm so Drop doesn't emit to the real log during the test.
        scope.armed = false;
        COLLECTOR.with(|c| *c.borrow_mut() = None);
    }
}
