# frozen_string_literal: true

require "spec_helper"
require_relative "support/standing_coordinator"

# A wake of the orchestrator's standing seat while its run is live answers that run, so an idle
# seat resumes under its own session. The start of a second run stays refused by name (the key is
# held); the answer is what follows it.
RSpec.describe "the standing seat's wake" do
  include_context "with a standing coordinator seat"

  before do
    fresh_sweep("beat-1")
    job_reads("done")
    fresh_sweep("beat-2")
  end

  it "answers the seat's run with the wake's brief" do
    expect(reactions("ResumeTheStandingSeatWhenWoken").size).to be >= 1
  end

  it "still holds one live seat run" do
    expect(live_seats.size).to eq(1)
  end
end
