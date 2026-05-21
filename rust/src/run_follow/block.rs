//! Rich-block parsing + rendering for `storehouse follow` — i697
//!
//! [antibody-exempt: rust/src/run_follow/block.rs — kernel-surface CLI
//!  primitive, sibling of rust/src/run_follow/mod.rs. Parses the
//!  ANSI-stripped pretty-JSON blocks runtime::dispatch_detail writes
//!  (one object per top-level dispatch) and renders them terse-by-
//!  default or --json-verbose. Retires alongside run_follow/mod.rs's
//!  exemption when the framework-wide kernel-hook registry absorbs the
//!  logging surface.]
//!
//! Terse:  `[Voice Voice Speak] ok 12.3s · 4 events · operator`
//! --json: the full block, re-colourised by runtime::dispatch_detail's
//! palette (the file copy is ANSI-stripped, so we re-apply colour here).
//!
//! Field scans are LINE-scoped (not whole-block split_once) so a
//! `summary` value that happens to contain literal `"elapsed_ms":` text
//! can't poison the number scan — each scanner only inspects the line
//! whose trimmed start matches its key.

use crate::runtime::dispatch_detail::{
    colour_for, BRIGHT_RED, CYAN, DIM, GREEN, MAGENTA, RESET, YELLOW,
};

/// The fields `follow` reads out of a rich dispatch block. `command` is
/// the FQN (`Domain::Aggregate.Command`); the rest feed the terse tail.
#[derive(Debug, Clone, PartialEq)]
pub struct Block {
    pub command: String,
    pub outcome: String,
    pub elapsed_ms: u64,
    pub event_count: u64,
    pub source_tag: String,
}

impl Block {
    /// Parse one ANSI-stripped pretty-JSON block. `None` when the text
    /// has no `"command"` line (a stray terse one-liner) so the caller
    /// suppresses it. Hand-rolled, line-scoped scan — the block shape is
    /// fixed by `dispatch_detail::render_block`, so no JSON dep here.
    pub fn parse(text: &str) -> Option<Block> {
        let command = line_string(text, "\"command\":")?;
        Some(Block {
            command,
            outcome: line_string(text, "\"outcome\":").unwrap_or_else(|| "ok".into()),
            elapsed_ms: line_number(text, "\"elapsed_ms\":").unwrap_or(0),
            event_count: line_number(text, "\"event_count\":").unwrap_or(0),
            source_tag: line_string(text, "\"source_tag\":").unwrap_or_default(),
        })
    }

    /// `[Domain Aggregate Command]` words from the FQN. `Domain::Aggregate.Command`
    /// → ["Domain","Aggregate","Command"]. Degenerate FQNs degrade
    /// gracefully (single token → ["Token"]).
    pub fn prefix_words(&self) -> Vec<String> {
        let (head, command) = match self.command.rsplit_once('.') {
            Some((h, c)) => (h, c),
            None => (self.command.as_str(), ""),
        };
        let mut words: Vec<String> = head.split("::").map(str::to_string).collect();
        if !command.is_empty() {
            words.push(command.to_string());
        }
        words.retain(|w| !w.is_empty());
        words
    }

    /// Domain token (first FQN segment) — `--exclude` matches this.
    pub fn domain(&self) -> &str {
        let head = self.command.split('.').next().unwrap_or(&self.command);
        head.split("::").next().unwrap_or(head)
    }

    /// Aggregate token (second `::` segment, or the domain if only one).
    pub fn aggregate(&self) -> &str {
        let head = self.command.split('.').next().unwrap_or(&self.command);
        let mut parts = head.split("::");
        let first = parts.next().unwrap_or(head);
        parts.next().unwrap_or(first)
    }

    /// Terse one-liner, colourised:
    ///   `[Domain Aggregate Command] ok 12.3s · 4 events · operator`
    pub fn terse(&self) -> String {
        let prefix = render_prefix(&self.prefix_words());
        let outcome_col = if self.outcome == "error" { BRIGHT_RED } else { GREEN };
        let plural = if self.event_count == 1 { "event" } else { "events" };
        format!(
            "{prefix} {oc}{outcome}{r} {y}{elapsed}{r} {d}\u{00b7}{r} {n} {plural} {d}\u{00b7}{r} {m}{tag}{r}",
            prefix = prefix,
            oc = outcome_col, outcome = self.outcome, r = RESET,
            y = YELLOW, elapsed = human_elapsed(self.elapsed_ms),
            d = DIM, n = self.event_count, plural = plural,
            m = MAGENTA, tag = self.source_tag,
        )
    }
}

