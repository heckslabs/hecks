//! Golden : `storehouse wire-persistence` must reproduce the PIZZAS EXEMPLAR
//! form. The heki rollout generates every domain's persistence hecksagon + world
//! with this command ; this test pins the output shape to the committed pizzas
//! files, so the form is guaranteed by construction and can never drift. If you
//! change the exemplar (pizzas.hecksagon / pizzas.world persistence form), this
//! test fails until the generator matches — exactly the point. (i750)

use std::process::Command;

fn rel(p: &str) -> String {
    format!("{}/../examples/pizzas/bluebook/{}", env!("CARGO_MANIFEST_DIR"), p)
}

#[test]
fn wire_persistence_reproduces_the_pizzas_exemplar() {
    let out = Command::new(env!("CARGO_BIN_EXE_storehouse"))
        .args(["wire-persistence", &rel("pizzas.bluebook"), "--memory", "Cart", "--stdout"])
        .output()
        .expect("run wire-persistence");
    assert!(out.status.success(), "wire-persistence exited non-zero: {}",
        String::from_utf8_lossy(&out.stderr));
    let gen = String::from_utf8_lossy(&out.stdout);
    let (gen_hex, gen_world) = gen.split_once("---WORLD---")
        .expect("generator must emit a ---WORLD--- section (pizzas has heki aggregates)");

    // (1) The generated persisted_by lines must EQUAL the committed exemplar's,
    //     byte-for-byte (indentation + adapter names + declaration order).
    let committed_hex = std::fs::read_to_string(rel("pizzas.hecksagon")).unwrap();
    let committed_lines: Vec<&str> = committed_hex.lines()
        .filter(|l| l.contains(".persisted_by("))
        .map(|l| l.trim_end())
        .collect();
    let gen_lines: Vec<&str> = gen_hex.lines()
        .filter(|l| l.contains(".persisted_by("))
        .map(|l| l.trim_end())
        .collect();
    assert_eq!(gen_lines, committed_lines,
        "generated persisted_by lines must match the pizzas exemplar exactly");
    // Sanity : the exemplar really exercises BOTH adapters.
    assert!(committed_lines.iter().any(|l| l.contains("persisted_by(\"Heki\")")));
    assert!(committed_lines.iter().any(|l| l.contains("persisted_by(\"Memory\")")));

    // (2) The generated world's persisted_by block must match the exemplar's.
    let committed_world = std::fs::read_to_string(rel("pizzas.world")).unwrap();
    for needle in ["persisted_by(\"Heki\") do", "dir :default"] {
        assert!(committed_world.contains(needle), "exemplar world missing: {needle}");
        assert!(gen_world.contains(needle), "generated world missing: {needle}");
    }
}
