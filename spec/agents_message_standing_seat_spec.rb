require "spec_helper"
require_relative "support/agents_message_helpers"

# Mail to a standing seat's name that no run answers reaches the live session holding that seat,
# and a message held for a seat names who may hold it and why.
RSpec.describe "the Agents message to a standing seat" do
  include AgentsMessageHelpers

  before { boot_messages }

  def recipients = { "orchestrator" => { status: "finished", session: "d0e5" } }

  def listed_sessions = ["1ead-full"]

  def register_lead = register_hand(run: "lead", session: "1ead-full", role: "lead")

  it "sends mail to orchestrator to the live lead seat", :aggregate_failures do
    register_lead
    expect(send_message(to: "orchestrator").status).to eq("sent")
    expect(inbox("lead")).to eq(["m1"])
  end

  it "keeps the tidied orchestrator run's inbox empty" do
    register_lead
    send_message(to: "orchestrator")
    expect(inbox("orchestrator")).to be_empty
  end

  it "holds mail to a seat nobody holds, naming the seat and who will hold it", :aggregate_failures do
    held = send_message(to: "orchestrator")
    expect(held.status).to eq("held")
    expect(held.held_for.value).to include("held for orchestrator", "until lead registers")
  end

  it "does not redirect mail to a role that is no standing seat" do
    register_hand(run: "coder-1", session: "1ead-full", role: "coder")
    expect(send_message(to: "coder").status).to eq("refused")
  end
end
