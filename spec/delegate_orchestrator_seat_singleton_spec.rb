# frozen_string_literal: true

require "spec_helper"
require_relative "support/standing_coordinator"

# The orchestrator's standing seat is one AgentRun under the key `orchestrator-seat`. Each sweep
# is a launcher call of its own and opens the in-Memory seat afresh, so the seat's run key, kept in
# the shared AgentRun journal, is what refuses a copy while one is live.
RSpec.describe "the orchestrator's one seat" do
  include_context "with a standing coordinator seat"

  before { fresh_sweep("beat-1") }

  it "keeps one live seat run when a second process sweeps" do
    fresh_sweep("beat-2")
    expect(live_seats.size).to eq(1)
  end

  it "records the seat's part on its run" do
    expect(live_seats.first).to include("run" => "orchestrator-seat", "parent" => "beat-1")
  end

  it "starts nothing while the seat's session is blocked" do
    job_reads("blocked")
    fresh_sweep("beat-2")
    expect(live_seats.map { |row| row["run"] }).to eq(["orchestrator-seat"])
  end

  # A seat whose job reads done is idle: a message resumes it, so it is kept, not replaced.
  it "keeps the idle seat instead of starting a new session" do
    job_reads("done")
    fresh_sweep("beat-2")
    expect(live_seats.map { |row| row["parent"] }).to eq(["beat-1"])
  end

  # The stand-in holds one session for every run, so it works again before the refill is read.
  it "starts the seat again once its session has stopped" do
    fresh_stop_and_refill
    expect(live_seats.map { |row| row["parent"] }).to contain_exactly(satisfy { |parent| parent != "beat-1" })
  end

  it "starts no session when a hand run registers" do
    expect { register_hand_run }.not_to(change { launch!("AgentRun.running").first })
  end

  def register_hand_run
    launch!("agents", "HandRun.register!", "run.value=orchestrator", "session.value=s-1", "role.value=orchestrator",
            "--wait")
  end
end
