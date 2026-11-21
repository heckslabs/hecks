require "spec_helper"
require_relative "support/agents_message_helpers"

# A message to a standing seat that has not registered waits, and registration releases it.
RSpec.describe "the Agents message hold" do
  include AgentsMessageHelpers

  before { boot_messages }

  def recipients = {}

  def hand_runs = nil

  def listed_sessions = ["134d89bd-full"]

  it "holds a message to a standing seat that has not registered" do
    expect(send_message(to: "miette").status).to eq("held")
  end

  it "still refuses a recipient that is no standing seat" do
    expect(send_message(to: "nobody").status).to eq("refused")
  end

  it "releases the held message when the seat registers", :aggregate_failures do
    send_message(to: "miette")
    register_hand(run: "miette", session: "134d89bd-full", role: "orchestrator-owner")
    expect(Hecks::Agents::Message.find("m1").status).to eq("sent")
    expect(inbox("miette")).to eq(["m1"])
  end
end
