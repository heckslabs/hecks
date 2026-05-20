//! 2nd Futamura projection — self-application byte-identity test.
//!
//! The canonical 2nd Futamura projection asserts :
//!
//!   specialize(specialize, interpreter) == compiler
//!
//! In Hecks terms : applying the specializer to itself — i.e. asking
//! `storehouse specialize` to regenerate a file under
//! `rust/src/specializer/*.rs` — should produce output byte-identical
//! to the tracked source. When that holds for ANY file in the
//! specializer family, the specializer is a fixed point of itself, the
//! 2nd Futamura proof exists, and the Rust tree under
//! `rust/src/specializer/` becomes a cache rather than a source.
//!
//! Today this is RED — see `hecks_conception/inbox/i650-futamura-drift.md`.
//! `rust/src/specializer/mod.rs::emit()` has 30 match arms, none of
//! which emit a file under `rust/src/specializer/`. Running the test
//! body below would fail at the `output.status.success()` assert with
//! `unknown specializer target: specializer_mod` from mod.rs's
//! fall-through arm.
//!
//! The smallest repair (per i650) is :
//!   1. Author `codegen/specializer_mod_shape/` (modeled on cli_dispatch_shape)
//!   2. Add `rust/src/specializer/specializer_mod.rs` emitter
//!   3. Add the `"specializer_mod" => specializer_mod::emit(...)` arm
//!   4. Lift the `#[ignore]` on this test
//!
//! When this test goes green, the 2nd Futamura proof is back.

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
#[ignore = "2026-05-20 — 2nd Futamura projection self-application is RED. \
            No specializer target emits a file under rust/src/specializer/. \
            See hecks_conception/inbox/i650-futamura-drift.md for the \
            structural gap (42 specializer source files, 0 emit arms in \
            mod.rs) and the smallest repair (author codegen/specializer_mod_shape/ \
            modeled on cli_dispatch_shape). Lift this ignore when the repair \
            lands ; the test passing IS the 2nd Futamura proof."]
fn rust_specializer_regenerates_its_own_mod_rs_byte_identically() {
    // Canonical 2nd Futamura test : applying the specializer to itself.
    //
    // The representative target is `mod.rs` — smallest file in
    // rust/src/specializer/ (95 lines), highest-leverage (every other
    // emit goes through its dispatch), and structurally a sibling of
    // cli_dispatch (both are "match arms + pub mod declarations" tables
    // and cli_dispatch IS specialized today). When `specializer_mod` is
    // a real target, this test goes green and the 2nd Futamura proof
    // exists.
    let root = repo_root();
    let bin = root.join("rust/target/release/storehouse");
    assert!(
        bin.exists(),
        "storehouse binary missing — build release first",
    );
    let output = Command::new(&bin)
        .args(["specialize", "specializer_mod"])
        .current_dir(&root)
        .output()
        .expect("storehouse specialize specializer_mod failed to invoke");
    assert!(
        output.status.success(),
        "storehouse specialize specializer_mod did not succeed — \
         the specializer_mod target is not registered. See \
         hecks_conception/inbox/i650-futamura-drift.md. stderr: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    let generated = String::from_utf8(output.stdout).expect("non-UTF-8 output");
    let tracked = fs::read_to_string(root.join("rust/src/specializer/mod.rs"))
        .expect("rust/src/specializer/mod.rs missing");
    assert_eq!(
        generated, tracked,
        "2nd Futamura projection failed : the specializer's regenerated \
         mod.rs is not byte-identical to the tracked source.",
    );
}

#[test]
fn second_futamura_drift_card_is_present() {
    // Companion guard : while the self-application test is ignored,
    // confirm the drift card exists so the documentation trail can't
    // silently rot away. When the ignore on the test above is lifted,
    // this guard can be deleted (or kept as historical context — it's
    // cheap and explicit).
    let root = repo_root();
    let card = root.join("hecks_conception/inbox/i650-futamura-drift.md");
    assert!(
        card.exists(),
        "i650-futamura-drift.md missing — the drift this test marks must \
         be tracked in the inbox or refreshed/retired explicitly.",
    );
    let body = fs::read_to_string(&card).expect("card unreadable");
    assert!(
        body.contains("2nd Futamura projection"),
        "drift card does not name what it tracks",
    );
}
