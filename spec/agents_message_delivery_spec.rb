require "spec_helper"
require_relative "support/agents_message_helpers"

# A sent message is handed to its run's session once: the hook reads `Undelivered`, records each
# message with `Receive`, which marks it read, and the run answers the sender with a message of its own.
RSpec.describe "the Agents message delivery" do
  include AgentsMessageHelpers

  before { boot_messages }

  def receive(key) = Hecks::Agents::Message.find(key).receive!(reader: { value: "run-a" })

  def undelivered = Hecks::Agents::Message.undelivered(recipient: { value: "run-a" }).map { |row| row[:message].value }

  it "lists a sent message as undelivered" do
    send_message
    expect(undelivered).to eq(["m1"])
  end

  it "marks a message read once its session has been handed it", :aggregate_failures do
    send_message
    receive("m1")
    message = Hecks::Agents::Message.find("m1")
    expect([message.status, message.reader.value]).to eq(%w[read run-a])
    expect([undelivered, inbox("run-a")]).to eq([[], []])
  end

  it "refuses to hand over a message twice" do
    send_message
    receive("m1")
    expect { receive("m1") }.to raise_error(StandardError, /Receive/)
  end

  it "reaches the sender with the run's reply" do
    send_message
    reply = send_message(key: "m2", to: "orchestrator", kind: "report", body: "done", reply: "m1")
    expect([reply.status, inbox("orchestrator")]).to eq(["sent", ["m2"]])
  end
end
