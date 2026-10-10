require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/self_consistency"
require_relative "support/rust_conformance_helpers"

# The Rust-side half of `Hecks::Fuzzing::SelfConsistency` (rehydration and idempotency checks
# against the binary's `"seed"` entry point). Both checks stay clean on a real binary and fire on the
# deliberately buggy `spec/fixtures/self_consistency_rust_fixture/` crate.
class Differ
  include RustConformanceHelpers
end

RSpec.describe "Hecks::Fuzzing::SelfConsistency (Rust side)", :io do
  # Prefixed: constants assigned in a describe block land on `Object`, and
  # `spec/load_hygiene_spec.rb` flags any name two spec files both assign.
  SELF_CONSISTENCY_RUST_PIZZAS = File.join(InMemoryDomain::ROOT, "examples/pizzas")
  SELF_CONSISTENCY_BANKING           = File.join(InMemoryDomain::ROOT, "examples/banking")
  SELF_CONSISTENCY_RUST_DIR          = File.join(InMemoryDomain::ROOT, "rust")
  SELF_CONSISTENCY_FIXTURE_RUST_DIR  = File.join(InMemoryDomain::ROOT, "spec/fixtures/self_consistency_rust_fixture")

  let(:differ) { Differ.new }

  # Runs `steps` through the binary and returns the live instances it reports. Not
  # `strip_emitted_flags!`ed: the seed needs the `emitted_*` bookkeeping fields
  # `Store::instances()` produced, and `Store::from_seed` refuses a seed missing one.
  def live_instances(binary, steps)
    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
    expect(status).to be_success
    JSON.parse(stdout)["instances"]
  end

  # Builds the domain's binary and drives a generated sequence through it; returns both.
  def domain_live(name, example_dir, seed:, steps:)
    binary = differ.build_rust_for(name, SELF_CONSISTENCY_RUST_DIR)
    skip "#{name} Rust feature not declared in rust/Cargo.toml" unless binary

    sequence = Hecks::Fuzzing::SequenceGenerator.generate(example_dir, seed: seed, steps: steps)
    [binary, live_instances(binary, sequence)]
  end

  def broken_fixture_live
    binary = differ.build_rust_for("self_consistency_rust_fixture", SELF_CONSISTENCY_FIXTURE_RUST_DIR)
    raise "fixture binary failed to build" unless binary

    [binary, live_instances(binary, [])]
  end

  def rehydration_findings(binary, live) = Hecks::Fuzzing::SelfConsistency.check_rust_rehydration(binary, differ, live)

  def idempotency_findings(binary, live) = Hecks::Fuzzing::SelfConsistency.check_rust_idempotency(binary, differ, live)

  it "stays clean against a real compiled domain binary (pizzas)", :aggregate_failures do
    binary, live = domain_live("pizzas", SELF_CONSISTENCY_RUST_PIZZAS, seed: 3, steps: 15)

    expect(rehydration_findings(binary, live)).to be_empty
    expect(idempotency_findings(binary, live)).to be_empty
  end

  # Pins the `emitted_*` regression: banking's `corrects` reaction adds `emitted_fee_applied`,
  # which `Store::from_seed` requires and pizzas (no `corrects`) never exercises.
  it "carries an emitted_* bookkeeping field in the generated banking sequence" do
    _binary, live = domain_live("banking", SELF_CONSISTENCY_BANKING, seed: 5, steps: 25)
    carries_bookkeeping_field = live.values.any? { |state| state.key?("emitted_fee_applied") }

    expect(carries_bookkeeping_field).to be(true),
                                         "fixture assumption broken: no record in this generated sequence " \
                                         "carries emitted_fee_applied any more"
  end

  it "stays clean against a real compiled domain binary with an emitted_* bookkeeping field (banking)", :aggregate_failures do
    binary, live = domain_live("banking", SELF_CONSISTENCY_BANKING, seed: 5, steps: 25)

    expect(rehydration_findings(binary, live)).to be_empty
    expect(idempotency_findings(binary, live)).to be_empty
  end

  it "fires check_rust_rehydration against a binary whose seed entry point is genuinely broken", :aggregate_failures do
    binary, live = broken_fixture_live
    findings = rehydration_findings(binary, live)

    expect(findings).not_to be_empty
    expect(findings.first[:field]).to eq("rust_rehydration")
  end

  it "fires check_rust_idempotency against the same genuinely broken binary", :aggregate_failures do
    binary, live = broken_fixture_live
    findings = idempotency_findings(binary, live)

    expect(findings).not_to be_empty
    expect(findings.first[:field]).to eq("rust_idempotency")
  end
end
