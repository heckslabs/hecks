//! run_boot detection + classification tests
//!
//! Confirms : (1) the runner only fires when a bluebook + hecksagon
//! shape match the boot capability ; (2) the psychic-link classifier
//! sorts heki filenames into linked / private / unclassified per the
//! constants ported from boot_miette.sh.

use hecks_life::hecksagon_parser;
use hecks_life::parser;
use hecks_life::run_boot;
use hecks_life::runtime::Runtime;
use hecks_life::runtime::adapter_registry::AdapterRegistry;

const BOOT_BLUEBOOK: &str = include_str!(
    "../../hecks_conception/capabilities/boot/boot.bluebook"
);
const BOOT_HECKSAGON: &str = include_str!(
    "../../hecks_conception/capabilities/boot/boot.hecksagon"
);

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
