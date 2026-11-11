# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../lib/hecks/hecks/adapters/claude_transcript"

# What `#reading` reports for `AgentRun.Tidy` to name: how the transcript read and how many turns a
# person typed after the brief.
RSpec.describe Hecks::Adapters::ClaudeTranscript, "#reading" do
  let(:projects) { Dir.mktmpdir("transcripts") }
  let(:reader) { described_class.new(projects: projects) }
  let(:mark) { described_class::PIPELINE_MARK }

  after { FileUtils.rm_rf(projects) }

  def write(text)
    FileUtils.mkdir_p(File.join(projects, "p"))
    File.write(File.join(projects, "p", "abc.jsonl"), text)
  end

  def turn(text) = JSON.generate(type: "user", origin: { kind: "human" }, message: { content: text })

  it "counts no person turn when only pipeline answers follow the brief" do
    write([turn("brief"), turn("#{mark}sound")].join("\n"))

    expect(reader.reading("abc")).to eq(state: :read, person_turns: 0)
  end

  it "counts the owner's typed turn" do
    write([turn("brief"), turn("#{mark}sound"), turn("do it my way")].join("\n"))

    expect(reader.reading("abc")).to eq(state: :read, person_turns: 1)
  end

  it "says the transcript is missing" do
    expect(reader.reading("absent")).to include(state: :missing)
  end

  it "says the transcript cannot be read" do
    write("{not json")

    expect(reader.reading("abc")).to include(state: :unreadable)
  end
end
