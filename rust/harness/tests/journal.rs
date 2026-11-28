//! A recorded run replays through the harness: the urgent exchange is run on its tapes with its
//! journal recorded, each session's recording is turned into a tape, and the same sessions are run
//! again on those tapes. The replay's journal is held to the run's, act by act; a tape changed to
//! say something else is the session's surprise.

// The helpers below fail the test that calls them, so they expect as a test does.
#![allow(clippy::expect_used)]

mod common;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

use common::{count, tape, Served, BIN};
use hecks_harness::json::{self, Value};

const SESSIONS: [(&str, &str, u64); 3] = [
    ("worker", "You are the worker. Carry the change through.", 3),
    ("peer", "You are the peer. Leave the worker a note.", 1),
    ("lead", "You are the lead. Main just moved.", 1),
];

static SCRATCH: AtomicUsize = AtomicUsize::new(0);

/// A new, empty directory of this test run's own.
fn scratch(name: &str) -> PathBuf {
    let made = SCRATCH.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "hecks-journal-{}-{made}-{name}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("a scratch directory");
    dir
}

/// Runs the urgent exchange with each session played from `tapes(session)`, its journal in `record`.
fn run(record: &Path, tapes: impl Fn(&str) -> String) {
    let record_text = record.display().to_string();
    let mut served = Served::start_with(&["--record", &record_text]);
    assert_eq!(served.next().str_at("tell"), Some("ready"));
    for (session, brief, _) in SESSIONS {
        served.op(&Value::object(vec![
            ("op", Value::text("open")),
            ("session", Value::text(session)),
            ("program", Value::text(BIN)),
            (
                "args",
                Value::Array(vec![Value::text("replay"), Value::text(tapes(session))]),
            ),
            ("brief", Value::text(brief)),
        ]));
    }
    served.route_until(|seen| {
        SESSIONS
            .iter()
            .all(|(session, _, turns)| count(seen, "turn_ended", session) as u64 == *turns)
    });
    served.quit();
}

/// Each session's recording in `journal` turned into a tape in a new directory.
fn taped(journal: &Path, name: &str) -> PathBuf {
    let dir = scratch(name);
    for (session, _, _) in SESSIONS {
        let recording = journal.join(format!("{session}.jsonl"));
        let made = Command::new(BIN)
            .arg("tape")
            .arg(&recording)
            .output()
            .expect("the tape is made");
        assert!(made.status.success(), "{made:?}");
        fs::write(dir.join(format!("{session}.jsonl")), made.stdout).expect("the tape is written");
    }
    dir
}

fn compared(journal: &Path, replay: &Path) -> (bool, Value) {
    let output = Command::new(BIN)
        .arg("compare")
        .arg(journal)
        .arg(replay)
        .output()
        .expect("the journals are compared");
    let text = String::from_utf8(output.stdout).expect("UTF-8");
    (
        output.status.success(),
        json::parse(text.trim()).expect("JSON"),
    )
}

fn journal_of_the_run() -> PathBuf {
    let journal = scratch("journal");
    run(&journal, |session| tape(&format!("urgent_{session}.jsonl")));
    journal
}

#[test]
fn a_run_replayed_from_its_journal_does_all_the_journal_says() {
    let journal = journal_of_the_run();
    let tapes = taped(&journal, "tapes");
    let replay = scratch("replay");
    run(&replay, |session| {
        tapes.join(format!("{session}.jsonl")).display().to_string()
    });
    let (held, outcome) = compared(&journal, &replay);
    assert!(held, "{}", outcome.to_json());
    assert_eq!(outcome.get("sessions"), Some(&Value::Number(3.0)));
    assert_eq!(outcome.get("surprises"), Some(&Value::Array(vec![])));
}

#[test]
fn a_session_that_says_otherwise_in_the_replay_is_its_surprise() {
    let journal = journal_of_the_run();
    let tapes = taped(&journal, "changed");
    let lead = tapes.join("lead.jsonl");
    let changed = fs::read_to_string(&lead)
        .expect("the lead's tape")
        .replace("main moved", "main stayed");
    assert!(changed.contains("main stayed"), "{changed}");
    fs::write(&lead, changed).expect("the changed tape");
    let replay = scratch("diverged");
    run(&replay, |session| {
        tapes.join(format!("{session}.jsonl")).display().to_string()
    });
    let (held, outcome) = compared(&journal, &replay);
    assert!(!held);
    let surprises = outcome
        .get("surprises")
        .and_then(Value::as_array)
        .expect("surprises");
    let lead = surprises
        .iter()
        .find(|surprise| surprise.str_at("session") == Some("lead"))
        .expect("the lead's surprise");
    assert_eq!(
        lead.get("journal").and_then(|act| act.str_at("act")),
        Some("sent")
    );
    assert!(lead
        .get("replay")
        .and_then(|act| act.str_at("text"))
        .is_some_and(|text| text.contains("main stayed")));
}

#[test]
fn outlines_each_sessions_turns() {
    let journal = journal_of_the_run();
    let output = Command::new(BIN)
        .arg("journal")
        .arg(&journal)
        .output()
        .expect("the journal is read");
    let outline =
        json::parse(String::from_utf8(output.stdout).expect("UTF-8").trim()).expect("JSON");
    for (session, _, turns) in SESSIONS {
        assert_eq!(
            outline.get(session).and_then(|counts| counts.get("turns")),
            Some(&Value::Number(turns as f64)),
            "{}",
            outline.to_json()
        );
    }
}
