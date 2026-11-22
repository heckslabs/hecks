require "spec_helper"
require_relative "support/agents_message_helpers"

# Mail to a name no live session answers to says who to address: a refusal names the live seats
# that fill the role, and a held message says who holds it and why.
RSpec.describe "the Agents message to a name with no live session" do
  include AgentsMessageHelpers

  before do
    boot_messages
    register_hand(run: "lead", session: "1ead-full", role: "lead")
    register_hand(run: "coder-1", session: "c0de-full", role: "coder")
  end

  def recipients = {}

  def listed_sessions = %w[1ead-full c0de-full]

  it "holds mail to orchestrator when two seats are live, naming both and why", :aggregate_failures do
    register_hand(run: "lead-2", session: "c0de-full", role: "lead")
    sent = send_message(to: "orchestrator", sender: "run-a")
    expect(sent.status).to eq("held")
    expect(sent.held_for.value).to include("no run has that id: orchestrator").and include("live holders: lead, lead-2")
  end

  it "refuses mail to a role, naming the live seats that fill it" do
    expect(send_message(to: "coder", sender: "run-a").refusal.value).to end_with("live holders: coder-1")
  end

  it "names no holder when none is live", :aggregate_failures do
    refused = send_message(to: "nobody", sender: "run-a")
    expect(refused.status).to eq("refused")
    expect(refused.refusal.value).not_to include("live holders")
  end
end
