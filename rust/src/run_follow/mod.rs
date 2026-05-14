//! `storehouse follow [stream]` — tail the storehouse bus log.
//!
//! [antibody-exempt: rust/src/run_follow/mod.rs — kernel-surface CLI
//!  primitive paired with rust/src/runtime/storehouse_log.rs. Reads
//!  the same log file the runtime writes ; lives in Rust because it
//!  owns the file-watching + filtering loop. Retires alongside
//!  storehouse_log's exemption when the framework-wide kernel-hook
//!  registry absorbs the logging surface.]
//!
//! Streams new lines from the storehouse log file (the one
//! `runtime::storehouse_log` writes alongside stdout) and prints them
//! filtered to a stream argument :
//!
//!   storehouse follow             # all events (default)
//!   storehouse follow all         # explicit all
//!   storehouse follow dispatch    # only `[...] dispatch ...` lines
//!   storehouse follow event       # only `[...] event ...` lines
//!   storehouse follow cascade     # only `[...] cascade ...` lines
//!   storehouse follow policy      # only `[...] policy ...` lines
//!   storehouse follow ShellTool   # substring filter — any line containing "ShellTool"
//!   storehouse follow Tools::EmailTool  # FQN substring filter
//!
//! Seeks to end-of-file on open so only NEW lines flow through. If the
//! log doesn't exist yet (no dispatches have happened), polls every
//! 100 ms until it appears rather than erroring.

use crate::runtime::storehouse_log;
use std::fs::File;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::Path;
use std::time::Duration;

/// Filter applied to each line read from the log. `All` prints
/// everything ; the four reserved-word variants match the leading verb
/// after the timestamp prefix ; `Substring(s)` is a generic contains-
/// check for any other argument (FQN matches, ad-hoc names, etc.).
#[derive(Debug, Clone)]
pub enum Filter {
    All,
    Surface(&'static str), // "dispatch" | "event" | "cascade" | "policy"
    Substring(String),
}

impl Filter {
    /// Resolve a CLI argument to a Filter. `None` and `Some("all")`
    /// produce `Filter::All` ; the four reserved surface words map to
    /// `Filter::Surface` ; anything else becomes a substring match.
    pub fn from_arg(arg: Option<&str>) -> Filter {
        match arg {
            None | Some("") | Some("all") => Filter::All,
            Some("dispatch") => Filter::Surface("dispatch"),
            Some("event")    => Filter::Surface("event"),
            Some("cascade")  => Filter::Surface("cascade"),
            Some("policy")   => Filter::Surface("policy"),
            Some(s)          => Filter::Substring(s.to_string()),
        }
    }