/// `[Domain Aggregate Command]` — leading words dim, final word (Command)
/// bright cyan, brackets dim.
fn render_prefix(words: &[String]) -> String {
    if words.is_empty() {
        return format!("{DIM}[]{RESET}");
    }
    let last = words.len() - 1;
    let mut inner = String::new();
    for (i, w) in words.iter().enumerate() {
        if i > 0 {
            inner.push(' ');
        }
        if i == last {
            inner.push_str(&format!("{CYAN}{w}{RESET}"));
        } else {
            inner.push_str(&format!("{DIM}{w}{RESET}"));
        }
    }
    format!("{DIM}[{RESET}{inner}{DIM}]{RESET}")
}

/// `3ms`, `0.4s`, `12.3s`. Sub-second → ms; ≥1s → one-decimal seconds.
pub fn human_elapsed(ms: u64) -> String {
    if ms < 1000 {
        format!("{ms}ms")
    } else {
        format!("{:.1}s", ms as f64 / 1000.0)
    }
}

/// Re-colourise an ANSI-stripped block for `--json` (file copy is plain),
/// AND unescape the embedded JSON-string values (args/result_state) so
/// the terminal shows real quotes + newlines, not \" and \n.
pub fn colourise_json(block_text: &str) -> String {
    let mut out = String::with_capacity(block_text.len() + 64);
    for line in block_text.lines() {
        out.push_str(&colourise_line(line));
        out.push('\n');
    }
    out.pop();
    out
}

/// Colour one JSON line by key (or by event kind for `events` entries),
/// mirroring `dispatch_detail::render_block`'s palette. Unescapes the
/// value portion so `\"` → `"` and `\\n` → newline-friendly text reads
/// cleanly in the terminal.
fn colourise_line(line: &str) -> String {
    let t = line.trim_start();
    if t.starts_with("\"command\":") {
        return colour_value(line, CYAN);
    }
    if t.starts_with("\"source_tag\":") {
        return colour_value(line, MAGENTA);
    }
    if t.starts_with("\"outcome\":") {
        let col = if line.contains("\"error\"") { BRIGHT_RED } else { GREEN };
        return colour_value(line, col);
    }
    if t.starts_with("\"elapsed_ms\":") {
        return colour_value(line, YELLOW);
    }
    if t.starts_with("\"args\":") || t.starts_with("\"result_state\":") || t.starts_with("\"metadata_json\":") {
        return unescape_value(line);
    }
    if t.starts_with("{ \"kind\":") {
        let ok = !line.contains("\"ok\": false");
        let kind = first_quoted_after(line, "\"kind\":").unwrap_or_default();
        return format!("{}{}{}", colour_for(&kind, ok), line, RESET);
    }
    line.to_string()
}

/// Unescape a `key: "...escaped json..."` line so the embedded JSON
/// reads naturally : `\"` → `"`, `\\n` → newline, `\\t` → tab, `\\\\` → `\`.
fn unescape_value(line: &str) -> String {
    match line.split_once(": ") {
        Some((k, v)) => {
            let unescaped = v
                .replace("\\\"", "\"")
                .replace("\\n", "\n")
                .replace("\\t", "\t")
                .replace("\\\\", "\\");
            format!("{k}: {unescaped}")
        }
        None => line.to_string(),
    }
}

/// Wrap the value of `key: value` in `col`, leaving key + comma plain.
fn colour_value(line: &str, col: &str) -> String {
    match line.split_once(": ") {
        Some((k, v)) => format!("{k}: {col}{v}{RESET}"),
        None => format!("{col}{line}{RESET}"),
    }
}

/// Line-scoped string-field scan.
fn line_string(text: &str, key: &str) -> Option<String> {
    text.lines()
        .find(|l| l.trim_start().starts_with(key))
        .and_then(|l| first_quoted_after(l, key))
}

