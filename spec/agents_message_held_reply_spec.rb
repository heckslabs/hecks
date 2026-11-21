require "spec_helper"
require_relative "support/agents_message_helpers"

# A reply to a hand-started sender (miette, the orchestrator, the staff engineer) is held unread
# for it instead of refused as unaddressable.
RSpec.describe "a reply to a hand-started sender" do
  include AgentsMessageHelpers

  before { boot_messages }

  def recipients = { "run-a" => live_run }

  def hear_from(sender)
    Hecks::Agents::Message.send!(message: { value: "q1" }, recipient: { value: "run-a" }, sender: { value: sender },
                                 kind: { value: "question" }, body: { value: "which?" }, in_reply_to: { value: "" })
  end

  it "is held for the sender, not refused", :aggregate_failures do
    hear_from("miette")
    expect(send_message(key: "r1", to: "miette", reply: "q1", sender: "run-a").status).to eq("sent")
    expect(inbox("miette")).to eq(["r1"])
  end

  it "still refuses a recipient that never sent anything" do
    expect(send_message(key: "r2", to: "nobody").status).to eq("refused")
  end
end
