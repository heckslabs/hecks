//! Build outputs the host tests read from `rust/dist`, which git ignores.
//!
//! CI builds them in its `build_host_wasm` job and hands them to the cargo job. A local checkout
//! builds them with the command a missing file names.

use std::path::PathBuf;

/// The path of `file` in `rust/dist`, failing with the command that builds it when it is absent.
pub fn dist_file(file: &str) -> PathBuf {
    let domain = if file.starts_with("banking.") {
        "examples/banking"
    } else if file.starts_with("checkout_fixture.") {
        "spec/fixtures/rust_host/checkout_fixture"
    } else if file.starts_with("pluginned.") {
        "spec/fixtures/rust_host/pluginned"
    } else {
        panic!("rust/dist/{file} has no domain registered in test_dist.rs")
    };
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../dist")
        .join(file);
    assert!(
        path.exists(),
        "missing {}: build it from the repository root with \
         `bundle exec exe/hecks build.build_wasm! domain={domain} profile=dev --wait`",
        path.display()
    );
    path
}
