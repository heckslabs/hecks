require "spec_helper"
require "securerandom"
require "hecks/hecks/adapters/main_integration"
require_relative "support/closed_train_runs"

# An operator releases a stuck integration run by its landed commit alone: Integration.Release
# needs no requested Integration record, moves a run in ci_running to needs_human and frees the
# line (the saga's in-flight runs, which boarding reads) for the next verified landing.
RSpec.describe "Integration.Release" do
  include ClosedTrainRuns

  let(:stuck) { "a" * 40 }

  before(:all) { @hecks = boot_hecks_in_memory }

  before { saga.clear }

  def release(sha)
    args = { run: SecureRandom.uuid, landed: sha, report: "train pull request closed" }
    Hecks::Runtime::Dispatcher.new(@hecks.registry).dispatch_flat("Hecks::Integration.Release", args)
  end

  it "moves a ci_running run to needs_human, found by its landed commit" do
    seed(stuck, "ci_running")
    release(stuck)
    expect(runs.find(stuck).state).to eq("needs_human")
  end

  it "frees the line for the next verified landing" do
    seed(stuck, "ci_running")
    release(stuck)
    expect(runs.in_flight(except: "b" * 40)).to eq([])
  end

  it "leaves a run that is not in ci_running where it is" do
    seed(stuck, "verified")
    release(stuck)
    expect(runs.find(stuck).state).to eq("verified")
  end
end
