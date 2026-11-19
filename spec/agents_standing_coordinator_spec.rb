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

  # The stand-in holds one session for every run, so a sweep that finds the stop may also start
  # into it; the seat is filled again by a run under a key that is not the stopped one.
  it "starts a new run under a new key after its run stops", :aggregate_failures do
    sweep("beat-1")
    stop_and_refill
    expect(seat).to include("status" => "present", "lost_by" => "stopped")
    expect(seat["run"]).not_to eq("beat-1")
  end

  it "keeps the seat when its run ends idle" do
    sweep("beat-1")
    job_reads("done")
    sweep("beat-2")
    expect(seat).to include("status" => "present", "run" => "beat-1")
  end
end
