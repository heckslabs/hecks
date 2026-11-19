# frozen_string_literal: true

require "spec_helper"
require_relative "support/standing_coordinator"

# The orchestrator's standing seat: a sweep that finds it empty starts one orchestrator run into
# it, and a run of its own that stops leaves it empty for the next sweep to fill.
RSpec.describe "the orchestrator's standing seat" do
  include_context "with a standing coordinator seat"

  it "starts one orchestrator run on the first sweep" do
    sweep("beat-1")
    expect(coordinators_started).to eq(1)
  end

  it "starts none while its run holds the seat" do
    sweep("beat-1")
    sweep("beat-2")
    expect(coordinators_started).to eq(1)
  end

  # Each sweep is a process of its own, which opens the in-Memory seat afresh; the seat's
  # AgentRun under `orchestrator-seat` ended with the stop, so a later sweep fills the seat again.
  it "fills the seat again from a later process after its run stops" do
    fresh_sweep("beat-1")
    fresh_stop_and_refill
    expect(live_seats.size).to eq(1)
  end

  it "keeps the seat when its run ends idle" do
    sweep("beat-1")
    job_reads("done")
    sweep("beat-2")
    expect(seat).to include("status" => "present", "run" => "beat-1")
  end
end
