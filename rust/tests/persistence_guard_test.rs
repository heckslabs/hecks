//! Guard : `storehouse wire-persistence` must NEVER clobber a hecksagon that
//! carries hand-authored non-persistence wiring. This pins the fix for the i750
//! incident where the rollout's skip-guard (a `charged_by`/`driven` substring
//! check) missed `tools.hecksagon`'s `:claude_tool` adapter binds and overwrote
//! them with bare `persisted_by` lines — the dispatch door went dark (Bash/Read
//! emitted events but never executed). The guard is now a per-line pure-
//! persistence allowlist ; these tests pin its GENERALITY (a single claude_tool
//! case would pass even an incomplete special-case fix).

use std::process::Command;

const MIN_BLUEBOOK: &str = r#"Hecks.bluebook "Foo" do
  core
  aggregate "Bar" do
    attribute :name, Name
    value_object "Name" do
      attribute :value, String
    end
    command "MakeBar" do
      role "Maker"
      goal "make a bar"
      attribute :name, Name
    end
  end
end
"#;

fn run_wire_persistence(dir: &std::path::Path) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_storehouse"))
        .args(["wire-persistence", dir.join("foo.bluebook").to_str().unwrap()])
        .output()
        .expect("run wire-persistence")
}

fn setup(dir: &std::path::Path) {
    let _ = std::fs::remove_dir_all(dir);
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join("foo.bluebook"), MIN_BLUEBOOK).unwrap();
}

#[test]
fn skips_every_shape_of_non_persistence_hecksagon() {
    // Each shape carries a DIFFERENT non-persistence bind. The guard must skip
    // ALL of them and leave the file byte-for-byte unchanged. The claude_tool
    // row is the exact i750 incident ; the rest pin that the allowlist is
    // general, not a claude_tool special-case.
    let shapes: &[(&str, &str)] = &[
        ("claude_tool", "  adapter :claude_tool, command: \"ShellTool.Bash\", tool: :bash\n"),
        ("web_tool",    "  adapter :web_tool, command: \"WebTool.WebFetch\", tool: :web_fetch\n"),
        ("mcp",         "  adapter :mcp, command: \"EmailTool.Send\", server: :gmail\n"),
        ("charged_by",  "  Foo::Bar.charged_by(\"Stripe\", on: \"BarPlaced\")\n"),
        ("driven",      "  Foo::Bar.driven_by(\"Clock\", every: \"1s\")\n"),
        ("sqlite",      "  adapter :sqlite\n"),
    ];
    for (case, bind) in shapes {
        let dir = std::env::temp_dir().join(format!("hecks_guard_skip_{case}"));
        setup(&dir);
        let original = format!("Hecks.hecksagon \"Foo\" do\n{bind}end\n");
        std::fs::write(dir.join("foo.hecksagon"), &original).unwrap();

        let out = run_wire_persistence(&dir);
        assert!(out.status.success(), "[{case}] exited non-zero");

        let after = std::fs::read_to_string(dir.join("foo.hecksagon")).unwrap();
        assert_eq!(after, original,
            "[{case}] guard MUST NOT clobber a hecksagon carrying a non-persistence bind");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("SKIP"),
            "[{case}] expected a SKIP report on stderr, got: {stderr}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[test]
fn upgrades_a_legacy_terse_pure_persistence_hecksagon() {
    // The skip cases prove we don't clobber ; this proves we didn't over-correct
    // into skipping everything. A legacy terse `adapter :heki` hecksagon IS
    // pure-persistence, so it is regenerated into the explicit per-aggregate
    // exemplar form.
    let dir = std::env::temp_dir().join("hecks_guard_upgrade_terse");
    setup(&dir);
    std::fs::write(dir.join("foo.hecksagon"),
        "Hecks.hecksagon \"Foo\" do\n  adapter :heki\nend\n").unwrap();

    let out = run_wire_persistence(&dir);
    assert!(out.status.success(), "exited non-zero: {}",
        String::from_utf8_lossy(&out.stderr));

    let after = std::fs::read_to_string(dir.join("foo.hecksagon")).unwrap();
    assert!(after.contains(".persisted_by("),
        "a pure-persistence hecksagon must be upgraded to explicit persisted_by, got: {after}");
    assert!(!after.contains("adapter :heki"),
        "the legacy terse form must be replaced, got: {after}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn preserves_a_world_carrying_extra_config() {
    // Sibling of the hecksagon guard : when a pure-persistence hecksagon (which
    // IS regenerated) sits beside a world that carries hand-authored config (an
    // endpoint / token / charged_by block), the WORLD must be preserved, never
    // overwritten with the bare persistence world. Pins `world_is_pure_persistence`.
    let dir = std::env::temp_dir().join("hecks_guard_world_config");
    setup(&dir);
    // Pure-persistence hecksagon — WILL be upgraded (so the world path is reached).
    std::fs::write(dir.join("foo.hecksagon"),
        "Hecks.hecksagon \"Foo\" do\n  adapter :heki\nend\n").unwrap();
    // World carrying extra config — MUST be preserved byte-for-byte.
    let world = "Hecks.world \"Foo\" do\n  Foo::Bar.charged_by(\"Stripe\") do\n    endpoint \"FOO_ENDPOINT\"\n  end\nend\n";
    std::fs::write(dir.join("foo.world"), world).unwrap();

    let out = run_wire_persistence(&dir);
    assert!(out.status.success(), "exited non-zero: {}",
        String::from_utf8_lossy(&out.stderr));

    let hex_after = std::fs::read_to_string(dir.join("foo.hecksagon")).unwrap();
    assert!(hex_after.contains(".persisted_by("),
        "the pure-persistence hecksagon should have been upgraded, got: {hex_after}");
    let world_after = std::fs::read_to_string(dir.join("foo.world")).unwrap();
    assert_eq!(world_after, world,
        "a config-bearing world must be preserved, never clobbered");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("SKIP") && stderr.contains(".world"),
        "expected a world SKIP report on stderr, got: {stderr}");
    let _ = std::fs::remove_dir_all(&dir);
}
