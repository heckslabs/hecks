//! boot_completion_test.rs — the boot-establishment keystone.
//!
//! Proves that routing `BootCompleted` through the policy engine at boot
//! (run_boot::complete) makes cross-domain `on "BootCompleted"` ESTABLISHMENT
//! policies self-seed — the mechanism authz Phase 4 + governance establishment
//! wait on. Drives the real `complete_over` in memory with inline domains, so
//! it never touches disk or the real conception.
//!
//! [antibody-exempt: rust/tests/boot_completion_test.rs — kernel-surface
//!  integration test for the run_boot completion step. Asserts on Rust runtime
//!  state, so it is necessarily Rust. Same category as run_boot_test.rs ;
//!  retires with the run_boot pipeline under i78/i145.]

use storehouse::parser;
use storehouse::run_boot::complete::complete_over;
use storehouse::runtime::Value;

// A minimal boot domain : the sole thing that matters is `CompleteBoot` emits
// `BootCompleted`. The real runtime/boot/boot.bluebook is far larger, but the
// completion step only needs this one command + event.
const BOOT: &str = r#"Hecks.bluebook "Boot" do
  aggregate "BootRun" do
    attribute :phase, String, default: "pending"
    command "CompleteBoot" do
      role "System"
      emits "BootCompleted"
    end
  end
end"#;

// A tiny establishment target + the reactive policy that seeds it at boot.
const GOV_WITH_POLICY: &str = r#"Hecks.bluebook "Gov" do
  aggregate "Ledger" do
    attribute :established, String, default: "false"
    command "Establish" do
      role "System"
      then_set :established, to: "true"
      emits "Established"
    end
  end
  policy "EstablishOnBoot" do
    on "BootCompleted"
    trigger "Ledger.Establish"
  end
end"#;

// The SAME corpus without the establishment policy — the negative baseline.
const GOV_NO_POLICY: &str = r#"Hecks.bluebook "Gov" do
  aggregate "Ledger" do
    attribute :established, String, default: "false"
    command "Establish" do
      role "System"
      then_set :established, to: "true"
      emits "Established"
    end
  end
end"#;

/// POSITIVE : an `on "BootCompleted"` policy in the corpus fires its
/// establishment command when the boot runner completes. This is the keystone
/// — proof that BootCompleted is a real genesis event the policy engine drives.
#[test]
fn establishment_policy_fires_on_boot_completed() {
    let boot = parser::parse(BOOT);
    let corpus = parser::parse(GOV_WITH_POLICY);

    // None data_dir => memory repositories ; vec![] hecksagons => no adapters
    // needed (pure policy + command). The cascade is synchronous, so it is
    // fully settled when complete_over returns.
    let rt = complete_over(boot, corpus, None, vec![], None, "Miette");

    let ledgers = rt.all("Ledger");
    assert!(
        !ledgers.is_empty(),
        "an `on \"BootCompleted\"` policy must fire its establishment command at boot"
    );
    assert!(
        matches!(ledgers[0].get("established"), Value::Str(s) if s == "true"),
        "the establishment command must have run (established=true), got {:?}",
        ledgers[0].get("established")
    );
}

/// NEGATIVE baseline : with NO `on "BootCompleted"` policy, dispatching
/// CompleteBoot establishes nothing. Proves it is the POLICY that seeds — not
/// the CompleteBoot dispatch itself — i.e. the wiring is genuinely reactive.
#[test]
fn no_establishment_without_a_policy() {
    let boot = parser::parse(BOOT);
    let corpus = parser::parse(GOV_NO_POLICY);

    let rt = complete_over(boot, corpus, None, vec![], None, "Miette");

    assert!(
        rt.all("Ledger").is_empty(),
        "with no establishment policy, CompleteBoot alone must not establish anything"
    );
}
