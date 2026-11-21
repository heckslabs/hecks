require "spec_helper"
require_relative "support/agents_message_helpers"

# A session the owner started by hand registers under a run key (`HandRun.register!`), and a
# message to that key is sent while `claude agents` lists the session.
RSpec.describe "a hand-started session registered as a run" do
  include AgentsMessageHelpers

  before { boot_messages }

  def recipients = {}

  def listed_sessions = ["134d89bd-full"]

  it "registers the session under its run key" do
    register_hand
    expect(Hecks::Agents::HandRun.find("owner-orchestrator").session.value).to eq("134d89bd-full")
  end

  it "keeps the newest session under the key when registered again" do
    2.times { register_hand }
    register_hand(session: "restarted")
    expect(Hecks::Agents::HandRun.find("owner-orchestrator").session.value).to eq("restarted")
  end

  it "delivers to the newest session after a restart" do
    register_hand(session: "gone")
    register_hand
    expect(send_message(to: "owner-orchestrator").status).to eq("sent")
  end

  it "delivers a message to the registered run's inbox" do
    register_hand
    send_message(to: "owner-orchestrator")
    expect(inbox("owner-orchestrator")).to eq(["m1"])
  end

  it "refuses a registered run whose session is not listed" do
    register_hand(session: "gone")
    expect(send_message(to: "owner-orchestrator").refusal.value).to end_with("session gone is not listed by claude agents")
  end

  it "still refuses a run key nobody registered" do
    expect(send_message(to: "owner-orchestrator").status).to eq("refused")
  end

  it "names the registered keys when it refuses an unknown run" do
    register_hand
    expect(send_message(to: "nobody").refusal.value).to end_with("registered hand runs: owner-orchestrator")
  end

  it "leaves an archived key out of the names it gives" do
    2.times { register_hand }
    expect(send_message(to: "nobody").refusal.value).not_to include("~")
  end

  it "says no hand run is registered when none is" do
    expect(send_message(to: "nobody").refusal.value).to end_with("no hand run is registered")
  end
end
