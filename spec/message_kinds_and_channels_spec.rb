require "spec_helper"
require_relative "support/agents_message_helpers"

# A message has a kind, a channel and a priority, each declared in the Agents bluebook: the kind
# decides routing and whether a reply is expected, a channel names who it wakes, and every message
# is normal or urgent.
RSpec.describe "message kinds" do
  include AgentsMessageHelpers

  let(:kinds) { %w[help question answer check-in report stand-down owner] }

  before { boot_messages }

  def sent_as(kind, **said) = send_message(key: "k-#{kind}", kind: kind, **said)

  it "admits each declared kind", :aggregate_failures do
    kinds.each { |kind| expect(sent_as(kind).status).to eq("sent") }
  end

  it "refuses a kind it does not declare" do
    expect { sent_as("brief-change") }.to raise_error(/MessageKind admits/)
  end

  it "is normal unless sent urgent", :aggregate_failures do
    expect(sent_as("question").priority.value).to eq("normal")
    expect(sent_as("help", priority: "urgent", to: "run-b").priority.value).to eq("urgent")
  end

  it "refuses a priority and a channel it does not declare", :aggregate_failures do
    expect { sent_as("question", priority: "loud") }.to raise_error(/Priority admits/)
    expect { sent_as("question", channel: "random") }.to raise_error(/Channel admits/)
  end
end
