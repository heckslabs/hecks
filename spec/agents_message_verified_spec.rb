require "spec_helper"
require_relative "support/agents_message_helpers"

# A delivered message says whether its sender is who it claims: the system stamps `verified` from
# the sending session's registration, and the sender's own words never set it.
RSpec.describe "the Agents message sender" do
  include AgentsMessageHelpers

  before { boot_messages }

  def recipients = { "run-a" => live_run, "orchestrator" => live_run, "run-done" => { status: "finished", session: "" } }

  attr_reader :sending_session

  def verified_for(session, sender: "orchestrator")
    @sending_session = session
    send_message(sender: sender).verified.value
  end

  it "shows a message from the session registered as its sender as verified" do
    expect(verified_for("5e55-full-id")).to eq("true")
  end

  it "shows a message whose sender text is forged as unverified" do
    expect(verified_for("ffff-another-session")).to eq("false")
  end

  it "shows a message from a session that registered no run as unverified" do
    expect(verified_for(nil)).to eq("false")
  end

  it "answers a message to a tidied run as refused, with the reason", :aggregate_failures do
    sent = send_message(to: "run-done")
    expect(sent.status).to eq("refused")
    expect(sent.refusal.value).to include("the run run-done has no live session (finished)")
  end

  it "hands a recipient's inbox the verified mark with each message" do
    @sending_session = "5e55"
    send_message
    expect(Hecks::Agents::Message.inbox(recipient: { value: "run-a" }).map { |row| row[:verified].value }).to eq(["true"])
  end
end
