//! The closed form's guard: every escape fixture under `tests/fixtures/closed/refused/` is refused
//! at its line for its reason, the admitted fixtures pass, and every bluebook, hecksagon, world and
//! context map the repository tracks passes `hecks-parse closed --check`, `bluebook.bluebook` first.

// reason: these helpers are test scaffolding outside `#[test]` fns, which clippy.toml does not
// cover; a failed unwrap here is the test failing.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// Each escape fixture, the line it is refused at and a piece of the reason it is refused for.
const REFUSED: &[(&str, usize, &str)] = &[
        ("argument_backticks.bluebook", 4, "a backtick runs a shell command"),
        ("argument_const_get.bluebook", 4, "`Object` is a handle on the host (its process, files or environment)"),
        ("argument_constant_call.bluebook", 4, "a method is called on a constant; an argument is a literal, not an expression"),
        ("argument_env.bluebook", 4, "`ENV` is a handle on the host (its process, files or environment)"),
        ("argument_file.bluebook", 4, "`File` is a handle on the host (its process, files or environment)"),
        ("argument_global.bluebook", 4, "`$` reads a global variable"),
        ("argument_host_constant.bluebook", 4, "`File` is a handle on the host (its process, files or environment)"),
        ("argument_interpolation.bluebook", 4, "an interpolation (`#{…}`) runs Ruby; a closed literal spells its text out"),
        ("argument_io.bluebook", 4, "`IO` is a handle on the host (its process, files or environment)"),
        ("argument_lambda.bluebook", 4, "`->` makes a lambda; an argument is a literal"),
        ("argument_modifier.bluebook", 4, "`if` is Ruby control flow; an argument list holds literals only"),
        ("argument_percent_shell.bluebook", 4, "only %w, %i and %q percent literals are closed; the others interpolate or run a shell"),
        ("block_assignment.bluebook", 4, "'name = ENV[\"HOME\"]' looks like a local variable assignment at byte 0 — this parser never interprets bare Ruby expressions or assignment"),
        ("block_conditional.bluebook", 4, "'if' is a bare Ruby control-flow/declaration form, which this parser never interprets — a bluebook may only use keyword calls this language declares"),
        ("block_define_method.bluebook", 4, "'define_method' is not a word Aggregate admits"),
        ("block_eval.bluebook", 4, "'eval' is not a word Aggregate admits"),
        ("block_file_read.bluebook", 4, "`File` is a handle on the host (its process, files or environment)"),
        ("block_heredoc.bluebook", 4, "`<<` opens a heredoc or appends"),
        ("block_instance_eval.bluebook", 4, "'instance_eval' is not a word Aggregate admits"),
        ("block_load.bluebook", 4, "'load' is not a word Aggregate admits"),
        ("block_nested_declaration.bluebook", 4, "`Hecks` opens the line, so Ruby would run it; a line opens on a declaration word"),
        ("block_params.bluebook", 4, "'lifecycle' opens a block with parameters |x|; a declaration block takes none"),
        ("block_public_send.bluebook", 4, "'public_send' is not a word Aggregate admits"),
        ("block_require.bluebook", 4, "'require' is not a word Aggregate admits"),
        ("block_semicolon.bluebook", 4, "`;` starts a second statement; a line holds one word call"),
        ("block_send.bluebook", 4, "'send' is not a word Aggregate admits"),
        ("hecksagon_env.hecksagon", 3, "`ENV` is a handle on the host (its process, files or environment)"),
        ("hecksagon_host_receiver.hecksagon", 3, "`File` is a handle on the host (its process, files or environment)"),
        ("hecksagon_loop.hecksagon", 3, "'%w[A B].each { |name| attaches name }' is not a word call — every line must be a keyword call or `end`"),
        ("hecksagon_receiver_send.hecksagon", 3, "'send' is a Ruby method, not a declaration word — Ruby would run it"),
        ("hecksagon_require.hecksagon", 2, "'require \"open3\"' sits outside any declaration — a file holds only `Hecks.<word> … do … end` declarations"),
        ("hecksagon_ruby_method.hecksagon", 3, "'system' is a Ruby method, not a declaration word — Ruby would run it"),
        ("loop_each.bluebook", 4, "'%w[a b].each { |w| attribute w.to_sym, String }' is not a word call — every line must be a keyword call or `end`"),
        ("loop_times.bluebook", 4, "'3.times { attribute :x, String }' is not a word call — every line must be a keyword call or `end`"),
        ("retired_process_manager.bluebook", 5, "process_manager is gone — saga is the word now"),
        ("rule_assignment.bluebook", 4, "`=` assigns; a rule compares with `==`"),
        ("rule_backticks.bluebook", 4, "a backtick runs a shell command"),
        ("rule_block_call.bluebook", 4, "`then` is Ruby, not a rule: the rule language has no such call"),
        ("rule_env.bluebook", 4, "`ENV` is a handle on the host (its process, files or environment)"),
        ("rule_eval.bluebook", 4, "`eval` is Ruby, not a rule: the rule language has no such call"),
        ("rule_file.bluebook", 4, "`File` is a handle on the host (its process, files or environment)"),
        ("rule_global.bluebook", 4, "`$` reads a global variable"),
        ("rule_instance_eval.bluebook", 4, "`instance_eval` is Ruby, not a rule: the rule language has no such call"),
        ("rule_interpolation.bluebook", 4, "an interpolation (`#{…}`) runs Ruby; a closed literal spells its text out"),
        ("rule_ivar.bluebook", 4, "`@` reads an instance variable"),
        ("rule_kernel.bluebook", 4, "`Kernel` is a handle on the host (its process, files or environment)"),
        ("rule_lambda.bluebook", 4, "`->` makes a lambda; a rule is an expression"),
        ("rule_semicolon.bluebook", 4, "`;` starts a second statement; a rule is one expression"),
        ("rule_send.bluebook", 4, "`send` is Ruby, not a rule: the rule language has no such call"),
        ("sets_block.bluebook", 5, "'sets' was written with a `{ ... }` block"),
        ("sets_method.bluebook", 5, "`instance_eval` is a Ruby method, not an operand — Ruby would run it"),
        ("top_level_after.bluebook", 7, "'puts \"loaded\"' sits outside any declaration — a file holds only `Hecks.<word> … do … end` declarations"),
        ("top_level_call.bluebook", 2, "'system(\"id\")' sits outside any declaration — a file holds only `Hecks.<word> … do … end` declarations"),
        ("top_level_constant.bluebook", 2, "'LIMIT = 3' sits outside any declaration — a file holds only `Hecks.<word> … do … end` declarations"),
        ("top_level_env.bluebook", 2, "'ENV[\"X\"] = \"1\"' sits outside any declaration — a file holds only `Hecks.<word> … do … end` declarations"),
        ("top_level_require.bluebook", 2, "'require \"open3\"' sits outside any declaration — a file holds only `Hecks.<word> … do … end` declarations"),
        ("world_env.world", 3, "`ENV` is a handle on the host (its process, files or environment)"),
        ("world_exit.world", 3, "'exit' is a Ruby method, not a declaration word — Ruby would run it"),
        ("world_home.world", 4, "`File` is a handle on the host (its process, files or environment)"),
        ("world_interpolation.world", 3, "an interpolation (`#{…}`) runs Ruby; a closed literal spells its text out"),
];

