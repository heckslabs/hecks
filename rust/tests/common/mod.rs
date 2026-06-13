//! Shared helpers for conception_kernel integration tests.
//!
//! `assert_matches_oracle` is the gate: the kernel's `plan()` must equal a
//! hand-derived chain AND agree with `generate_behaviors` (generator.rs, the
//! byte-oracle) on per-producer setup counts — the kernel is correct iff it
//! agrees with the code it will replace.

use std::collections::BTreeMap;
use storehouse::behaviors_conceiver::generator::generate_behaviors;
use storehouse::conception_kernel::planner::{plan, Plan};
use storehouse::ir::Domain;
use storehouse::parser;

/// The kernel's plan for `agg_name`.`cmd_name`, as command names.
pub fn kernel_chain(domain: &Domain, agg_name: &str, cmd_name: &str) -> Vec<String> {
    let agg = domain
        .aggregates
        .iter()
        .find(|a| a.name == agg_name)
        .expect("aggregate");
    let cmd = agg
        .commands
        .iter()
        .find(|c| c.name == cmd_name)
        .expect("command");
    match plan(agg, cmd) {
        Plan::Chain(names) => names,
        Plan::Unsatisfiable => panic!("unexpected Unsatisfiable for {cmd_name}"),
    }
}

fn counts(names: &[String]) -> BTreeMap<String, usize> {
    let mut m = BTreeMap::new();
    for n in names {
        *m.entry(n.clone()).or_insert(0) += 1;
    }
    m
}

/// Extract the `test "..." do ... end` block whose body declares
/// `tests "<cmd_name>"`.
fn test_block(out: &str, cmd_name: &str) -> String {
    let needle = format!("tests {cmd_name:?}");
    let mut cur = String::new();
    let mut in_test = false;
    for line in out.lines() {
        if line.trim_start().starts_with("test ") && line.contains(" do") {
            in_test = true;
            cur.clear();
        }
        if in_test {
            cur.push_str(line);
            cur.push('\n');
        }
        if in_test && line.trim() == "end" {
            if cur.contains(&needle) {
                return cur;
            }
            in_test = false;
        }
    }
    String::new()
}

/// Assert the kernel plan equals `expected` AND agrees with generator.rs on
/// per-producer setup counts for `agg`.`cmd`.
pub fn assert_matches_oracle(source: &str, agg: &str, cmd: &str, expected: &[&str]) {
    let domain = parser::parse(source);
    let chain = kernel_chain(&domain, agg, cmd);
    let expected: Vec<String> = expected.iter().map(|s| s.to_string()).collect();
    assert_eq!(chain, expected, "kernel plan for {cmd} != expected");

    let out = generate_behaviors(&domain, None);
    let block = test_block(&out, cmd);
    assert!(!block.is_empty(), "no test block for {cmd} in:\n{out}");
    for (producer, k) in counts(&chain) {
        let oracle = block.matches(&format!("setup  {producer:?}")).count();
        assert_eq!(
            oracle, k,
            "oracle emitted {oracle} `setup {producer:?}` for {cmd}, kernel planned {k}\n{block}"
        );
    }
}

/// Assert the kernel plans an empty chain (default-held / no producer) and the
/// oracle still emits the test.
pub fn assert_empty_chain_but_emits(source: &str, agg: &str, cmd: &str) {
    let domain = parser::parse(source);
    assert_eq!(
        kernel_chain(&domain, agg, cmd),
        Vec::<String>::new(),
        "expected empty chain for {cmd}"
    );
    let out = generate_behaviors(&domain, None);
    assert!(
        out.contains(&format!("tests {cmd:?}")),
        "{cmd} test should emit:\n{out}"
    );
}
