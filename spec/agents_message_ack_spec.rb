require "spec_helper"
require_relative "support/agents_message_helpers"

# An ack is delivered at the next natural boundary: it never wakes its session, opens no reply
# obligation, and is cleared once handed over.
RSpec.describe "the Agents message ack" do
  include AgentsMessageHelpers

  before { boot_messages }

  def undelivered = Hecks::Agents::Message.undelivered(recipient: { value: "run-a" }).map { |row| row[:message].value }

  def receive(key) = Hecks::Agents::Message.find(key).receive!(reader: { value: "run-a" })

  def heard_events = @agents_runtime.events.map { |event| event.respond_to?(:name) ? event.name : event[:name] }.map(&:to_s)

  it "is queued, not sent, so no session is woken", :aggregate_failures do
    ack = send_message(kind: "ack", body: "got it")
    expect(ack.status).to eq("queued")
    expect(heard_events).not_to include("MessageSent")
  end

  it "is handed over once at the next boundary" do
    send_message(kind: "ack", body: "got it")
    expect(undelivered).to eq(["m1"])
  end

  it "is read as soon as it is delivered, so it never waits in the inbox", :aggregate_failures do
    send_message(kind: "ack", body: "got it")
    receive("m1")
    expect(Hecks::Agents::Message.find("m1").status).to eq("read")
    expect(inbox("run-a")).to be_empty
  end

  it "leaves an ordinary message sent", :aggregate_failures do
    expect(send_message(kind: "question").status).to eq("sent")
    expect(heard_events).to include("MessageSent")
  end
end
