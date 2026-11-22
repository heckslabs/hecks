require "spec_helper"
require_relative "support/agents_message_helpers"

# A message has a kind, a channel and a priority, each declared in the Agents bluebook: the kind
# decides routing and whether a reply is expected, a channel names who it wakes, and every message
# is normal or urgent.
MESSAGE_KINDS = %w[help question answer check-in report stand-down owner].freeze

# The declared rows of the Message aggregate, read from the bluebook.
module MessageCatalog
  def message_catalog(name)
    root = File.join(InMemoryDomain::ROOT, "lib/hecks/agents")
    aggregate = Hecks.describe(root).registry.bluebooks.fetch("Agents").aggregates.find { |a| a.hecks_name == "Message" }
    aggregate.value_objects.find { |object| object.hecks_name == name }.members
  end
end

RSpec.describe "message kinds" do
  include AgentsMessageHelpers

  before { boot_messages }

  def sent_as(kind, **said) = send_message(key: "k-#{kind}", kind: kind, **said)

  it "admits each declared kind", :aggregate_failures do
    MESSAGE_KINDS.each { |kind| expect(sent_as(kind).status).to eq("sent") }
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

RSpec.describe "message channels and kind rules" do
  include MessageCatalog

  def rule(name, key, value) = message_catalog(name).to_h { |row| [row[key], row[value]] }

  it "declares a routing row for every kind" do
    expect(message_catalog("KindRule").map { |row| row[:kind] }).to match_array(MESSAGE_KINDS)
  end

  it "routes a help call to the help channel and a check-in to all" do
    expect(rule("KindRule", :kind, :route)).to include("help" => "help", "check-in" => "all", "question" => "direct")
  end

  it "expects a reply to a question and a help call but not to an answer" do
    expect(rule("KindRule", :kind, :reply_expected)).to include("question" => "true", "help" => "true", "answer" => "false")
  end

  it "declares the help channel as waking only the scrum master" do
    expect(rule("ChannelRule", :channel, :wakes)).to include("help" => "scrum-master", "all" => "", "train" => "")
  end
end
