# frozen_string_literal: true

require "spec_helper"
require_relative "support/standing_coordinator"

# The owner's switch on the standing seat, and the orchestrator runs that are not the seat's own.
RSpec.describe "pausing the orchestrator's standing seat" do
  include_context "with a standing coordinator seat"

  def pause = launch!("agents", "Coordinator.pause!", "to=orchestrator", "--wait")

  def lose(run) = launch("agents", "Coordinator.lose!", "to=orchestrator", "lost.value=#{run}", "lost_by.value=stopped", "--wait")

  it "starts no run into a paused seat after its run stops" do
    sweep("beat-1")
    pause
    stop_and_refill
    expect(coordinators_started).to eq(1)
  end

  it "refuses to empty the seat for a run that is not its own" do
    sweep("beat-1")
    expect(lose("stall-1").last).not_to eq(0)
  end
end
