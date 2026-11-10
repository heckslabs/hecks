require "spec_helper"
require_relative "support/resting_pruner"

# A landed feature wakes the pruner, which starts a session through AgentRun; a run that finishes
# without landing wakes nothing, and the pruner's own finish only rests it.
RSpec.describe "the pruner started by a landed feature" do
  include_context "with a resting pruner"

  def session_reads_done
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "done"))
  end

  it "dispatches no pruner when a coder run finishes" do
    dispatch("w-finished")
    finish("w-finished")
    expect(pruners_started).to eq(0)
  end

  it "wakes the pruner for the landing and rests it when its own run ends", :aggregate_failures do
    session_reads_done
    land("w-own")
    expect(reactions("WakeThePrunerWhenWorkLands").size).to eq(1)
    expect(reactions("RestThePrunerWhenItsRunEnds").size).to eq(1)
  end
end