/// Line-scoped number-field scan.
fn line_number(text: &str, key: &str) -> Option<u64> {
    let line = text.lines().find(|l| l.trim_start().starts_with(key))?;
    let after = line.split_once(key)?.1.trim_start();
    let digits: String = after.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// First `"..."`-quoted token appearing after `key` within one line.
fn first_quoted_after(line: &str, key: &str) -> Option<String> {
    let after = line.split_once(key)?.1;
    let start = after.find('"')? + 1;
    let end = after[start..].find('"')? + start;
    Some(after[start..end].to_string())
}


/// Colourise a legacy single-line log entry :
///   `[ts] dispatch Domain::Aggregate.Command#inv ...`
///   `[ts] cascade X#id ok=true`  /  `[ts] policy P on E -> T`  /  `[ts] event A.B#id`
/// Timestamp dim, verb coloured by kind (dispatch=cyan, event/cascade-ok=green,
/// cascade-fail=red, policy=magenta), the FQN token bright. Falls back to the
/// raw line when the shape doesn't match.
pub fn colourise_legacy(line: &str) -> String {
    let (ts, rest) = match line.split_once("] ") {
        Some((t, r)) => (format!("{}]", t), r),
        None => return line.to_string(),
    };
    let mut toks = rest.splitn(2, ' ');
    let verb = toks.next().unwrap_or("");
    let tail = toks.next().unwrap_or("");
    let ok_fail = line.contains("ok=false");
    let verb_col = match verb {
        "dispatch" => CYAN,
        "event" => GREEN,
        "cascade" => if ok_fail { BRIGHT_RED } else { GREEN },
        "policy" => MAGENTA,
        _ => DIM,
    };
    format!("{DIM}{ts}{RESET} {vc}{verb}{RESET} {tail}", vc = verb_col)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::dispatch_detail::strip_ansi;

    fn sample_block() -> String {
        "{\n  \"invocation_id\": \"inv1\",\n  \"command\": \"Voice::Voice.Speak\",\n  \"source_tag\": \"operator\",\n  \"outcome\": \"ok\",\n  \"elapsed_ms\": 12345,\n  \"dispatched_at\": \"2026-05-21T00:00:00Z\",\n  \"event_count\": 4,\n  \"events\": [\n    { \"kind\": \"dispatch\", \"verb\": \"Voice::Voice.Speak\", \"ok\": true }\n  ]\n}".to_string()
    }

    #[test]
    fn parse_extracts_fields() {
        let b = Block::parse(&sample_block()).unwrap();
        assert_eq!(b.command, "Voice::Voice.Speak");
        assert_eq!(b.outcome, "ok");
        assert_eq!(b.elapsed_ms, 12345);
        assert_eq!(b.event_count, 4);
        assert_eq!(b.source_tag, "operator");
    }

    #[test]
    fn parse_none_for_terse_line() {
        assert!(Block::parse("[2026-05-21T00:00:00Z] event Voice.Spoke#1").is_none());
    }

    #[test]
    fn prefix_words_three_segments() {
        let b = Block::parse(&sample_block()).unwrap();
        assert_eq!(b.prefix_words(), vec!["Voice", "Voice", "Speak"]);
    }

    #[test]
    fn prefix_words_degenerate() {
        let b = Block { command: "Beat".into(), outcome: "ok".into(), elapsed_ms: 0, event_count: 0, source_tag: "x".into() };
        assert_eq!(b.prefix_words(), vec!["Beat"]);
    }

    #[test]
    fn domain_and_aggregate() {
        let b = Block { command: "Tools::ShellTool.Bash".into(), outcome: "ok".into(), elapsed_ms: 0, event_count: 0, source_tag: "x".into() };
        assert_eq!(b.domain(), "Tools");
        assert_eq!(b.aggregate(), "ShellTool");
    }

    #[test]
    fn human_elapsed_boundaries() {
        assert_eq!(human_elapsed(3), "3ms");
        assert_eq!(human_elapsed(999), "999ms");
        assert_eq!(human_elapsed(1000), "1.0s");
        assert_eq!(human_elapsed(12345), "12.3s");
    }

    #[test]
    fn terse_is_one_line_and_scannable() {
        let b = Block::parse(&sample_block()).unwrap();
        let plain = strip_ansi(&b.terse());
        assert_eq!(plain, "[Voice Voice Speak] ok 12.3s \u{00b7} 4 events \u{00b7} operator");
        assert!(!plain.contains('\n'));
    }

    #[test]
    fn terse_singular_event() {
        let b = Block { command: "Heart::Heart.Beat".into(), outcome: "ok".into(), elapsed_ms: 3, event_count: 1, source_tag: "process-manager".into() };
        let plain = strip_ansi(&b.terse());
        assert_eq!(plain, "[Heart Heart Beat] ok 3ms \u{00b7} 1 event \u{00b7} process-manager");
    }

    #[test]
    fn line_scan_not_poisoned_by_summary() {
        let block = "{\n  \"command\": \"D::A.C\",\n  \"summary\": \"says elapsed_ms: 999 in text\",\n  \"outcome\": \"ok\",\n  \"elapsed_ms\": 42,\n  \"event_count\": 0,\n  \"events\": []\n}";
        let b = Block::parse(block).unwrap();
        assert_eq!(b.elapsed_ms, 42);
    }
}
