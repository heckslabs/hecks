# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"
require "support/reap_turn"

# A session started by hand has no AgentRun, so its end is its HandRun's: an ended registration,
# or a session found stopped, failed or gone, asks for the turn to reap at once, inside the beat's
# half hour, and the reap frees the turn as a run's end does.
RSpec.describe "The turn to reap, asked by a hand-started session's end" do
  include_context "with a reaping fleet"
  include_context "with a first beat at noon"

  def register(run)
    launch("agents", "HandRun.register!", "run.value=#{run}", "session.value=s-#{run}", "role.value=coder", "--wait")
  end

  def end_hand_run(run)
    register(run)
    launch("agents", "HandRun.end!", "to=#{run}", "--wait")
  end

  def lose_hand_run(run)
    register(run)
    launch("agents", "HandRun.lose!", "to=#{run}", "session.value=s-#{run}", "role.value=coder",
           "reason.value=stopped", "--wait")
  end

  it "reaps at once when a hand run's registration ends, and frees the turn", :aggregate_failures do
    end_hand_run("h-end")
    expect(delivered("ReapWhenAHandRunEnds")).to eq(1)
    expect(delivered("FreeTheTurnWhenTheReapIsReported")).to eq(2)
  end

  it "reaps at once when a hand run's session is found stopped" do
    lose_hand_run("h-lost")
    expect(delivered("ReapWhenAHandRunIsLost")).to eq(1)
  end

  it "takes no turn for a hand run that is only registered" do
    register("h-standing")
    expect(delivered("ReapWhenTheTurnIsTaken")).to eq(1)
  end
end
