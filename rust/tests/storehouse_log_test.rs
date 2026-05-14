//! Integration tests for the i622 stdout logger.
//!
//! Spawns the storehouse binary against a minimal bluebook fixture and
//! asserts that stdout carries the expected dispatch/event/cascade/
//! policy lines under each `STOREHOUSE_LOG` level. The level is read
//! once per process via OnceLock — so each test invokes a fresh
//! subprocess to flip levels safely.
//!
//! [antibody-exempt: rust/tests/storehouse_log_test.rs — integration
//!  test for the i622 stdout logger. Necessarily Rust : owns
//!  subprocess invocation + STOREHOUSE_LOG env-var gating + stdout
//!  capture, which can't be expressed in a `.bluebook` until the
//!  `:test` adapter family lands.]

use std::path::PathBuf;
use std::process::Command;

fn binary() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) { "debug" } else { "release" });
    p.push("storehouse");
    p
}

fn tmpdir() -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "slog_{}_{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Minimal bluebook : one aggregate with one Create command. The
/// dispatch produces an event the logger captures.
fn fixture_bluebook(dir: &std::path::Path) -> PathBuf {
    let path = dir.join("note.bluebook");
    let src = r#"Hecks.bluebook "NoteTaking" do
  aggregate "Note" do
    description "A note"
    attribute :text
    command "CreateNote" do
      role "Author"
      attribute :text
    end
  end
  entrypoint "Note.CreateNote"
end
"#;
    std::fs::write(&path, src).unwrap();
    path
}

fn run_with_level(level: Option<&str>) -> (String, String, i32) {
    let dir = tmpdir();
    let bb = fixture_bluebook(&dir);
    let mut cmd = Command::new(binary());
    cmd.args(["run", bb.to_str().unwrap(), "text=hello"]);
    cmd.env_remove("STOREHOUSE_LOG");
    if let Some(v) = level {
        cmd.env("STOREHOUSE_LOG", v);
    }
    let out = cmd.output().expect("binary should run");
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    let code = out.status.code().unwrap_or(-1);
    let _ = std::fs::remove_dir_all(&dir);
    (stdout, stderr, code)
}

#[test]
fn normal_emits_dispatch_and_event_lines() {
    let (stdout, stderr, _code) = run_with_level(None); // default = normal
    assert!(
        stdout.contains("dispatch") && stdout.contains("CreateNote"),
        "expected dispatch line ; stdout=\n{}\nstderr=\n{}",
        stdout,
        stderr
    );
    assert!(
        stdout.contains("event") && stdout.contains("NoteCreated"),
        "expected event line ; stdout=\n{}",
        stdout
    );
}

#[test]
fn quiet_suppresses_event_line() {
    let (stdout, _stderr, _code) = run_with_level(Some("quiet"));
    // Dispatch entry survives at quiet (policy + dispatch are the two
    // surfaces every level prints).
    assert!(
        stdout.contains("dispatch"),
        "quiet should still print dispatch ; stdout=\n{}",
        stdout
    );
    // Event line must NOT appear under quiet.
    assert!(
        !stdout.contains("] event "),
        "quiet must suppress event lines ; stdout=\n{}",
        stdout
    );
}

#[test]
fn verbose_includes_attribute_trace() {
    let (stdout, _stderr, _code) = run_with_level(Some("verbose"));
    assert!(
        stdout.contains("dispatch"),
        "verbose should print dispatch ; stdout=\n{}",
        stdout
    );
    assert!(
        stdout.contains("] event "),
        "verbose should print event ; stdout=\n{}",
        stdout
    );
    assert!(
        stdout.contains("] attr ") && stdout.contains("text=hello"),
        "verbose should print attribute trace ; stdout=\n{}",
        stdout
    );
}