    /// True when `line` survives the filter. Surface filters look for
    /// the verb word immediately after the timestamp bracket so we
    /// don't accidentally match "dispatch" appearing inside a value.
    pub fn accepts(&self, line: &str) -> bool {
        match self {
            Filter::All => true,
            Filter::Surface(word) => {
                // Line shape : "[2026-05-14T18:42:01Z] dispatch ..."
                // We match on the space-prefixed verb token after the
                // closing bracket to avoid false positives.
                if let Some(rest) = line.split_once("] ").map(|(_, r)| r) {
                    let first = rest.split_whitespace().next().unwrap_or("");
                    first == *word
                } else {
                    false
                }
            }
            Filter::Substring(needle) => line.contains(needle.as_str()),
        }
    }
}

/// Print the follow subcommand's help text to stdout. Mirrors the
/// CLI contract documented in the i590 follow inbox note.
pub fn print_help() {
    let path = storehouse_log::log_file_path();
    println!("storehouse follow [stream]");
    println!();
    println!("Stream live events from the storehouse bus.");
    println!();
    println!("  storehouse follow             # all events (default)");
    println!("  storehouse follow all         # explicit all");
    println!("  storehouse follow dispatch    # only dispatches");
    println!("  storehouse follow event       # only emitted events");
    println!("  storehouse follow cascade     # only cascade steps");
    println!("  storehouse follow policy      # only policy reactions");
    println!("  storehouse follow ShellTool   # substring match — any line mentioning \"ShellTool\"");
    println!("  storehouse follow Tools::EmailTool  # FQN match");
    println!();
    println!("The log lives at $STOREHOUSE_LOG_FILE");
    println!("(default: {}).", path.display());
}

/// Run the follow subcommand. `args` is the full argv slice from
/// main.rs ; we look at `args.get(2)` for the optional stream
/// argument (matching the `storehouse follow [stream]` shape).
/// Returns a Unix-style exit code : 0 on clean SIGINT exit, 1 if
/// `--help` / `-h` printed help, 0 otherwise.
pub fn run(args: &[String]) -> i32 {
    let stream_arg = args.get(2).map(|s| s.as_str());
    if matches!(stream_arg, Some("--help") | Some("-h") | Some("help")) {
        print_help();
        return 0;
    }
    let filter = Filter::from_arg(stream_arg);
    let path = storehouse_log::log_file_path();
    tail_file(&path, &filter);
    0
}

/// Tail `path` for new lines and pipe survivors of `filter` to stdout.
/// Polls every 100 ms when there's nothing new ; if the file doesn't
/// exist yet, polls until it appears. Exits cleanly on SIGINT (the
/// default Rust signal handler turns Ctrl-C into a process exit).
fn tail_file(path: &Path, filter: &Filter) {
    let poll = Duration::from_millis(100);
    // Wait for the file to appear if it doesn't exist yet — operators
    // run `storehouse follow` before any dispatches in a fresh repo.
    let mut file = loop {
        match File::open(path) {
            Ok(f) => break f,
            Err(_) => std::thread::sleep(poll),
        }
    };
    // Seek to end so we only see NEW lines, not the whole history.
    let _ = file.seek(SeekFrom::End(0));
    let mut reader = BufReader::new(file);
    let mut buf = String::new();
    loop {
        buf.clear();
        match reader.read_line(&mut buf) {
            Ok(0) => {
                // No new bytes. Sleep briefly, then try again. Also
                // re-check that the file still exists ; if it was
                // rotated / deleted we re-open from the new path.
                std::thread::sleep(poll);
                if !path.exists() {
                    // Wait for the file to come back, then re-open.
                    let new_file = loop {
                        match File::open(path) {
                            Ok(f) => break f,
                            Err(_) => std::thread::sleep(poll),
                        }
                    };
                    reader = BufReader::new(new_file);
                }
            }
            Ok(_) => {
                let line = buf.trim_end_matches('\n').trim_end_matches('\r');
                if !line.is_empty() && filter.accepts(line) {
                    println!("{}", line);
                    // Flush so the next process in a pipeline sees it
                    // immediately. read_line + println! buffer otherwise.
                    use std::io::Write as _;
                    let _ = std::io::stdout().flush();
                }
            }
            Err(_) => {
                // Transient I/O error ; sleep and try again rather than
                // crashing the operator's follow session.
                std::thread::sleep(poll);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_all_default() {
        let f = Filter::from_arg(None);
        assert!(f.accepts("[2026-05-14T00:00:00Z] dispatch X#1"));
        assert!(f.accepts("[2026-05-14T00:00:00Z] event A.B#1"));
        assert!(f.accepts("[2026-05-14T00:00:00Z] anything"));
    }

    #[test]
    fn filter_all_explicit() {
        let f = Filter::from_arg(Some("all"));
        assert!(matches!(f, Filter::All));
        assert!(f.accepts("[ts] cascade C#1 ok=true"));
    }

    #[test]
    fn filter_dispatch_excludes_event() {
        let f = Filter::from_arg(Some("dispatch"));
        assert!(f.accepts("[2026-05-14T00:00:00Z] dispatch Tools::ShellTool.Bash#1"));
        assert!(!f.accepts("[2026-05-14T00:00:00Z] event ShellTool.BashRan#1"));
        assert!(!f.accepts("[2026-05-14T00:00:00Z] cascade Cascade.RecordResult#1 ok=true"));
        assert!(!f.accepts("[2026-05-14T00:00:00Z] policy OnX on A.B#1 -> Y"));
    }

    #[test]
    fn filter_event_excludes_dispatch() {
        let f = Filter::from_arg(Some("event"));
        assert!(f.accepts("[ts] event Foo.Bar#1"));
        assert!(!f.accepts("[ts] dispatch Foo.Bar#1"));
    }

    #[test]
    fn filter_cascade_excludes_others() {
        let f = Filter::from_arg(Some("cascade"));
        assert!(f.accepts("[ts] cascade Cascade.RecordResult#1 ok=true"));
        assert!(!f.accepts("[ts] dispatch Tools::ShellTool.Bash#1"));
        assert!(!f.accepts("[ts] event ShellTool.BashRan#1"));
    }

    #[test]
    fn filter_policy_excludes_others() {
        let f = Filter::from_arg(Some("policy"));
        assert!(f.accepts("[ts] policy OnBashRan on ShellTool.BashRan#1 -> Cascade.RecordResult"));
        assert!(!f.accepts("[ts] dispatch X#1"));
        assert!(!f.accepts("[ts] event X.Y#1"));
        assert!(!f.accepts("[ts] cascade X#1 ok=true"));
    }

    #[test]
    fn filter_substring_matches_fqn() {
        let f = Filter::from_arg(Some("ShellTool"));
        assert!(f.accepts("[ts] dispatch Tools::ShellTool.Bash#1"));
        assert!(f.accepts("[ts] event ShellTool.BashRan#1"));
        assert!(!f.accepts("[ts] dispatch Tools::FileTool.Read#1"));
        assert!(!f.accepts("[ts] event FileTool.FileRead#1"));
    }

    #[test]
    fn filter_substring_full_fqn() {
        let f = Filter::from_arg(Some("Tools::EmailTool"));
        assert!(f.accepts("[ts] dispatch Tools::EmailTool.Send#1"));
        assert!(!f.accepts("[ts] dispatch Tools::ShellTool.Bash#1"));
    }

    #[test]
    fn filter_surface_ignores_substring_in_payload() {
        // A description containing the word "dispatch" must NOT
        // match the `dispatch` surface filter — only the leading
        // verb after the bracket counts.
        let f = Filter::from_arg(Some("dispatch"));
        assert!(!f.accepts("[ts] event Foo.Bar#1 dispatch happened earlier"));
    }
}