/// Parser fixtures that test another subcommand's refusals, or the `world` subcommand's own reading
/// of `ENV.fetch`; the closed form refuses each, at the line and for the reason given.
const OUTSIDE_THE_VOCABULARY: &[(&str, usize, &str)] = &[
    (
        "rust/parser/tests/fixtures/world_bad_unterminated.world",
        4,
        "a block is never closed",
    ),
    (
        "rust/parser/tests/fixtures/world_bad_word.world",
        2,
        "'puts' is a Ruby method",
    ),
    (
        "rust/parser/tests/fixtures/world_bindings.world",
        1,
        "sits outside any declaration",
    ),
    (
        "rust/parser/tests/fixtures/world_env_database.world",
        2,
        "`ENV` is a handle on the host",
    ),
];

/// The admitted fixtures: the words, literals, rules and values each kind of file is written in.
const ADMITTED: &[&str] = &[
    "rules_and_values.bluebook",
    "settings.world",
    "wiring.hecksagon",
];

/// The bluebook every other bluebook is written in, checked before the rest.
const FIRST: &str = "lib/hecks/language/bluebook/bluebook.bluebook";

fn crate_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn repository() -> PathBuf {
    crate_dir().join("../..").canonicalize().unwrap()
}

fn closed(args: &[&str], dir: &Path) -> Output {
    Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .arg("closed")
        .args(args)
        .current_dir(dir)
        .output()
        .expect("failed to run hecks-parse")
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// Asserts `path` is refused at `line` with `reason` in its message.
fn assert_refused(path: &str, line: usize, reason: &str, dir: &Path) {
    let output = closed(&[path], dir);
    let message = stderr(&output);
    assert_eq!(output.status.code(), Some(1), "{path} was admitted");
    assert!(
        message.contains(&format!("{path}:{line}")),
        "{path}: refused elsewhere: {message}"
    );
    assert!(
        message.contains(reason),
        "{path}: refused for another reason: {message}"
    );
}

/// The sorted names of the files in `dir`.
fn names_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

#[test]
fn every_escape_fixture_is_refused_at_its_line() {
    let dir = crate_dir().join("tests/fixtures/closed/refused");
    let mut listed: Vec<&str> = REFUSED.iter().map(|(name, ..)| *name).collect();
    listed.sort_unstable();
    assert_eq!(
        names_in(&dir),
        listed,
        "every escape fixture has one row in REFUSED, and no more"
    );
    for (name, line, reason) in REFUSED {
        assert_refused(name, *line, reason, &dir);
    }
}

#[test]
fn the_admitted_fixtures_come_back_line_for_line() {
    let dir = crate_dir().join("tests/fixtures/closed/admitted");
    assert_eq!(
        names_in(&dir),
        ADMITTED,
        "every admitted fixture is listed in ADMITTED, and no more"
    );
    for name in ADMITTED {
        let output = closed(&[name], &dir);
        let source = std::fs::read_to_string(dir.join(name)).unwrap();
        let text = String::from_utf8_lossy(&output.stdout);
        assert!(output.status.success(), "{name}: {}", stderr(&output));
        assert_eq!(text.lines().count(), source.lines().count(), "{name}");
    }
}

#[test]
fn frozen_era_text_keeps_the_process_manager_spelling_live_source_refuses() {
    // ADR 0180: the gem reads text held from an earlier era with `--frozen` while it
    // shadow-parses, so a saga spelled `process_manager` there still comes back line for line.
    let dir = crate_dir().join("tests/fixtures/closed/refused");
    let name = "retired_process_manager.bluebook";
    let output = closed(&["--frozen", name], &dir);
    let source = std::fs::read_to_string(dir.join(name)).unwrap();
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).lines().count(),
        source.lines().count()
    );
}

