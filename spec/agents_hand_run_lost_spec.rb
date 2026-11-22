require "spec_helper"
require_relative "support/agents_hand_run_watch_helpers"

# A hand-started run whose session dies is recorded as lost each beat, a pinned one is restarted
# under its run key and registered to its new session, and any other has its registration ended.
RSpec.describe "a hand-started run that dies" do
  include AgentsHandRunWatchHelpers

  before { boot_watch }

  def lead_dead = sessions.replace([session_entry("1ead-old-full", "lead", "stopped")])

  def lead_back = sessions.replace([session_entry("1ead-new-full", "lead", "working")])

  def register_lead = register_hand(run: "lead", session: "1ead-old-full", role: "orchestrator-owner")

  it "records a registered run whose session reads stopped as lost" do
    register_lead
    lead_dead
    beat("b1")
    expect(hand("lead").status).to eq("lost")
  end

  it "restarts a lost pinned run under its run key", :aggregate_failures do
    register_lead
    lead_dead
    beat("b1")
    expect(shell.commands.first[:command]).to eq(%w[claude --bg --resume 1ead-old-full -n lead])
  end

  def restart_lead
    register_lead
    lead_dead
    beat("b1")
    lead_back
    beat("b2")
  end

  it "registers the restarted run to its new session" do
    restart_lead
    expect(hand("lead").session.value).to eq("1ead-new-full")
  end

  it "delivers mail to lead once it is registered to its new session" do
    restart_lead
    expect(send_message(to: "lead").status).to eq("sent")
  end

  def lead_beside_a_zombie
    register_lead
    lead_dead
    beat("b1")
    sessions << session_entry("1ead-zombie-full", "lead", "stopped")
    beat("b2")
  end

  it "does not take another stopped session under the run key for the restart" do
    lead_beside_a_zombie
    expect(hand("lead").status).to eq("lost")
  end

  it "never reads a busy or idle session as dead" do
    register_lead
    sessions.replace([session_entry("1ead-old-full", "lead", "working")])
    beat("b1")
    expect(hand("lead").status).to eq("registered")
  end

  it "leaves a replaced registration of a live run alone" do
    register_lead
    register_hand(run: "lead", session: "1ead-new-full", role: "orchestrator-owner")
    lead_back
    beat("b1")
    expect(hand("lead").status).to eq("registered")
  end

  it "ends the registration of a lost run that is not pinned" do
    register_hand(run: "coder-1", session: "c0de-full", role: "coder")
    sessions.replace([session_entry("c0de-full", "coder-1", "failed")])
    beat("b1")
    expect(hand("coder-1").status).to eq("ended")
  end

  it "ends a pinned run whose session is no longer listed, since nothing can be resumed" do
    register_lead
    beat("b1")
    expect(hand("lead").status).to eq("ended")
  end
end
