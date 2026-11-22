require "spec_helper"
require "json"
require "hecks/hecks/adapters/main_integration"
require_relative "support/closed_train_runs"

# A train pull request closed unmerged releases its integration run, even when the run rode a
# train named for a later commit: the run leaves ci_running for needs_human and the line it held
# is free for the next verified landing. Each example resets the booted registry's runtime state and
# holds the code watch's fingerprint fixed, so the spec passes alone and in a shard.
RSpec.describe Hecks::Adapters::MainIntegration do
  include ClosedTrainRuns

  let(:stuck) { "a" * 40 }

  before(:all) { @hecks = boot_hecks_in_memory }

  before do
    @hecks.registry.reset_runtime_state!
    hold_code_steady
    stand_in_closed_train(stuck)
    Hecks::Adapters::MainIntegration::Stale.stand_in(lines: -> { [] })
  end

  after do
    Hecks::Adapters::CiRuns.runner = nil
    release_code
    Hecks::Adapters::MainIntegration::Stale.stand_in
  end

  it "moves a run out of ci_running when the train it rode was closed unmerged" do
    seed(stuck, "ci_running")
    observe
    expect(runs.find(stuck).state).to eq("needs_human")
  end

  it "frees the line, so nothing is held in flight behind the closed run" do
    seed(stuck, "ci_running")
    observe
    expect(runs.in_flight).to eq([])
  end

  it "holds the next verified run for confirmation only, not behind the closed run" do
    seed(stuck, "ci_running")
    seed("b" * 40, "verified")
    report = described_class.new(registry: @hecks.registry).step[:report][:value]
    expect(report).to include("waiting: advance with --confirm")
  end
end
