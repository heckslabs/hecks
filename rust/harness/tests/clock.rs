//! The supervisor keeps the run's clock: it writes a `tick` tell every interval, with no session
//! open and nothing said, so a wait the Harness bluebook times is checked even in a quiet run.

// The helpers below fail the test that calls them, so they expect as a test does.
#![allow(clippy::expect_used)]

mod common;

use std::process::{Command, Stdio};

use common::{Served, BIN};

#[test]
fn a_quiet_supervisor_ticks_on_its_own_clock() {
    let mut served = Served::start_with(&["--tick-ms", "40"]);
    assert_eq!(served.next().str_at("tell"), Some("ready"));
    let ticks: Vec<f64> = (0..3)
        .map(|_| {
            let tell = served.next();
            assert_eq!(tell.str_at("tell"), Some("tick"));
            tell.get("at_ms")
                .and_then(hecks_harness::json::Value::as_f64)
                .expect("a tick is stamped")
        })
        .collect();
    assert!(
        ticks[0] >= 40.0 && ticks.windows(2).all(|pair| pair[1] > pair[0]),
        "{ticks:?}"
    );
    served.quit();
}

#[test]
fn the_tick_and_the_recording_are_named_in_either_order() {
    let dir = std::env::temp_dir().join(format!("hecks-harness-clock-{}", std::process::id()));
    let dir_text = dir.display().to_string();
    let mut served = Served::start_with(&["--tick-ms", "40", "--record", &dir_text]);
    served.next();
    assert_eq!(served.next().str_at("tell"), Some("tick"));
    served.quit();
    assert!(dir.is_dir());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_tick_that_is_not_a_positive_whole_number_is_refused() {
    for flags in [
        &["--tick-ms", "0"][..],
        &["--tick-ms", "soon"],
        &["--tick-ms"],
    ] {
        let run = Command::new(BIN)
            .arg("serve")
            .args(flags)
            .stdin(Stdio::null())
            .output()
            .expect("the binary runs");
        assert_eq!(run.status.code(), Some(2), "{flags:?}");
        assert!(run.stdout.is_empty(), "{flags:?}");
    }
}
