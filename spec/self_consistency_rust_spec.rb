require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/self_consistency"
require_relative "support/rust_conformance_helpers"

# THE RUST-SIDE HALF OF `Hecks::Fuzzing::SelfConsistency` — `check_rust_
# rehydration`/`check_rust_idempotency`, the compiled binary's own
# `"seed"` door (`kernel/cli.rs`'s own header; `Hecks::Fuzzing::
# SelfConsistency`'s own file header explains the mechanism in full).
# Proven two ways, matching this practice's existing "found something"
# fixture pattern (`spec/qa_sweep_all_spec.rb`'s own fixture crate):
#
#   - against a REAL compiled domain binary (pizzas), both checks stay
#     clean — `Store::from_seed`/`Store::instances` really are inverses
#     for a well-behaved binary;
#   - against `spec/fixtures/self_consistency_rust_fixture/` (a small,
#     hand-maintained crate whose OWN header explains the deliberate
#     bug), both checks fire — proving they actually CAN, not just that
#     they stay quiet.
class Differ
  include RustConformanceHelpers
end

RSpec.describe "Hecks::Fuzzing::SelfConsistency (Rust side)", :io do
  ROOT      = InMemoryDomain::ROOT
  PIZZAS    = File.join(ROOT, "examples/pizzas")
  BANKING   = File.join(ROOT, "examples/banking")
  RUST_DIR  = File.join(ROOT, "rust")
  FIXTURE_RUST_DIR = File.join(ROOT, "spec/fixtures/self_consistency_rust_fixture")

  let(:differ) { Differ.new }

  it "stays clean against a real compiled domain binary (pizzas)" do
    binary = differ.build_rust_for("pizzas", RUST_DIR)
    skip "pizzas Rust feature not declared in rust/Cargo.toml" unless binary

    steps = Hecks::Fuzzing::SequenceGenerator.generate(PIZZAS, seed: 3, steps: 15)
    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
    expect(status).to be_success

    # NOT `strip_emitted_flags!`ed — that mutation is for the Ruby-vs-Rust
    # DIFFERENTIAL comparison only (Ruby has no such field to agree with).
    # The self-consistency seed needs the WIRE-REAL `"instances"` `Store::
    # instances()` actually produced, `emitted_*` bookkeeping included:
    # `Store::from_seed` refuses a seed missing one, found live against
    # `examples/banking` while this integration was being written
    # (`bin/qa_sweep`'s own `diff_ruby_vs_rust` carries the same fix, with
    # the fuller story in its own comment there).
    live = JSON.parse(stdout)["instances"]

    expect(Hecks::Fuzzing::SelfConsistency.check_rust_rehydration(binary, differ, live)).to be_empty
    expect(Hecks::Fuzzing::SelfConsistency.check_rust_idempotency(binary, differ, live)).to be_empty
  end

  # THE REGRESSION `bin/qa_sweep`'s own `rust_live_instances` comment
  # names directly — `Banking::Account`'s `corrects` reaction (docs/
  # decisions/0049) gives its own generated `Store` an `emitted_fee_
  # applied` bookkeeping field that `banking`'s `pizzas`-only sibling
  # example never exercises. `Store::from_seed` REQUIRES it present —
  # seeding with a copy that had `strip_emitted_flags!` applied (the
  # DIFFERENTIAL comparison's own mutation) refused outright with
  # "Account.emitted_fee_applied: missing from JSON args," live, the
  # first time this integration ran against a real domain with a
  # `corrects` reaction rather than only `pizzas` (which has none). Proves
  # the fix, not just the mechanism `pizzas` alone already covers above.
  it "stays clean against a real compiled domain binary with an emitted_* bookkeeping field (banking)" do
    binary = differ.build_rust_for("banking", RUST_DIR)
    skip "banking Rust feature not declared in rust/Cargo.toml" unless binary

    steps = Hecks::Fuzzing::SequenceGenerator.generate(BANKING, seed: 5, steps: 25)
    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
    expect(status).to be_success

    live = JSON.parse(stdout)["instances"]
    carries_bookkeeping_field = live.values.any? { |state| state.key?("emitted_fee_applied") }
    expect(carries_bookkeeping_field).to be(true),
                                         "fixture assumption broken: no record in this generated sequence " \
                                         "carries emitted_fee_applied any more"

    expect(Hecks::Fuzzing::SelfConsistency.check_rust_rehydration(binary, differ, live)).to be_empty
    expect(Hecks::Fuzzing::SelfConsistency.check_rust_idempotency(binary, differ, live)).to be_empty
  end

  it "fires check_rust_rehydration against a binary whose seed door is genuinely broken" do
    binary = differ.build_rust_for("self_consistency_rust_fixture", FIXTURE_RUST_DIR)
    raise "fixture binary failed to build" unless binary

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => [] }))
    expect(status).to be_success
    live = JSON.parse(stdout)["instances"]

    findings = Hecks::Fuzzing::SelfConsistency.check_rust_rehydration(binary, differ, live)
    expect(findings).not_to be_empty
    expect(findings.first[:field]).to eq("rust_rehydration")
  end

  it "fires check_rust_idempotency against the same genuinely broken binary" do
    binary = differ.build_rust_for("self_consistency_rust_fixture", FIXTURE_RUST_DIR)
    raise "fixture binary failed to build" unless binary

    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => [] }))
    expect(status).to be_success
    live = JSON.parse(stdout)["instances"]

    findings = Hecks::Fuzzing::SelfConsistency.check_rust_idempotency(binary, differ, live)
    expect(findings).not_to be_empty
    expect(findings.first[:field]).to eq("rust_idempotency")
  end
end
