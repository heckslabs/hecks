require "spec_helper"
require_relative "support/resting_pruner"

# A finished run wakes the pruner, which starts a session through AgentRun.
RSpec.describe "the pruner started by a finished run" do
  include_context "with a resting pruner"

  it "dispatches the pruner once when a run finishes" do
    dispatch("w-finished")
    finish("w-finished")
    expect(reactions("DispatchThePrunerWhenWoken").size).to eq(1)
  end

  it "wakes the pruner only for the finished run, not for its own finish", :aggregate_failures do
    dispatch("w-own")
    finish("w-own")
    expect(reactions("WakeThePrunerWhenARunFinishes").size).to eq(1)
    expect(reactions("RestThePrunerWhenItsRunEnds").size).to eq(1)
  end
end
