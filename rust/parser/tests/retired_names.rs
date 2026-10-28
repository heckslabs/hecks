//! The spellings ADR 0134 retires still work, say once that they are retired, and give the same
//! answer as the new ones: the `chapter` subcommand, the `--chapter` flag and the `gem_chapters`
//! key of `resolve`.

// reason: these helpers are test scaffolding outside `#[test]` fns, which clippy.toml does not
// cover; a failed unwrap here is the test failing.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::PathBuf;
use std::process::{Command, Output};

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args(args)
        .output()
        .expect("failed to run hecks-parse")
}

fn deprecation_lines(output: &Output) -> Vec<String> {
    String::from_utf8_lossy(&output.stderr)
        .lines()
        .filter(|line| line.contains("is deprecated"))
        .map(str::to_string)
        .collect()
}

#[test]
fn the_chapter_subcommand_and_flag_answer_as_the_new_names_do() {
    let path = fixture("command.bluebook");
    let file = path.to_str().unwrap();
    let new = run(&["bluebook", "--bluebook", "FixtureCommand", file]);
    let old = run(&["chapter", "--chapter", "FixtureCommand", file]);

    assert!(new.status.success() && old.status.success());
    assert_eq!(new.stdout, old.stdout);
    assert!(deprecation_lines(&new).is_empty());
    assert_eq!(
        deprecation_lines(&old),
        vec![
            "hecks-parse: the chapter subcommand is deprecated, use bluebook".to_string(),
            "hecks-parse: --chapter is deprecated, use --bluebook".to_string(),
        ]
    );
}

#[test]
fn the_chapter_flag_alone_is_named_on_the_new_subcommands() {
    let path = fixture("command.bluebook");
    let file = path.to_str().unwrap();
    let old = run(&["format", "--chapter", "FixtureCommand", file]);

    assert!(old.status.success());
    assert_eq!(
        deprecation_lines(&old),
        vec!["hecks-parse: --chapter is deprecated, use --bluebook".to_string()]
    );
}

#[test]
fn resolve_carries_the_list_under_both_keys_and_takes_either_flag() {
    let path = fixture("hecksagon.hecksagon");
    let file = path.to_str().unwrap();
    let new = run(&["resolve", "--bluebook", "FixtureHecksagon", file]);
    let old = run(&["resolve", "--chapter", "FixtureHecksagon", file]);
    let stdout = String::from_utf8_lossy(&new.stdout);

    assert!(new.status.success() && old.status.success(), "{stdout}");
    assert_eq!(new.stdout, old.stdout);
    assert!(stdout.contains("\"gem_bluebooks\""), "{stdout}");
    assert!(stdout.contains("\"gem_chapters\""), "{stdout}");
    assert_eq!(deprecation_lines(&old).len(), 1);
}