/// Every declaration file the repository tracks, `bluebook.bluebook` first, leaving out the escape
/// fixtures and the parser fixtures listed in `OUTSIDE_THE_VOCABULARY`.
fn tracked_declarations(root: &Path) -> Vec<String> {
    let output = Command::new("git")
        .args(["ls-files", "--cached", "--others", "--exclude-standard"])
        .args(["*.bluebook", "*.hecksagon", "*.world", "*.contextmap"])
        .current_dir(root)
        .output()
        .expect("the guard reads the file list from git");
    assert!(
        output.status.success(),
        "git ls-files failed: {}",
        stderr(&output)
    );
    let listed = String::from_utf8(output.stdout).unwrap();
    let skipped = |path: &str| {
        path.starts_with("rust/parser/tests/fixtures/closed/refused/")
            || OUTSIDE_THE_VOCABULARY
                .iter()
                .any(|(known, ..)| *known == path)
    };
    let mut files: Vec<String> = listed
        .lines()
        .filter(|path| !skipped(path) && root.join(path).is_file())
        .map(str::to_string)
        .collect();
    files.sort_by_key(|path| (path != FIRST, path.clone()));
    files
}

#[test]
fn every_declaration_file_in_the_repository_is_closed() {
    let root = repository();
    let files = tracked_declarations(&root);
    assert_eq!(
        files.first().map(String::as_str),
        Some(FIRST),
        "bluebook.bluebook is checked first"
    );
    let args: Vec<&str> = std::iter::once("--check")
        .chain(files.iter().map(String::as_str))
        .collect();
    let output = closed(&args, &root);
    println!("{}", String::from_utf8_lossy(&output.stdout).trim_end());
    assert!(
        output.status.success(),
        "these files reach outside the closed vocabulary:\n{}",
        stderr(&output)
    );
    for (path, line, reason) in OUTSIDE_THE_VOCABULARY {
        assert_refused(path, *line, reason, &root);
    }
}
