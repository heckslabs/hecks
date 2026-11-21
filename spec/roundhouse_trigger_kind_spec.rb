# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "hecks/roundhouse/adapters/metering"

# What set each turn going: the declared trigger rows label a prompt, and the report counts turns,
# context and trigger without the prompt text.
RSpec.describe Hecks::Adapters::Metering::TriggerKinds do
  let(:notice) { "<task-notification>\n<task-id>b1</task-id>\n</task-notification>" }

  it "labels a known notification" do
    expect(described_class.label(notice)).to eq("task notification")
  end

  it "labels a known prompt a person typed" do
    expect(described_class.label("Outcome: count the turns", typed: true)).to eq("user prompt")
  end

  it "labels a pipeline answer and a hook feedback", :aggregate_failures do
    expect(described_class.label("[pipeline answer] Your review's verdict")).to eq("pipeline answer")
    expect(described_class.label("Stop hook feedback:\n[command hook 2]")).to eq("hook feedback")
  end

  it "labels a prompt no row matches as other when no person typed it" do
    expect(described_class.label("Shell cwd was reset")).to eq("other")
  end

  it "declares each label once", :aggregate_failures do
    expect(described_class.labels.uniq).to eq(described_class.labels)
    expect(described_class.labels.last(2)).to eq(["user prompt", "other"])
  end
end
