# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require_relative "../lib/hecks/hecks/adapters/claude_transcript"

# The pipeline's own answers are not a person: a turn that starts with the mark `ClaudeResumption`
# writes does not make a session taken over, and the owner typing still does.
RSpec.describe Hecks::Adapters::ClaudeTranscript, "#taken_over? pipeline answers" do
  let(:projects) { Dir.mktmpdir("transcripts") }
  let(:reader) { described_class.new(projects: projects) }
  let(:mark) { described_class::PIPELINE_MARK }

  after { FileUtils.rm_rf(projects) }

  def write(entries)
    FileUtils.mkdir_p(File.join(projects, "p"))
    File.write(File.join(projects, "p", "abc.jsonl"), entries.map { |entry| JSON.generate(entry) }.join("\n"))
  end

  def human(content) = { type: "user", origin: { kind: "human" }, message: { content: content } }
  def answer = human("#{mark}the verdict is sound")

  it "does not count the pipeline's own answer as a person" do
    write([human("brief"), answer, answer])

    expect(reader.taken_over?("abc")).to be(false)
  end

  it "still counts the owner typing after the pipeline answered" do
    write([human("brief"), answer, human("stop, do it my way")])

    expect(reader.taken_over?("abc")).to be(true)
  end

  it "reads a marked answer given as text parts" do
    write([human("brief"), human([{ type: "text", text: "#{mark}ok" }])])

    expect(reader.taken_over?("abc")).to be(false)
  end
end
