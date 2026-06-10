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
    // Walk by `char`, never by byte. ANSI SGR markers are all ASCII so
    // the escape scan is byte-equivalent, but the body text carries
    // multi-byte UTF-8 (the `·` separator, accents in French summaries).
    // Pushing `byte as char` would split U+00B7 (C2 B7) into two chars
    // — the mojibake that poisoned the terse render. Iterating chars
    // keeps every codepoint whole.
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1b' && chars.peek() == Some(&'[') {
            chars.next(); // consume '['
            // Skip until the final byte of the CSI sequence (a letter).
            while let Some(&next) = chars.peek() {
                chars.next();
                if next.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
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
    /// Holds the event timeline from the most-recently-completed dispatch
    /// scope. Written by `DispatchScope::drop` immediately after the
    /// thread-local collector is drained. Callers (e.g. the warm serve
    /// path) call `take_last_events()` after `Runtime::dispatch` returns to
    /// retrieve the events for inclusion in the wire reply. A subsequent
    /// dispatch overwrites it ; `take_last_events` clears it on read.
    static LAST_EVENTS: RefCell<Vec<EventTrace>> = const { RefCell::new(Vec::new()) };
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

/// Return and clear the event timeline from the most-recently-completed
/// dispatch scope. Called by the warm serve path immediately after
/// `Runtime::dispatch` returns so it can include the events in the RESULT
/// envelope. Returns an empty Vec when no dispatch has run yet (or after
/// a second call drains the same scope). Idempotent after drain.
pub fn take_last_events() -> Vec<EventTrace> {
    LAST_EVENTS.with(|s| std::mem::take(&mut *s.borrow_mut()))
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
    source_tag: String,
    dispatched_at: String,
    started: std::time::Duration,
    outcome: String,
    result_state: String,
    armed: bool,
}

impl DispatchScope {
    /// Begin a scope. Installs a fresh thread-local event collector and
    /// captures invocation_id, command, args, source_tag and the
    /// wall-clock start — everything the JSONL envelope needs.
    pub fn begin(invocation_id: &str, command: &str, args_json: String) -> Self {
        COLLECTOR.with(|c| *c.borrow_mut() = Some(Vec::new()));
        DispatchScope {
            invocation_id: invocation_id.to_string(),
            command: command.to_string(),
            args_json,
            source_tag: resolve_source_tag(),
            dispatched_at: storehouse_log::now_iso8601(),
            started: crate::clock::now_duration(),
            outcome: "ok".to_string(),
            result_state: String::new(),
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
        // Snapshot the events for the warm serve path BEFORE serialising
        // the file block. `take_last_events()` drains this after dispatch.
        LAST_EVENTS.with(|s| *s.borrow_mut() = events.clone());
        let elapsed_ms = crate::clock::now_duration()
            .saturating_sub(self.started)
            .as_millis() as u64;
        // JSONL event stream : one self-contained JSON object per emitted
        // event, one per line. The dispatch event carries `args` ; the
        // final `done` event carries outcome + elapsed_ms + event_count +
        // result. The watcher (`storehouse follow`) parses one object per
        // line and renders terse by default or raw with --json. One line =
        // one object, so there is never a multi-line block to re-assemble.
        let args: serde_json::Value =
            serde_json::from_str(&self.args_json).unwrap_or(serde_json::Value::Null);
        for (i, ev) in events.iter().enumerate() {
            let mut obj = serde_json::json!({
                "ts": self.dispatched_at,
                "invocation_id": self.invocation_id,
                "command": self.command,
                "kind": ev.kind,
                "verb": ev.verb,
                "ok": ev.ok,
                "source": self.source_tag,
            });
            if i == 0 && ev.kind == "dispatch" && !args.is_null() {
                obj["args"] = args.clone();
            }
            storehouse_log::emit_file(&obj.to_string());
        }
        let result: serde_json::Value = serde_json::from_str(&self.result_state)
            .unwrap_or_else(|_| serde_json::Value::String(self.result_state.clone()));
        let done = serde_json::json!({
            "ts": self.dispatched_at,
            "invocation_id": self.invocation_id,
            "command": self.command,
            "kind": "done",
            "outcome": self.outcome,
            "elapsed_ms": elapsed_ms,
            "event_count": events.len(),
            "result": result,
            "source": self.source_tag,
        });
        storehouse_log::emit_file(&done.to_string());
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
    fn scope_collects_events_into_timeline() {
        let mut scope = DispatchScope::begin("inv_t", "Foo::Bar.Baz", "{}".to_string());
        assert!(is_in_scope());
        record_event("dispatch", "Foo::Bar.Baz", true);
        record_event("event", "Bar.Bazzed", true);
        scope.finish("ok", "{}".to_string());
        let events = COLLECTOR.with(|c| c.borrow().clone()).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, "dispatch");
        // Disarm so Drop doesn't emit to the real log during the test.
        scope.armed = false;
        COLLECTOR.with(|c| *c.borrow_mut() = None);
    }

    #[test]
    fn take_last_events_returns_events_after_scope_drop() {
        // Verify LAST_EVENTS is populated by Drop and drained by
        // take_last_events() — the i718 warm-serve fix.
        let mut scope = DispatchScope::begin("inv_u", "A::B.C", "{}".to_string());
        record_event("dispatch", "A::B.C", true);
        record_event("event", "B.Cd", true);
        scope.finish("ok", "{}".to_string());
        drop(scope); // triggers LAST_EVENTS write
        let taken = take_last_events();
        assert_eq!(taken.len(), 2);
        assert_eq!(taken[0].kind, "dispatch");
        assert_eq!(taken[1].kind, "event");
        // Second call must drain (idempotent — returns empty Vec).
        assert!(take_last_events().is_empty());
    }
}
