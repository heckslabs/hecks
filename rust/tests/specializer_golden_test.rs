//! Golden tests for the i51 Futamura specializers.
//!
//! Phase E deleted the Ruby `bin/specialize` driver + Ruby specializer
//! modules ; the Rust-native `storehouse specialize <target>` subcommand
//! is now the only path. These tests invoke it and assert byte-identity
//! against the tracked, generated `.rs` sources under `rust/src/`.
//!
//! When any test goes green, we have a Futamura proof for that module :
//! a specialized interpreter (bluebook → Rust) that produces the same
//! artifact a human wrote.
//!
//! If a tracked .rs is edited by hand, this test fails until the
//! shape + specializer are updated to match.
//!
//! [antibody-exempt: rust/tests/specializer_golden_test.rs — golden-test
//!  scaffolding for the i51 Futamura specializer pipeline. Each `#[test]`
//!  shells to `storehouse specialize <target>` and asserts byte-identity
//!  against the tracked `rust/src/<target>.rs`. Test-only kernel-floor
//!  surface : the specializers under test ARE the path that retires
//!  generated `.rs` files, but the byte-identity harness itself is
//!  necessarily Rust (it asserts on Rust byte sequences). Retires when
//!  i78 lands and the specializer pipeline regenerates from its own
//!  meta-shape, at which point byte-identity goldens move under the
//!  meta-shape's coverage. Previously carried 25 identical per-test
//!  scaffolding markers ; consolidated to a single file-level header
//!  on 2026-05-12 (the macrophage / antibody check only inspects the
//!  first 30 lines, so mid-file markers were decorative).]

use storehouse::hecksagon_parser;
use std::fs;
use std::path::PathBuf;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust has a parent")
        .to_path_buf()
}

#[test]
fn specializer_hecksagon_wiring_is_present() {
    // Confirms the capability wiring exists and declares the memory
    // adapter, all three shell adapters, and the Specializer gate.
    let path = repo_root().join("codegen/specializer/specializer.hecksagon");
    let src = fs::read_to_string(&path)
        .expect("specializer.hecksagon not found — capability wiring missing");
    let hex = hecksagon_parser::parse(&src);

    assert_eq!(hex.name, "Specializer");
    // i728 — specializer.hecksagon declares no persistence adapter ; unwired now
    // parses to None (the None→"memory" normalization was removed).
    assert_eq!(hex.persistence.as_deref(), None);
    // Phase E removed all shell adapters — `storehouse specialize`
    // (a Rust subcommand) is now the sole codegen path. The hecksagon
    // file keeps the `:memory` + `:fs` adapters + the Specializer
    // gate as declarative metadata. The 2026-05-12 "no bluebooks
    // without commands" sweep collapsed SpecializeRun + the four
    // catalog aggregates (IRLayer, Projection, SpecializerTarget,
    // SpecializerSubclass) into a single Specializer root with
    // value_object row-types ; the gate is renamed accordingly.
    assert!(
        hex.gates.iter().any(|g| g.aggregate == "Specializer"),
        "Specializer gate not declared",
    );
}
