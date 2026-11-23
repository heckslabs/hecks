require "spec_helper"

# Each message kind decides its routing and whether a reply is expected, and each channel names who
# it wakes: declared as rows of the Message aggregate in the Agents bluebook.

RSpec.describe "message channels and kind rules" do
  let(:kinds) { %w[help question answer check-in report stand-down owner person] }
  let(:root) { File.join(InMemoryDomain::ROOT, "lib/hecks/agents") }
  let(:message) { Hecks.describe(root).registry.bluebooks.fetch("Agents").aggregates.find { |a| a.hecks_name == "Message" } }

  def message_catalog(name) = message.value_objects.find { |object| object.hecks_name == name }.members

  def rule(name, key, value) = message_catalog(name).to_h { |row| [row[key], row[value]] }

  it "declares a routing row for every kind" do
    expect(message_catalog("KindRule").map { |row| row[:kind] }).to match_array(kinds)
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
