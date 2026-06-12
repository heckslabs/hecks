//! Regression pin for the FileTool.Edit ARGV path — multi-line
//! `old_string` with leading whitespace on continuation lines.
//!
//! The inbox card `filetool-edit-multiline-whitespace-2026-06-11.md`
//! reported `old_string not found` whenever a continuation line carried
//! leading indentation, suspecting the CLI's k=v transport. The unit
//! tests in `claude_tool_dispatcher` enter BELOW that transport, so
//! they could not arbitrate. This test spawns the REAL binary —
//! `storehouse <dir> Files::FileTool.Edit old_string=<multi-line> …` —
//! so the whole path (argv → splitn k=v parse → Value::Str → edit
//! matcher) is pinned byte-for-byte. If any layer ever trims or
//! collapses a newline + leading spaces, these tests go red.
//!
//! Usage : `cargo test --release --test filetool_edit_argv_test`
//!
//! [antibody-exempt: rust/tests/filetool_edit_argv_test.rs — kernel-floor
//!  argv-transport pin. Necessarily Rust : spawns the real storehouse
//!  binary and asserts byte-fidelity of the argv → k=v → matcher layer,
//!  which a .behaviors file cannot reach because behaviors dispatch ABOVE
//!  that transport — the transport is the thing under test. Same category
//!  as the storehouse_log_test.rs exemption, until the :test adapter
//!  family lands.]

use std::path::PathBuf;
use std::process::Command;

fn binary() -> PathBuf {
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) { "debug" } else { "release" });
    p.push("storehouse");
    p
}

fn tmpdir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!(
        "ft_edit_argv_{}_{}_{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Minimal FileTool fixture mirroring the conception's shape : the
/// command declares file_path/old_string/new_string ; the companion
/// hecksagon binds the :claude_tool :edit dispatcher.
fn write_fixture(dir: &std::path::Path) {
    std::fs::write(
        dir.join("files.bluebook"),
        "Hecks.bluebook \"Files\" do\n  entrypoint \"Edit\"\n  aggregate \"FileTool\" do\n    identified_by :id\n    attribute :id, String\n    attribute :file_path, String\n    command \"Edit\" do\n      attribute :id, String\n      attribute :file_path, String\n      attribute :old_string, String\n      attribute :new_string, String\n      then_set :file_path, to: :file_path\n      emits \"EditApplied\"\n    end\n  end\nend\n",
    )
    .unwrap();
    std::fs::write(
        dir.join("files.hecksagon"),
        "Hecks.hecksagon \"Files\" do\n  adapter :memory\n  adapter :claude_tool, command: \"FileTool.Edit\", tool: :edit\nend\n",
    )
    .unwrap();
}

/// Dispatch one Edit through the real binary and return (status, target
/// file content after). old/new arrive as SINGLE argv elements — the
/// exact shape the MCP door's one-shot spawn produces.
fn dispatch_edit(tag: &str, original: &str, old: &str, new: &str) -> (bool, String) {
    let dir = tmpdir(tag);
    write_fixture(&dir);
    let target = dir.join("target.rs");
    std::fs::write(&target, original).unwrap();

    let out = Command::new(binary())
        .arg(dir.to_str().unwrap())
        .arg("Files::FileTool.Edit")
        .arg(format!("id=t_{}", tag))
        .arg(format!("file_path={}", target.display()))
        .arg(format!("old_string={}", old))
        .arg(format!("new_string={}", new))
        .output()
        .expect("failed to spawn storehouse binary");

    let after = std::fs::read_to_string(&target).unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    (out.status.success(), after)
}

#[test]
fn multi_line_old_string_with_indented_continuation_lines_matches() {
    // The card's reported failure shape : 12-space struct-literal
    // continuation lines after a newline.
    let original = "impl Foo {\n    fn bar() {\n        Some(Baz {\n            name: \"x\".into(),\n            produces: None,\n        })\n    }\n}\n";
    let old = "        Some(Baz {\n            name: \"x\".into(),\n            produces: None,";
    let new = "        Some(Baz {\n            name: \"y\".into(),\n            produces: None,";
    let (ok, after) = dispatch_edit("deep", original, old, new);
    assert!(ok, "edit dispatch must exit 0");
    assert!(
        after.contains("name: \"y\".into()"),
        "multi-line old_string with 12-space continuation lines must match byte-for-byte ; file after :\n{}",
        after
    );
}

#[test]
fn tab_indented_continuation_lines_match() {
    let original = "mod x {\n\tfn tabbed() {\n\t\tlet z = 1;\n\t}\n}\n";
    let old = "mod x {\n\tfn tabbed() {\n\t\tlet z = 1;";
    let new = "mod x {\n\tfn tabbed() {\n\t\tlet z = 2;";
    let (ok, after) = dispatch_edit("tabs", original, old, new);
    assert!(ok, "edit dispatch must exit 0");
    assert!(
        after.contains("let z = 2;"),
        "tab-indented continuation lines must match ; file after :\n{}",
        after
    );
}

#[test]
fn equals_sign_inside_old_string_survives_kv_split() {
    // k=v parsing uses splitn(2, '=') — an '=' INSIDE the value must
    // ride through untouched, including on a continuation line.
    let original = "fn cfg() {\n    let pair = \"k=v\";\n    let other = 1;\n}\n";
    let old = "fn cfg() {\n    let pair = \"k=v\";";
    let new = "fn cfg() {\n    let pair = \"k=v2\";";
    let (ok, after) = dispatch_edit("eq", original, old, new);
    assert!(ok, "edit dispatch must exit 0");
    assert!(
        after.contains("k=v2"),
        "= inside the value must survive the splitn(2, '=') parse ; file after :\n{}",
        after
    );
}
