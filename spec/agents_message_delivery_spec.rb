require "spec_helper"
require_relative "support/agents_message_helpers"

# A sent message is handed to its run's session once: the hook reads `Undelivered`, records each
# message delivered with `Receive`, and the run answers the sender with a message of its own.
RSpec.describe "the Agents message delivery" do
  include AgentsMessageHelpers

  before { boot_messages }

  def receive(key) = Hecks::Agents::Message.find(key).receive!(reader: { value: "run-a" })

  def undelivered = Hecks::Agents::Message.undelivered(recipient: { value: "run-a" }).map { |row| row[:message].value }

  it "lists a sent message as undelivered" do
    send_message
    expect(undelivered).to eq(["m1"])
  end

  it "marks a received message delivered and hands it over only once", :aggregate_failures do
    send_message
    receive("m1")
    expect(Hecks::Agents::Message.find("m1").status).to eq("delivered")
    expect(undelivered).to be_empty
  end

  it "keeps a delivered message in the inbox until it is read", :aggregate_failures do
    send_message
    receive("m1")
    expect(inbox("run-a")).to eq(["m1"])
    Hecks::Agents::Message.find("m1").read!(reader: { value: "run-a" })
    expect(inbox("run-a")).to be_empty
  end

  it "reaches the sender with the run's reply" do
    send_message
    reply = send_message(key: "m2", to: "orchestrator", kind: "report", body: "done", reply: "m1")
    expect([reply.status, inbox("orchestrator")]).to eq(["sent", ["m2"]])
  end
end
