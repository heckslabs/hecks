//! run_boot detection + classification tests
//!
//! Confirms : (1) the runner only fires when a bluebook + hecksagon
//! shape match the boot capability ; (2) the psychic-link classifier
//! sorts heki filenames into linked / private / unclassified per the
//! constants ported from boot_miette.sh.
//!
//! [antibody-exempt: rust/tests/run_boot_test.rs — kernel-surface
//!  integration test for run_boot capability detection + classifier.
//!  Same category as restructure_integration_test.rs (test-only kernel
//!  surface). Retires when the behaviors framework gains a capability-
//!  detection vocabulary (filed as i569 ; one of five cluster markers
//!  retired by that capability landing).]

use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::run_boot;
use storehouse::runtime::Runtime;
use storehouse::runtime::adapter_registry::AdapterRegistry;

// Vendored snapshots of a real boot bluebook + hecksagon shape (copied from
// hecks/runtime/boot/). The test exercises CAPABILITY DETECTION, not the live
// deployment pipeline, so a self-contained fixture is correct — and it lets the
// engine's gate compile standalone now that storehouse lives outside the hecks
// tree (the include_str! used to reach ../../runtime/boot/, which no longer
// exists beside the engine).
const BOOT_BLUEBOOK: &str = include_str!("fixtures/boot/boot.bluebook");
const BOOT_HECKSAGON: &str = include_str!("fixtures/boot/boot.hecksagon");

#[test]
fn detects_boot_capability_from_real_bluebook_and_hecksagon() {
    let domain = parser::parse(BOOT_BLUEBOOK);
    let hex = hecksagon_parser::parse(BOOT_HECKSAGON);
    let registry = AdapterRegistry::from_hecksagon(hex);
    let rt = Runtime::boot(domain);

    assert!(
        run_boot::is_boot_capability(&registry, &rt),
        "boot.bluebook + boot.hecksagon should trigger the boot runner"
    );
}

#[test]
fn does_not_detect_without_bootrun_aggregate() {
    let domain = parser::parse(r#"
        Hecks.bluebook "NotBoot" do
          aggregate "Other" do
            attribute :x, String
          end
        end
    "#);
    let hex = hecksagon_parser::parse(BOOT_HECKSAGON);
    let registry = AdapterRegistry::from_hecksagon(hex);
    let rt = Runtime::boot(domain);

    assert!(
        !run_boot::is_boot_capability(&registry, &rt),
        "missing BootRun aggregate must not trigger the boot runner"
    );
}

#[test]
fn does_not_detect_without_fs_or_stdout_adapters() {
    let domain = parser::parse(BOOT_BLUEBOOK);
    let hex = hecksagon_parser::parse(r#"
        Hecks.hecksagon "Boot" do
          adapter :memory
        end
    "#);
    let registry = AdapterRegistry::from_hecksagon(hex);
    let rt = Runtime::boot(domain);

    assert!(
        !run_boot::is_boot_capability(&registry, &rt),
        "missing :fs / :stdout adapters must not trigger the boot runner"
    );
}
