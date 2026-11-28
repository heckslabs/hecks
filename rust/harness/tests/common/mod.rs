//! What the integration tests share: the supervisor run as a child, its tells read on a thread of
//! their own, and the Harness bluebook's part (routing each `sent` tell to a `deliver` op) played
//! by the test.

// Each test crate uses some of these helpers, so the rest are dead code to it.
#![allow(dead_code)]
// The helpers below fail the test that calls them, so they expect as a test does.
#![allow(clippy::expect_used)]

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread;
use std::time::Duration;

use hecks_harness::json::{self, Value};

pub const BIN: &str = env!("CARGO_BIN_EXE_hecks-harness");
pub const WAIT: Duration = Duration::from_secs(20);

pub fn tape(name: &str) -> String {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/tapes")
        .join(name)
        .display()
        .to_string()
}

/// The supervisor, with its tells read on a thread of their own.
pub struct Served {
    child: Child,
    ops: ChildStdin,
    tells: Receiver<String>,
    heard: Vec<String>,
}

impl Served {
    pub fn start() -> Self {
        Self::start_with(&[])
    }

    /// The supervisor, started with these flags after `serve`.
    pub fn start_with(flags: &[&str]) -> Self {
        let mut child = Command::new(BIN)
            .arg("serve")
            .args(flags)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .expect("the supervisor starts");
        let ops = child.stdin.take().expect("its stdin");
        let stdout = child.stdout.take().expect("its stdout");
        let (lines, tells) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if lines.send(line).is_err() {
                    return;
                }
            }
        });
        Self {
            child,
            ops,
            tells,
            heard: Vec::new(),
        }
    }

    pub fn op(&mut self, op: &Value) {
        writeln!(self.ops, "{}", op.to_json()).expect("an op is written");
    }

    pub fn open(&mut self, session: &str, tape_name: &str, brief: &str) {
        self.op(&Value::object(vec![
            ("op", Value::text("open")),
            ("session", Value::text(session)),
            ("program", Value::text(BIN)),
            (
                "args",
                Value::Array(vec![Value::text("replay"), Value::text(tape(tape_name))]),
            ),
            ("brief", Value::text(brief)),
        ]));
    }

    /// The next tell, kept in `heard`.
    pub fn next(&mut self) -> Value {
        let line = self
            .tells
            .recv_timeout(WAIT)
            .expect("a tell arrives in time");
        self.heard.push(line.clone());
        json::parse(&line).expect("a tell is JSON")
    }

    /// Routes every `sent` tell to its addressee, urgent or not, until `done` holds, as the bluebook's
    /// policy does.
    pub fn route_until(&mut self, done: impl Fn(&[Value]) -> bool) -> Vec<Value> {
        let mut seen = Vec::new();
        while !done(&seen) {
            let tell = self.next();
            if tell.str_at("tell") == Some("sent") {
                self.op(&Value::object(vec![
                    ("op", Value::text("deliver")),
                    (
                        "session",
                        Value::text(tell.str_at("to").unwrap_or_default()),
                    ),
                    (
                        "message",
                        Value::text(tell.str_at("message").unwrap_or_default()),
                    ),
                    (
                        "from",
                        Value::text(tell.str_at("session").unwrap_or_default()),
                    ),
                    ("text", Value::text(tell.str_at("text").unwrap_or_default())),
                    (
                        "about",
                        Value::text(tell.str_at("about").unwrap_or_default()),
                    ),
                    (
                        "urgent",
                        Value::Bool(tell.get("urgent").and_then(Value::as_bool) == Some(true)),
                    ),
                ]));
            }
            seen.push(tell);
        }
        seen
    }

    pub fn quit(mut self) -> (Vec<Value>, Vec<String>) {
        self.op(&Value::object(vec![("op", Value::text("quit"))]));
        let mut rest = Vec::new();
        loop {
            let tell = self.next();
            let last = tell.str_at("tell") == Some("quit");
            rest.push(tell);
            if last {
                break;
            }
        }
        assert!(self.child.wait().expect("the supervisor exits").success());
        (rest, self.heard)
    }
}

pub fn count(tells: &[Value], kind: &str, session: &str) -> usize {
    tells
        .iter()
        .filter(|tell| tell.str_at("tell") == Some(kind) && tell.str_at("session") == Some(session))
        .count()
}
