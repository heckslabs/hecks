# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "hecks/roundhouse/adapters/metering"

# The turns the transcripts record: each counted once with its context and the label of what
# set it going, rolled up by the token report without the prompt text.
RSpec.describe Hecks::Adapters::Metering::TokenTranscripts do
  let(:dir) { Dir.mktmpdir }
  let(:secret) { "Outcome: the secret plan for the launch" }
  let(:rows) { described_class.new(projects: dir).call }

  def user(text, kind) = { type: "user", origin: { kind: kind }, message: { role: "user", content: text } }

  def reply(id, read)
    usage = { input_tokens: 1, output_tokens: 5, cache_creation_input_tokens: 2, cache_read_input_tokens: read }
    { type: "assistant", timestamp: "2026-11-21T10:00:00Z", message: { id: id, model: "claude-opus-5-5", usage: usage } }
  end

  before do
    Dir.mkdir(File.join(dir, "p"))
    lines = [user(secret, "human"), reply("m1", 100), reply("m1", 100),
             user("<task-notification>x", "task-notification"), reply("m2", 200)]
    File.write(File.join(dir, "p", "s1.jsonl"), lines.map { |line| JSON.generate(line) }.join("\n"))
  end

  after { FileUtils.remove_entry(dir) }

  it "counts each message once with the context it read in", :aggregate_failures do
    expect(rows.size).to eq(2)
    expect(rows.map { |row| row[:context] }).to eq([103, 203])
  end

  it "labels each turn by the prompt before it" do
    expect(rows.map { |row| row[:trigger] }).to eq(["user prompt", "task notification"])
  end

  it "never carries the prompt text out", :aggregate_failures do
    report = Hecks::Adapters::Metering::TokenReport.new(rows, {}).facts
    expect(JSON.generate(report)).not_to include("secret plan")
    expect(report[:total]).to include(turns: 2, context: 306, mean_context: 153, max_context: 203)
  end

  it "rolls the turns up by trigger, the dearest context first", :aggregate_failures do
    lines = Hecks::Adapters::Metering::TokenReport.new(rows, {}).facts[:by_trigger]
    expect(lines.map { |line| line["trigger"] }).to eq(["task notification", "user prompt"])
    expect(lines.first).to include(turns: 1, context: 203)
  end
end
