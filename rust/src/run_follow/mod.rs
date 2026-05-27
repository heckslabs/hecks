//! `storehouse follow [stream] [--quiet] [--json] [--pretty] [--exclude D1,D2,...]` —
//! watch the JSONL event stream. [antibody-exempt: rust/src/run_follow/mod.rs
//!  — kernel-surface CLI primitive paired with runtime/storehouse_log.rs +
//!  runtime/dispatch_detail.rs. A dumb watcher : tail the log, parse one
//!  JSON object per line, render. Retires with storehouse_log's exemption.]
//!
//! The log is JSONL — one self-contained JSON object per emitted event
//! (storehouse_log::emit_file, written by dispatch_detail::DispatchScope on
//! drop). follow tails the file, parses one object per line, and renders it
//! terse by default, compact JSON with --json, or human-readable indented JSON
//! with --pretty. --pretty unescapes multi-line string fields (e.g. shell_command)
//! so hard newlines / quotes print literally. One line = one object in the log,
//! so there is no multi-line block to re-assemble ; pipe to `jq` for anything.
//!   storehouse follow                 # terse colourised event stream
//!   storehouse follow --json          # compact JSON per event (jq-friendly)
//!   storehouse follow --pretty        # indented JSON, strings unescaped
//!   storehouse follow --quiet         # hide process-manager (daemon) events
//!   storehouse follow --exclude Heart,SpeechStream
//!   storehouse follow ShellTool       # substring filter on the line

use crate::runtime::dispatch_detail::{colour_for, parse_fqn, BRIGHT_RED, CYAN, DIM, GREEN, MAGENTA, RESET, YELLOW};
use crate::runtime::storehouse_log;
use serde_json::Value;
use std::fs::File;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::Path;
use std::time::Duration;

struct Opts { needle: Option<String>, quiet: bool, json: bool, pretty: bool, exclude: Vec<String> }

fn parse_opts(args: &[String]) -> Opts {
    let mut quiet = false;
    let mut json = false;
    let mut pretty = false;
    let mut exclude: Vec<String> = Vec::new();
    let mut needle: Option<String> = None;
    let mut i = 2;
    while i < args.len() {
        let a = args[i].as_str();
        if a == "--quiet" || a == "-q" { quiet = true; }
        else if a == "--json" { json = true; }
        else if a == "--pretty" { pretty = true; }
        else if a == "--exclude" { if let Some(v) = args.get(i + 1) { exclude = split_csv(v); i += 1; } }
        else if let Some(v) = a.strip_prefix("--exclude=") { exclude = split_csv(v); }
        else if !a.starts_with('-') && needle.is_none() {
            let s = a.to_string();
            if s != "all" { needle = Some(s); }
        }
        i += 1;
    }
    Opts { needle, quiet, json, pretty, exclude }
}

fn split_csv(v: &str) -> Vec<String> {
    v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}

pub fn print_help() {
    let path = storehouse_log::log_file_path();
    println!("storehouse follow [stream] [--quiet] [--json] [--pretty] [--exclude D1,D2,...]");
    println!();
    println!("  storehouse follow                  # terse colourised event stream");
    println!("  storehouse follow --json           # compact JSON per event (jq-friendly)");
    println!("  storehouse follow --pretty         # indented JSON, strings unescaped");
    println!("  storehouse follow --quiet          # hide process-manager (daemon) events");
    println!("  storehouse follow --exclude Heart,SpeechStream");
    println!("  storehouse follow ShellTool        # substring filter on the line");
    println!();
    println!("Log: $STOREHOUSE_LOG_FILE (default {}). JSONL — one event per line.", path.display());
}

pub fn run(args: &[String]) -> i32 {
    let first = args.get(2).map(|s| s.as_str());
    if matches!(first, Some("--help") | Some("-h") | Some("help")) { print_help(); return 0; }
    let opts = parse_opts(args);
    let path = storehouse_log::log_file_path();
    tail(&path, &opts);
    0
}

fn tail(path: &Path, opts: &Opts) {
    let poll = Duration::from_millis(100);
    let mut file = loop { match File::open(path) { Ok(f) => break f, Err(_) => std::thread::sleep(poll) } };
    let _ = file.seek(SeekFrom::End(0));
    let mut reader = BufReader::new(file);
    let mut buf = String::new();
    loop {
        buf.clear();
        match reader.read_line(&mut buf) {
            Ok(0) => {
                std::thread::sleep(poll);
                if !path.exists() {
                    let nf = loop { match File::open(path) { Ok(f) => break f, Err(_) => std::thread::sleep(poll) } };
                    reader = BufReader::new(nf);
                }
            }
            Ok(_) => {
                let line = buf.trim_end_matches('\n').trim_end_matches('\r');
                if let Some(rendered) = render(line, opts) {
                    println!("{}", rendered);
                    use std::io::Write as _;
                    let _ = std::io::stdout().flush();
                }
            }
            Err(_) => std::thread::sleep(poll),
        }
    }
}

