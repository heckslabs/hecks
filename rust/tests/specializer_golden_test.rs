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
use std::process::Command;

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

// Ruby-path tests deleted in Phase E PR 1 — `bin/specialize` no longer
// exists; the Rust-native `storehouse specialize` path (below) is the
// sole gate for every target now.


#[test]
fn wrangler_toml_emitter_matches_committed_deployment_toml() {
    // Per-deployment emitter golden — unlike the tracked rust/src/*.rs
    // goldens above, the wrangler_toml emitter reads a deployment's
    // cloudflare.bluebook (the WorkerConfig fixture) and emits the
    // matching wrangler.toml. This golden regenerates into a tmp file
    // and asserts byte-identity against the committed
    // deployments/daily_musing_cf/worker/wrangler.toml — proving the
    // toml IS derived from the bluebook, not hand-synced. Sibling to
    // the cf_function_proxy / embedded_bluebooks emitters, which are
    // likewise per-deployment (no arm in the generic emit() dispatch).
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(bin.exists(), "storehouse binary missing — build release first");
    // deployments/ stayed in the hecks tree (the binary above stays under
    // the engine `root`) ; resolve the deployment fixtures via the sibling
    // hecks root.
    let hecks = std::env::var("HECKS_CONCEPTION_DIR")
        .ok()
        .and_then(|c| std::path::Path::new(&c).parent().map(|p| p.to_path_buf()))
        .unwrap_or_else(|| root.join("../hecks"));
    let config = hecks.join("deployments/daily_musing_cf/cloudflare.bluebook");
    let committed = hecks.join("deployments/daily_musing_cf/worker/wrangler.toml");
    let out = std::env::temp_dir().join("wrangler_toml_golden.toml");
    let output = Command::new(&bin)
        .args([
            "specialize",
            "wrangler_toml",
            "--config",
            config.to_str().unwrap(),
            "--output",
            out.to_str().unwrap(),
        ])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize wrangler_toml failed");
    assert!(output.status.success(), "stderr: {}", String::from_utf8_lossy(&output.stderr));
    let generated = fs::read_to_string(&out).expect("generated wrangler.toml missing");
    let tracked = fs::read_to_string(&committed).expect("committed wrangler.toml missing");
    assert_eq!(
        generated, tracked,
        "wrangler.toml drifted from what cloudflare.bluebook would emit — regenerate with \
         `storehouse specialize wrangler_toml --config deployments/daily_musing_cf/cloudflare.bluebook \
         --output deployments/daily_musing_cf/worker/wrangler.toml`",
    );
}
