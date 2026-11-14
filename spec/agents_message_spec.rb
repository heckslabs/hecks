require "spec_helper"
require_relative "support/agents_message_helpers"

# A message between sessions is a recorded event with an inbox: sent, listed for its run, read.
RSpec.describe "the Agents messages" do
  include AgentsMessageHelpers

  before { AgentsMemoryBoot.call }

  it "records a sent message as unread" do
    expect(send_message.status).to eq("sent")
  end

  it "lists a run's unread messages and no other run's", :aggregate_failures do
    send_message
    send_message(key: "m2", to: "run-b")
    expect(inbox("run-a")).to eq(["m1"])
    expect(inbox("run-b")).to eq(["m2"])
  end

  it "takes a read message out of the inbox", :aggregate_failures do
    expect(send_message.read!(reader: { value: "run-a" }).status).to eq("read")
    expect(inbox("run-a")).to be_empty
  end

  it "keeps the message a reply answers" do
    send_message
    expect(send_message(key: "m2", to: "orchestrator", kind: "report", reply: "m1").in_reply_to.value).to eq("m1")
  end
end