/// Parse one JSONL event line, filter, and render. `None` when the line
/// isn't a JSON object or is filtered out (--quiet / --exclude / needle).
fn render(line: &str, opts: &Opts) -> Option<String> {
    let line = line.trim();
    let v: Value = serde_json::from_str(line).ok()?;
    let command = v.get("command").and_then(|c| c.as_str())?;
    let source = v.get("source").and_then(|s| s.as_str()).unwrap_or("");
    if opts.quiet && source == "process-manager" { return None; }
    if opts.exclude.iter().any(|x| command.contains(x.as_str())) { return None; }
    if let Some(n) = &opts.needle { if !line.contains(n.as_str()) { return None; } }
    if opts.pretty {
        let mut out = String::new();
        write_human_value(&v, &mut out, 0);
        return Some(out);
    }
    if opts.json {
        return Some(serde_json::to_string_pretty(&v).unwrap_or_else(|_| line.to_string()));
    }
    Some(terse(&v, command, source))
}

/// Render a JSON value with indentation, printing string fields that contain
/// newlines as literal multi-line text (unescaped) rather than `\n` sequences.
fn write_human_value(v: &Value, out: &mut String, indent: usize) {
    let pad = " ".repeat(indent);
    let inner = " ".repeat(indent + 2);
    match v {
        Value::Object(map) => {
            out.push('{');
            for (i, (k, val)) in map.iter().enumerate() {
                out.push('\n');
                out.push_str(&inner);
                out.push('"');
                out.push_str(k);
                out.push_str("\": ");
                if let Value::String(s) = val {
                    if s.contains('\n') {
                        out.push_str("|\n");
                        for ln in s.lines() {
                            out.push_str(&inner);
                            out.push_str("  ");
                            out.push_str(ln);
                            out.push('\n');
                        }
                        out.push_str(&inner);
                        out.push_str("  (end)");
                    } else {
                        out.push('"');
                        out.push_str(&s.replace('"', "\\\""));
                        out.push('"');
                    }
                } else {
                    write_human_value(val, out, indent + 2);
                }
                if i + 1 < map.len() { out.push(','); }
            }
            out.push('\n');
            out.push_str(&pad);
            out.push('}');
        }
        Value::Array(arr) => {
            out.push('[');
            for (i, item) in arr.iter().enumerate() {
                out.push('\n');
                out.push_str(&inner);
                write_human_value(item, out, indent + 2);
                if i + 1 < arr.len() { out.push(','); }
            }
            out.push('\n');
            out.push_str(&pad);
            out.push(']');
        }
        Value::String(s) => {
            out.push('"');
            out.push_str(&s.replace('"', "\\\""));
            out.push('"');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// Render the terse colourised line from a parsed event object.
fn terse(v: &Value, command: &str, source: &str) -> String {
    let ts = v.get("ts").and_then(|t| t.as_str()).unwrap_or("");
    let kind = v.get("kind").and_then(|k| k.as_str()).unwrap_or("");
    let ok = v.get("ok").and_then(|b| b.as_bool()).unwrap_or(true);
    let dac = dac_label(command);
    let kind_col = if !ok { BRIGHT_RED } else { colour_for(kind, true) };
    if kind == "done" {
        let outcome = v.get("outcome").and_then(|o| o.as_str()).unwrap_or("ok");
        let ms = v.get("elapsed_ms").and_then(|m| m.as_u64()).unwrap_or(0);
        let n = v.get("event_count").and_then(|m| m.as_u64()).unwrap_or(0);
        let oc = if outcome == "error" { BRIGHT_RED } else { GREEN };
        let plural = if n == 1 { "event" } else { "events" };
        format!(
            "{DIM}[{ts}]{RESET} {dac} {kc}done{RESET} {oc}{outcome}{RESET} {YELLOW}{el}{RESET} {DIM}\u{00b7}{RESET} {n} {plural} {DIM}\u{00b7}{RESET} {MAGENTA}{source}{RESET}",
            ts = ts, dac = dac, kc = kind_col, oc = oc, outcome = outcome,
            el = human_elapsed(ms), n = n, plural = plural, source = source,
        )
    } else {
        let verb = v.get("verb").and_then(|x| x.as_str()).unwrap_or("");
        format!(
            "{DIM}[{ts}]{RESET} {dac} {kc}{kind}{RESET} {verb} {DIM}\u{00b7}{RESET} {MAGENTA}{source}{RESET}",
            ts = ts, dac = dac, kc = kind_col, kind = kind, verb = verb, source = source,
        )
    }
}

/// `[Domain Aggregate Command]` — command word bright-cyan, the rest dim.
fn dac_label(command: &str) -> String {
    let (d, a, c) = parse_fqn(command);
    let words: Vec<String> = [d, a, c].into_iter().filter(|w| !w.is_empty()).collect();
    let mut inner = String::new();
    for (i, w) in words.iter().enumerate() {
        if i > 0 { inner.push(' '); }
        if i + 1 == words.len() { inner.push_str(&format!("{CYAN}{w}{RESET}")); }
        else { inner.push_str(&format!("{DIM}{w}{RESET}")); }
    }
    format!("{DIM}[{RESET}{inner}{DIM}]{RESET}")
}

fn human_elapsed(ms: u64) -> String {
    if ms < 1000 { format!("{ms}ms") } else { format!("{:.1}s", ms as f64 / 1000.0) }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn opts() -> Opts { Opts { needle: None, quiet: false, json: false, pretty: false, exclude: Vec::new() } }
    fn strip(s: String) -> String { crate::runtime::dispatch_detail::strip_ansi(&s) }

    #[test]
    fn renders_event_terse() {
        let l = r#"{"ts":"T","command":"Voice::Voice.Speak","kind":"event","verb":"Voice.Spoke","ok":true,"source":"operator"}"#;
        let out = strip(render(l, &opts()).unwrap());
        assert!(out.contains("Voice.Spoke"), "{out}");
        assert!(out.contains("operator"), "{out}");
        assert!(out.contains("event"), "{out}");
    }

    #[test]
    fn renders_done_with_elapsed() {
        let l = r#"{"ts":"T","command":"Heart::Heart.Beat","kind":"done","outcome":"ok","elapsed_ms":1300,"event_count":2,"source":"process-manager"}"#;
        let out = strip(render(l, &opts()).unwrap());
        assert!(out.contains("done"), "{out}");
        assert!(out.contains("1.3s"), "{out}");
        assert!(out.contains("2 events"), "{out}");
    }

    #[test]
    fn quiet_drops_process_manager() {
        let l = r#"{"command":"Heart::Heart.Beat","kind":"done","source":"process-manager","outcome":"ok","elapsed_ms":1,"event_count":1}"#;
        let q = Opts { needle: None, quiet: true, json: false, pretty: false, exclude: Vec::new() };
        assert!(render(l, &q).is_none());
    }

    #[test]
    fn exclude_matches_command() {
        let l = r#"{"command":"Heart::Heart.Beat","kind":"event","verb":"x","ok":true,"source":"process-manager"}"#;
        let e = Opts { needle: None, quiet: false, json: false, pretty: false, exclude: vec!["Heart".into()] };
        assert!(render(l, &e).is_none());
    }

    #[test]
    fn json_mode_pretty_prints() {
        let l = r#"{"command":"D::A.C","kind":"event","verb":"v","ok":true,"source":"operator"}"#;
        let o = Opts { needle: None, quiet: false, json: true, pretty: false, exclude: Vec::new() };
        let out = render(l, &o).unwrap();
        assert!(out.contains("\"command\""), "{out}");
        assert!(out.contains('\n'), "pretty json is multi-line: {out}");
    }

    #[test]
    fn non_json_line_ignored() {
        assert!(render("just some text", &opts()).is_none());
    }

    #[test]
    fn pretty_unescapes_multiline_shell_command() {
        // shell_command contains a real newline in the JSON source — serde_json
        // parses it back to a Rust String with an actual \n byte.
        let l = r#"{"command":"Tools::ShellTool.Bash","kind":"event","verb":"Bash","ok":true,"source":"operator","shell_command":"echo hello\necho world"}"#;
        let o = Opts { needle: None, quiet: false, json: false, pretty: true, exclude: Vec::new() };
        let out = render(l, &o).unwrap();
        // The rendered output must contain a literal newline inside the value block,
        // NOT the two-character sequence backslash-n.
        assert!(!out.contains("\\n"), "escaped \\n found in pretty output:\n{out}");
        assert!(out.contains("echo hello"), "{out}");
        assert!(out.contains("echo world"), "{out}");
    }
}
